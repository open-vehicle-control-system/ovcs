//! What the QNN Ports share: their command line and start, the opening of their model, and
//! the loop that reads requests and writes their replies, timing each stage.

use std::io::Read;
use std::os::fd::AsFd;
use std::process::exit;
use std::time::Instant;

use framing::{log_record, LogLevel, Writer};

use crate::stage_times::Stage;
use crate::{
    CommandLine, Model, Power, StageTimes, TimeLog, Timing, EXECUTION_STAGES, STAGE_TIMES_EVERY,
};

/// Room asked for in the request pipe, which the BEAM then fills in fewer turns with the Port.
const REQUEST_PIPE_BYTES: usize = 4 << 20;

/// The longest request taken: above any camera's whole RGB frame.
const MAX_REQUEST_BYTES: usize = 64 << 20;

/// What a Port serves with: its own positional arguments, the power vote, and the writer of
/// its records.
pub struct Start {
    pub arguments: Vec<String>,
    pub power: Power,
    pub writer: Writer,
}

pub fn log(writer: &Writer, level: LogLevel, message: &str) {
    let _ = writer.write_record(&log_record(level, message));
}

/// A failure before stdout carries records goes to stderr.
pub fn exit_early(name: &str, message: &str, status: i32) -> ! {
    eprintln!("{name}: {message}");
    exit(status)
}

/// Reads the command line of the Port `name`: answers `--graph-names` and exits, exits with
/// `usage` on one it cannot read, and otherwise points stdout at stderr for the libraries and
/// reports panics as LOG records.
pub fn start(name: &str, usage: &str) -> Start {
    let command_line: Vec<String> = std::env::args().skip(1).collect();
    let (arguments, power) = match crate::command_line(&command_line) {
        Ok(CommandLine::GraphNames(dlc)) => match crate::print_dlc_graph_names(dlc) {
            Ok(()) => exit(0),
            Err(message) => exit_early(name, &message, 1),
        },
        Ok(CommandLine::Serve { arguments, power }) => (arguments.to_vec(), power),
        Err(message) => exit_early(name, &format!("{message}; {usage}"), 2),
    };
    // Before any QNN call: its libraries may log onto stdout.
    let writer = match Writer::from_stdout_redirecting() {
        Ok(writer) => writer,
        Err(error) => exit_early(name, &format!("stdout: {error}"), 1),
    };
    writer.log_panics();
    Start {
        arguments,
        power,
        writer,
    }
}

/// Enlarges the request pipe, then opens the context binary at `context_path` under
/// `power`, logging the pipe's size and the vote's outcome.
pub fn open_model(context_path: &str, power: Power, writer: &Writer) -> Result<Model, String> {
    match framing::enlarge_pipe(std::io::stdin().as_fd(), REQUEST_PIPE_BYTES) {
        Ok(bytes) => log(
            writer,
            LogLevel::Info,
            &format!("request pipe: {bytes} bytes"),
        ),
        Err(error) => log(
            writer,
            LogLevel::Warning,
            &format!("request pipe not enlarged: {error}"),
        ),
    }
    let binary = std::fs::read(context_path).map_err(|e| format!("{context_path}: {e}"))?;
    let model = Model::open(&binary, power)?;
    match power.outcome(model.power_vote_error.as_deref()) {
        Ok(line) => log(writer, LogLevel::Info, &line),
        Err(line) => log(writer, LogLevel::Warning, &line),
    }
    Ok(model)
}

/// Logs what an execution's first profile holds, once, and what its time measures
/// (`TimeLog`).
pub fn log_execution(writer: &Writer, model: &mut Model, time_log: &mut TimeLog, timing: &Timing) {
    if let Some(report) = model.take_profile_report() {
        log(
            writer,
            LogLevel::Info,
            &format!("first execution's profile events: {report}"),
        );
    }
    if let Some(message) = time_log.message(timing.source, model.profile_error.as_deref()) {
        log(writer, LogLevel::Info, &message);
    }
}

/// A Port's stage times, logged every minute: a request's wait and read, the Port's
/// preparation of the model's input, the execution's stages, what the Port finishes the reply
/// with, and the reply's write. Each stage runs from the one before it.
pub struct Clock {
    times: StageTimes,
    mark: Instant,
    idle: Stage,
    read: Stage,
    prepare: Stage,
    execution: [Stage; 6],
    finish: Stage,
    reply: Stage,
}

impl Clock {
    /// A clock started at `now`, the Port's own two stages named `prepare` and `finish`.
    pub fn new(prepare: &'static str, finish: &'static str, now: Instant) -> Clock {
        let [graph_execute, execute, host_rpc, htp_rpc, htp, profile_read] = EXECUTION_STAGES;
        let names = [
            "idle",
            "read",
            prepare,
            graph_execute,
            execute,
            host_rpc,
            htp_rpc,
            htp,
            profile_read,
            finish,
            "reply",
        ];
        let (times, [idle, read, prepare, e0, e1, e2, e3, e4, e5, finish, reply]) =
            StageTimes::new(names, STAGE_TIMES_EVERY, now);
        Clock {
            times,
            mark: now,
            idle,
            read,
            prepare,
            execution: [e0, e1, e2, e3, e4, e5],
            finish,
            reply,
        }
    }

    fn lap(&mut self, stage: Stage) {
        self.times.lap(stage, &mut self.mark);
    }

    /// The model's input is ready.
    pub fn prepared(&mut self) {
        self.lap(self.prepare);
    }

    /// The model ran, in `timing`; the finish stage starts now.
    pub fn executed(&mut self, timing: &Timing) {
        timing.add_to(&mut self.times, &self.execution);
        self.mark = Instant::now();
    }

    /// The reply is ready.
    pub fn finished(&mut self) {
        self.lap(self.finish);
    }
}

/// Answers the requests `input` brings until it closes, each record with the reply `answer`
/// gives it, written to `writer`; a record `answer` gives none for is skipped with a warning.
/// `Err` is a failed read.
pub fn serve<R: Read>(
    input: &mut R,
    writer: &Writer,
    clock: &mut Clock,
    mut answer: impl FnMut(&[u8], &mut Clock) -> Option<Vec<u8>>,
) -> Result<(), String> {
    let mut record = Vec::new();
    let failed = |error: std::io::Error| format!("reading a request: {error}");
    loop {
        let Some(length) = framing::read_length(input, MAX_REQUEST_BYTES).map_err(failed)? else {
            return Ok(());
        };
        clock.lap(clock.idle);
        if !framing::read_body_into(input, length, &mut record).map_err(failed)? {
            return Ok(());
        }
        clock.lap(clock.read);
        let Some(reply) = answer(&record, clock) else {
            let skipped = format!(
                "skipped a record of {} bytes that is no request",
                record.len()
            );
            log(writer, LogLevel::Warning, &skipped);
            continue;
        };
        // The host closed the Port: nothing reads a log either.
        if writer.write_record(&reply).is_err() {
            return Ok(());
        }
        clock.lap(clock.reply);
        clock.times.count_request();
        if let Some(line) = clock.times.line(clock.mark) {
            log(writer, LogLevel::Info, &line);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::os::fd::OwnedFd;
    use std::os::unix::net::UnixStream;

    use super::*;

    // A writer and the end its records are read from.
    fn writer() -> (Writer, File) {
        let (written, read) = UnixStream::pair().unwrap();
        (
            Writer::from_file(File::from(OwnedFd::from(written))),
            File::from(OwnedFd::from(read)),
        )
    }

    fn framed(records: &[&[u8]]) -> Vec<u8> {
        (records.iter())
            .flat_map(|record| [&(record.len() as u32).to_be_bytes()[..], record].concat())
            .collect()
    }

    // The records `serve` writes for `input`, each request answered with its bytes doubled,
    // one starting with 0 skipped.
    fn served(mut input: impl Read) -> (Result<(), String>, Vec<Vec<u8>>) {
        let (writer, mut written) = writer();
        let mut clock = Clock::new("resize", "argmax", Instant::now());
        let outcome = serve(&mut input, &writer, &mut clock, |record, clock| {
            clock.prepared();
            clock.finished();
            (record[0] != 0).then(|| record.iter().map(|byte| byte * 2).collect())
        });
        drop(writer);
        let mut records = Vec::new();
        while let Some(record) = framing::read_record(&mut written, 1 << 10).unwrap() {
            records.push(record);
        }
        (outcome, records)
    }

    #[test]
    fn each_request_is_answered_in_order_until_the_input_closes() {
        let (outcome, records) = served(&framed(&[&[1, 2], &[3]])[..]);
        assert_eq!(outcome, Ok(()));
        assert_eq!(records, [vec![2, 4], vec![6]]);
    }

    #[test]
    fn a_record_that_is_no_request_is_skipped_with_a_warning() {
        let (outcome, records) = served(&framed(&[&[0, 9], &[3]])[..]);
        assert_eq!(outcome, Ok(()));
        let warning = log_record(
            LogLevel::Warning,
            "skipped a record of 2 bytes that is no request",
        );
        assert_eq!(records, [warning, vec![6]]);
    }

    #[test]
    fn a_request_cut_short_ends_the_loop_as_a_closed_input_does() {
        let cut = &framed(&[&[1, 2], &[3, 4, 5]])[..10];
        let (outcome, records) = served(cut);
        assert_eq!(outcome, Ok(()));
        assert_eq!(records, [vec![2, 4]]);
    }

    // One request, then a read that fails.
    struct Broken(&'static [u8]);

    impl Read for Broken {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if self.0.is_empty() {
                return Err(std::io::Error::other("input gone"));
            }
            self.0.read(buffer)
        }
    }

    #[test]
    fn a_failed_read_ends_the_loop_with_its_error() {
        let (outcome, records) = served(Broken(&[0, 0, 0, 1, 7]));
        assert_eq!(outcome, Err("reading a request: input gone".to_string()));
        assert_eq!(records, [vec![14]]);
    }

    #[test]
    fn the_stage_line_names_the_ports_stages_around_the_executions() {
        let start = Instant::now();
        let mut clock = Clock::new("letterbox", "decode", start);
        clock.times.count_request();
        assert_eq!(
            clock.times.line(start + STAGE_TIMES_EVERY).as_deref(),
            Some(
                "last 60 s: 1 requests, us each: idle none, read none, letterbox none, \
                 graphExecute none, QNN execute none, host RPC none, HTP RPC none, HTP none, \
                 profile read none, decode none, reply none"
            )
        );
    }
}
