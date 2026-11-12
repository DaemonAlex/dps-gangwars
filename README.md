# dps-gangwars

Ambient gang AI for **DelPerroSands**. Turns quiet gang territories into places
that feel lived-in and dangerous — corner crews holding their blocks, rivals
rolling through, the occasional drive-by or shoot-out — and drives large
reinforcement wars on top of [rcore_gangs](https://rcore.store) rivalries. Every
gunfight can generate a delayed, fuzzed 911 call into the MDT.

Players are **civilians** to all of it. The AI fights the AI; you're a bystander
unless you make yourself a target.

---

## What it is for

Gang areas in the base game are empty and quiet. Players who run gangs, and
police who patrol those blocks, have nobody to react to. This script puts gang
NPCs on the corners, lets rival crews clash with each other now and then, and
sends extra NPC fighters when two gangs go to war. The city feels lived in,
and police get real calls to answer, without staff running events by hand.

---

## Features

### Street vibe layer
Each configured territory, when a player is nearby, spawns a **corner crew** — a
few gang members in that gang's models doing corner things (dealing, smoking,
leaning), most of them concealed-armed. Cross a couple of streets and the colors
change.

Occasionally (rare by design — a per-territory cooldown of several minutes) a
crew rolls an **event**:

| Event | Weight | What happens |
|-------|--------|--------------|
| **Taunt stand-off** | 50% | Rivals walk up, both sides shout at each other, then back off — *unless* it escalates to gunfire (25% by day, **35% at night**). |
| **Drive-by** | 30% | A rival car rolls the corner, sprays it, and keeps moving; the crew returns fire. |
| **Foot skirmish** | 20% | It genuinely pops off for 20–35s; survivors break contact and the crew re-holds the corner. |

The **Vespucci boardwalk** runs a special "stroll" mode instead: mixed random-gang
walkers, presence without turf events.

### Hangout territories
A territory can be a **hangout** in place of a corner. The Yellow Jack Inn is
the one set up in `config.lua`. Two small groups of bikers and locals stand on
the lot by parked choppers and trucks. The usual event there is a **dust-up**:
two of them shove and swing fists, then it calms down. Nobody and no bike
spawns inside the building.

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
  always neutral to every gang group. (A "wear colors in rival turf → recognized"
  mechanic is planned; it will be *earned* hostility, never automatic.)
- **Same gang never fights itself.**
- **Cops get lip, not lead** — never attacked unless they attack first.
- **Events are rare.** Atmosphere, not a constant war zone.

---

## On its own, and with other scripts

**On its own.** With ox_lib and qbx_core only, the script uses the territory
list in `config.lua` (`Config.StandaloneTerritories`). Players see corner
crews in each gang block, the Vespucci boardwalk walkers, the Yellow Jack
hangout, and the rare taunt, drive-by or skirmish. Staff can start and end a
war with the `gangwar` and `gangwar_end` commands. When NPCs open fire, on-duty
police within 500 m get a plain "Shots fired in gang territory!" notice.

**With a paid gang script (rcore_gangs).** The script finds rcore_gangs by
itself when it is running. When players start a rivalry in rcore_gangs, a
reinforcement war starts in that zone: NPC waves arrive for both the attacking
and the defending gang, and they leave when the rivalry ends. The script asks
rcore_gangs which zone a position is in and which gang owns it. It only reads
from rcore_gangs and listens for its rivalry events. It never writes to
rcore_gangs and never creates a rivalry in it, so an rcore_gangs update should
not break it. If rcore_gangs cannot name a zone owner, the script falls back
to its own territory list.

**With a paid police computer (wasabi_mdt).** When gang NPCs shoot at each
other, a "10-71 Shots Fired" call appears on the MDT a few seconds later, from
an anonymous caller, with a rough location. A long fight can raise a second
"Sustained Gunfire" call at a higher priority. There are at most three calls
per fight and at least two minutes between them. The script only sends a
dispatch through the wasabi_mdt `CreateDispatch` export. If wasabi_mdt is not
running, the call is skipped and nothing else changes.

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

## Credits

DelPerroSands Development. Built on the ox / Qbox stack; integrates rcore_gangs
and wasabi_mdt.

## Recent changes

- **12 November 2026.** README: what it is for, how it works alone and with paid scripts, other DPS scripts.
- **31 October 2026.** Yellow Jack hangout: fewer gang members (two groups of two or three, was three groups of three to five). Bikes no longer spawn inside the bar: any spot inside a building is rejected, and a keep-out circle covers the bar itself. If no open spot is found, the bike is not spawned.
- **25 October 2026.** Synced with the live server. Five bikes that were cut from the server fleet were removed from the hangout vehicle list.
- **27 September 2026.** Hangout territories added: the Yellow Jack lot with bikers, locals, parked bikes and dust-ups.

## Author

Made by [DaemonAlex](https://github.com/DaemonAlex) for DelPerroSands.

## Other DPS scripts

All of these are made for DelPerroSands and run together on one Qbox server. Each one works on
its own. The ones marked "pairs with" do more when both are running.

| Script | What it does |
|---|---|
| [dps-inventory](https://github.com/DaemonAlex/dps-inventory) | The inventory: ox_inventory with equipment slots, backpacks, armour plates and a self status panel, in the DelPerroSands colours. |
| [dps-medical](https://github.com/DaemonAlex/dps-medical) | Patient records, illness and diagnostic tests. A companion to wasabi_ambulance. Pairs with dps-inventory: symptoms and diagnoses show on the status panel. |
| [dps-insurance](https://github.com/DaemonAlex/dps-insurance) | Ties m-Insurance into the MDT, impound, hospital and medical chart. Pairs with dps-medical. |
| [dps-studio](https://github.com/DaemonAlex/dps-studio) | Build rooms, doors and portals in game from one panel (`/studio`), with owners and managers so staff do not have to support them. |
| [dps-shops](https://github.com/DaemonAlex/dps-shops) | Shop clerks who greet and react to a robbery, then player-owned shops. |
| [dps-fleet](https://github.com/DaemonAlex/dps-fleet) | Vehicle browser and workshop on one panel: extras, liveries and mods for emergency vehicles. |
| [dps-parking](https://github.com/DaemonAlex/dps-parking) | Parking with valet, impound, violations and reserved spots. |
| [dps-vehiclepersistence](https://github.com/DaemonAlex/dps-vehiclepersistence) | Vehicles stay where they were parked. Pairs with dps-parking. |
| [dps-towjob](https://github.com/DaemonAlex/dps-towjob) | Queue-based tow job with jg-mechanic integration. |
| [dps-services](https://github.com/DaemonAlex/dps-services) | Request a tow and follow it live on the lb-phone and lb-tablet. Pairs with dps-towjob. |
| [dps-autoshops](https://github.com/DaemonAlex/dps-autoshops) | Self-service repair shops when no mechanic is on duty. |
| [dps-cityworker](https://github.com/DaemonAlex/dps-cityworker) | City infrastructure job and career. |
| [dps-ainpcs](https://github.com/DaemonAlex/dps-ainpcs) | NPCs you can talk to, with trust, quests and intel. |
| [dps-badpeds](https://github.com/DaemonAlex/dps-badpeds) | Police interaction with NPCs: stops, arrests, intel and jail records. |
| [dps-rotations](https://github.com/DaemonAlex/dps-rotations) | Moves dealers, harvests and other spots on a fixed schedule. |
| [dps-trains](https://github.com/DaemonAlex/dps-trains) | The train system. Pairs with dps-trains-stock, dps-traintools and dps-transitapp. |
| [dps-transitapp](https://github.com/DaemonAlex/dps-transitapp) | Live train arrival boards on the lb-phone. |
| [dps-faceplant](https://github.com/DaemonAlex/dps-faceplant) | City help, reports and staff tools on the lb-phone and lb-tablet. |
| [dps-chat](https://github.com/DaemonAlex/dps-chat) | A command box for voice-only servers. No chat feed. |
| [dps-filmmode](https://github.com/DaemonAlex/dps-filmmode) | One key hides every HUD layer and gives a smooth free camera for recording. |
