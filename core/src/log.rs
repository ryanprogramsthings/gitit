//! Streaming commit walk.
//!
//! Opening a `LogSession` spawns a background thread that walks the entire
//! reachable history, extracts each commit's metadata, and appends to a
//! shared `Vec<CommitRow>`. The Swift side calls `next_batch` to snapshot
//! whatever has been produced so far — never blocks the walker, never sees
//! duplicate or out-of-order rows.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum LogError {
    #[error("could not open repository at {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: Box<gix::open::Error>,
    },
    #[error("no HEAD commit (empty repository?)")]
    NoHead,
}

#[derive(Debug, Clone)]
pub struct CommitRow {
    pub oid: String,
    pub summary: String,
    pub author_name: String,
    pub time_unix: i64,
}

struct SessionState {
    rows: Mutex<Vec<CommitRow>>,
    walking: AtomicBool,
    cancelled: AtomicBool,
}

pub struct LogSession {
    state: Arc<SessionState>,
    cursor: usize,
}

impl Drop for LogSession {
    fn drop(&mut self) {
        self.state.cancelled.store(true, Ordering::Relaxed);
    }
}

impl LogSession {
    /// Validates that the repo opens, resolves `ref_names` to tip oids, then
    /// spawns a walker thread. An empty (or fully unresolvable) `ref_names`
    /// falls back to HEAD. The walker re-opens the repository inside its own
    /// thread (gix's repo isn't Sync).
    pub fn open(repo_path: &Path, ref_names: &[String]) -> Result<Self, LogError> {
        let repo = gix::open(repo_path).map_err(|e| LogError::Open {
            path: repo_path.display().to_string(),
            source: Box::new(e),
        })?;

        let mut tips = resolve_tips(&repo, ref_names);
        if tips.is_empty() {
            match repo.head_id() {
                Ok(h) => tips.push(h.detach()),
                Err(_) => return Err(LogError::NoHead),
            }
        }

        let state = Arc::new(SessionState {
            rows: Mutex::new(Vec::with_capacity(1024)),
            walking: AtomicBool::new(true),
            cancelled: AtomicBool::new(false),
        });
        let walker_state = state.clone();
        let path = repo_path.to_path_buf();
        std::thread::Builder::new()
            .name("gitit-log-walker".into())
            .spawn(move || walk_into(&path, &tips, walker_state))
            .expect("spawn walker thread");

        Ok(LogSession { state, cursor: 0 })
    }

    pub fn total(&self) -> usize {
        self.state.rows.lock().unwrap().len()
    }

    pub fn remaining(&self) -> usize {
        self.total().saturating_sub(self.cursor)
    }

    pub fn is_walking(&self) -> bool {
        self.state.walking.load(Ordering::Relaxed)
    }

    pub fn next_batch(&mut self, limit: usize) -> Vec<CommitRow> {
        let rows = self.state.rows.lock().unwrap();
        let end = (self.cursor + limit).min(rows.len());
        let slice = rows[self.cursor..end].to_vec();
        self.cursor = end;
        slice
    }
}

/// Resolve branch short-names to tip oids, trying `refs/heads/<name>`,
/// `refs/remotes/<name>`, then `refs/tags/<name>`. Unresolvable names are
/// skipped. `peel_to_id_in_place` peels annotated tags through to the commit.
fn resolve_tips(repo: &gix::Repository, ref_names: &[String]) -> Vec<gix::ObjectId> {
    let mut tips = Vec::with_capacity(ref_names.len());
    for name in ref_names {
        for full in [
            format!("refs/heads/{name}"),
            format!("refs/remotes/{name}"),
            format!("refs/tags/{name}"),
        ] {
            if let Ok(mut reference) = repo.find_reference(&full) {
                if let Ok(id) = reference.peel_to_id_in_place() {
                    tips.push(id.detach());
                    break;
                }
            }
        }
    }
    tips
}

fn walk_into(path: &Path, tips: &[gix::ObjectId], state: Arc<SessionState>) {
    // Errors here are silent — open errors were surfaced on the foreground call.
    let Ok(repo) = gix::open(path) else {
        state.walking.store(false, Ordering::Relaxed);
        return;
    };
    let Ok(walker) = repo.rev_walk(tips.iter().copied()).all() else {
        state.walking.store(false, Ordering::Relaxed);
        return;
    };

    // Flush in chunks to amortize lock contention.
    const FLUSH_CHUNK: usize = 64;
    let mut buf: Vec<CommitRow> = Vec::with_capacity(FLUSH_CHUNK);

    for info in walker {
        if state.cancelled.load(Ordering::Relaxed) {
            break;
        }
        let Ok(info) = info else { continue };
        buf.push(build_row(&repo, info.id));
        if buf.len() >= FLUSH_CHUNK {
            let mut rows = state.rows.lock().unwrap();
            rows.extend(buf.drain(..));
        }
    }
    if !buf.is_empty() {
        let mut rows = state.rows.lock().unwrap();
        rows.extend(buf.drain(..));
    }
    state.walking.store(false, Ordering::Relaxed);
}

fn build_row(repo: &gix::Repository, oid: gix::ObjectId) -> CommitRow {
    let oid_str = oid.to_string();
    let commit = match repo.find_commit(oid) {
        Ok(c) => c,
        Err(_) => {
            return CommitRow { oid: oid_str, summary: String::new(), author_name: String::new(), time_unix: 0 }
        }
    };
    let summary = commit
        .message_raw()
        .ok()
        .map(|m| {
            let first = m.split(|&b| b == b'\n').next().unwrap_or(b"");
            String::from_utf8_lossy(first).trim().to_string()
        })
        .unwrap_or_default();
    let (author_name, time_unix) = match commit.author() {
        Ok(sig) => (sig.name.to_string(), sig.time.seconds),
        Err(_) => (String::new(), 0),
    };
    CommitRow { oid: oid_str, summary, author_name, time_unix }
}
