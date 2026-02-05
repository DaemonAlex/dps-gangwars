Config = {}

-- ============================================
-- RCORE_GANGS INTEGRATION
-- This script augments rcore_gangs with ambient AI
-- ============================================

Config.Integration = {
    -- rcore_gangs resource name
    rcoreResource = 'rcore_gangs',

    -- Sync interval for checking rcore territory ownership (ms)
    syncInterval = 30000,

    -- Use rcore's gang data for spawning appropriate NPCs
    useRcoreGangData = true,

    -- Fallback to Config.GangData if rcore gang not found
    useFallbackData = true
}

-- ============================================
-- GANG NPC DATA
-- Visual/combat data for gang ambient NPCs
-- Maps to rcore gang names (case-sensitive)
-- ============================================

Config.GangData = {
    ['ballas'] = {
        models = { 'g_m_y_ballaorig_01', 'g_m_y_ballasout_01', 'g_m_y_ballaeast_01', 'csb_ballasog' },
        vehicles = { 'buccaneer', 'peyote', 'voodoo' },
        weapons = { 'WEAPON_MICROSMG', 'WEAPON_PISTOL', 'WEAPON_BAT', 'WEAPON_KNIFE' },
        scenarios = {
            'WORLD_HUMAN_DRUG_DEALER',
            'WORLD_HUMAN_HANG_OUT_STREET',
            'WORLD_HUMAN_SMOKING'
        },
        combatStyle = 'aggressive' -- aggressive, defensive, balanced
    },
    ['vagos'] = {
        models = { 'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02', 'g_m_y_mexgoon_03', 'csb_ortega' },
        vehicles = { 'tornado3', 'chino', 'buccaneer2' },
        weapons = { 'WEAPON_MICROSMG', 'WEAPON_PISTOL', 'WEAPON_MACHETE', 'WEAPON_CROWBAR' },
        scenarios = {
            'WORLD_HUMAN_DRINKING',
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_LEANING'
        },
        combatStyle = 'aggressive'
    },
    ['families'] = {
        models = { 'g_f_y_families_01', 'g_m_y_famdnf_01', 'g_m_y_famfor_01', 'csb_ramp_gang' },
        vehicles = { 'greenwood', 'manana', 'tornado' },
        weapons = { 'WEAPON_MICROSMG', 'WEAPON_PISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_SWITCHBLADE' },
        scenarios = {
            'WORLD_HUMAN_STAND_IMPATIENT',
            'WORLD_HUMAN_SMOKING_POT',
            'WORLD_HUMAN_DRINKING'
        },
        combatStyle = 'defensive'
    },
    ['triads'] = {
        models = { 'g_m_m_chigoon_01', 'g_m_m_chigoon_02', 'g_m_y_korean_01', 'g_m_y_korean_02' },
        vehicles = { 'tailgater', 'sultan', 'schafter2' },
        weapons = { 'WEAPON_ASSAULTSMG', 'WEAPON_APPISTOL', 'WEAPON_KNIFE', 'WEAPON_COMBATPISTOL' },
        scenarios = {
            'WORLD_HUMAN_STAND_MOBILE',
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_CLIPBOARD'
        },
        combatStyle = 'balanced'
    },
    ['lostmc'] = {
        models = { 'g_m_y_lost_01', 'g_m_y_lost_02', 'g_m_y_lost_03', 'g_f_y_lost_01' },
        vehicles = { 'daemon', 'hexer', 'zombie' },
        weapons = { 'WEAPON_SAWNOFFSHOTGUN', 'WEAPON_PISTOL', 'WEAPON_CROWBAR', 'WEAPON_BOTTLE' },
        scenarios = {
            'WORLD_HUMAN_DRINKING',
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_STAND_MOBILE'
        },
        combatStyle = 'aggressive'
    },
    ['marabunta'] = {
        models = { 'g_m_y_salvaboss_01', 'g_m_y_salvagoon_01', 'g_m_y_salvagoon_02', 'g_m_y_salvagoon_03' },
        vehicles = { 'tornado', 'buccaneer', 'vigero' },
        weapons = { 'WEAPON_MICROSMG', 'WEAPON_PISTOL', 'WEAPON_MACHETE' },
        scenarios = {
            'WORLD_HUMAN_DRUG_DEALER',
            'WORLD_HUMAN_HANG_OUT_STREET',
            'WORLD_HUMAN_SMOKING'
        },
        combatStyle = 'aggressive'
    },
    ['cartel'] = {
        models = { 'g_m_m_mexboss_01', 'g_m_m_mexboss_02', 'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02' },
        vehicles = { 'dubsta2', 'cavalcade2', 'baller3' },
        weapons = { 'WEAPON_ASSAULTRIFLE', 'WEAPON_COMBATPISTOL', 'WEAPON_SMG', 'WEAPON_MACHETE' },
        scenarios = {
            'WORLD_HUMAN_GUARD_STAND',
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_STAND_MOBILE'
        },
        combatStyle = 'balanced'
    }
}

-- ============================================
-- AMBIENT SPAWNING SETTINGS
-- ============================================

Config.AmbientSpawning = {
    enabled = true,

    -- Tiered proximity throttling (ms)
    tickRates = {
        combat = 100,       -- Player in combat or <20m from gang NPCs
        nearby = 500,       -- 20-50m from territory
        distant = 2000,     -- 50-150m from territory
        background = 5000   -- >150m or no nearby territories
    },

    -- Spawn density based on territory heat
    spawnDensity = {
        peaceful = { min = 2, max = 4 },    -- No recent conflict
        tense = { min = 3, max = 6 },       -- Recent player activity
        wartime = { min = 5, max = 10 }     -- Active rcore war
    },

    -- Distance thresholds
    spawnRadius = 100.0,        -- Radius around territory center to spawn NPCs
    despawnDistance = 200.0,    -- Distance before NPCs despawn
    playerTriggerDistance = 80.0, -- Distance to trigger ambient spawn

    -- Timing
    respawnCooldown = 60000,    -- Minimum time between respawns in same area (ms)
    despawnDelay = 300000       -- Time until idle NPCs despawn (5 min)
}

-- ============================================
-- COMBAT AI SETTINGS
-- ============================================

Config.CombatAI = {
    -- Base combat stats
    accuracy = {
        min = 40,
        max = 70
    },

    -- Behavior modifiers by combat style
    styles = {
        aggressive = {
            combatMovement = 3,     -- 0=stationary, 1=defensive, 2=offensive, 3=suicidal
            combatRange = 2,        -- 0=near, 1=medium, 2=far
            fleeHealthThreshold = 0, -- Never flee
            useCover = false,
            recruitNearby = true
        },
        defensive = {
            combatMovement = 1,
            combatRange = 1,
            fleeHealthThreshold = 30,
            useCover = true,
            recruitNearby = false
        },
        balanced = {
            combatMovement = 2,
            combatRange = 1,
            fleeHealthThreshold = 20,
            useCover = true,
            recruitNearby = true
        }
    },

    -- Advanced behaviors
    enableCoverSystem = true,
    enableRetreat = true,
    enableRecruitment = true,      -- NPCs call for backup
    recruitmentRadius = 50.0,
    maxRecruits = 3
}

-- ============================================
-- WAR REINFORCEMENT SETTINGS
-- Triggered when rcore starts a territory war
-- ============================================

Config.WarReinforcements = {
    enabled = true,

    -- Waves of reinforcements during war
    waves = {
        { delay = 0, count = 4 },       -- Immediate defenders
        { delay = 30000, count = 3 },   -- 30 second reinforcement
        { delay = 60000, count = 3 },   -- 1 minute reinforcement
        { delay = 120000, count = 2 }   -- 2 minute final wave
    },

    -- Spawn attackers for the attacking gang
    spawnAttackers = true,
    attackerWaves = {
        { delay = 5000, count = 3 },
        { delay = 45000, count = 3 },
        { delay = 90000, count = 2 }
    }
}

-- ============================================
-- RELATIONSHIP GROUPS
-- Managed centrally to prevent conflicts
-- ============================================

Config.Relationships = {
    -- Sync with rcore gang relationships
    syncWithRcore = true,

    -- Default relationship if rcore data unavailable
    -- 0=companion, 1=respect, 2=like, 3=neutral, 4=dislike, 5=hate
    defaultToPlayer = 3,        -- Neutral unless in rival gang
    defaultToRivals = 5,        -- Hate rival gangs
    defaultToSameGang = 1,      -- Respect same gang members
    defaultToPolice = 4         -- Dislike police
}

-- ============================================
-- POLICE INTEGRATION
-- ============================================

Config.PoliceJobs = {
    police = true,
    sheriff = true,
    bcso = true,
    sasp = true,
    lspd = true
}

-- Distance for police notifications
Config.PoliceNotifyDistance = 500.0

-- ============================================
-- DEBUG & PERFORMANCE
-- ============================================

Config.Debug = false

-- Maximum concurrent spawned gang NPCs (performance limit)
Config.MaxSpawnedNPCs = 30

-- Cleanup orphaned NPCs interval (ms)
Config.CleanupInterval = 60000
