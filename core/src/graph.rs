//! Commit-graph layout.
//!
//! Given a set of ref names to include, walks the reachable history and
//! assigns each commit a `(lane, color)` so the Swift Canvas can paint
//! without any layout logic of its own.
//!
//! Algorithm (intentionally simple for first cut):
//!
//! 1. Walk all selected tips together via `rev_walk(...).all()` to enumerate
//!    every reachable commit in topo+date order, collecting parents.
//! 2. **First-parent ownership pass:** for each tip in priority order (HEAD
//!    first), follow the first-parent chain from the tip; claim commits
//!    until we hit one already claimed by an earlier tip. Each tip gets a
//!    fresh lane and color index.
//! 3. **Second-parent pass:** for each merge commit, walk first-parent from
//!    each non-first parent that is still unclaimed, again allocating a
//!    fresh lane and color. This is how merged-in branches (often with no
//!    surviving ref) get their own lane.
//!
//! Lanes are never re-used. For typical filtered views (HEAD + a handful of
//! branches) that produces a small fixed number of lanes; we'll revisit if
//! a future view wants thousands of lanes on screen.

use std::collections::HashMap;
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum GraphError {
    #[error("could not open repository at {path}: {source}")]
    Open {
        path: String,
        #[source]
        source: Box<gix::open::Error>,
    },
    #[error("no tips selected")]
    NoTips,
    #[error("ref not found: {0}")]
    RefNotFound(String),
}

#[derive(Debug, Clone)]
pub struct GraphTip {
    pub name: String,
    pub oid: String,
    pub color: u32,
    pub is_remote: bool,
    /// For local refs only: an `origin/<name>` counterpart exists.
    pub is_tracked: bool,
}

pub struct Graph {
    /// Walk order: commit oids in topo+date order produced by `rev_walk(...).all()`.
    oids: Vec<String>,
    times: Vec<i64>,
    lanes: Vec<u32>,
    colors: Vec<u32>,
    /// CSR layout for parents: `parent_starts[i]..parent_starts[i+1]` slice into
    /// `parent_oids`. `parent_starts` has length `commit_count + 1`.
    parent_starts: Vec<u32>,
    parent_oids: Vec<String>,
    tips: Vec<GraphTip>,
}

impl Graph {
    pub fn commit_count(&self) -> u32 { self.oids.len() as u32 }
    pub fn oids(&self) -> Vec<String> { self.oids.clone() }
    pub fn times(&self) -> Vec<i64> { self.times.clone() }
    pub fn lanes(&self) -> Vec<u32> { self.lanes.clone() }
    pub fn colors(&self) -> Vec<u32> { self.colors.clone() }
    pub fn parent_starts(&self) -> Vec<u32> { self.parent_starts.clone() }
    pub fn parent_oids(&self) -> Vec<String> { self.parent_oids.clone() }

    pub fn tip_count(&self) -> u32 { self.tips.len() as u32 }
    pub fn tip_names(&self) -> Vec<String> { self.tips.iter().map(|t| t.name.clone()).collect() }
    pub fn tip_oids(&self) -> Vec<String> { self.tips.iter().map(|t| t.oid.clone()).collect() }
    pub fn tip_colors(&self) -> Vec<u32> { self.tips.iter().map(|t| t.color).collect() }
    pub fn tip_is_remote(&self) -> Vec<u8> {
        self.tips.iter().map(|t| if t.is_remote { 1 } else { 0 }).collect()
    }
    pub fn tip_is_tracked(&self) -> Vec<u8> {
        self.tips.iter().map(|t| if t.is_tracked { 1 } else { 0 }).collect()
    }
}

pub fn build(repo_path: &Path, ref_names: &[String]) -> Result<Graph, GraphError> {
    let repo = gix::open(repo_path).map_err(|e| GraphError::Open {
        path: repo_path.display().to_string(),
        source: Box::new(e),
    })?;

    if ref_names.is_empty() {
        return Err(GraphError::NoTips);
    }

    // Resolve each requested name to (full_name, oid, is_remote, is_tracked).
    // The same short-name might appear as both a local and a remote ref; we
    // prefer the local one because that's the more common UX expectation.
    let platform = repo.references().map_err(|_| GraphError::RefNotFound("references()".to_string()))?;
    let mut remote_short_set = std::collections::HashSet::new();
    if let Ok(iter) = platform.remote_branches() {
        for r in iter.flatten() {
            remote_short_set.insert(r.name().shorten().to_string());
        }
    }

    let mut tip_infos: Vec<(String, gix::ObjectId, bool, bool)> = Vec::with_capacity(ref_names.len());
    for name in ref_names {
        // Try local: refs/heads/<name>
        let full = format!("refs/heads/{name}");
        if let Ok(mut reference) = repo.find_reference(&full) {
            let id = reference.peel_to_id_in_place().map_err(|_| GraphError::RefNotFound(name.clone()))?;
            let tracked = remote_short_set.contains(&format!("origin/{name}"));
            tip_infos.push((name.clone(), id.detach(), false, tracked));
            continue;
        }
        // Try remote: refs/remotes/<name>
        let full = format!("refs/remotes/{name}");
        if let Ok(mut reference) = repo.find_reference(&full) {
            let id = reference.peel_to_id_in_place().map_err(|_| GraphError::RefNotFound(name.clone()))?;
            tip_infos.push((name.clone(), id.detach(), true, true));
            continue;
        }
        // Try tag: refs/tags/<name>. Peels annotated tags to their commit.
        // Drawn like a tracked ref (`is_tracked = true`) — solid, filled dot.
        let full = format!("refs/tags/{name}");
        if let Ok(mut reference) = repo.find_reference(&full) {
            let id = reference.peel_to_id_in_place().map_err(|_| GraphError::RefNotFound(name.clone()))?;
            tip_infos.push((name.clone(), id.detach(), false, true));
            continue;
        }
        return Err(GraphError::RefNotFound(name.clone()));
    }

    // Walk every commit reachable from any tip, in topo+date order.
    let tip_oids: Vec<gix::ObjectId> = tip_infos.iter().map(|(_, oid, _, _)| *oid).collect();
    let walker = repo
        .rev_walk(tip_oids.iter().copied())
        .all()
        .map_err(|_| GraphError::RefNotFound("rev_walk".to_string()))?;

    let mut all_oids: Vec<gix::ObjectId> = Vec::new();
    let mut all_parents: Vec<Vec<gix::ObjectId>> = Vec::new();
    let mut all_times: Vec<i64> = Vec::new();
    let mut idx_of: HashMap<gix::ObjectId, usize> = HashMap::new();
    for info in walker {
        let Ok(info) = info else { continue };
        let id = info.id;
        let Ok(commit) = repo.find_commit(id) else { continue };
        let parents: Vec<gix::ObjectId> = commit.parent_ids().map(|p| p.detach()).collect();
        let time = commit.committer().map(|s| s.time.seconds).unwrap_or(0);
        idx_of.insert(id, all_oids.len());
        all_oids.push(id);
        all_parents.push(parents);
        all_times.push(time);
    }

    let n = all_oids.len();
    let mut commit_lane = vec![u32::MAX; n];
    let mut commit_color = vec![u32::MAX; n];
    let mut next_lane: u32 = 0;

    // First-parent ownership pass: each tip in priority order.
    for (tip_idx, (_, tip_oid, _, _)) in tip_infos.iter().enumerate() {
        let lane = next_lane;
        next_lane += 1;
        let color = tip_idx as u32;
        let mut cur: Option<gix::ObjectId> = Some(*tip_oid);
        while let Some(oid) = cur {
            let Some(&i) = idx_of.get(&oid) else { break };
            if commit_lane[i] != u32::MAX { break; }
            commit_lane[i] = lane;
            commit_color[i] = color;
            cur = all_parents[i].first().copied();
        }
    }

    // Second-parent pass: claim merged-in ancestry on fresh lanes.
    let tip_count = tip_infos.len() as u32;
    let mut next_color_for_merge: u32 = tip_count;
    for i in 0..n {
        if all_parents[i].len() < 2 { continue; }
        for p in all_parents[i].iter().skip(1) {
            let Some(&pi) = idx_of.get(p) else { continue };
            if commit_lane[pi] != u32::MAX { continue; }
            let lane = next_lane; next_lane += 1;
            let color = next_color_for_merge; next_color_for_merge += 1;
            let mut cur: Option<gix::ObjectId> = Some(*p);
            while let Some(oid) = cur {
                let Some(&j) = idx_of.get(&oid) else { break };
                if commit_lane[j] != u32::MAX { break; }
                commit_lane[j] = lane;
                commit_color[j] = color;
                cur = all_parents[j].first().copied();
            }
        }
    }

    // Anything still unclaimed (shouldn't really happen given the passes
    // above, but be defensive): treat as lane 0 / color 0.
    for i in 0..n {
        if commit_lane[i] == u32::MAX { commit_lane[i] = 0; }
        if commit_color[i] == u32::MAX { commit_color[i] = 0; }
    }

    // Flatten parents into CSR layout.
    let mut parent_starts: Vec<u32> = Vec::with_capacity(n + 1);
    let mut parent_oids: Vec<String> = Vec::new();
    parent_starts.push(0);
    for parents in &all_parents {
        for p in parents { parent_oids.push(p.to_string()); }
        parent_starts.push(parent_oids.len() as u32);
    }

    let oids_str: Vec<String> = all_oids.iter().map(|o| o.to_string()).collect();

    let tips: Vec<GraphTip> = tip_infos
        .into_iter()
        .enumerate()
        .map(|(i, (name, oid, is_remote, is_tracked))| GraphTip {
            name,
            oid: oid.to_string(),
            color: i as u32,
            is_remote,
            is_tracked,
        })
        .collect();

    Ok(Graph {
        oids: oids_str,
        times: all_times,
        lanes: commit_lane,
        colors: commit_color,
        parent_starts,
        parent_oids,
        tips,
    })
}
