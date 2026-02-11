# dps-gangwars v2.1.0

**Gang Ambient AI System** - Spawns intelligent gang NPCs in territories with combat AI, recruitment, and war reinforcements. Works with rcore_gangs, standalone territories, or any gang script via the bridge adapter system.

![download-3](https://github.com/user-attachments/assets/adec31f4-caf0-4aca-83d5-cb592c859b0a)
![download](https://github.com/user-attachments/assets/bac84964-3943-486e-ae5b-e5c492b63b8c)
![images](https://github.com/user-attachments/assets/bff7795c-3329-4f6a-ad8f-1193b93733b6)
![download](https://github.com/user-attachments/assets/38b8a0dc-8ff2-4aec-af72-6f1a8dd1721e)
![images](https://github.com/user-attachments/assets/60e91c8e-b399-418e-a4ac-062a7fcac8ac)
![images-4](https://github.com/user-attachments/assets/0f02192c-f107-42c6-970b-91279aead39e)

## Overview

This resource adds ambient gang NPC presence to your server. Gang members populate their territories, react to threats, recruit nearby allies into fights, and spawn reinforcements during gang wars. Uses a **bridge/adapter pattern** so it works with multiple gang scripts or standalone.

## Features

- **Territory Population**: Gang NPCs spawn in owned territories when players approach
- **Combat AI**: Configurable combat styles (aggressive, defensive, balanced) with cover, retreat, and recruitment
- **War Reinforcements**: Timed waves of defender and attacker NPCs during territory wars/rivalries
- **Gang Script Bridge**: Auto-detects rcore_gangs or falls back to standalone config territories
- **Tiered Tick Rates**: Performance-optimized loop that speeds up near NPCs and slows down when distant
- **Relationship Groups**: NPCs respect/hate based on gang affiliation — same-gang players are friendly, rivals are hostile
- **Police Notifications**: Nearby LEO players get dispatch alerts when shots fire in gang territory
- **Admin Commands**: `/gangai status`, `/gangai spawn <gang>`, `/gangai clear`

## Dependencies

- [ox_lib](https://github.com/overextended/ox_lib)
- [qb-core](https://github.com/qbcore-framework/qb-core) or [qbx_core](https://github.com/Qbox-project/qbx_core)

### Optional

- [rcore_gangs](https://store.rcore.cz/) — auto-detected, uses real territory zones and war events

## Installation

1. Download and extract to your resources folder (e.g. `[standalone]/[dps]/dps-gangwars`)
2. Add to your `server.cfg`:
   ```
   ensure dps-gangwars
   ```
3. Configure `config.lua` — set `Config.Integration.gangScript` and adjust gang data as needed
4. Restart your server or run `ensure dps-gangwars`

## Gang Script Bridge

The bridge system abstracts gang script differences so the core logic doesn't need to know which gang script you run.

### Configuration

In `config.lua`:

```lua
Config.Integration = {
    gangScript = 'auto',  -- 'auto', 'rcore_gangs', or 'standalone'
}
```

| Value | Behavior |
|-------|----------|
| `'auto'` | Detects rcore_gangs at runtime, falls back to standalone |
| `'rcore_gangs'` | Force rcore_gangs adapter |
| `'standalone'` | Use `Config.StandaloneTerritories` only |

### Supported Adapters

**rcore_gangs** — Uses `GetZoneAtPosition`, `GetGangAtZone`, `GetPlayerGang` exports. Listens to `start_rivalry`/`finish_rivalry` events for war reinforcements.

**standalone** — Uses hardcoded territories from `Config.StandaloneTerritories`. Good for testing or servers without a gang script.

### Adding a New Adapter

Create `bridge/my_gang_script.lua`, implement:

```lua
-- Client
GangBridge.GetZoneAtPosition(coords)    -- returns { name, label, center, owner } or nil
GangBridge.GetPlayerGangClient()         -- returns { tag, name } or nil

-- Server
GangBridge.GetZoneOwner(zoneName, coords) -- returns resolved gang name or nil
GangBridge.GetPlayerGang(source)          -- returns resolved gang name or nil
```

Register war events using `GangBridge._fireWarStart(zoneName, attacker, defender)` and `GangBridge._fireWarEnd(zoneName, winner)`.

Add the file to `fxmanifest.lua` shared_scripts.

## Configuration

### Gang Data

Each gang is defined in `Config.GangData` with NPC appearance, weapons, and combat style:

```lua
Config.GangData = {
    ['ballas'] = {
        models = { 'g_m_y_ballaorig_01', 'g_m_y_ballasout_01' },
        vehicles = { 'buccaneer', 'peyote', 'voodoo' },
        weapons = { 'WEAPON_MICROSMG', 'WEAPON_PISTOL', 'WEAPON_BAT' },
        scenarios = {
            'WORLD_HUMAN_DRUG_DEALER',
            'WORLD_HUMAN_HANG_OUT_STREET',
        },
        combatStyle = 'aggressive'  -- aggressive, defensive, balanced
    },
}
```

### Gang Tag Map

Maps gang script tags to `Config.GangData` keys. Needed when your gang script uses uppercase or different names:

```lua
Config.GangTagMap = {
    ['BALLAS']    = 'ballas',
    ['VAGOS']     = 'vagos',
    ['LOST MC']   = 'lostmc',
}
```

### Standalone Territories

When using `standalone` mode, define territories manually:

```lua
Config.StandaloneTerritories = {
    {
        name = 'grove_street',
        label = 'Grove Street',
        owner = 'families',            -- must match a Config.GangData key
        center = vector3(-120.0, -1620.0, 34.0),
        radius = 100.0,
    },
}
```

### Combat Styles

| Style | Movement | Cover | Flee | Recruit |
|-------|----------|-------|------|---------|
| `aggressive` | Suicidal charge | No | Never | Yes |
| `defensive` | Hold position | Yes | At 30% HP | No |
| `balanced` | Push forward | Yes | At 20% HP | Yes |

## Included Gangs

| Gang | Style | Location |
|------|-------|----------|
| Ballas | Aggressive | Davis |
| Vagos | Aggressive | Rancho |
| Families | Defensive | Grove Street |
| Triads | Balanced | Little Seoul |
| Lost MC | Aggressive | East Vinewood |
| Marabunta Grande | Aggressive | El Burro Heights |
| Cartel | Balanced | Sandy Shores area |

## Admin Commands

| Command | Description |
|---------|-------------|
| `/gangai status` | Shows active NPC count and bridge adapter |
| `/gangai spawn <gang>` | Spawns gang NPCs at your location |
| `/gangai clear` | Removes all spawned gang NPCs |

Requires `admin` permission via QBCore.

## Debugging

Set `Config.Debug = true` in `config.lua` to see:

- Bridge adapter detection on startup
- Zone detection when entering territories
- NPC spawn/despawn counts
- War start/end events
- Recruitment triggers

Check your **server console** for `[GangAI]` prefixed messages.

## Performance

- NPCs only spawn when players enter territory radius
- Tiered tick rates: 100ms in combat, 500ms nearby, 2000ms distant, 5000ms background
- Automatic cleanup of distant/dead NPCs every 60s
- Global NPC cap (`Config.MaxSpawnedNPCs = 30`)
- Cooldown between respawns per zone (`Config.AmbientSpawning.respawnCooldown`)

## File Structure

```
dps-gangwars/
  bridge/
    init.lua           -- Bridge loader + shared utilities
    rcore_gangs.lua    -- rcore_gangs adapter
    standalone.lua     -- Standalone/fallback adapter
  client.lua           -- NPC spawning, combat AI, relationship groups
  server.lua           -- Spawn authorization, war reinforcements, admin commands
  config.lua           -- All configuration
  fxmanifest.lua       -- Resource manifest
```

## License

MIT License - Free to use and modify.

## Credits

- **Author**: DaemonAlex
- **Discord**: [Del Perro Sands RP](https://discord.gg/dpsrp)
