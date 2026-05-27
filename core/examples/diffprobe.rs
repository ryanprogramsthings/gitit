//! Smoke test for the commit-diff path. Run from the repo root:
//!   cargo run -p gitit-core --example diffprobe -- <path-to-repo> <oid>

use std::env;

fn main() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let path = args.next().ok_or("usage: diffprobe <repo> <oid>")?;
    let oid = args.next().ok_or("usage: diffprobe <repo> <oid>")?;

    let t0 = std::time::Instant::now();
    let diff = gitit_core::open_commit_diff(path, oid.clone()).map_err(|e| e)?;
    let t_open = t0.elapsed();
    println!("open_commit_diff(\"{}\") in {:.2?}", oid, t_open);
    println!("  files: {}", diff.file_count());
    for i in 0..diff.file_count() {
        println!(
            "    [{}] {} {} +{} -{}",
            diff.file_status(i),
            diff.file_path(i),
            i,
            diff.file_additions(i),
            diff.file_deletions(i),
        );
    }

    if diff.file_count() > 0 {
        // Pick the first .kt file if any, else the first file.
        let mut idx: u32 = 0;
        for i in 0..diff.file_count() {
            if diff.file_path(i).ends_with(".kt") { idx = i; break; }
        }
        let t1 = std::time::Instant::now();
        let fd = diff.open_file_diff(idx).map_err(|e| e)?;
        let t_file = t1.elapsed();
        println!("\nopen_file_diff({}) [{}] in {:.2?}, {} lines, {} highlight spans",
            idx, diff.file_path(idx), t_file, fd.line_count(), fd.hl_kinds().len());

        let kinds  = fd.line_kinds();
        let olds   = fd.line_old();
        let news   = fd.line_new();
        let texts  = fd.line_text();
        let hl_st  = fd.hl_starts();
        let hl_off = fd.hl_offsets();
        let hl_len = fd.hl_lengths();
        let hl_k   = fd.hl_kinds();

        for i in 0..kinds.len().min(40) {
            let k = match kinds[i] { 0 => " ", 1 => "+", 2 => "-", 3 => "@", _ => "?" };
            let spans_lo = hl_st[i] as usize;
            let spans_hi = hl_st[i + 1] as usize;
            let span_summary: String = (spans_lo..spans_hi)
                .map(|j| format!("{}@{}+{}", hl_k[j], hl_off[j], hl_len[j]))
                .collect::<Vec<_>>().join(" ");
            println!("  {} {:>4} {:>4} | {}", k, olds[i], news[i], texts[i]);
            if !span_summary.is_empty() {
                println!("                  spans: {}", span_summary);
            }
        }
        if kinds.len() > 40 {
            println!("  … ({} more lines)", kinds.len() - 40);
        }
    }

    Ok(())
}
