//! gitit-core: gitoxide-backed git operations.
//!
//! FFI boundary rule: this crate exposes plain value types or opaque session
//! handles. Swift never holds a `gix::Repository` directly.

mod diff;
mod graph;
mod highlight;
mod log;
mod repo;

use diff::CommitDiff as InnerCommitDiff;
use diff::FileDiff as InnerFileDiff;
use graph::Graph as InnerGraph;
use log::LogSession as InnerLogSession;

/// Opaque log session held by Swift. Walks the entire reachable history on
/// open and yields batches of commit metadata. Drop frees the underlying
/// repository handle.
pub struct LogSession {
    inner: InnerLogSession,
}

impl LogSession {
    pub fn total(&self) -> u32 {
        self.inner.total() as u32
    }
    pub fn remaining(&self) -> u32 {
        self.inner.remaining() as u32
    }
    pub fn is_walking(&self) -> bool {
        self.inner.is_walking()
    }
    pub fn next_batch(&mut self, limit: u32) -> LogBatch {
        let rows = self.inner.next_batch(limit as usize);
        let cap = rows.len();
        let mut oids = Vec::with_capacity(cap);
        let mut summaries = Vec::with_capacity(cap);
        let mut authors = Vec::with_capacity(cap);
        let mut times = Vec::with_capacity(cap);
        for r in rows {
            oids.push(r.oid);
            summaries.push(r.summary);
            authors.push(r.author_name);
            times.push(r.time_unix);
        }
        LogBatch { oids, summaries, authors, times }
    }
}

/// Columnar page of commits. Held opaquely by Swift; one batch per page.
/// Layout keeps each column in a contiguous Vec so the Swift pager pulls each
/// column in a single FFI call.
pub struct LogBatch {
    oids: Vec<String>,
    summaries: Vec<String>,
    authors: Vec<String>,
    times: Vec<i64>,
}

impl LogBatch {
    pub fn len(&self) -> usize { self.oids.len() }
    pub fn oids(&self) -> Vec<String> { self.oids.clone() }
    pub fn summaries(&self) -> Vec<String> { self.summaries.clone() }
    pub fn authors(&self) -> Vec<String> { self.authors.clone() }
    pub fn times(&self) -> Vec<i64> { self.times.clone() }
}

/// Opaque commit-level diff held by Swift. Walks the tree-vs-first-parent change
/// set once on open; per-file hunks are computed lazily via `open_file_diff`.
pub struct CommitDiff {
    inner: InnerCommitDiff,
}

impl CommitDiff {
    pub fn file_count(&self) -> u32 { self.inner.file_count() }
    pub fn file_path(&self, i: u32) -> String { self.inner.file_path(i) }
    pub fn file_status(&self, i: u32) -> String { self.inner.file_status(i) }
    pub fn file_additions(&self, i: u32) -> u32 { self.inner.file_additions(i) }
    pub fn file_deletions(&self, i: u32) -> u32 { self.inner.file_deletions(i) }
    pub fn open_file_diff(&self, index: u32) -> Result<FileDiff, String> {
        let inner = self.inner.open_file_diff(index)?;
        Ok(FileDiff { inner })
    }
}

/// Opaque columnar unified-diff page for a single file.
pub struct FileDiff {
    inner: InnerFileDiff,
}

impl FileDiff {
    pub fn line_count(&self) -> u32 { self.inner.line_count() }
    pub fn line_kinds(&self) -> Vec<u8> { self.inner.line_kinds() }
    pub fn line_old(&self) -> Vec<i32> { self.inner.line_old() }
    pub fn line_new(&self) -> Vec<i32> { self.inner.line_new() }
    pub fn line_text(&self) -> Vec<String> { self.inner.line_text() }
    pub fn hl_starts(&self) -> Vec<u32> { self.inner.hl_starts() }
    pub fn hl_offsets(&self) -> Vec<u32> { self.inner.hl_offsets() }
    pub fn hl_lengths(&self) -> Vec<u32> { self.inner.hl_lengths() }
    pub fn hl_kinds(&self) -> Vec<u8> { self.inner.hl_kinds() }
}

/// Opaque result of "determine work not merged": a columnar list of commits in
/// `ref_a`'s ancestry that introduced lines not present in `ref_b`. Sorted by
/// commit timestamp descending (most recent first).
pub struct UnmergedWork {
    oids:      Vec<String>,
    summaries: Vec<String>,
    authors:   Vec<String>,
    times:     Vec<i64>,
}

impl UnmergedWork {
    pub fn commit_count(&self) -> u32 { self.oids.len() as u32 }
    pub fn oids(&self)      -> Vec<String> { self.oids.clone() }
    pub fn summaries(&self) -> Vec<String> { self.summaries.clone() }
    pub fn authors(&self)   -> Vec<String> { self.authors.clone() }
    pub fn times(&self)     -> Vec<i64>    { self.times.clone() }
}

/// Opaque commit graph held by Swift. Built once on `open_graph` from a list
/// of ref tip names; columnar accessors mirror the Rust-side layout.
pub struct Graph {
    inner: InnerGraph,
}

impl Graph {
    pub fn commit_count(&self) -> u32 { self.inner.commit_count() }
    pub fn oids(&self) -> Vec<String> { self.inner.oids() }
    pub fn times(&self) -> Vec<i64> { self.inner.times() }
    pub fn lanes(&self) -> Vec<u32> { self.inner.lanes() }
    pub fn colors(&self) -> Vec<u32> { self.inner.colors() }
    pub fn parent_starts(&self) -> Vec<u32> { self.inner.parent_starts() }
    pub fn parent_oids(&self) -> Vec<String> { self.inner.parent_oids() }
    pub fn tip_count(&self) -> u32 { self.inner.tip_count() }
    pub fn tip_names(&self) -> Vec<String> { self.inner.tip_names() }
    pub fn tip_oids(&self) -> Vec<String> { self.inner.tip_oids() }
    pub fn tip_colors(&self) -> Vec<u32> { self.inner.tip_colors() }
    pub fn tip_is_remote(&self) -> Vec<u8> { self.inner.tip_is_remote() }
    pub fn tip_is_tracked(&self) -> Vec<u8> { self.inner.tip_is_tracked() }
}

#[swift_bridge::bridge]
mod ffi {
    #[swift_bridge(swift_repr = "struct")]
    struct RepoSummary {
        head_oid: String,
        head_name: String,
        head_tag: String,
        branches: Vec<String>,
        branch_oids: Vec<String>,
        branch_tracked: Vec<u8>,
        branch_ahead: Vec<u32>,
        branch_behind: Vec<u32>,
        remote_branches: Vec<String>,
        remote_branch_oids: Vec<String>,
        tags: Vec<String>,
    }

    extern "Rust" {
        type LogSession;
        fn total(self: &LogSession) -> u32;
        fn remaining(self: &LogSession) -> u32;
        fn is_walking(self: &LogSession) -> bool;
        fn next_batch(self: &mut LogSession, limit: u32) -> LogBatch;
    }

    extern "Rust" {
        type LogBatch;
        fn len(self: &LogBatch) -> usize;
        fn oids(self: &LogBatch) -> Vec<String>;
        fn summaries(self: &LogBatch) -> Vec<String>;
        fn authors(self: &LogBatch) -> Vec<String>;
        fn times(self: &LogBatch) -> Vec<i64>;
    }

    extern "Rust" {
        type CommitDiff;
        fn file_count(self: &CommitDiff) -> u32;
        fn file_path(self: &CommitDiff, index: u32) -> String;
        fn file_status(self: &CommitDiff, index: u32) -> String;
        fn file_additions(self: &CommitDiff, index: u32) -> u32;
        fn file_deletions(self: &CommitDiff, index: u32) -> u32;
        fn open_file_diff(self: &CommitDiff, index: u32) -> Result<FileDiff, String>;
    }

    extern "Rust" {
        type FileDiff;
        fn line_count(self: &FileDiff) -> u32;
        fn line_kinds(self: &FileDiff) -> Vec<u8>;
        fn line_old(self: &FileDiff) -> Vec<i32>;
        fn line_new(self: &FileDiff) -> Vec<i32>;
        fn line_text(self: &FileDiff) -> Vec<String>;
        fn hl_starts(self: &FileDiff) -> Vec<u32>;
        fn hl_offsets(self: &FileDiff) -> Vec<u32>;
        fn hl_lengths(self: &FileDiff) -> Vec<u32>;
        fn hl_kinds(self: &FileDiff) -> Vec<u8>;
    }

    extern "Rust" {
        type Graph;
        fn commit_count(self: &Graph) -> u32;
        fn oids(self: &Graph) -> Vec<String>;
        fn times(self: &Graph) -> Vec<i64>;
        fn lanes(self: &Graph) -> Vec<u32>;
        fn colors(self: &Graph) -> Vec<u32>;
        fn parent_starts(self: &Graph) -> Vec<u32>;
        fn parent_oids(self: &Graph) -> Vec<String>;
        fn tip_count(self: &Graph) -> u32;
        fn tip_names(self: &Graph) -> Vec<String>;
        fn tip_oids(self: &Graph) -> Vec<String>;
        fn tip_colors(self: &Graph) -> Vec<u32>;
        fn tip_is_remote(self: &Graph) -> Vec<u8>;
        fn tip_is_tracked(self: &Graph) -> Vec<u8>;
    }

    extern "Rust" {
        type UnmergedWork;
        fn commit_count(self: &UnmergedWork) -> u32;
        fn oids(self: &UnmergedWork) -> Vec<String>;
        fn summaries(self: &UnmergedWork) -> Vec<String>;
        fn authors(self: &UnmergedWork) -> Vec<String>;
        fn times(self: &UnmergedWork) -> Vec<i64>;
    }

    extern "Rust" {
        fn hello(name: String) -> String;
        fn repo_summary(path: String) -> Result<RepoSummary, String>;
        fn checkout_branch(path: String, branch: String) -> Result<(), String>;
        fn core_version() -> String;
        fn open_log(path: String, ref_names: Vec<String>) -> Result<LogSession, String>;
        fn open_commit_diff(path: String, commit_oid: String) -> Result<CommitDiff, String>;
        fn open_range_diff(path: String, old_ref: String, new_ref: String) -> Result<CommitDiff, String>;
        fn open_graph(path: String, ref_names: Vec<String>) -> Result<Graph, String>;
        fn open_unmerged_work(path: String, ref_a: String, ref_b: String) -> Result<UnmergedWork, String>;
    }
}

pub fn hello(name: String) -> String {
    format!("hello, {name}, from gitit-core")
}

pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

pub fn repo_summary(path: String) -> Result<ffi::RepoSummary, String> {
    let path = std::path::PathBuf::from(path);
    let summary = repo::repo_summary(&path).map_err(|e| e.to_string())?;
    Ok(ffi::RepoSummary {
        head_oid: summary.head_oid.unwrap_or_default(),
        head_name: summary.head_name.unwrap_or_default(),
        head_tag: summary.head_tag.unwrap_or_default(),
        branches: summary.branches,
        branch_oids: summary.branch_oids,
        branch_tracked: summary.branch_tracked,
        branch_ahead: summary.branch_ahead,
        branch_behind: summary.branch_behind,
        remote_branches: summary.remote_branches,
        remote_branch_oids: summary.remote_branch_oids,
        tags: summary.tags,
    })
}

pub fn checkout_branch(path: String, branch: String) -> Result<(), String> {
    repo::checkout_branch(std::path::Path::new(&path), &branch)
}

pub fn open_log(path: String, ref_names: Vec<String>) -> Result<LogSession, String> {
    let inner =
        InnerLogSession::open(std::path::Path::new(&path), &ref_names).map_err(|e| e.to_string())?;
    Ok(LogSession { inner })
}

pub fn open_commit_diff(path: String, commit_oid: String) -> Result<CommitDiff, String> {
    let inner = InnerCommitDiff::open(std::path::Path::new(&path), &commit_oid).map_err(|e| e.to_string())?;
    Ok(CommitDiff { inner })
}

pub fn open_range_diff(path: String, old_ref: String, new_ref: String) -> Result<CommitDiff, String> {
    let inner = InnerCommitDiff::open_range(std::path::Path::new(&path), &old_ref, &new_ref)
        .map_err(|e| e.to_string())?;
    Ok(CommitDiff { inner })
}

pub fn open_graph(path: String, ref_names: Vec<String>) -> Result<Graph, String> {
    let inner = graph::build(std::path::Path::new(&path), &ref_names).map_err(|e| e.to_string())?;
    Ok(Graph { inner })
}

pub fn open_unmerged_work(path: String, ref_a: String, ref_b: String) -> Result<UnmergedWork, String> {
    let result = diff::open_unmerged_work(std::path::Path::new(&path), &ref_a, &ref_b)
        .map_err(|e| e.to_string())?;
    Ok(UnmergedWork {
        oids:      result.oids,
        summaries: result.summaries,
        authors:   result.authors,
        times:     result.times,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_works() {
        assert_eq!(hello("world".to_string()), "hello, world, from gitit-core");
    }
}
