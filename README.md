# dps-gangwars

Gang ambient AI for Del Perro Sands - augments rcore_gangs with living
territories, rare-but-real violence, and witness-driven police alerts.

## Design rules (non-negotiable)
- **Gangs fight gangs.** Players are civilians: no database-driven enmity,
  ever. NPCs cannot know your affiliation by looking at you (a visible
  gang-colors recognition mechanic is planned; qbx reports gangless players
  as the string `'none'` - normalized, never treated as a gang).
- **Cops get lip, not lead**: crews taunt nearby police with shouted voice
  lines but never initiate; hostility only ever comes from being attacked.
- **Same gang never fights itself** (companion relationship +
  SetCanAttackFriendly false on every spawn path).

## Street vibe layer
Ten territories (two per gang: Families, Ballas, Vagos, Marabunta, Triads,
plus the Lost clubhouse) hold **corner crews** - 3-5 peds per spot in gang
models doing corner scenarios, 60% concealed-armed. The Vespucci boardwalk
runs "stroll" mode: mixed random-gang walker groups, no turf events.

When a player is nearby, each territory occasionally rolls an event
(4-8 min cooldown): **taunt stand-off** (50%; escalates to a shootout 25% by
day, 35% at night), **drive-by** (30%; rival car sprays the corner and rolls
on), **foot skirmish** (20%; brief, survivors flee). Gunfire feeds the
ambient-witness system: delayed, position-fuzzed anonymous 911 calls into
wasabi_mdt - rare by design (per-area cooldowns, 3-call cap per fight).

## Wars
Admin commands `gangwar [zone] [attacker] [defender]` / `gangwar_end [zone]`
drive rcore rivalry events: reinforcement waves (8/6/6/4 defenders,
8/6/6/4 attackers), pair-target combat pump so both sides stay engaged, war
NPCs blocked from re-targeting players. `gangvibe [taunt|driveby|skirmish]`
forces a vibe event at the nearest territory for testing.

## Notable implementation details
- `PlaceOnGroundProperly` is not a real native - ground-snap is done via
  GetGroundZFor_3dCoord (this bug silently killed all spawns upstream).
- `TaskCombatHatedTargetsAroundPed` is one-shot and targets players; the
  combat pump assigns explicit `TaskCombatPed` targets instead.
- Set `Config.Debug = false` for production.

Bridges: rcore_gangs (auto-detected) or standalone territory fallback.
