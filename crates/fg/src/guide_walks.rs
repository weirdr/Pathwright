//! `fg guide-walks`: the walks of a batch of legs (from a place to the next, at a level) as the
//! addon gets them in a guide of the app (`wp`), for the built-in guides.

use anyhow::{Context, Result, bail};
use fg_route::export::lighten_walk;
use fg_route::faction::Faction;
use fg_route::job::{Overrides, landing, leveled_walk_world, map_position, walk_shown, walk_turns};
use fg_route::world::{Pos, World};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::Read as _;
use std::path::Path;

/// Where a leg starts or ends.
#[derive(Debug, Clone, PartialEq)]
enum Place {
    /// A UiMap and percent coordinates (0-100) on it.
    Map { ui_map: i64, x: f64, y: f64 },
    /// Where a flight to a taxi node lands, by its id (`client_taxinodes.ID`).
    TaxiId(i64),
    /// The same, by the node's exact name (any case).
    TaxiName(String),
}

#[derive(Debug, Clone, PartialEq)]
struct Leg {
    from: Place,
    to: Place,
    level: i64,
}

/// Reads `input` (`-`: stdin), `{"faction", "legs": [{"from", "to", "level"}]}`, and writes
/// `{"walks": [[x1, y1, x2, y2...], ...]}`, a walk by leg (world yards, the start then the turns,
/// the leg's end left out; empty: none).
pub fn run(conn: &Connection, overrides_dir: &Path, input: &Path, out: Option<&Path>) -> Result<()> {
    let text = if input == Path::new("-") {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text)?;
        text
    } else {
        std::fs::read_to_string(input).with_context(|| format!("reading {}", input.display()))?
    };
    let (faction, legs) = parse(&text)?;
    let overrides = Overrides::load_edition(overrides_dir, crate::edition())?;
    let world = leveled_walk_world(conn, &overrides, faction)?;
    let (walks, searched, unresolved) = leg_walks(&world, &legs);
    let found = walks.iter().filter(|w| !w.is_empty()).count();
    let walks: Vec<Vec<i64>> = (walks.iter())
        .map(|w| w.iter().flat_map(|p| [p[0] as i64, p[1] as i64]).collect())
        .collect();
    let text = json!({ "walks": walks }).to_string();
    match out {
        Some(out) => std::fs::write(out, text + "\n").with_context(|| format!("writing {}", out.display()))?,
        None => println!("{text}"),
    }
    eprintln!(
        "guide-walks: {} legs ({searched} searched), {found} walks, {unresolved} places not found",
        legs.len()
    );
    Ok(())
}

/// The faction and the legs of the input.
fn parse(text: &str) -> Result<(Faction, Vec<Leg>)> {
    let v: Value = serde_json::from_str(text).context("reading the legs (JSON)")?;
    let name = v["faction"].as_str().context("no faction")?;
    let faction = Faction::parse(name).with_context(|| format!("{name}: not a faction (horde, alliance)"))?;
    let legs = (v["legs"].as_array().context("no legs")?.iter().enumerate())
        .map(|(i, l)| -> Result<Leg> {
            Ok(Leg {
                from: place(&l["from"]).with_context(|| format!("leg {i}: from"))?,
                to: place(&l["to"]).with_context(|| format!("leg {i}: to"))?,
                level: l["level"].as_i64().with_context(|| format!("leg {i}: no level"))?,
            })
        })
        .collect::<Result<_>>()?;
    Ok((faction, legs))
}

/// `{"m", "x", "y"}` or `{"taxi": id or name}`.
fn place(v: &Value) -> Result<Place> {
    match (&v["taxi"], v["m"].as_i64(), v["x"].as_f64(), v["y"].as_f64()) {
        (Value::Number(n), ..) => Ok(Place::TaxiId(n.as_i64().context("not a taxi node id")?)),
        (Value::String(s), ..) => Ok(Place::TaxiName(s.clone())),
        (Value::Null, Some(ui_map), Some(x), Some(y)) => Ok(Place::Map { ui_map, x, y }),
        _ => bail!("not a place: {v}"),
    }
}

/// Where a place is in the world, if it is known.
fn resolve(world: &World, place: &Place) -> Option<Pos> {
    match place {
        Place::Map { ui_map, x, y } => map_position(world, *ui_map, *x, *y),
        Place::TaxiId(id) => landing(world, *id),
        // The node's whole name ("Thunder Bluff, Mulgore"), else its town's ("Thunder Bluff"):
        // one node only.
        Place::TaxiName(name) => {
            let name = name.to_lowercase();
            let town = |n: &str| n.split(',').next().unwrap_or(n).trim().to_owned();
            let one = |is: &dyn Fn(&str) -> bool| {
                let mut nodes = world.taxi_nodes.iter().filter(|n| is(&n.name.to_lowercase()));
                match (nodes.next(), nodes.next()) {
                    (Some(node), None) => Some(node.id),
                    _ => None,
                }
            };
            let id = one(&|n| n == name).or_else(|| one(&|n| town(n) == name))?;
            landing(world, id)
        }
    }
}

/// Each leg's walk for the addon (`add_walk_paths`, then `lighten_walk`), the walks searched
/// (the same leg once) and the places not found.
fn leg_walks(world: &World, legs: &[Leg]) -> (Vec<Vec<[f64; 2]>>, usize, usize) {
    let mut unresolved = 0;
    let mut ends: Vec<(Pos, Pos, u8)> = Vec::new();
    let mut seen = HashMap::new();
    let mut which = Vec::with_capacity(legs.len());
    for (i, leg) in legs.iter().enumerate() {
        let (a, b) = (resolve(world, &leg.from), resolve(world, &leg.to));
        for (p, end, place) in [(&a, "from", &leg.from), (&b, "to", &leg.to)] {
            if p.is_none() {
                unresolved += 1;
                eprintln!("leg {i}: {end} place not found: {place:?}");
            }
        }
        let (Some(a), Some(b)) = (a, b) else {
            which.push(None);
            continue;
        };
        if !walk_shown(&a, &b) {
            which.push(None);
            continue;
        }
        let level = world.walk_level(leg.level);
        let key = (a.continent, [a.x, a.y, b.x, b.y].map(f64::to_bits), a.z, b.z, level);
        let n = *seen.entry(key).or_insert_with(|| {
            ends.push((a, b, level));
            ends.len() - 1
        });
        which.push(Some(n));
    }
    let turns = walk_turns(world, &ends);
    let walks = (which.into_iter())
        .map(|w| w.map_or_else(Vec::new, |n| lighten_walk(&turns[n], [ends[n].1.x, ends[n].1.y])))
        .collect();
    (walks, ends.len(), unresolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legs_are_read_with_their_places() {
        let (faction, legs) = parse(
            r#"{"faction": "HORDE", "legs": [
                {"from": {"m": 1440, "x": 40.46, "y": 61.42}, "to": {"taxi": 22}, "level": 21},
                {"from": {"taxi": "Thunder Bluff"}, "to": {"m": 1456, "x": 47, "y": 49.83}, "level": 3}
            ]}"#,
        )
        .unwrap();
        assert_eq!(faction, Faction::Horde);
        assert_eq!(
            legs,
            vec![
                Leg {
                    from: Place::Map {
                        ui_map: 1440,
                        x: 40.46,
                        y: 61.42
                    },
                    to: Place::TaxiId(22),
                    level: 21
                },
                Leg {
                    from: Place::TaxiName("Thunder Bluff".into()),
                    to: Place::Map {
                        ui_map: 1456,
                        x: 47.0,
                        y: 49.83
                    },
                    level: 3
                },
            ]
        );
    }

    #[test]
    fn bad_input_is_refused() {
        for text in [
            r#"{"faction": "scourge", "legs": []}"#,
            r#"{"faction": "horde"}"#,
            r#"{"faction": "horde", "legs": [{"from": {"m": 1440, "x": 1}, "to": {"taxi": 1}, "level": 2}]}"#,
            r#"{"faction": "horde", "legs": [{"from": {"taxi": 1}, "to": {"taxi": 2}}]}"#,
        ] {
            assert!(parse(text).is_err(), "{text}");
        }
    }
}
