# dps-gangwars v2.0.0

**Gang Ambient AI System** - Augments rcore_gangs with intelligent NPCs, territory population, and war reinforcements.

![download-3](https://github.com/user-attachments/assets/adec31f4-caf0-4aca-83d5-cb592c859b0a)
![download](https://github.com/user-attachments/assets/bac84964-3943-486e-ae5b-e5c492b63b8c)
![images](https://github.com/user-attachments/assets/bff7795c-3329-4f6a-ad8f-1193b93733b6)
![download](https://github.com/user-attachments/assets/38b8a0dc-8ff2-4aec-af72-6f1a8dd1721e)
![images](https://github.com/user-attachments/assets/60e91c8e-b399-418e-a4ac-062a7fcac8ac)
![images-4](https://github.com/user-attachments/assets/0f02192c-f107-42c6-970b-91279aead39e)

## Overview

This resource adds ambient gang NPC presence to your server. Gang members populate their territories, react to threats, and provide reinforcements during gang wars. Designed to work alongside **rcore_gangs** for a complete gang experience.

## Features

- **Territory Population**: Gang NPCs spawn and patrol their territories
- **Intelligent AI**: NPCs react to rival gangs and hostile players
- **War Reinforcements**: Additional NPCs spawn during rcore_gangs war events
- **Configurable Gangs**: Easy setup for gang appearance, weapons, vehicles, and territories
- **Performance Optimized**: Smart spawning/despawning based on player proximity

## Dependencies

- [ox_lib](https://github.com/overextended/ox_lib)
- [qb-core](https://github.com/qbcore-framework/qb-core) or [qbx_core](https://github.com/Qbox-project/qbx_core)
- [rcore_gangs](https://store.rcore.cz/) (recommended)

## Installation

1. Download and extract to your resources folder
2. Add to your server.cfg (or place in a category folder):
   ```
   ensure dps-gangwars
   ```
3. Configure gangs in `config.lua`

## Configuration

Each gang is defined in `config.lua` with:

```lua
['ballas'] = {
    label = 'Ballas',
    color = {r = 128, g = 0, b = 128},  -- Purple
    blipColor = 27,
    territory = {
        vector3(-168.69, -1768.48, 29.41),
        -- Add more territory points...
    },
    peds = {'g_m_y_ballaorig_01', 'g_f_y_ballas_01'},
    weapons = {'WEAPON_PISTOL', 'WEAPON_MICROSMG'},
    vehicles = {'buccaneer', 'manana'},
}
```

### Gang Properties

| Property | Description |
|----------|-------------|
| `label` | Display name |
| `color` | RGB color for markers |
| `blipColor` | Map blip color ID |
| `territory` | Array of vector3 locations |
| `peds` | Ped models to spawn |
| `weapons` | Weapons NPCs can carry |
| `vehicles` | Vehicles that spawn in territory |

## Included Gangs

- **Ballas** - Purple, South LS
- **Vagos** - Yellow, East LS
- **Families** - Green, Grove Street
- **Triads** - Red, Little Seoul
- **Madrazo Cartel** - Brown, Sandy Shores
- **Marabunta Grande** - Blue, El Burro Heights

## Adding Custom Gangs

1. Add the gang to `qbx_core/shared/gangs.lua`:
   ```lua
   ['mygang'] = {
       label = 'My Gang',
       grades = {
           [0] = { name = 'Recruit' },
           [1] = { name = 'Member' },
           [2] = { name = 'Veteran' },
           [3] = { name = 'Leader', isboss = true },
       },
   },
   ```

2. Add NPC configuration to `dps-gangwars/config.lua`:
   ```lua
   ['mygang'] = {
       label = 'My Gang',
       color = {r = 255, g = 0, b = 0},
       blipColor = 1,
       territory = { vector3(x, y, z) },
       peds = {'ped_model'},
       weapons = {'WEAPON_PISTOL'},
       vehicles = {'vehicle_model'},
   },
   ```

## Integration with rcore_gangs

When rcore_gangs triggers a war event, this script automatically:
- Spawns additional reinforcement NPCs
- Increases aggression in affected territories
- Cleans up NPCs when war ends

## Performance

- NPCs only spawn when players are nearby
- Automatic cleanup of distant NPCs
- Configurable spawn limits per territory
- Uses ox_lib for efficient entity management

## License

MIT License - Free to use and modify.

## Credits

- **Author**: DaemonAlex
- **Discord**: [Del Perro Sands RP](https://discord.gg/dpsrp)
