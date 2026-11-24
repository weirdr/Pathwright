//! `fg guide-walks` gives each leg the walk the addon gets in a guide of the app between the
//! same places, on the ground of Tirisfal Glades.
use fg_route::Route;
use fg_route::faction::Faction;
use fg_route::job;
use fg_route::plan::Breakdown;
use fg_route::xp::Edition;
use serde_json::{Value, json};
use std::{path::PathBuf, process::Command};

#[test]
fn each_leg_gets_the_walk_of_a_guide() {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let temp = std::env::temp_dir().join(format!("factoruide-guide-walks-cli-{}", std::process::id()));
    std::fs::create_dir_all(&temp).unwrap();
    let mut conn = fg_route::fixture::Fixture::new(Edition::Classic)
        .file("classic_tirisfal_terrain")
        .open();
    let database = temp.join("classic.sqlite");
    std::fs::write(&database, conn.serialize(rusqlite::MAIN_DB).unwrap().to_vec()).unwrap();
    // Deathknell to the slope north of it: the walk goes around the steep ground.
    let (start, end) = ((30.23, 71.61), (30.87, 66.2));
    let at = |(x, y): (f64, f64)| json!({ "m": 1420, "x": x, "y": y });
    let legs = json!({ "faction": "Horde", "legs": [
        { "from": at(start), "to": at(end), "level": 2 },
        { "from": at(start), "to": at((30.24, 71.62)), "level": 2 },
        { "from": { "m": 999_999, "x": 1, "y": 1 }, "to": at(end), "level": 2 },
        { "from": { "taxi": "Nowhere" }, "to": at(end), "level": 2 },
        { "from": at(start), "to": at(end), "level": 2 },
    ]});
    let input = temp.join("legs.json");
    std::fs::write(&input, legs.to_string()).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_fg"))
        .current_dir(&repo)
        .args(["--edition", "classic", "--db"])
        .arg(&database)
        .arg("guide-walks")
        .arg(&input)
        .output()
        .unwrap();
    let error = String::from_utf8(out.stderr).unwrap();
    assert!(out.status.success(), "{error}");
    assert!(error.contains("leg 2: from place not found"), "{error}");
    assert!(error.contains("leg 3: from place not found"), "{error}");
    let walks: Value = serde_json::from_slice(&out.stdout).unwrap();
    let walks: Vec<Vec<i64>> = serde_json::from_value(walks["walks"].clone()).unwrap();

    // The same two places as steps of a guide.
    let overrides = job::Overrides::load_edition(&repo.join("overrides"), Edition::Classic).unwrap();
    let world = job::leveled_walk_world(&conn, &overrides, Faction::Horde).unwrap();
    let steps: Vec<_> = [start, end]
        .iter()
        .map(|(x, y)| json!({ "kind": "accept", "map": { "ui_map": 1420, "x": x, "y": y }, "level": 2, "time": 0.0 }))
        .collect();
    let mut route: Route = serde_json::from_value(json!({
        "name": "walks", "race_id": 5, "class_id": 1, "class": "Warrior", "faction": "Horde",
        "from_level": 1, "to_level": 10, "total_time": 0.0, "total_time_text": "", "quests": 0,
        "breakdown": serde_json::to_value(Breakdown::default()).unwrap(), "steps": steps,
    }))
    .unwrap();
    job::add_walk_paths(&world, &mut route);
    let to = job::map_position(&world, 1420, end.0, end.1).unwrap();
    let guide: Vec<i64> = fg_route::export::lighten_walk(&route.steps[1].path, [to.x, to.y])
        .iter()
        .flat_map(|p| [p[0] as i64, p[1] as i64])
        .collect();

    assert!(!guide.is_empty(), "the walk turns");
    assert_eq!(walks.len(), 5);
    assert_eq!(walks[0], guide);
    assert!(walks[1].is_empty(), "in sight");
    assert!(walks[2].is_empty() && walks[3].is_empty(), "nowhere");
    assert_eq!(walks[4], guide, "the same leg again");
    std::fs::remove_dir_all(temp).unwrap();
}
