//! `overrides/npc_places.toml`: the file the guide writer and the guide builder share.

use fg_route::faction::Faction;
use fg_route::xp::Edition;

/// Every entry says why, names a map the world knows and stays on the map (0-100).
#[test]
fn each_place_has_a_reason_a_known_map_and_coordinates_on_it() {
    let entries = fg_route::world::npc_place_entries().unwrap();
    assert!(!entries.is_empty());
    let world = crate::common::bare_world(Edition::Classic, Faction::Alliance);
    for e in &entries {
        assert!(!e.reason.trim().is_empty(), "NPC {} has no reason", e.id);
        assert!(
            world.zone_of_ui_map(e.map).is_some(),
            "NPC {}: unknown map {}",
            e.id,
            e.map
        );
        assert!(
            (0.0..=100.0).contains(&e.x) && (0.0..=100.0).contains(&e.y),
            "NPC {}: {}, {} is off the map",
            e.id,
            e.x,
            e.y
        );
    }
}
