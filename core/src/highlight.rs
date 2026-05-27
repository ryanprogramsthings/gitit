//! Syntax highlighting via tree-sitter. Maps each grammar's `highlights.scm`
//! captures into a small palette of kinds the UI knows how to color.
//!
//! Output is a flat `Vec<HlSpan>` over the whole source text, sorted by start
//! byte. The diff builder slices this into per-line spans.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Language {
    Swift,
    Kotlin,
}

pub fn detect_language(path: &str) -> Option<Language> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".swift") {
        Some(Language::Swift)
    } else if lower.ends_with(".kt") || lower.ends_with(".kts") {
        Some(Language::Kotlin)
    } else {
        None
    }
}

// Keep the palette small and stable — the Swift renderer hard-codes a color per kind.
pub const KIND_NONE: u8 = u8::MAX;
pub const KIND_KEYWORD: u8 = 0;
pub const KIND_STRING: u8 = 1;
pub const KIND_COMMENT: u8 = 2;
pub const KIND_TYPE: u8 = 3;
pub const KIND_FUNCTION: u8 = 4;
pub const KIND_NUMBER: u8 = 5;
pub const KIND_VARIABLE: u8 = 6;
pub const KIND_OPERATOR: u8 = 7;

#[derive(Debug, Clone, Copy)]
pub struct HlSpan {
    pub start: u32,
    pub end: u32,
    pub kind: u8,
}

pub fn highlight(text: &str, lang: Language) -> Vec<HlSpan> {
    let (language, query_src) = match lang {
        Language::Swift => (tree_sitter_swift::language(), tree_sitter_swift::HIGHLIGHTS_QUERY),
        Language::Kotlin => (tree_sitter_kotlin::language(), tree_sitter_kotlin::HIGHLIGHTS_QUERY),
    };

    let mut parser = tree_sitter::Parser::new();
    if parser.set_language(&language).is_err() {
        return Vec::new();
    }
    let Some(tree) = parser.parse(text, None) else { return Vec::new() };
    let Ok(query) = tree_sitter::Query::new(&language, query_src) else {
        return Vec::new();
    };

    let mut cursor = tree_sitter::QueryCursor::new();
    let bytes = text.as_bytes();
    let capture_names = query.capture_names();

    // Innermost (last) capture wins for any byte. Collect all, sort by (start, -length),
    // then a single sweep keeps only the non-overlapping innermost spans.
    let mut raw: Vec<HlSpan> = Vec::new();
    for (m, cap_idx) in cursor.captures(&query, tree.root_node(), bytes) {
        let cap = m.captures[cap_idx];
        let name = capture_names[cap.index as usize];
        let kind = classify(name);
        if kind == KIND_NONE {
            continue;
        }
        let node = cap.node;
        let start = node.start_byte() as u32;
        let end = node.end_byte() as u32;
        if start >= end {
            continue;
        }
        raw.push(HlSpan { start, end, kind });
    }

    raw.sort_by(|a, b| a.start.cmp(&b.start).then(b.end.cmp(&a.end)));

    // Flatten overlaps: walk in order, when a later span's start falls inside the previous,
    // either drop it (same kind / pure containment) or replace the tail of the previous.
    let mut out: Vec<HlSpan> = Vec::with_capacity(raw.len());
    for span in raw {
        if let Some(prev) = out.last_mut() {
            if span.start < prev.end {
                if span.end <= prev.end {
                    // Nested span: split prev into (prev.start, span.start) — span — (span.end, prev.end).
                    let prev_end = prev.end;
                    let prev_kind = prev.kind;
                    prev.end = span.start;
                    if prev.start >= prev.end {
                        out.pop();
                    }
                    out.push(span);
                    if span.end < prev_end {
                        out.push(HlSpan { start: span.end, end: prev_end, kind: prev_kind });
                    }
                    continue;
                } else {
                    // Partial overlap: trim prev.
                    prev.end = span.start;
                    if prev.start >= prev.end {
                        out.pop();
                    }
                }
            }
        }
        out.push(span);
    }
    out
}

fn classify(name: &str) -> u8 {
    // Order matters: check most specific prefixes first.
    if name == "comment" || name.starts_with("comment.") {
        KIND_COMMENT
    } else if name == "string" || name.starts_with("string.") || name == "character" {
        KIND_STRING
    } else if name == "keyword"
        || name.starts_with("keyword.")
        || name == "conditional"
        || name == "repeat"
        || name == "include"
        || name == "exception"
        || name == "namespace"
    {
        KIND_KEYWORD
    } else if name == "type" || name.starts_with("type.") {
        KIND_TYPE
    } else if name == "function"
        || name.starts_with("function.")
        || name == "method"
        || name == "constructor"
    {
        KIND_FUNCTION
    } else if name == "number"
        || name == "float"
        || name == "boolean"
        || name == "constant"
        || name.starts_with("number.")
        || name.starts_with("constant.")
    {
        KIND_NUMBER
    } else if name == "variable"
        || name.starts_with("variable.")
        || name == "parameter"
        || name == "property"
        || name == "attribute"
        || name == "label"
    {
        KIND_VARIABLE
    } else if name == "operator" || name.starts_with("punctuation.") {
        KIND_OPERATOR
    } else {
        KIND_NONE
    }
}
