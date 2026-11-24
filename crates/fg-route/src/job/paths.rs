//! The walks of a guide for the addon: where each walk from one step to the next turns, so that
//! the compass shows which way to go around the steep ground.

use super::Overrides;
use crate::export::{Route, Step, StepKind};
use crate::faction::Faction;
use crate::sync::Joined;
use crate::world::{Pos, World, WorldBuilder};
use anyhow::Result;
use rusqlite::Connection;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Walks shorter than this (yards) are not worked out: the step is in sight.
const SHORT: f64 = 40.0;

/// The world as the planner walks it for a faction: the terrain, the areas left only by boat and
/// the passages between zones.
pub fn walk_world(conn: &Connection, overrides: &Overrides, faction: Faction) -> Result<World> {
    world_of(conn, overrides, faction, false)
}

/// `walk_world` with the zones whose mobs are too strong for a character closed to its walks
/// (`World::walk_level`), as in the world the guides of the app are walked in (`Editor::set_walks`).
pub fn leveled_walk_world(conn: &Connection, overrides: &Overrides, faction: Faction) -> Result<World> {
    world_of(conn, overrides, faction, true)
}

fn world_of(conn: &Connection, overrides: &Overrides, faction: Faction, levels: bool) -> Result<World> {
    let params = &overrides.params;
    let passes: Vec<_> = (overrides.passes.iter())
        .filter(|p| params.shortcuts || !p.shortcut)
        .cloned()
        .collect();
    let mut builder = WorldBuilder::load(conn, faction, params.flight_speed, params.drop_tier())?;
    if levels {
        builder = builder.zone_levels(params.zone_gap)?;
    }
    let (world, _) = builder
        .closed(&overrides.closed)
        .enclosed(&overrides.enclosed)
        .caves(&overrides.caves)
        .passes(&passes, crate::world::WorldTables::shared())?
        .build();
    Ok(world)
}

/// Fill each step's `path`: the start and turns of the walk to it from where the step before
/// leaves the character (a flight's landing, the inn of a hearthstone), when it does not go
/// straight. None after a boat, a teleport or a step without a place, for the steps done along
/// the way and inside dungeons.
pub fn add_walk_paths(world: &World, route: &mut Route) {
    for step in &mut route.steps {
        step.path.clear();
    }
    // The walks, in order (where one starts depends on the steps before), then searched side by
    // side: each on its own.
    let walks = route_walks(world, route);
    let ends: Vec<_> = walks.iter().map(|&(_, a, b, level)| (a, b, level)).collect();
    for ((k, ..), path) in walks.iter().zip(walk_turns(world, &ends)) {
        route.steps[*k].path = path;
    }
}

/// Whether the walk from `a` to `b` is worked out: on one continent, and not in sight.
pub fn walk_shown(a: &Pos, b: &Pos) -> bool {
    a.continent == b.continent && a.dist(b) >= SHORT
}

/// The start and turns of each walk (from, to, walk level), in whole yards, searched side by
/// side: empty for one that goes straight. A walk the zones closed at its level stop is made
/// with them open (as `Editor::set_walks` draws it).
pub fn walk_turns(world: &World, walks: &[(Pos, Pos, u8)]) -> Vec<Vec<[f64; 2]>> {
    let next = AtomicUsize::new(0);
    let threads = std::thread::available_parallelism()
        .map_or(1, usize::from)
        .min(walks.len());
    let found: Vec<(usize, Vec<[f64; 2]>)> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..threads)
            .map(|_| {
                scope.spawn(|| {
                    let _release = crate::threads::Release;
                    let mut found = Vec::new();
                    loop {
                        let k = next.fetch_add(1, Ordering::Relaxed);
                        let Some(&(a, b, mut level)) = walks.get(k) else {
                            break;
                        };
                        if level != 0 && !world.walk_distance_at(&a, &b, level).is_finite() {
                            level = 0;
                        }
                        let walk = world.walk_path(&a, &b, level);
                        if walk.len() > 2 {
                            found.push((
                                k,
                                walk[..walk.len() - 1]
                                    .iter()
                                    .map(|p| [p.x.round(), p.y.round()])
                                    .collect(),
                            ));
                        }
                    }
                    found
                })
            })
            .collect();
        workers.into_iter().flat_map(|w| w.join().joined()).collect()
    });
    let mut turns = vec![Vec::new(); walks.len()];
    for (k, path) in found {
        turns[k] = path;
    }
    turns
}

/// Where a flight to taxi node `id` lands.
pub fn landing(world: &World, id: i64) -> Option<Pos> {
    let node = world.taxi_nodes.iter().find(|n| n.id == id)?;
    Some(Pos {
        zone: world.zone_at(&node.pos).unwrap_or(0),
        ..node.pos
    })
}

/// Where a place of a map is (percent coordinates of a UiMap), in world space.
pub fn map_position(world: &World, ui_map: i64, x: f64, y: f64) -> Option<Pos> {
    let zone = world.zone_of_ui_map(ui_map)?;
    world.to_world(zone, x, y)
}

/// The walks of a route from one step to the next (`add_walk_paths`): the step walked to, from
/// where, to where, and the walk level of the character then (`World::walk_level`).
pub fn route_walks(world: &World, route: &Route) -> Vec<(usize, Pos, Pos, u8)> {
    let mut walks: Vec<(usize, Pos, Pos, u8)> = Vec::new();
    let mut from: Option<Pos> = None;
    for (k, step) in route.steps.iter().enumerate() {
        if step.bg || step.inside {
            continue;
        }
        let here = position(world, step);
        if let (Some(a), Some(b)) = (&from, &here)
            && walk_shown(a, b)
        {
            walks.push((k, *a, *b, world.walk_level(step.level)));
        }
        from = match step.kind {
            // Where the flight lands.
            StepKind::Fly => step.target.as_ref().and_then(|t| landing(world, t.id)),
            StepKind::Link | StepKind::Teleport => None,
            _ => here.or(from),
        };
    }
    walks
}

/// Where a step is: its world position, else (guides made before they had it) its map's.
fn position(world: &World, step: &Step) -> Option<Pos> {
    let p = if let Some([continent, x, y]) = step.world {
        Pos {
            continent: continent as i64,
            x,
            y,
            zone: step.zone_id.unwrap_or(0),
            z: step.height,
        }
    } else {
        let map = step.map.as_ref()?;
        map_position(world, map.ui_map, map.x, map.y)?
    };
    Some(Pos {
        zone: if p.zone == 0 {
            world.zone_at(&p).unwrap_or(0)
        } else {
            p.zone
        },
        ..p
    })
}
