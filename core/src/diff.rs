//! Commit-level diff against the first parent (or the empty tree for a root commit).
//!
//! `CommitDiff::open` walks the tree-vs-tree change set once. Each entry caches
//! the old/new blob oids so per-file hunk computation can fetch lazily. Hunks are
//! produced by `similar::TextDiff` and exposed in a columnar shape that crosses
//! the FFI cleanly.

use std::collections::{HashMap, HashSet};
use std::convert::Infallible;
use std::path::{Path, PathBuf};

use similar::{ChangeTag, TextDiff};
use thiserror::Error;

use crate::highlight::{self, HlSpan, Language};

#[derive(Debug, Error)]
pub enum DiffError {
    #[error("could not open repository at {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: Box<gix::open::Error>,
    },
    #[error("invalid commit id {oid}")]
    BadOid { oid: String },
    #[error("could not resolve commit {oid}: {message}")]
    Commit { oid: String, message: String },
    #[error("tree diff failed: {0}")]
    Tree(String),
}

#[derive(Debug, Clone, Copy)]
pub enum FileStatus {
    Added,
    Modified,
    Deleted,
}

impl FileStatus {
    fn code(self) -> &'static str {
        match self {
            FileStatus::Added => "A",
            FileStatus::Modified => "M",
            FileStatus::Deleted => "D",
        }
    }
}

#[derive(Debug, Clone)]
struct FileChange {
    path: String,
    status: FileStatus,
    old_oid: Option<gix::ObjectId>,
    new_oid: Option<gix::ObjectId>,
    additions: u32,
    deletions: u32,
}

pub struct CommitDiff {
    repo_path: PathBuf,
    files: Vec<FileChange>,
}

impl CommitDiff {
    pub fn open(repo_path: &Path, commit_oid: &str) -> Result<Self, DiffError> {
        let repo = gix::open(repo_path).map_err(|e| DiffError::Open {
            path: repo_path.display().to_string(),
            source: Box::new(e),
        })?;

        let oid: gix::ObjectId = commit_oid
            .parse()
            .map_err(|_| DiffError::BadOid { oid: commit_oid.to_string() })?;

        let commit = repo.find_commit(oid).map_err(|e| DiffError::Commit {
            oid: commit_oid.to_string(),
            message: e.to_string(),
        })?;
        let new_tree = commit.tree().map_err(|e| DiffError::Tree(e.to_string()))?;

        let parent_id = commit.parent_ids().next();
        let old_tree = match parent_id {
            Some(pid) => {
                let parent = repo.find_commit(pid).map_err(|e| DiffError::Tree(e.to_string()))?;
                parent.tree().map_err(|e| DiffError::Tree(e.to_string()))?
            }
            None => repo.empty_tree(),
        };

        let files = diff_trees(&repo, &old_tree, &new_tree)?;
        Ok(CommitDiff { repo_path: repo_path.to_path_buf(), files })
    }

    /// Diff the trees of two refs (branches or tags) directly — every file-state
    /// difference between the two snapshots, as `git diff <old_ref> <new_ref>`.
    pub fn open_range(repo_path: &Path, old_ref: &str, new_ref: &str) -> Result<Self, DiffError> {
        let repo = gix::open(repo_path).map_err(|e| DiffError::Open {
            path: repo_path.display().to_string(),
            source: Box::new(e),
        })?;

        let old_oid = resolve_ref_commit(&repo, old_ref)?;
        let new_oid = resolve_ref_commit(&repo, new_ref)?;

        let old_commit = repo.find_commit(old_oid).map_err(|e| DiffError::Commit {
            oid: old_ref.to_string(),
            message: e.to_string(),
        })?;
        let new_commit = repo.find_commit(new_oid).map_err(|e| DiffError::Commit {
            oid: new_ref.to_string(),
            message: e.to_string(),
        })?;
        let old_tree = old_commit.tree().map_err(|e| DiffError::Tree(e.to_string()))?;
        let new_tree = new_commit.tree().map_err(|e| DiffError::Tree(e.to_string()))?;

        let files = diff_trees(&repo, &old_tree, &new_tree)?;
        Ok(CommitDiff { repo_path: repo_path.to_path_buf(), files })
    }

    pub fn file_count(&self) -> u32 { self.files.len() as u32 }

    pub fn file_path(&self, i: u32) -> String {
        self.files.get(i as usize).map(|f| f.path.clone()).unwrap_or_default()
    }
    pub fn file_status(&self, i: u32) -> String {
        self.files.get(i as usize).map(|f| f.status.code().to_string()).unwrap_or_default()
    }
    pub fn file_additions(&self, i: u32) -> u32 {
        self.files.get(i as usize).map(|f| f.additions).unwrap_or(0)
    }
    pub fn file_deletions(&self, i: u32) -> u32 {
        self.files.get(i as usize).map(|f| f.deletions).unwrap_or(0)
    }

    pub fn open_file_diff(&self, index: u32) -> Result<FileDiff, String> {
        let file = self
            .files
            .get(index as usize)
            .ok_or_else(|| "file index out of bounds".to_string())?;
        let repo = gix::open(&self.repo_path).map_err(|e| e.to_string())?;
        let old_text = match file.old_oid {
            Some(oid) => read_blob_text(&repo, oid)?,
            None => String::new(),
        };
        let new_text = match file.new_oid {
            Some(oid) => read_blob_text(&repo, oid)?,
            None => String::new(),
        };
        Ok(FileDiff::compute(&file.path, &old_text, &new_text))
    }
}

/// Resolve a ref name (branch, remote branch, or tag) to a commit oid.
/// Tries `refs/heads/`, `refs/remotes/`, then `refs/tags/` — matching the
/// lookup order used for log tips — and peels annotated tags to the commit.
fn resolve_ref_commit(repo: &gix::Repository, name: &str) -> Result<gix::ObjectId, DiffError> {
    for full in [
        format!("refs/heads/{name}"),
        format!("refs/remotes/{name}"),
        format!("refs/tags/{name}"),
    ] {
        if let Ok(mut r) = repo.find_reference(&full) {
            if let Ok(id) = r.peel_to_id_in_place() {
                return Ok(id.detach());
            }
        }
    }
    Err(DiffError::Commit {
        oid: name.to_string(),
        message: "ref not found".to_string(),
    })
}

/// Walk the change set between two trees into a path-sorted `Vec<FileChange>`.
/// Each entry caches old/new blob oids so per-file hunks can be fetched lazily.
fn diff_trees(
    repo: &gix::Repository,
    old_tree: &gix::Tree<'_>,
    new_tree: &gix::Tree<'_>,
) -> Result<Vec<FileChange>, DiffError> {
    let mut files: Vec<FileChange> = Vec::new();
    old_tree
        .changes()
        .map_err(|e| DiffError::Tree(e.to_string()))?
        .track_path()
        .track_rewrites(None)
        .for_each_to_obtain_tree(new_tree, |change| -> Result<gix::object::tree::diff::Action, Infallible> {
            let path = change.location.to_string();
            let entry: Option<FileChange> = match change.event {
                gix::object::tree::diff::change::Event::Addition { entry_mode, id }
                    if entry_mode.is_blob() =>
                {
                    Some(FileChange {
                        path,
                        status: FileStatus::Added,
                        old_oid: None,
                        new_oid: Some(id.detach()),
                        additions: 0,
                        deletions: 0,
                    })
                }
                gix::object::tree::diff::change::Event::Deletion { entry_mode, id }
                    if entry_mode.is_blob() =>
                {
                    Some(FileChange {
                        path,
                        status: FileStatus::Deleted,
                        old_oid: Some(id.detach()),
                        new_oid: None,
                        additions: 0,
                        deletions: 0,
                    })
                }
                gix::object::tree::diff::change::Event::Modification {
                    previous_entry_mode,
                    previous_id,
                    entry_mode,
                    id,
                } if entry_mode.is_blob() || previous_entry_mode.is_blob() => Some(FileChange {
                    path,
                    status: FileStatus::Modified,
                    old_oid: Some(previous_id.detach()),
                    new_oid: Some(id.detach()),
                    additions: 0,
                    deletions: 0,
                }),
                _ => None,
            };
            if let Some(mut fc) = entry {
                let (adds, dels) = count_changes(repo, fc.old_oid, fc.new_oid);
                fc.additions = adds;
                fc.deletions = dels;
                files.push(fc);
            }
            Ok(gix::object::tree::diff::Action::Continue)
        })
        .map_err(|e| DiffError::Tree(e.to_string()))?;

    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

pub(crate) fn read_blob_text(repo: &gix::Repository, oid: gix::ObjectId) -> Result<String, String> {
    let obj = repo.find_object(oid).map_err(|e| e.to_string())?;
    let blob = obj.try_into_blob().map_err(|e| e.to_string())?;
    // Lossy: binary files won't render usefully in a text diff anyway.
    Ok(String::from_utf8_lossy(&blob.data).into_owned())
}

/// Count added/deleted lines without materializing the full hunk list.
/// Returns (0,0) if either blob is unreadable — diff stats are best-effort metadata.
fn count_changes(repo: &gix::Repository, old: Option<gix::ObjectId>, new: Option<gix::ObjectId>) -> (u32, u32) {
    let old_text = match old {
        Some(oid) => read_blob_text(repo, oid).unwrap_or_default(),
        None => String::new(),
    };
    let new_text = match new {
        Some(oid) => read_blob_text(repo, oid).unwrap_or_default(),
        None => String::new(),
    };
    let diff = TextDiff::from_lines(&old_text, &new_text);
    let mut adds = 0u32;
    let mut dels = 0u32;
    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Insert => adds += 1,
            ChangeTag::Delete => dels += 1,
            ChangeTag::Equal => {}
        }
    }
    (adds, dels)
}

/// Columnar unified-diff page for a single file.
///
/// Line kinds: 0=context, 1=add, 2=delete, 3=hunk header.
/// `old_lineno`/`new_lineno` are 1-based; -1 means "not applicable" (e.g. a
/// hunk header, or an addition has no old line number).
///
/// Highlight spans are stored CSR-style: line `i`'s spans occupy
/// `hl_starts[i] .. hl_starts[i+1]` in (`hl_offsets`, `hl_lengths`, `hl_kinds`).
/// Offsets are byte positions within `line_text[i]` (no prefix prepended).
pub struct FileDiff {
    line_kinds: Vec<u8>,
    line_old: Vec<i32>,
    line_new: Vec<i32>,
    line_text: Vec<String>,
    hl_starts: Vec<u32>,
    hl_offsets: Vec<u32>,
    hl_lengths: Vec<u32>,
    hl_kinds: Vec<u8>,
}

impl FileDiff {
    fn compute(path: &str, old: &str, new: &str) -> Self {
        let lang = highlight::detect_language(path);
        let old_spans: Vec<Vec<LineSpan>> = lang.map(|l| spans_by_line(old, l)).unwrap_or_default();
        let new_spans: Vec<Vec<LineSpan>> = lang.map(|l| spans_by_line(new, l)).unwrap_or_default();

        let diff = TextDiff::from_lines(old, new);
        let mut out = FileDiff {
            line_kinds: Vec::new(),
            line_old: Vec::new(),
            line_new: Vec::new(),
            line_text: Vec::new(),
            hl_starts: vec![0],
            hl_offsets: Vec::new(),
            hl_lengths: Vec::new(),
            hl_kinds: Vec::new(),
        };

        for group in diff.grouped_ops(3) {
            if group.is_empty() {
                continue;
            }
            let first = group.first().unwrap();
            let last = group.last().unwrap();
            let old_start = first.old_range().start;
            let old_end = last.old_range().end;
            let new_start = first.new_range().start;
            let new_end = last.new_range().end;
            let header = format!(
                "@@ -{},{} +{},{} @@",
                old_start + 1,
                old_end.saturating_sub(old_start),
                new_start + 1,
                new_end.saturating_sub(new_start),
            );
            out.push(3, -1, -1, header, &[]);

            for op in group {
                for change in diff.iter_changes(&op) {
                    let kind = match change.tag() {
                        ChangeTag::Equal => 0u8,
                        ChangeTag::Insert => 1u8,
                        ChangeTag::Delete => 2u8,
                    };
                    let old_n = change.old_index().map(|i| (i + 1) as i32).unwrap_or(-1);
                    let new_n = change.new_index().map(|i| (i + 1) as i32).unwrap_or(-1);
                    let text = change
                        .value()
                        .trim_end_matches('\n')
                        .trim_end_matches('\r')
                        .to_string();
                    // Context lines exist on both sides with the same content; prefer the new
                    // side's parse since edits typically land there. Deletes use old side only.
                    let spans: &[LineSpan] = match (kind, old_n, new_n) {
                        (2, o, _) if o > 0 => old_spans.get((o - 1) as usize).map(Vec::as_slice).unwrap_or(&[]),
                        (_, _, n) if n > 0 => new_spans.get((n - 1) as usize).map(Vec::as_slice).unwrap_or(&[]),
                        (_, o, _) if o > 0 => old_spans.get((o - 1) as usize).map(Vec::as_slice).unwrap_or(&[]),
                        _ => &[],
                    };
                    out.push(kind, old_n, new_n, text, spans);
                }
            }
        }
        out
    }

    fn push(&mut self, kind: u8, old: i32, new: i32, text: String, spans: &[LineSpan]) {
        self.line_kinds.push(kind);
        self.line_old.push(old);
        self.line_new.push(new);
        let text_len = text.len() as u32;
        self.line_text.push(text);
        for s in spans {
            // Clip to current text length — span byte offsets came from the source line,
            // which may exceed the trimmed text if a trailing newline/CR was stripped.
            let off = s.offset.min(text_len);
            let end = (s.offset + s.length).min(text_len);
            if end > off {
                self.hl_offsets.push(off);
                self.hl_lengths.push(end - off);
                self.hl_kinds.push(s.kind);
            }
        }
        self.hl_starts.push(self.hl_offsets.len() as u32);
    }

    pub fn line_count(&self) -> u32 { self.line_kinds.len() as u32 }
    pub fn line_kinds(&self) -> Vec<u8> { self.line_kinds.clone() }
    pub fn line_old(&self) -> Vec<i32> { self.line_old.clone() }
    pub fn line_new(&self) -> Vec<i32> { self.line_new.clone() }
    pub fn line_text(&self) -> Vec<String> { self.line_text.clone() }
    pub fn hl_starts(&self) -> Vec<u32> { self.hl_starts.clone() }
    pub fn hl_offsets(&self) -> Vec<u32> { self.hl_offsets.clone() }
    pub fn hl_lengths(&self) -> Vec<u32> { self.hl_lengths.clone() }
    pub fn hl_kinds(&self) -> Vec<u8> { self.hl_kinds.clone() }
}

#[derive(Debug, Clone, Copy)]
struct LineSpan {
    offset: u32,
    length: u32,
    kind: u8,
}

/// Run tree-sitter highlighting on `text` and bucket the resulting spans by
/// 0-based source line index. Multi-line spans (block comments, multiline
/// strings) get split per-line. Returned vec has one entry per line in `text`.
fn spans_by_line(text: &str, lang: Language) -> Vec<Vec<LineSpan>> {
    let spans: Vec<HlSpan> = highlight::highlight(text, lang);
    let bytes = text.as_bytes();
    // line_starts[i] = byte offset of line i; sentinel at end = bytes.len().
    let mut line_starts: Vec<u32> = vec![0];
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'\n' {
            line_starts.push((i + 1) as u32);
        }
    }
    let line_count = line_starts.len();
    let total = bytes.len() as u32;

    let mut out: Vec<Vec<LineSpan>> = vec![Vec::new(); line_count];
    for s in spans {
        if s.start >= total {
            continue;
        }
        // First line whose start is > s.start, then step back one.
        let mut idx = match line_starts.binary_search(&s.start) {
            Ok(i) => i,
            Err(i) => i.saturating_sub(1),
        };
        while idx < line_count {
            let line_start = line_starts[idx];
            let line_end_raw = if idx + 1 < line_count { line_starts[idx + 1] } else { total };
            // Trim trailing \n then \r so spans don't extend past visible text.
            let mut line_end = line_end_raw;
            if line_end > line_start && bytes[(line_end - 1) as usize] == b'\n' { line_end -= 1; }
            if line_end > line_start && bytes[(line_end - 1) as usize] == b'\r' { line_end -= 1; }

            if s.end <= line_start { break; }
            let clip_start = s.start.max(line_start);
            let clip_end = s.end.min(line_end);
            if clip_end > clip_start {
                out[idx].push(LineSpan {
                    offset: clip_start - line_start,
                    length: clip_end - clip_start,
                    kind: s.kind,
                });
            }
            if s.end <= line_end_raw { break; }
            idx += 1;
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Unmerged-work detection
// ---------------------------------------------------------------------------

/// Columnar result for `open_unmerged_work`. Commits are sorted by timestamp
/// descending (most recent first).
pub struct UnmergedWorkResult {
    pub oids:      Vec<String>,
    pub summaries: Vec<String>,
    pub authors:   Vec<String>,
    pub times:     Vec<i64>,
}

/// Commits in `ref_a` but not `ref_b` whose changes still appear in the A vs B
/// tree diff. Bounded walk via `git rev-list --right-only --cherry-pick B...A`
/// (gix 0.66 has no `with_hidden`; cherry-pick drops same-patch-id commits).
/// Each surviving commit is then content-checked: at least one of its inserted
/// or deleted lines must intersect the A↔B line diff of a changed file. This
/// drops commits whose changes are already in B by some other route (e.g. a
/// larger refactor that subsumed them), which patch-id matching misses.
pub fn open_unmerged_work(
    repo_path: &Path,
    ref_a: &str,
    ref_b: &str,
) -> Result<UnmergedWorkResult, DiffError> {
    let repo = gix::open(repo_path).map_err(|e| DiffError::Open {
        path: repo_path.display().to_string(),
        source: Box::new(e),
    })?;

    let a_oid = resolve_ref_commit(&repo, ref_a)?;
    let b_oid = resolve_ref_commit(&repo, ref_b)?;

    let a_commit = repo.find_commit(a_oid).map_err(|e| DiffError::Commit {
        oid: ref_a.to_string(),
        message: e.to_string(),
    })?;
    let b_commit = repo.find_commit(b_oid).map_err(|e| DiffError::Commit {
        oid: ref_b.to_string(),
        message: e.to_string(),
    })?;

    let a_tree = a_commit.tree().map_err(|e| DiffError::Tree(e.to_string()))?;
    let b_tree = b_commit.tree().map_err(|e| DiffError::Tree(e.to_string()))?;
    let file_changes = diff_trees(&repo, &b_tree, &a_tree)?;

    let changed_paths: HashSet<String> =
        file_changes.iter().map(|fc| fc.path.clone()).collect();

    if changed_paths.is_empty() {
        return Ok(UnmergedWorkResult {
            oids: Vec::new(),
            summaries: Vec::new(),
            authors: Vec::new(),
            times: Vec::new(),
        });
    }

    // path -> (B's blob oid, A's blob oid); used to lazily build A↔B line sets.
    let ab_blobs: HashMap<String, (Option<gix::ObjectId>, Option<gix::ObjectId>)> =
        file_changes.iter().map(|fc| (fc.path.clone(), (fc.old_oid, fc.new_oid))).collect();
    let mut line_sets: HashMap<String, AbLineSets> = HashMap::new();

    let oids_in_range = rev_list_range(repo_path, b_oid, a_oid);

    let mut rows: Vec<(String, String, String, i64)> = Vec::with_capacity(oids_in_range.len());
    for oid in oids_in_range {
        let Ok(commit) = repo.find_commit(oid) else { continue };
        let Ok(new_tree) = commit.tree() else { continue };

        let old_tree = match commit.parent_ids().next() {
            Some(pid) => {
                let Ok(parent) = repo.find_commit(pid) else { continue };
                let Ok(t) = parent.tree() else { continue };
                t
            }
            None => repo.empty_tree(),
        };

        if !commit_is_meaningful(&repo, &old_tree, &new_tree, &changed_paths, &ab_blobs, &mut line_sets) {
            continue;
        }

        let oid_str = oid.to_string();
        let summary = commit
            .message_raw()
            .ok()
            .map(|m| {
                let first = m.split(|&b| b == b'\n').next().unwrap_or(b"");
                String::from_utf8_lossy(first).trim().to_string()
            })
            .unwrap_or_default();
        let (author, time) = match commit.author() {
            Ok(sig) => (sig.name.to_string(), sig.time.seconds),
            Err(_) => (String::new(), 0i64),
        };
        rows.push((oid_str, summary, author, time));
    }

    rows.sort_by(|a, b| b.3.cmp(&a.3));

    Ok(UnmergedWorkResult {
        oids:      rows.iter().map(|r| r.0.clone()).collect(),
        summaries: rows.iter().map(|r| r.1.clone()).collect(),
        authors:   rows.iter().map(|r| r.2.clone()).collect(),
        times:     rows.iter().map(|r| r.3).collect(),
    })
}

/// Per-file line sets of the A↔B diff used to decide whether a commit's
/// changes are still visible at A's tip relative to B. Built lazily once per
/// path on first lookup.
struct AbLineSets {
    /// Lines in A's tip blob that aren't in B's tip blob.
    a_only: HashSet<String>,
    /// Lines in B's tip blob that aren't in A's tip blob.
    b_only: HashSet<String>,
    /// Binary file (NUL in first 8 KiB of either blob) — we can't verify
    /// content, so any touched commit is treated as meaningful.
    binary: bool,
}

fn build_ab_line_sets(
    repo: &gix::Repository,
    b_blob: Option<gix::ObjectId>,
    a_blob: Option<gix::ObjectId>,
) -> AbLineSets {
    let read = |oid: Option<gix::ObjectId>| -> String {
        oid.and_then(|o| read_blob_text(repo, o).ok()).unwrap_or_default()
    };
    let b_text = read(b_blob);
    let a_text = read(a_blob);
    let is_binary =
        |s: &str| s.as_bytes().iter().take(8192).any(|&b| b == 0);
    if is_binary(&b_text) || is_binary(&a_text) {
        return AbLineSets { a_only: HashSet::new(), b_only: HashSet::new(), binary: true };
    }
    // Whitespace-insensitive set difference. A line whose only difference
    // between branches is leading/trailing whitespace ends up in both
    // `a_lines` and `b_lines` and therefore in neither "only" set — so the
    // commit that introduced one indentation isn't flagged when the other
    // indentation already lives on B.
    let normalize = |s: &str| -> Option<String> {
        let t = s.trim();
        if t.is_empty() { None } else { Some(t.to_string()) }
    };
    let a_lines: HashSet<String> = a_text.lines().filter_map(normalize).collect();
    let b_lines: HashSet<String> = b_text.lines().filter_map(normalize).collect();
    let a_only: HashSet<String> = a_lines.difference(&b_lines).cloned().collect();
    let b_only: HashSet<String> = b_lines.difference(&a_lines).cloned().collect();
    AbLineSets { a_only, b_only, binary: false }
}

/// True if the commit (`parent_tree` → `commit_tree`) touches any file in
/// `changed_paths` AND at least one of its inserted/deleted lines still
/// appears in the A↔B diff of that file. The second check drops commits whose
/// changes are already in B by some other route — e.g. a larger refactor on
/// B's side that subsumed the same lines, which `--cherry-pick` patch-id
/// matching can't catch. Binary touches are treated as meaningful (no content
/// to compare).
fn commit_is_meaningful(
    repo: &gix::Repository,
    parent_tree: &gix::Tree<'_>,
    commit_tree: &gix::Tree<'_>,
    changed_paths: &HashSet<String>,
    ab_blobs: &HashMap<String, (Option<gix::ObjectId>, Option<gix::ObjectId>)>,
    line_sets: &mut HashMap<String, AbLineSets>,
) -> bool {
    let mut meaningful = false;
    if let Ok(mut changes) = parent_tree.changes() {
        let _ = changes
            .track_path()
            .track_rewrites(None)
            .for_each_to_obtain_tree(commit_tree, |change| -> Result<_, Infallible> {
                let path = change.location.to_string();
                if !changed_paths.contains(&path) {
                    return Ok(gix::object::tree::diff::Action::Continue);
                }
                let (c_old, c_new) = match change.event {
                    gix::object::tree::diff::change::Event::Addition { id, .. } => (None, Some(id.detach())),
                    gix::object::tree::diff::change::Event::Deletion { id, .. } => (Some(id.detach()), None),
                    gix::object::tree::diff::change::Event::Modification { previous_id, id, .. } => {
                        (Some(previous_id.detach()), Some(id.detach()))
                    }
                    _ => return Ok(gix::object::tree::diff::Action::Continue),
                };

                if !line_sets.contains_key(&path) {
                    let (b_blob, a_blob) = ab_blobs.get(&path).copied().unwrap_or((None, None));
                    line_sets.insert(path.clone(), build_ab_line_sets(repo, b_blob, a_blob));
                }
                let sets = &line_sets[&path];

                if sets.binary {
                    meaningful = true;
                    return Ok(gix::object::tree::diff::Action::Cancel);
                }

                let read = |oid: Option<gix::ObjectId>| -> String {
                    oid.and_then(|o| read_blob_text(repo, o).ok()).unwrap_or_default()
                };
                let old_text = read(c_old);
                let new_text = read(c_new);
                let nul_in =
                    |s: &str| s.as_bytes().iter().take(8192).any(|&b| b == 0);
                if nul_in(&old_text) || nul_in(&new_text) {
                    meaningful = true;
                    return Ok(gix::object::tree::diff::Action::Cancel);
                }

                let tdiff = TextDiff::from_lines(&old_text, &new_text);
                for ch in tdiff.iter_all_changes() {
                    let line = ch.value().trim().to_string();
                    if line.is_empty() { continue; }
                    let hit = match ch.tag() {
                        ChangeTag::Insert => sets.a_only.contains(&line),
                        ChangeTag::Delete => sets.b_only.contains(&line),
                        ChangeTag::Equal => false,
                    };
                    if hit {
                        meaningful = true;
                        return Ok(gix::object::tree::diff::Action::Cancel);
                    }
                }
                Ok(gix::object::tree::diff::Action::Continue)
            });
    }
    meaningful
}

/// Shell to `git rev-list --right-only --cherry-pick <b>...<a>` and parse the
/// OIDs. gix 0.66's rev-walk has no hidden-tip support — same pattern as
/// `repo::divergence`. `--cherry-pick` drops commits in A whose patch-id has an
/// equivalent on B's side (i.e. cherry-picks: same diff, different SHA). Any
/// failure degrades to an empty list (better an empty result than a hung UI).
fn rev_list_range(path: &Path, b_oid: gix::ObjectId, a_oid: gix::ObjectId) -> Vec<gix::ObjectId> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .arg("rev-list")
        .arg("--right-only")
        .arg("--cherry-pick")
        .arg(format!("{b_oid}...{a_oid}"))
        .output();
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|line| line.trim().parse().ok())
            .collect(),
        _ => Vec::new(),
    }
}
