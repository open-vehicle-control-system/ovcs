use framing::{frame_record, log_record, metadata_record, LogLevel, Writer};

fn main() -> std::io::Result<()> {
    let writer = Writer::from_stdout_redirecting()?;
    writer.write_record(&frame_record(
        640,
        480,
        123_456_789,
        &[0xff, 0xd8, 0xff, 0xd9],
    ))?;
    writer.write_record(&log_record(LogLevel::Warning, "hello"))?;
    let values = [1000.0, 2.5, 1.0, 1.5, 33333.0, 4500.0, 1.0, 250.0];
    writer.write_record(&metadata_record(987_654_321, 0b0101_0101, &values))?;
    Ok(())
}
