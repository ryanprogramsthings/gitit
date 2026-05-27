//! Repo open + ref enumeration.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RepoError {
    #[error("could not open repository at {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: Box<gix::open::Error>,
    },
    #[error("could not read references: {0}")]
    Refs(#[from] gix::reference::iter::Error),
    #[error("could not iterate references: {0}")]
    RefIter(#[from] gix::reference::iter::init::Error),
}

/// Snapshot of a repository's top-level state, suitable for FFI return.
/// Branch info is laid out as parallel vectors keyed by index so the
/// swift-bridge struct stays primitive.
#[derive(Debug, Clone)]
pub struct RepoSummary {
    pub head_oid: Option<String>,
    pub head_name: Option<String>,
    /// When HEAD is detached exactly on a tag, that tag's short name.
    pub head_tag: Option<String>,
    /// Local branch short-names (`refs/heads/<name>` → `<name>`).
    pub branches: Vec<String>,
    /// Parallel to `branches`: tip oid as hex string.
    pub branch_oids: Vec<String>,
    /// Parallel to `branches`: 1 if `refs/remotes/origin/<name>` exists.
    pub branch_tracked: Vec<u8>,
    /// Parallel to `branches`: commits on the local branch not on `origin/<name>`.
    pub branch_ahead: Vec<u32>,
    /// Parallel to `branches`: commits on `origin/<name>` not on the local branch.
    pub branch_behind: Vec<u32>,
    /// Remote branch short-names (`refs/remotes/<name>` → `<name>`, e.g. `origin/main`).
    pub remote_branches: Vec<String>,
    /// Parallel to `remote_branches`: tip oid.
    pub remote_branch_oids: Vec<String>,
    pub tags: Vec<String>,
}

pub fn repo_summary(path: &Path) -> Result<RepoSummary, RepoError> {
    let repo = gix::open(path).map_err(|e| RepoError::Open {
        path: path.display().to_string(),
        source: Box::new(e),
    })?;

    let head = repo.head().ok();
    let head_oid = head
        .as_ref()
        .and_then(|h| h.id())
        .map(|id| id.to_string());
    let head_name = head
        .as_ref()
        .and_then(|h| h.referent_name())
        .map(|n| n.shorten().to_string());

    // A detached HEAD may be sitting on a tag — surface its name so the UI
    // can show what's checked out.
    let head_tag = if head_name.is_none() && head_oid.is_some() {
        describe_exact_tag(path)
    } else {
        None
    };

    let platform = repo.references()?;

    let mut remote_branches = Vec::new();
    let mut remote_branch_oids = Vec::new();
    // Remote short-name → tip oid, used to compute local ahead/behind.
    let mut remote_oid_by_short: HashMap<String, gix::ObjectId> = HashMap::new();
    for r in platform.remote_branches()?.flatten() {
        let short = r.name().shorten().to_string();
        if let Some(id) = r.target().try_id() {
            remote_oid_by_short.insert(short.clone(), id.into());
        }
        let oid = r.target().try_id().map(|id| id.to_string()).unwrap_or_default();
        remote_branches.push(short);
        remote_branch_oids.push(oid);
    }

    let mut branches = Vec::new();
    let mut branch_oids = Vec::new();
    let mut branch_tracked = Vec::new();
    let mut branch_ahead = Vec::new();
    let mut branch_behind = Vec::new();
    for r in platform.local_branches()?.flatten() {
        let short = r.name().shorten().to_string();
        let local_id = r.target().try_id().map(|id| id.into());
        let oid = local_id.map(|id: gix::ObjectId| id.to_string()).unwrap_or_default();
        let upstream = remote_oid_by_short.get(&format!("origin/{short}")).copied();
        let (ahead, behind) = match (local_id, upstream) {
            (Some(local), Some(up)) => divergence(path, local, up),
            _ => (0, 0),
        };
        branches.push(short);
        branch_oids.push(oid);
        branch_tracked.push(if upstream.is_some() { 1 } else { 0 });
        branch_ahead.push(ahead);
        branch_behind.push(behind);
    }

    let mut tags = Vec::new();
    for r in platform.tags()?.flatten() {
        tags.push(r.name().shorten().to_string());
    }

    Ok(RepoSummary {
        head_oid,
        head_name,
        head_tag,
        branches,
        branch_oids,
        branch_tracked,
        branch_ahead,
        branch_behind,
        remote_branches,
        remote_branch_oids,
        tags,
    })
}

/// When HEAD is detached, the short name of a tag pointing exactly at it
/// (`git describe --tags --exact-match`). `None` if HEAD isn't on a tag —
/// gix 0.66 has no direct "tag at this commit" lookup, so this shells out.
fn describe_exact_tag(path: &Path) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["describe", "--tags", "--exact-match", "HEAD"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if name.is_empty() { None } else { Some(name) }
}

/// `(ahead, behind)` for a local branch relative to its upstream: commits
/// reachable from `local` but not `upstream`, and vice versa. gix 0.66's
/// rev-walk has no hidden-tip support, so this shells to `git rev-list`. Any
/// failure degrades to `(0, 0)` — a missing badge beats a failed repo open.
fn divergence(path: &Path, local: gix::ObjectId, upstream: gix::ObjectId) -> (u32, u32) {
    if local == upstream {
        return (0, 0);
    }
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-list", "--left-right", "--count"])
        .arg(format!("{local}...{upstream}"))
        .output();
    match output {
        Ok(o) if o.status.success() => {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut nums = text.split_whitespace();
            let ahead = nums.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            let behind = nums.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            (ahead, behind)
        }
        _ => (0, 0),
    }
}

/// Switch the working tree to `branch`. Shells to `git checkout` — its
/// incremental tree update and dirty-tree refusal are exactly what we want.
pub fn checkout_branch(path: &Path, branch: &str) -> Result<(), String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .arg("checkout")
        .arg(branch)
        .output()
        .map_err(|e| format!("could not run git: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        let msg = String::from_utf8_lossy(&output.stderr).trim().to_string();
        Err(if msg.is_empty() { "git checkout failed".to_string() } else { msg })
    }
}
