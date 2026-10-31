//! What the matcher's threads share. Work is handed out in small items as
//! it becomes ready, never in fixed shares met at barriers: on a board whose
//! cores also run the BEAM and the compiled stages, a thread that loses its
//! core then delays only the item it holds.

use std::ops::Range;
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

/// A buffer several threads write, each in parts no other thread accesses
/// meanwhile.
pub struct Shared<T> {
    pointer: *mut T,
    len: usize,
}

// SAFETY: access goes through the unsafe methods, whose callers keep
// concurrent accesses disjoint.
unsafe impl<T: Send> Send for Shared<T> {}
unsafe impl<T: Send> Sync for Shared<T> {}

impl<T> Shared<T> {
    pub fn new(buffer: &mut [T]) -> Shared<T> {
        Shared {
            pointer: buffer.as_mut_ptr(),
            len: buffer.len(),
        }
    }

    /// # Safety
    /// No other thread may access `range` while the slice lives.
    #[allow(clippy::mut_from_ref)]
    pub unsafe fn slice_mut(&self, range: Range<usize>) -> &mut [T] {
        assert!(range.start <= range.end && range.end <= self.len);
        std::slice::from_raw_parts_mut(self.pointer.add(range.start), range.end - range.start)
    }

    /// # Safety
    /// No other thread may write `range` while the slice lives.
    pub unsafe fn slice(&self, range: Range<usize>) -> &[T] {
        assert!(range.start <= range.end && range.end <= self.len);
        std::slice::from_raw_parts(self.pointer.add(range.start), range.end - range.start)
    }
}

/// Hands out rows in blocks, so threads slowed by other work take fewer.
pub struct RowQueue {
    next: AtomicUsize,
    rows: usize,
}

const ROWS_PER_TAKE: usize = 4;

impl RowQueue {
    pub fn new(rows: usize) -> RowQueue {
        RowQueue {
            next: AtomicUsize::new(0),
            rows,
        }
    }

    pub fn take(&self) -> Option<Range<usize>> {
        let start = self.next.fetch_add(ROWS_PER_TAKE, Ordering::Relaxed);
        (start < self.rows).then(|| start..(start + ROWS_PER_TAKE).min(self.rows))
    }
}

/// Column chunks a sweep follows down (or up) the image, each claimed by
/// one thread at a time, with the number of rows each has done.
pub struct Chunks {
    columns: Vec<Range<usize>>,
    progress: Vec<AtomicUsize>,
    claimed: Vec<AtomicBool>,
}

/// Chunks per thread: enough for others to take over a slowed thread's share.
const CHUNKS_PER_THREAD: usize = 4;
const MIN_CHUNK_COLUMNS: usize = 16;

impl Chunks {
    pub fn new(width: usize, threads: usize) -> Chunks {
        let count = (threads * CHUNKS_PER_THREAD)
            .min(width / MIN_CHUNK_COLUMNS)
            .max(1);
        Chunks {
            columns: (0..count)
                .map(|chunk| width * chunk / count..width * (chunk + 1) / count)
                .collect(),
            progress: (0..count).map(|_| AtomicUsize::new(0)).collect(),
            claimed: (0..count).map(|_| AtomicBool::new(false)).collect(),
        }
    }

    pub fn count(&self) -> usize {
        self.columns.len()
    }

    pub fn columns(&self, chunk: usize) -> Range<usize> {
        self.columns[chunk].clone()
    }

    /// The rows `chunk` has done; what it did is visible once this is read.
    pub fn progress(&self, chunk: usize) -> usize {
        self.progress[chunk].load(Ordering::Acquire)
    }

    pub fn min_progress(&self) -> usize {
        (0..self.count())
            .map(|chunk| self.progress(chunk))
            .min()
            .unwrap_or(0)
    }

    /// Whether the calling thread now holds `chunk`.
    pub fn try_claim(&self, chunk: usize) -> bool {
        self.claimed[chunk]
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_ok()
    }

    /// Publishes the rows a held `chunk` has done.
    pub fn set_progress(&self, chunk: usize, rows: usize) {
        self.progress[chunk].store(rows, Ordering::Release);
    }

    pub fn release(&self, chunk: usize) {
        self.claimed[chunk].store(false, Ordering::Release);
    }
}

/// Waiting for work another thread is finishing: spins briefly, then
/// yields the core a few times, then sleeps, so the core goes to the
/// threads with work, this process's or another's.
#[derive(Default)]
pub struct Backoff {
    rounds: u32,
}

const SPIN_ROUNDS: u32 = 6;
const YIELD_ROUNDS: u32 = 4;
const SLEEP: Duration = Duration::from_micros(50);

impl Backoff {
    pub fn wait(&mut self) {
        if self.rounds < SPIN_ROUNDS {
            for _ in 0..1 << self.rounds {
                std::hint::spin_loop();
            }
        } else if self.rounds < SPIN_ROUNDS + YIELD_ROUNDS {
            std::thread::yield_now();
        } else {
            std::thread::sleep(SLEEP);
        }
        self.rounds = self.rounds.saturating_add(1);
    }

    pub fn reset(&mut self) {
        self.rounds = 0;
    }
}

/// A job's work with its borrows' lifetime erased: `on_threads` waits for
/// every worker to be done with it before it returns.
#[derive(Clone, Copy)]
struct Work(*const (dyn Fn(usize) + Sync));

// SAFETY: the work is `Sync` and outlives every use; see `on_threads`.
unsafe impl Send for Work {}

struct Job {
    generation: u64,
    threads: usize,
    work: Option<Work>,
    pending: usize,
    panicked: bool,
}

/// Worker threads, parked between jobs.
struct Pool {
    job: Mutex<Job>,
    started: Condvar,
    finished: Condvar,
    /// Held by a job's caller until the job is done; counts the workers.
    workers: Mutex<usize>,
}

static POOL: Pool = Pool {
    job: Mutex::new(Job {
        generation: 0,
        threads: 0,
        work: None,
        pending: 0,
        panicked: false,
    }),
    started: Condvar::new(),
    finished: Condvar::new(),
    workers: Mutex::new(0),
};

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn worker(index: usize) {
    let mut seen = 0;
    loop {
        let work = {
            let mut job = lock(&POOL.job);
            while job.generation == seen {
                job = POOL
                    .started
                    .wait(job)
                    .unwrap_or_else(PoisonError::into_inner);
            }
            seen = job.generation;
            match job.work {
                Some(work) if index < job.threads => work,
                _ => continue,
            }
        };
        // SAFETY: the job's caller waits for this worker before `work` ends.
        let run = AssertUnwindSafe(|| unsafe { (*work.0)(index) });
        let panicked = std::panic::catch_unwind(run).is_err();
        let mut job = lock(&POOL.job);
        job.panicked |= panicked;
        job.pending -= 1;
        if job.pending == 0 {
            POOL.finished.notify_all();
        }
    }
}

/// Waits for the current job's workers, also while unwinding.
struct Finish;

impl Drop for Finish {
    fn drop(&mut self) {
        let mut job = lock(&POOL.job);
        while job.pending > 0 {
            job = POOL
                .finished
                .wait(job)
                .unwrap_or_else(PoisonError::into_inner);
        }
        job.work = None;
        if std::mem::take(&mut job.panicked) && !std::thread::panicking() {
            panic!("a worker thread panicked");
        }
    }
}

/// Runs `work(thread)` on `threads` threads: the calling one as thread 0,
/// the others from a pool kept from one call to the next. Calls from
/// several threads run one at a time; `work` must not call it.
pub fn on_threads<F: Fn(usize) + Sync>(threads: usize, work: &F) {
    if threads <= 1 {
        work(0);
        return;
    }
    let mut workers = lock(&POOL.workers);
    while *workers < threads - 1 {
        *workers += 1;
        let index = *workers;
        std::thread::Builder::new()
            .name(format!("stereo_match {index}"))
            .spawn(move || worker(index))
            .expect("a worker thread");
    }
    let work: &(dyn Fn(usize) + Sync) = work;
    // SAFETY: only the lifetime changes, and `Finish` waits for every
    // worker to be done with `work` before this returns or unwinds.
    let work = Work(unsafe {
        std::mem::transmute::<*const (dyn Fn(usize) + Sync + '_), *const (dyn Fn(usize) + Sync)>(
            work,
        )
    });
    {
        let mut job = lock(&POOL.job);
        job.generation += 1;
        job.threads = threads;
        job.work = Some(work);
        job.pending = threads - 1;
        POOL.started.notify_all();
    }
    let _finish = Finish;
    // SAFETY: as above.
    unsafe { (*work.0)(0) };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_queue_hands_out_every_row_once() {
        let queue = RowQueue::new(10);
        let mut rows = Vec::new();
        while let Some(range) = queue.take() {
            rows.extend(range);
        }
        assert_eq!(rows, (0..10).collect::<Vec<_>>());
    }

    #[test]
    fn chunks_cover_the_width_once_and_are_held_by_one_thread() {
        let chunks = Chunks::new(100, 2);
        assert_eq!(chunks.count(), 6);
        let covered: Vec<usize> = (0..chunks.count())
            .flat_map(|chunk| chunks.columns(chunk))
            .collect();
        assert_eq!(covered, (0..100).collect::<Vec<_>>());
        assert!(chunks.try_claim(3));
        assert!(!chunks.try_claim(3));
        chunks.release(3);
        assert!(chunks.try_claim(3));
        assert_eq!(Chunks::new(10, 4).count(), 1);
    }
}
