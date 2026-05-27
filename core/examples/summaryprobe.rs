//! Smoke test for the repo-summary path. Run from the repo root:
//!   cargo run -p gitit-core --example summaryprobe -- <path-to-repo>

use std::env;

fn main() -> Result<(), String> {
    let path = env::args().nth(1).ok_or("usage: summaryprobe <repo>")?;

    let t0 = std::time::Instant::now();
    let s = gitit_core::repo_summary(path)?;
    let elapsed = t0.elapsed();

    println!("repo_summary in {elapsed:.2?}");
    println!("  head: {} ({})", s.head_name, s.head_oid);
    println!("  local branches:  {}", s.branches.len());
    println!("  remote branches: {}", s.remote_branches.len());
    println!("  tags:            {}", s.tags.len());
    Ok(())
}
