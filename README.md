# Hmph Wiretap

Hmph Wiretap is a maintained fork of [Wiretap on the Factorio Mod Portal](https://mods.factorio.com/mod/wiretap)
by [ekrauser/wiretap](https://github.com/ekrauser/wiretap). It retains the original
mod's purpose and credits while adding the Prometheus bridge, Grafana dashboard, and
deployment workflow used by Hmph.

The mod is published under its own Mod Portal identity, `hmph-wiretap`, so it never
impersonates or modifies the original listing.

## Client installation

The Factorio client must use the exact same Hmph Wiretap version as the server.
Download the ZIP from the latest successful **Build Factorio mod** Forgejo Actions
run, place it in Factorio's `mods` directory, then enable Wiretap in the Mods menu.

On macOS the directory is `~/Library/Application Support/factorio/mods/`.

Export as many vitals as possible from Factorio **2.1.x** to the outside world, so you
can watch your factory from Home Assistant, Grafana, MQTT dashboards, or an ESP32 on
your desk.

Two parts:

| Part | What it does |
| --- | --- |
| [`mod/hmph-wiretap`](mod/hmph-wiretap/) | Factorio mod. Collects stats incrementally across ticks and writes completed JSON snapshots to `script-output/wiretap/stats.json` (and/or an append-only NDJSON journal), targeting an N-second interval. Also exposes a `wiretap` remote interface and `/wiretap` command for RCON polling. It conflicts with the original `wiretap` package. |
| [`companion/wiretap_bridge.py`](companion/wiretap_bridge.py) | Python bridge (stdlib-only). Watches the JSON file and re-serves it as an HTTP API (`/stats`), Prometheus metrics (`/metrics`), and optionally MQTT with Home Assistant auto-discovery. |

The mod can't talk to the network directly — Factorio's Lua sandbox only allows writing
to `script-output` — hence the bridge. If you already run RCON, you can skip the file
entirely (see [RCON](#option-c-rcon-no-file-no-bridge)).

## What gets exported

Per **surface** (every planet, moon, and space platform is a surface):

- **Power, per electric network and totals**: production and consumption in watts
  (5-second average, same as the in-game GUI), optionally broken down by entity type
  (how much your steam engines make, how much your labs eat) with a matching
  `count_by_entity` (how many of each exist on the surface, all forces combined;
  zero-count types are omitted), plus accumulator charge/capacity in joules.
  Networks that only contain accumulators are listed with zero flows so totals and
  networks always agree; all-zero networks (isolated poles) are dropped. Space
  platforms report their pole-less grid as one network keyed `"global"`
  (needs Factorio ≥ 2.0.48; older runtimes fall back to charge-only entries).
- **Logistics, per force**: item counts aggregated across all logistic networks
  (optionally broken down by quality), robot counts (logistic/construction,
  total/available), network count.
- **Pollution**: total on the surface, cumulative produced/absorbed by source, and the
  count of enemy spawners whose `absorbed_pollution` value is above zero.
- **Defense**: player-force turrets, walls, and gates by entity; loaded/empty ammo turrets and
  ammunition by item; cumulative damage and hit events received by player-force entities;
  enemy kills and player entity losses. Damage/death counters include surface, entity, damage
  type, and attacker force dimensions.

Per **force**: current research + progress + level, research queue, previous
research, researched/total technology counts, **science pack rates** (packs per
minute produced/consumed, 1- and 10-minute averages, plus all-time totals, per
surface), rockets launched, items launched, all-time production/consumption totals
for items and fluids per surface.

Enemy evolution is exported per surface as the total plus its time, pollution, and spawner-kill
contributors. Plus: game tick, play time, online player names.

<details>
<summary>Snapshot shape (abridged)</summary>

```json
{
  "meta": {"tick": 12345, "game_time_seconds": 205, "player_count": 1,
            "players_online": ["kraus"], "interval_seconds": 10, "mod_version": "1.3.9",
            "collection_started_tick": 12200, "collection_duration_ticks": 145,
            "robot_order_sample_interval_seconds": 60, "robot_order_sample_age_seconds": 3},
  "surfaces": {
    "nauvis": {
      "index": 1,
      "is_platform": false,
      "pollution": 5231.4,
      "power": {
        "totals": {"production_watts": 1.8e6, "consumption_watts": 1.7e6,
                    "accumulator_charge_joules": 2.5e7, "accumulator_capacity_joules": 5e7,
                    "network_count": 1},
        "networks": {
          "1": {"production_watts": 1.8e6, "consumption_watts": 1.7e6,
                 "accumulator_charge_joules": 2.5e7, "accumulator_capacity_joules": 5e7,
                 "production_by_entity": {"steam-engine": 1.8e6},
                 "consumption_by_entity": {"assembling-machine-2": 9e5, "lab": 8e5}}
        },
        "count_by_entity": {"steam-engine": 20, "assembling-machine-2": 45, "lab": 12}
      },
      "logistics": {
        "player": {
          "network_count": 2,
          "items": {"iron-plate": 3200, "copper-plate": 1800},
          "robots": {"logistic_total": 50, "logistic_available": 41,
                      "construction_total": 20, "construction_available": 20,
                      "waiting_for_charge": 1},
          "robot_orders": {
            "logistic": {"pickup": 4, "deliver": 3, "pickup_items": 0, "deliver_items": 0},
            "construction": {"construct": 2, "repair": 0, "deconstruct": 0,
                             "upgrade": 0, "explode_cliff": 0}
          }
        }
      }
    }
  },
  "forces": {
    "player": {
      "rockets_launched": 0,
      "research": {"current": "logistics-2", "progress": 0.62, "current_level": 1,
                    "previous": "logistics", "queue": ["logistics-2", "steel-processing"],
                    "technologies_researched": 24, "technologies_total": 214},
      "science_packs": {
        "nauvis": {
          "automation-science-pack": {"produced_per_minute": 61.2, "consumed_per_minute": 60.0,
                                        "produced_per_minute_10m": 58.9, "consumed_per_minute_10m": 60.1,
                                        "produced_total": 8123, "consumed_total": 8000}
        }
      },
      "production": {"nauvis": {"items_produced_total": {"iron-plate": 51234},
                                  "items_consumed_total": {"iron-plate": 48000},
                                  "fluids_produced_total": {"water": 1.2e6},
                                  "fluids_consumed_total": {"water": 1.2e6}}}
    },
    "enemy": {"evolution": {"nauvis": 0.14}}
  }
}
```

Empty tables are omitted rather than serialized, so always use defaults when a key
might be missing.
</details>

## 1. Install the mod

Option A — folder (easiest for development):

```bash
# Linux / WSL (adjust the target to your Factorio user-data dir)
cp -r mod/hmph-wiretap ~/.factorio/mods/hmph-wiretap
```

Option B — zip:

```bash
./scripts/package.sh          # builds dist/hmph-wiretap_<version>.zip
```

then drop the zip into your mods folder:

- Windows: `%APPDATA%\Factorio\mods\`
- Linux: `~/.factorio/mods/`
- Playing on Windows but running the bridge in WSL? The mods folder is at
  `/mnt/c/Users/<you>/AppData/Roaming/Factorio/mods/`.

Enable **Hmph Wiretap** in the in-game Mods menu and load your save. Collection
starts on the next tick; after the first cycle completes, the snapshot appears at:

- Windows: `%APPDATA%\Factorio\script-output\wiretap\stats.json`
- Linux: `~/.factorio/script-output/wiretap/stats.json`

All knobs live in **Settings → Mod settings → Map**: interval, number precision
(exported values are rounded to 3 decimal places by default to keep the file small),
output mode (snapshot / journal / both), filenames, and per-category toggles
(logistics, quality breakdown, power, per-entity power breakdown, accumulator scan,
production totals, science pack rates, pollution, defense/combat). Changes apply immediately, no
restart needed. Research progress is always exported.

Two quirks in the exported data are the game's own, passed through faithfully:

- Production totals contain an item literally named `science`: a hidden vanilla
  pseudo-item Factorio 2.0 uses to chart *effective* research throughput
  (including lab/research productivity). It never matches the `science_packs`
  section and is genuinely useful as your true science-per-minute.
- Logistic item counts can go briefly **negative** (e.g. `nutrients: -2`):
  robots over-reserve items they are flying to pick up. Officially "not a bug";
  counts self-correct when the robot arrives. Clamp on the consumer side if it
  bothers your dashboard.

> **Multiplayer note:** "Write on server only" is on by default, so in multiplayer
> only the host / dedicated server writes the file. All peers still run the same
> incremental collection so saved state stays deterministic across multiplayer joins
> and save/load. The setting is ignored in single player (the file is always written there).

> **Performance note:** surface queries process at most 32 chunks and 256 matching
> entities per tick. Power entity counts share a chunk pass instead of scanning the
> entire surface separately for each entity name. Robot-order sampling visits at
> most 256 robots per tick. Logistics aggregation visits at most 256 item/roboport
> records and starts at most four networks per tick. Power flow collection makes at
> most 64 flow calls per tick. Research and science-key traversal visit at most 128
> records per tick, science rates process at most 16 packs (64 flow calls), train
> state sampling visits at most 128 trains, and rounding takes at most 256 traversal
> steps. Each collector runs in its own phase, followed by separate serialization
> and publication ticks. Native list/statistics reads, JSON conversion, and each
> file write remain synchronous; work limits do not guarantee a wall-clock tick budget.

The default 10-second interval is the target spacing between collection starts.
Cycles never overlap: if collection takes longer, it finishes before the next cycle
starts. Only complete snapshots are published. Values are sampled over the cycle,
not all on one tick; `meta.tick` is its completion tick,
`meta.collection_started_tick` is its start, and `meta.collection_duration_ticks`
reports the sampling window. Large maps can therefore update less often than the
configured interval. Pending work survives saves and multiplayer joins. Changing
a Wiretap setting discards pending work and starts a fresh cycle.

Damage callbacks reuse counter tables and the cached defense setting. Zero-damage
hits (for example, fire against immune walls) still count as events, with zero
damage, so existing combat metrics retain their meaning.

Science and production reuse the same item-total copies per force/surface.
Technology names are indexed once on initialization or mod configuration changes.
These reduce repeated work in addition to spreading collection across ticks.

The jobs are cooperative, not background threads. Factorio does not expose
`coroutine`, `io`, or `os` in its Lua sandbox, and multiplayer collection must
remain deterministic. Cursors and LuaObjects are kept in `storage`; work is
chosen by fixed record limits rather than a machine's elapsed milliseconds.
Formatting Prometheus/MQTT/HTTP output remains in the external companion process.
See [Factorio's Lua library restrictions](https://lua-api.factorio.com/latest/auxiliary/libraries.html)
and [saveable storage types](https://lua-api.factorio.com/latest/auxiliary/storage.html).

## 2. Run the bridge

```bash
python3 companion/wiretap_bridge.py \
    --file ~/.factorio/script-output/wiretap/stats.json
```

- `http://<host>:8787/stats` — full JSON snapshot (plus `X-Stats-Age-Seconds` header)
- `http://<host>:8787/metrics` — Prometheus format (power, items, robots, pollution,
  evolution, research, players…)
- `http://<host>:8787/health` — returns 503 until the first snapshot is parsed

With MQTT + Home Assistant discovery:

```bash
pip install paho-mqtt
python3 companion/wiretap_bridge.py \
    --file ~/.factorio/script-output/wiretap/stats.json \
    --mqtt-host homeassistant.local --mqtt-user mqtt --mqtt-password secret \
    --ha-discovery --watch-items iron-plate,copper-plate,rocket-fuel
```

Sensors then appear in HA automatically under one "Factorio (wiretap)" device:
per-surface power production/consumption (W), accumulator charge (%), pollution,
science consumed per minute, players online, game tick, and one sensor per
`--watch-items` item (logistic count summed across all surfaces). Topics are published under `wiretap/…` (retained),
with availability on `wiretap/availability`.

Robot Prometheus gauges include:

- `factorio_robot_waiting_for_charge_count`, labeled by surface and force; this counts robots
  queued for charging across logistic cells in each network.
- `factorio_robot_order_count`, labeled by surface, force, robot kind, and order type. It counts
  robots by the first order in their current order queue and refreshes once per minute; snapshots
  between samples reuse the last result.

<details>
<summary>systemd unit example</summary>

```ini
[Unit]
Description=wiretap bridge
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/wiretap/companion/wiretap_bridge.py \
    --file /home/factorio/.factorio/script-output/wiretap/stats.json \
    --mqtt-host 192.168.1.10 --ha-discovery
Restart=always

[Install]
WantedBy=multi-user.target
```
</details>

## 3. Hook up Home Assistant

### Option A: MQTT (recommended)

Run the bridge with `--mqtt-host … --ha-discovery` as above. Done — entities
auto-appear. Works great for driving physical hardware too: any ESPHome/ESP32 device
can subscribe to the same `wiretap/…` topics.

### Option B: REST (no MQTT broker needed)

```yaml
# configuration.yaml
rest:
  - resource: http://192.168.1.50:8787/stats
    scan_interval: 15
    sensor:
      - name: "Factorio power production"
        unit_of_measurement: "W"
        device_class: power
        value_template: >-
          {{ value_json.surfaces.nauvis.power.totals.production_watts | round(0) }}
      - name: "Factorio power consumption"
        unit_of_measurement: "W"
        device_class: power
        value_template: >-
          {{ value_json.surfaces.nauvis.power.totals.consumption_watts | round(0) }}
      - name: "Factorio accumulator charge"
        unit_of_measurement: "%"
        value_template: >-
          {% set p = value_json.surfaces.nauvis.power.totals %}
          {{ (100 * p.accumulator_charge_joules / p.accumulator_capacity_joules)
             | round(1) if p.accumulator_capacity_joules else 0 }}
      - name: "Factorio iron plates in logistics"
        value_template: >-
          {{ value_json.surfaces.nauvis.get('logistics', {}).get('player', {})
             .get('items', {}).get('iron-plate', 0) }}
      - name: "Factorio players online"
        value_template: "{{ value_json.meta.player_count }}"
```

Note the `.get(..., {})` chaining on the iron-plate sensor: the mod omits empty
sections entirely, so intermediate keys like `logistics` are absent until you build
your first roboport — a plain dotted path would throw a template error until then.
The same applies to `power`, `production`, and `science_packs`.

Swap `nauvis` for any surface name (e.g. `vulcanus`, or a platform) to monitor other
worlds. Platform names contain hyphens, so use bracket syntax for them:
`value_json.surfaces['platform-1'].power.totals.production_watts`.

### Option C: RCON (no file, no bridge)

If your server has RCON enabled, poll the mod directly — the command prints the same
completed JSON snapshot to the RCON client, without starting another scan:

```bash
# any rcon client, e.g. `pip install factorio-rcon-py`
python3 -c "
import factorio_rcon
client = factorio_rcon.RCONClient('127.0.0.1', 27015, 'rconpassword')
print(client.send_command('/wiretap'))
"
```

Other mods can also call `remote.call("wiretap", "stats")` (table) or
`remote.call("wiretap", "stats_json")` (string). Both return the latest completed
snapshot. Until the first cycle completes (including after settings/configuration
changes), reads report that collection is not ready; retry later.

`/wiretap write` immediately exports the latest completed snapshot; it does not
force synchronous collection. If none is ready, it reports that collection is
pending and the first completed cycle will export automatically. The remote
`write_now` call returns `true` when it writes, or `false` while awaiting that first
snapshot.

Heads-up for dedicated-server admins: typed into the server's *stdin console*, the
full JSON dump of `/wiretap` is delivered to RCON callers only (short messages
like the `write` confirmation and errors do echo to stdout). Use RCON or an in-game
player console to see the dump.

## Prometheus / Grafana

Point a scrape job at the bridge:

```yaml
scrape_configs:
  - job_name: factorio
    static_configs: [{targets: ["192.168.1.50:8787"]}]
```

Useful series: `factorio_power_production_watts{surface=…}`,
`factorio_power_headroom_watts{surface=…}` (maximum generation minus maximum load),
`factorio_power_maximum_production_watts{surface=…}`,
`factorio_power_maximum_consumption_watts{surface=…}`,
`factorio_logistic_item_count{item=…}`, `factorio_accumulator_charge_joules`,
`factorio_entity_count{surface=…,entity=…}` (divide watts by it for per-machine
utilization),
`factorio_science_pack_consumption_per_minute{item=…}` (your live SPM),
`factorio_technologies_researched`, `factorio_evolution_factor`,
`factorio_power_production_by_entity_watts`, `factorio_defense_damage_received_total`,
`factorio_defense_enemy_kills_total`, `factorio_evolution_component`,
`factorio_stats_age_seconds` (alert if it grows — the game is paused, crashed, or
the mod is disabled). Train telemetry is available as `factorio_train_count`,
`factorio_train_moving_count`, `factorio_train_waiting_count`,
`factorio_train_blocked_count`, `factorio_train_manual_count`,
`factorio_train_stop_count`, and `factorio_train_state_count{surface=…,state=…}`.
Trains in `destination_full` state count as waiting; `blocked` counts only
trains in `no_path` state.
Pollution-active enemy spawners are exported as
`factorio_pollution_absorbing_nest_count{surface=…}`.

Collection health is available as `factorio_collection_duration_ticks`,
`factorio_collection_started_tick`, and `factorio_interval_seconds`. Compare
`factorio_collection_duration_ticks / 60` with `factorio_interval_seconds` to see
whether collection takes longer than the target interval. Duration is in simulation
ticks, not measured CPU time or wall-clock seconds. These gauges require the updated
bridge; start/duration are omitted for snapshots from mods older than 1.3.6.
