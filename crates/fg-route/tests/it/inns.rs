//! `overrides/inns.toml`: the file the guide writer and the guide builder share.

use std::collections::HashSet;

#[derive(serde::Deserialize)]
struct Entry {
    npc: i64,
    place: Option<String>,
    reason: String,
}

#[derive(serde::Deserialize)]
struct File {
    inn: Vec<Entry>,
    left_out: Vec<Entry>,
}

fn file() -> File {
    toml::from_str(include_str!("../../../../overrides/inns.toml")).unwrap()
}

/// An innkeeper decided on is in one list only, and every entry says why: the check of
/// `scripts/check-inns.py` relies on it.
#[test]
fn each_innkeeper_is_listed_once_with_a_reason() {
    let file = file();
    let mut seen = HashSet::new();
    for e in file.inn.iter().chain(&file.left_out) {
        assert!(seen.insert(e.npc), "innkeeper {} is listed twice", e.npc);
        assert!(!e.reason.trim().is_empty(), "innkeeper {} has no reason", e.npc);
    }
}

/// A listed innkeeper names its place; one left out does not (it would be taken for decided).
#[test]
fn only_listed_innkeepers_have_a_place() {
    let file = file();
    for e in &file.inn {
        assert!(
            e.place.as_deref().is_some_and(|p| !p.trim().is_empty()),
            "innkeeper {} has no place",
            e.npc
        );
    }
    for e in &file.left_out {
        assert!(e.place.is_none(), "left-out innkeeper {} names a place", e.npc);
    }
}
