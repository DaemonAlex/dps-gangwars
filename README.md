# dps-gangwars

Ambient gang AI for **Del Perro Sands**. Turns quiet gang territories into places
that feel lived-in and dangerous — corner crews holding their blocks, rivals
rolling through, the occasional drive-by or shoot-out — and drives large
reinforcement wars on top of [rcore_gangs](https://rcore.store) rivalries. Every
gunfight can generate a delayed, fuzzed 911 call into the MDT.

Players are **civilians** to all of it. The AI fights the AI; you're a bystander
unless you make yourself a target.

---

## Features

### Street vibe layer
Ten territories — two per gang (Families, Ballas, Vagos, Marabunta, Triads) plus
the Lost clubhouse — hold **corner crews**: 3–5 peds per spot in that gang's
models running corner scenarios (dealing, smoking, leaning), ~60% concealed-armed.
Cross a couple of streets and the colors change.

Occasionally (rare by design — a 4–8 minute per-territory cooldown) a crew rolls
an **event**:

| Event | Weight | What happens |
|-------|--------|--------------|
| **Taunt stand-off** | 50% | Rivals walk up, both sides shout at each other, then back off — *unless* it escalates to gunfire (25% by day, **35% at night**). |
| **Drive-by** | 30% | A rival car rolls the corner, sprays it, and keeps moving; the crew returns fire. |
| **Foot skirmish** | 20% | It genuinely pops off for 20–35s; survivors break contact and the crew re-holds the corner. |

The **Vespucci boardwalk** runs a special "stroll" mode instead: mixed random-gang
walkers, presence without turf events.

### Reinforcement wars
An [rcore_gangs](https://rcore.store) rivalry (or an admin command) starts a war:
staggered reinforcement waves for both the attacking and defending gang, a combat
pump that keeps both sides engaged with explicit targets, and automatic cleanup
when the war ends. Wave sizes are capped per client so a war can't overrun the
entity budget.

### Cop taunts
Corner crews **talk shit** to police who roll past — they turn, bark a line, and
that's it. Gangs never *initiate* on police; hostility toward cops only ever comes
from being attacked.

### Ambient gunfight witness reports
When the AI's own NPCs shoot it out, nearby civilians "call it in": a delayed,
position-fuzzed, anonymous **10-71** dispatch into `wasabi_mdt`. Rare and paced —
per-area cooldowns and a cap of a few calls per fight — so it reads like real 911
traffic, not a firehose. Distant simultaneous fights report separately, not as one
phantom call at their midpoint.

---

## Design rules (non-negotiable)

- **Gangs fight gangs. Players are civilians.** There is no database-driven
  enmity — an NPC cannot know your affiliation by looking at you. The player is
  always neutral to every gang group, and qbx's gangless string `'none'` is
  normalized rather than treated as a gang. (A "wear colors in rival turf →
  recognized" mechanic is planned; it will be *earned* hostility, never automatic.)
- **Same gang never fights itself** (companion relationship + `SetCanAttackFriendly`
  false on every spawn path).
- **Cops get lip, not lead** — never attacked unless they attack first.
- **Events are rare.** Atmosphere, not a constant war zone.

---

## Requirements

- [ox_lib](https://github.com/overextended/ox_lib)
- A gang script — [rcore_gangs](https://rcore.store) (auto-detected) — or the
  built-in **standalone** territory list as a fallback.
- [wasabi_mdt](https://wasabiscripts.com) (optional) for the witness dispatch calls.

Works on **Qbox / QBCore** (qbx_core native, QBCore-compat).

---

## Installation

1. Drop `dps-gangwars` in your resources folder.
2. `ensure dps-gangwars` after your gang script and ox_lib.
3. Review `config.lua` — gang models/weapons/vehicles, territories, event tuning.
4. For production, set `Config.Debug = false`.

---

## Configuration highlights (`config.lua`)

- **`Config.Integration.gangScript`** — `'auto'` / `'rcore_gangs'` / `'standalone'`.
- **`Config.GangData`** — per-gang models, vehicles, weapons, scenarios, combat style.
- **`Config.StandaloneTerritories`** — name / label / owner / center / radius per
  block (also used by the vibe layer even under rcore).
- **`Config.WarReinforcements`** — wave schedule + `maxWarNPCs` cap.
- **`Config.Relationships`** — gang↔gang levels (player is always neutral, set in code).
- **`Config.AmbientSpawning`** — density by heat/time-of-day, spawn/despawn distances.
- **Vibe tuning** lives in the `VIBE` table at the top of the street-vibe section
  in `client.lua`: crew size, event chance, cooldowns, event weights, armed share.

---

## Admin commands

Console or `command` ace holders:

| Command | Effect |
|---------|--------|
| `gangwar [zone] [attacker] [defender]` | Start a war (e.g. `gangwar davis families ballas`). Drives the bridge directly — works under standalone too, and never fabricates a real rivalry inside rcore. |
| `gangwar_end [zone]` | End the war in a zone. |
| `gangvibe [taunt\|driveby\|skirmish]` | Force a vibe event at *your* nearest territory (only you see it). |

---

## How it fits together

`bridge/` abstracts the gang script: the **rcore_gangs adapter** listens for
`start_rivalry` / `finish_rivalry` and resolves zones/owners server-side; the
**standalone adapter** uses `Config.StandaloneTerritories`. Ambient spawning and
war waves are requested by the client but **authorized server-side** (the server
resolves zone ownership and validates spawn requests).

---

## Notable implementation details

Worth knowing before editing the spawn paths — each of these was a real bug:

- `PlaceOnGroundProperly` is **not a real native** (only the object version exists);
  ground-snap goes through `GetGroundZFor_3dCoord`. This silently killed every
  spawn upstream.
- `TaskCombatHatedTargetsAroundPed` is one-shot and targets *players*; the combat
  pump assigns explicit `TaskCombatPed` targets instead.
- Putting a ped **into** a gang relationship group makes membership drive
  relationships regardless of PLAYER-hash settings — which is why the player ped
  is never placed in one.
- Set `Config.Debug = false` for production (it is off by default).

---

## Credits

Del Perro Sands Development. Built on the ox / Qbox stack; integrates rcore_gangs
and wasabi_mdt.
