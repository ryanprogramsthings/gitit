//! Smoke test for the graph path. Run from the repo root:
//!   cargo run -p gitit-core --example graphprobe -- <path-to-repo> main

use std::env;

fn main() -> Result<(), String> {
    let mut args = env::args().skip(1);
    let path = args.next().ok_or("usage: graphprobe <repo> <branch...>")?;
    let refs: Vec<String> = args.collect();
    if refs.is_empty() {
        return Err("usage: graphprobe <repo> <branch...>".into());
    }

    let t0 = std::time::Instant::now();
    let g = gitit_core::open_graph(path, refs.clone())?;
    let t_open = t0.elapsed();
    println!("open_graph({:?}) in {:.2?}", refs, t_open);
    println!("  commits: {}, tips: {}", g.commit_count(), g.tip_count());

    let tnames = g.tip_names();
    let toids  = g.tip_oids();
    let tcols  = g.tip_colors();
    let trem   = g.tip_is_remote();
    let ttrk   = g.tip_is_tracked();
    println!("\n  tips:");
    for i in 0..g.tip_count() as usize {
        println!("    [{}] {} {} color={} remote={} tracked={}",
            i, &toids[i][..8], tnames[i], tcols[i], trem[i], ttrk[i]);
    }

    let oids   = g.oids();
    let times  = g.times();
    let lanes  = g.lanes();
    let colors = g.colors();
    let pstart = g.parent_starts();
    let poids  = g.parent_oids();

    println!("\n  first 20 commits (oid lane color time #parents):");
    let n = (g.commit_count() as usize).min(20);
    for i in 0..n {
        let lo = pstart[i] as usize;
        let hi = pstart[i + 1] as usize;
        let np = hi - lo;
        let mut parent_summary = String::new();
        for j in lo..hi {
            if !parent_summary.is_empty() { parent_summary.push(' '); }
            parent_summary.push_str(&poids[j][..8]);
        }
        println!("    {:>3} {} lane={:>2} color={:>2} t={} np={} {}",
            i, &oids[i][..8], lanes[i], colors[i], times[i], np, parent_summary);
    }
    if g.commit_count() as usize > n {
        println!("  … ({} more commits)", g.commit_count() as usize - n);
    }

    // Sanity histogram: which lanes and colors are used?
    let max_lane = lanes.iter().copied().max().unwrap_or(0);
    let max_color = colors.iter().copied().max().unwrap_or(0);
    println!("\n  lanes used: 0..={}, colors used: 0..={}", max_lane, max_color);

    Ok(())
}
