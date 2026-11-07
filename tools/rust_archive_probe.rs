// Local research adapter to the pinned GPL-3.0-or-later msg-tool library.
// No parser algorithm is copied here. No archive writer or filesystem extraction API.
// Binary stdout is a PRIVATE pipe to verify_gpl_archive.py, never a user-facing log.
use msg_tool::scripts::base::Script;
use msg_tool::scripts::qlie::archive::pack::QliePackArchive;
use msg_tool::types::{Encoding, ExtraConfig};
use serde_json::{json, Value};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::FromRawFd;

const MEMBER_LIMIT: u64 = 16 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 128 * 1024 * 1024;
const INPUT_LIMIT: u64 = 1024 * 1024;

#[derive(Debug)]
struct RestrictedReader {
    file: File,
    spans: Vec<(u64, u64)>,
    pos: u64,
    size: u64,
    read_bytes: u64,
    seeks: u64,
}
impl Read for RestrictedReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() || self.pos == self.size { return Ok(0); }
        let end = self.spans.iter().filter(|(a,b)| *a <= self.pos && self.pos < *b)
            .map(|(_, b)| *b).max().ok_or_else(|| io::Error::other("read_span_refused"))?;
        let count = (buf.len() as u64).min(end-self.pos).min(64*1024*1024-self.read_bytes) as usize;
        if count == 0 { return Err(io::Error::other("read_budget")); }
        let got = self.file.read(&mut buf[..count])?;
        self.pos += got as u64;
        self.read_bytes += got as u64;
        Ok(got)
    }
}
impl Seek for RestrictedReader {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        self.seeks += 1;
        if self.seeks > 1_000_000 { return Err(io::Error::other("seek_budget")); }
        let target = match from { SeekFrom::Start(n) => n as i128,
            SeekFrom::End(n) => self.size as i128+n as i128,
            SeekFrom::Current(n) => self.pos as i128+n as i128 };
        if target < 0 || target > self.size as i128 { return Err(io::Error::other("seek_range")); }
        self.pos = self.file.seek(SeekFrom::Start(target as u64))?;
        Ok(self.pos)
    }
}
fn number(value: &Value, key: &str) -> Result<u64, &'static str> {
    value[key].as_u64().ok_or("invalid_request_number")
}
fn frame(out: &mut impl Write, value: Value) -> Result<(), &'static str> {
    let data = serde_json::to_vec(&value).map_err(|_| "json_encode")?;
    if data.len() > 8*1024*1024 { return Err("metadata_output_limit"); }
    out.write_all(&(data.len() as u32).to_le_bytes()).map_err(|_| "pipe_write")?;
    out.write_all(&data).map_err(|_| "pipe_write")
}
fn run() -> Result<(), &'static str> {
    let fd: i32 = std::env::args().nth(1).ok_or("missing_fd")?.parse().map_err(|_| "invalid_fd")?;
    if fd < 3 { return Err("invalid_fd"); }
    let mut bytes = Vec::new();
    io::stdin().take(INPUT_LIMIT+1).read_to_end(&mut bytes).map_err(|_| "request_read")?;
    if bytes.len() as u64 > INPUT_LIMIT { return Err("request_limit"); }
    let request: Value = serde_json::from_slice(&bytes).map_err(|_| "request_json")?;
    // The parent opens every path component read-only with O_NOFOLLOW and passes only this FD.
    let file = unsafe { File::from_raw_fd(fd) };
    let size = file.metadata().map_err(|_| "file_metadata")?.len();
    if size != number(&request, "file_size")? { return Err("file_size_changed"); }
    let spans = request["allowed_spans"].as_array().ok_or("missing_spans")?;
    if spans.is_empty() || spans.len() > 514 { return Err("span_count"); }
    let mut allowed = Vec::new();
    for s in spans {
        let a = number(s, "start")?; let b = number(s, "end")?;
        if a >= b || b > size { return Err("span_bounds"); }
        allowed.push((a,b));
    }
    let entries = request["entries"].as_array().ok_or("missing_entries")?;
    if entries.len() > 512 { return Err("entry_count"); }
    let mut declared_total = 0u64;
    for e in entries {
        let length = number(e, "decoded_size")?;
        if length > MEMBER_LIMIT { return Err("member_limit"); }
        declared_total = declared_total.checked_add(length).ok_or("size_overflow")?;
        if declared_total > TOTAL_LIMIT { return Err("total_limit"); }
    }
    let reader = RestrictedReader { file, spans: allowed, pos: 0, size, read_bytes: 0, seeks: 0 };
    // Empty filename disables the upstream neighbour-key and EXE discovery branches.
    // The known V3.1 inputs must carry their own uncompressed, bounded embedded key.
    let archive = QliePackArchive::new(reader, Encoding::Cp932, &ExtraConfig::default(), "")
        .map_err(|_| "upstream_archive_init")?;
    let names = archive.iter_archive_filename().map_err(|_| "upstream_list")?
        .collect::<Result<Vec<_>, _>>().map_err(|_| "upstream_name")?;
    if names.len() as u64 != number(&request, "expected_count")? || names.len() > 100_000 {
        return Err("entry_count_mismatch");
    }
    let mut out = io::stdout().lock();
    frame(&mut out, json!({"kind":"index", "names":names}))?;
    for entry in entries {
        let index = number(entry, "index")? as usize;
        let maximum = number(entry, "decoded_size")?;
        let mut data = Vec::new();
        let result = archive.open_file(index).and_then(|r| {
            r.take(maximum+1).read_to_end(&mut data)?;
            Ok(())
        });
        if result.is_err() {
            frame(&mut out, json!({"kind":"payload", "index":index, "status":"unsupported", "code":"upstream_decode"}))?;
            continue;
        }
        if data.len() as u64 != maximum {
            frame(&mut out, json!({"kind":"payload", "index":index, "status":"unsupported", "code":"decoded_size_mismatch"}))?;
            continue;
        }
        frame(&mut out, json!({"kind":"payload", "index":index, "status":"verified", "length":data.len()}))?;
        out.write_all(&data).map_err(|_| "pipe_payload")?;
    }
    frame(&mut out, json!({"kind":"end", "counter":format!("{}", msg_tool::get_counter())}))?;
    out.flush().map_err(|_| "pipe_flush")
}
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(run).unwrap_or(Err("upstream_panic"));
    if let Err(code) = result {
        let _ = frame(&mut io::stdout().lock(), json!({"kind":"fatal", "code":code}));
        std::process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn owned_reader(spans: Vec<(u64,u64)>) -> (RestrictedReader, std::path::PathBuf) {
        let suffix = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("mangekyou-owned-{}-{}", std::process::id(), suffix));
        let mut out = std::fs::OpenOptions::new().create_new(true).write(true).open(&path).unwrap();
        out.write_all(b"abcdef").unwrap(); drop(out);
        let file = File::open(&path).unwrap();
        (RestrictedReader { file, spans, pos:0, size:6, read_bytes:0, seeks:0 }, path)
    }
    #[test]
    fn restrict_reads_to_admitted_span_and_reject_next_gap() {
        let (mut reader, path) = owned_reader(vec![(1,3)]);
        let mut buf = [0u8; 8];
        assert!(reader.read(&mut buf).is_err());
        reader.seek(SeekFrom::Start(1)).unwrap();
        assert_eq!(reader.read(&mut buf).unwrap(), 2);
        assert_eq!(&buf[..2], b"bc");
        assert!(reader.read(&mut buf).is_err());
        drop(reader); std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn reject_outside_seeks_and_budget_exhaustion() {
        let (mut reader, path) = owned_reader(vec![(0,6)]);
        assert!(reader.seek(SeekFrom::Current(-1)).is_err());
        assert!(reader.seek(SeekFrom::Start(u64::MAX)).is_err());
        reader.seek(SeekFrom::End(-1)).unwrap();
        let mut buf = [0u8; 1]; assert_eq!(reader.read(&mut buf).unwrap(),1);
        assert_eq!(buf[0], b'f');
        reader.seek(SeekFrom::Start(0)).unwrap(); reader.read_bytes = 64*1024*1024;
        assert!(reader.read(&mut buf).is_err());
        reader.seeks = 1_000_000; assert!(reader.seek(SeekFrom::Start(0)).is_err());
        drop(reader); std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn frame_prefix_matches_json_bytes_and_large_metadata_is_rejected() {
        let mut out = Vec::new(); frame(&mut out, json!({"kind":"owned"})).unwrap();
        let length = u32::from_le_bytes(out[..4].try_into().unwrap()) as usize;
        assert_eq!(length, out.len()-4);
        assert_eq!(serde_json::from_slice::<Value>(&out[4..]).unwrap()["kind"], "owned");
        assert!(frame(&mut Vec::new(), json!({"x":"x".repeat(8*1024*1024)})).is_err());
    }
}
