-- ============================================
-- GANG AMBIENT AI - Server
-- Uses GangBridge for gang script abstraction
-- ============================================

-- qbx_core is native and does NOT expose GetCoreObject; it ships each function as a
-- discrete export. Provide a thin compat shim mapping only the methods this file uses,
-- so the QBCore.Functions.* call sites below stay unchanged.
local QBCore = {
    Functions = {
        GetPlayer = function(src) return exports.qbx_core:GetPlayer(src) end,
        GetQBPlayers = function() return exports.qbx_core:GetQBPlayers() end,
    }
}

-- State tracking
local spawnedNPCCount = 0           -- Track total ambient spawned NPCs
local warNPCCount = 0               -- Track total war-reinforcement NPCs (separate pool/cap)
local playerSpawnCounts = {}        -- Per-player ambient spawn tracking for cleanup on disconnect
local playerWarCounts = {}          -- Per-player war-reinforcement spawn tracking for cleanup on disconnect
local playerSpawnCooldowns = {}     -- Per-player rate limiting { [source] = lastRequestTime }
local playerPoliceNotifyCooldowns = {} -- Per-player police notify rate limiting
local zoneCentersCache = {}         -- Cache zone centers discovered from rcore for war reinforcements

-- ============================================
-- PLAYER GANG SYNC
-- Server sends gang name, client handles relationship groups
-- ============================================

local function GetPlayerGang(source)
    -- Try bridge first (gang script aware)
    if GangBridge and GangBridge.GetPlayerGang then
        local bridgeGang = GangBridge.GetPlayerGang(source)
        if bridgeGang then return bridgeGang end
    end

    -- Fallback to QBCore gang data
    local Player = QBCore.Functions.GetPlayer(source)
    if not Player then return nil end

    local gangData = Player.PlayerData.gang
    if gangData and gangData.name and gangData.name ~= 'none' then
        return GangBridge and GangBridge.ResolveGangName(gangData.name) or gangData.name:lower()
    end

    return nil
end

RegisterNetEvent('gangai:server:syncPlayerRelationship', function()
    local src = source
    local playerGang = GetPlayerGang(src)

    TriggerClientEvent('gangai:client:setPlayerRelationship', src, playerGang)
end)

-- ============================================
-- AMBIENT SPAWNING
-- ============================================

RegisterNetEvent('gangai:server:requestAmbientSpawn', function(zoneName, coords, heatLevel, densityMult)
    local src = source

    -- Rate limit: max 1 request per 10 seconds per player
    local now = GetGameTimer()
    local lastRequest = playerSpawnCooldowns[src] or 0
    if now - lastRequest < 10000 then
        return
    end
    playerSpawnCooldowns[src] = now

    -- Validate inputs
    if type(zoneName) ~= 'string' or zoneName == '' then return end
    if type(heatLevel) ~= 'string' then heatLevel = 'peaceful' end
    if heatLevel ~= 'peaceful' and heatLevel ~= 'tense' and heatLevel ~= 'wartime' then
        heatLevel = 'peaceful'
    end

    -- Time-of-day density multiplier (client-computed, clamped server-side)
    if type(densityMult) ~= 'number' then densityMult = 1.0 end
    densityMult = math.max(0.5, math.min(2.0, densityMult))

    -- Determine gang owner via bridge (server-side authority)
    local gangName = nil

    if GangBridge and GangBridge.GetZoneOwner then
        gangName = GangBridge.GetZoneOwner(zoneName, coords)
    end

    -- If bridge couldn't determine owner (e.g. standalone), fall back to the
    -- configured territory list (gated by Config.Integration.useFallbackData).
    if not gangName and zoneName and Config.Integration.useFallbackData then
        if Config.StandaloneTerritories then
            for _, territory in ipairs(Config.StandaloneTerritories) do
                if territory.name == zoneName then
                    gangName = territory.owner
                    break
                end
            end
        end
    end

    if not gangName then
        if Config.Debug then
            print('^1[GangAI] Could not determine zone owner for: ' .. tostring(zoneName))
        end
        return
    end

    -- Resolve gang name to Config.GangData key
    local resolvedName = GangBridge and GangBridge.ResolveGangName(gangName) or gangName:lower()
    local gangData = Config.GangData[resolvedName]

    if not gangData then
        if Config.Debug then
            print('^1[GangAI] No Config.GangData for gang: ' .. tostring(resolvedName) .. ' (raw: ' .. tostring(gangName) .. ')')
        end
        return
    end

    -- Check global NPC limit
    if spawnedNPCCount >= Config.MaxSpawnedNPCs then
        if Config.Debug then
            print('^3[GangAI] NPC limit reached, skipping spawn')
        end
        return
    end

    -- Cache zone center for war reinforcements
    if coords then
        zoneCentersCache[zoneName] = coords
    end

    -- Determine spawn count based on heat level, scaled by time-of-day density
    local density = Config.AmbientSpawning.spawnDensity[heatLevel] or Config.AmbientSpawning.spawnDensity.peaceful
    local spawnCount = math.random(density.min, density.max)
    spawnCount = math.floor(spawnCount * densityMult + 0.5)
    spawnCount = math.max(density.min, spawnCount) -- night boost never drops below base minimum

    -- Clamp to not exceed limit
    spawnCount = math.min(spawnCount, Config.MaxSpawnedNPCs - spawnedNPCCount)

    if spawnCount > 0 then
        TriggerClientEvent('gangai:client:spawnAmbientNPCs', src, {
            gangName = resolvedName,
            gangData = gangData,
            coords = coords,
            count = spawnCount
        })

        spawnedNPCCount = spawnedNPCCount + spawnCount

        -- Track per-player for cleanup on disconnect
        playerSpawnCounts[src] = (playerSpawnCounts[src] or 0) + spawnCount

        if Config.Debug then
            print('^2[GangAI] Spawning ' .. spawnCount .. ' ' .. resolvedName .. ' NPCs for zone ' .. tostring(zoneName) .. ' (total: ' .. spawnedNPCCount .. ')')
        end
    end
end)

-- NPC despawned callback (validated)
RegisterNetEvent('gangai:server:npcDespawned', function(count)
    local src = source

    -- Validate count: must be a positive integer, max reasonable value
    if type(count) ~= 'number' or count < 1 or count > Config.MaxSpawnedNPCs then
        return
    end
    count = math.floor(count)

    -- Don't let per-player count go below 0
    local playerCount = playerSpawnCounts[src] or 0
    local actualDecrement = math.min(count, playerCount)

    playerSpawnCounts[src] = math.max(0, playerCount - actualDecrement)
    spawnedNPCCount = math.max(0, spawnedNPCCount - actualDecrement)
end)

-- War-reinforcement NPC spawned callback (client reports actual spawns so the
-- war tally stays symmetric with despawns and cannot drift).
RegisterNetEvent('gangai:server:warNpcSpawned', function(count)
    local src = source

    if type(count) ~= 'number' or count < 1 or count > (Config.WarReinforcements.maxWarNPCs or 40) then
        return
    end
    count = math.floor(count)

    warNPCCount = warNPCCount + count
    playerWarCounts[src] = (playerWarCounts[src] or 0) + count
end)

-- War-reinforcement NPC despawned callback (validated, symmetric with the above)
RegisterNetEvent('gangai:server:warNpcDespawned', function(count)
    local src = source

    if type(count) ~= 'number' or count < 1 or count > (Config.WarReinforcements.maxWarNPCs or 40) then
        return
    end
    count = math.floor(count)

    local playerCount = playerWarCounts[src] or 0
    local actualDecrement = math.min(count, playerCount)

    playerWarCounts[src] = math.max(0, playerCount - actualDecrement)
    warNPCCount = math.max(0, warNPCCount - actualDecrement)
end)

-- Cleanup when player disconnects
AddEventHandler('playerDropped', function(reason)
    local src = source

    -- Decrement global count by however many NPCs this player had spawned
    local playerCount = playerSpawnCounts[src] or 0
    if playerCount > 0 then
        spawnedNPCCount = math.max(0, spawnedNPCCount - playerCount)
        if Config.Debug then
            print('^3[GangAI] Player ' .. src .. ' dropped, releasing ' .. playerCount .. ' NPC slots')
        end
    end

    -- Release this player's war-reinforcement slots too
    local warCount = playerWarCounts[src] or 0
    if warCount > 0 then
        warNPCCount = math.max(0, warNPCCount - warCount)
    end

    playerSpawnCounts[src] = nil
    playerWarCounts[src] = nil
    playerSpawnCooldowns[src] = nil
    playerPoliceNotifyCooldowns[src] = nil
end)

-- ============================================
-- WAR REINFORCEMENTS
-- Uses GangBridge callbacks for war events
-- ============================================

CreateThread(function()
    -- Wait for bridge to initialize
    Wait(3000)

    if not GangBridge then
        print('^1[GangAI] GangBridge not available, war reinforcements disabled')
        return
    end

    GangBridge.OnWarStart(function(zoneName, attacker, defender)
        if not Config.WarReinforcements.enabled then return end

        if Config.Debug then
            print('^3[GangAI] War started: ' .. tostring(attacker) .. ' vs ' .. tostring(defender) .. ' at zone ' .. tostring(zoneName))
        end

        -- Try multiple sources for zone coordinates
        local zoneCoords = nil

        -- 1. Check cached zone centers (populated during ambient spawning)
        if zoneCentersCache[zoneName] then
            zoneCoords = zoneCentersCache[zoneName]
        end

        -- 2. Check standalone territories
        if not zoneCoords and Config.StandaloneTerritories then
            for _, territory in ipairs(Config.StandaloneTerritories) do
                if territory.name == zoneName then
                    zoneCoords = territory.center
                    break
                end
            end
        end

        -- 3. Try rcore_gangs export to get zone position
        if not zoneCoords and GangBridge._adapter == 'rcore_gangs' and GetResourceState('rcore_gangs') == 'started' then
            local ok, result = pcall(function()
                -- rcore zones are defined in config, try to get zone data
                -- We iterate connected players to find one near the war zone
                local players = QBCore.Functions.GetQBPlayers()
                for _, Player in pairs(players) do
                    if Player then
                        local ped = GetPlayerPed(Player.PlayerData.source)
                        if DoesEntityExist(ped) then
                            local playerCoords = GetEntityCoords(ped)
                            local okZone, zone = pcall(function()
                                return exports['rcore_gangs']:GetZoneAtPosition(playerCoords)
                            end)
                            if okZone and zone and (zone.name == zoneName) then
                                -- Use this player's coords as approximate zone center
                                zoneCoords = playerCoords
                                zoneCentersCache[zoneName] = zoneCoords
                                return true
                            end
                        end
                    end
                end
                return false
            end)
        end

        if not zoneCoords then
            if Config.Debug then
                print('^1[GangAI] Could not get zone coordinates for war reinforcements at: ' .. tostring(zoneName))
            end
            return
        end

        -- Spawn defender waves
        local defenderData = defender and Config.GangData[defender]
        if defenderData then
            for _, wave in ipairs(Config.WarReinforcements.waves) do
                SetTimeout(wave.delay, function()
                    if GangBridge.IsZoneAtWar(zoneName) then
                        -- Send to all clients — client-side does 300m distance check
                        TriggerClientEvent('gangai:client:spawnWarReinforcements', -1, {
                            gangName = defender,
                            gangData = defenderData,
                            coords = zoneCoords,
                            count = wave.count,
                            isDefender = true
                        })
                    end
                end)
            end
        end

        -- Spawn attacker waves
        if Config.WarReinforcements.spawnAttackers then
            local attackerData = attacker and Config.GangData[attacker]
            if attackerData then
                for _, wave in ipairs(Config.WarReinforcements.attackerWaves) do
                    SetTimeout(wave.delay, function()
                        if GangBridge.IsZoneAtWar(zoneName) then
                            TriggerClientEvent('gangai:client:spawnWarReinforcements', -1, {
                                gangName = attacker,
                                gangData = attackerData,
                                coords = zoneCoords,
                                count = wave.count,
                                isDefender = false
                            })
                        end
                    end)
                end
            end
        end
    end)

    GangBridge.OnWarEnd(function(zoneName, winner)
        if Config.Debug then
            print('^2[GangAI] War ended at zone ' .. tostring(zoneName) .. '. Winner: ' .. tostring(winner))
        end
    end)
end)

-- ============================================
-- POLICE NOTIFICATIONS (rate limited)
-- ============================================

RegisterNetEvent('gangai:server:notifyPolice', function(message, coords)
    local src = source

    -- Rate limit: max 1 notification per 15 seconds per player
    local now = GetGameTimer()
    local lastNotify = playerPoliceNotifyCooldowns[src] or 0
    if now - lastNotify < 15000 then
        return
    end
    playerPoliceNotifyCooldowns[src] = now

    -- Validate coords
    if type(coords) ~= 'vector3' and (type(coords) ~= 'table' or not coords.x) then
        return
    end

    local players = QBCore.Functions.GetQBPlayers()

    for _, Player in pairs(players) do
        if Player and Config.PoliceJobs[Player.PlayerData.job.name] then
            local playerCoords = GetEntityCoords(GetPlayerPed(Player.PlayerData.source))
            local distance = #(vector3(playerCoords.x, playerCoords.y, playerCoords.z) - vector3(coords.x, coords.y, coords.z))

            if distance < Config.PoliceNotifyDistance then
                TriggerClientEvent('ox_lib:notify', Player.PlayerData.source, {
                    title = 'Dispatch',
                    description = message,
                    type = 'warning',
                    duration = 7000
                })
            end
        end
    end
end)

-- ============================================
-- ADMIN COMMANDS
-- ============================================

lib.addCommand('gangai', {
    help = 'Gang AI admin commands',
    params = {
        { name = 'action', help = 'status/spawn/clear' },
        { name = 'gang', help = 'Gang name (optional)', optional = true },
    },
    restricted = 'group.admin',
}, function(source, args)
    local action = args.action

    if action == 'status' then
        local adapterName = GangBridge and GangBridge._adapter or 'unknown'
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Gang AI Status',
            description = 'Ambient NPCs: ' .. spawnedNPCCount .. '/' .. Config.MaxSpawnedNPCs ..
                '\nWar NPCs: ' .. warNPCCount ..
                '\nBridge: ' .. adapterName,
            type = 'info',
            duration = 5000
        })
    elseif action == 'spawn' and args.gang then
        local gangName = args.gang:lower()
        local resolvedName = GangBridge and GangBridge.ResolveGangName(gangName) or gangName
        if Config.GangData[resolvedName] then
            local ped = GetPlayerPed(source)
            local coords = GetEntityCoords(ped)
            TriggerClientEvent('gangai:client:spawnAmbientNPCs', source, {
                gangName = resolvedName,
                gangData = Config.GangData[resolvedName],
                coords = coords,
                count = math.random(Config.AmbientSpawning.spawnDensity.wartime.min, Config.AmbientSpawning.spawnDensity.wartime.max)
            })
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'Gang AI',
                description = 'Spawning ' .. resolvedName .. ' NPCs',
                type = 'success'
            })
        else
            TriggerClientEvent('ox_lib:notify', source, {
                title = 'Error',
                description = 'Unknown gang: ' .. args.gang,
                type = 'error'
            })
        end
    elseif action == 'clear' then
        TriggerClientEvent('gangai:client:clearAllNPCs', -1)
        spawnedNPCCount = 0
        warNPCCount = 0
        playerSpawnCounts = {}
        playerWarCounts = {}
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Gang AI',
            description = 'All gang NPCs cleared',
            type = 'success'
        })
    end
end)

-- ============================================
-- INITIALIZATION
-- ============================================

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        TriggerClientEvent('gangai:client:clearAllNPCs', -1)
    end
end)

print('^2[GangAI] Server initialized — bridge mode')


-- ============================================
-- AMBIENT GUNFIGHT -> MDT WITNESS CALLS (DPS)
-- Rare by design: per 200m area, at most one call per 2 minutes and
-- three calls per fight (10 min window), escalating if fire is sustained.
-- ============================================
local gunfights = {}  -- ["x:y"] = { calls = n, firstAt = ms, lastAt = ms }
local gunfightReporterCooldown = {}  -- [src] = next allowed report time

local GUNFIGHT_DESCS = {
    'Multiple callers reporting gunshots in the area',
    'Caller heard a prolonged exchange of gunfire',
    'Resident reports what sounds like automatic weapons',
    'Several 911 calls about shots fired, callers sheltering indoors',
}

RegisterNetEvent('gangai:server:reportGunfight', function(coords, shooters)
    local src = source
    if type(coords) ~= 'table' or type(coords.x) ~= 'number'
        or type(coords.y) ~= 'number' or type(coords.z) ~= 'number' then return end
    -- reject non-finite/out-of-world coords: nan/inf pass the number check but
    -- crash ('%d'):format(math.floor(...)) and let a crafted client error the handler
    if coords.x ~= coords.x or coords.y ~= coords.y
        or math.abs(coords.x) > 20000 or math.abs(coords.y) > 20000 then return end
    -- per-reporter rate limit: the client scanner legitimately reports at most
    -- once / 60s, so anything faster is a modified client trying to spam the MDT
    local nowSrc = GetGameTimer()
    if nowSrc - (gunfightReporterCooldown[src] or 0) < 30000 then return end
    gunfightReporterCooldown[src] = nowSrc
    shooters = (type(shooters) == 'number') and shooters or 2

    -- prune stale per-cell records (>10 min) so gunfights can't grow unbounded
    for k, f in pairs(gunfights) do
        if nowSrc - f.firstAt > 600000 then gunfights[k] = nil end
    end

    local key = ('%d:%d'):format(math.floor(coords.x / 200), math.floor(coords.y / 200))
    local now = GetGameTimer()
    local fight = gunfights[key]
    if not fight or now - fight.firstAt > 600000 then
        fight = { calls = 0, firstAt = now, lastAt = 0 }
        gunfights[key] = fight
    end

    if now - fight.lastAt < 120000 then return end  -- never constant
    if fight.calls >= 3 then return end
    fight.lastAt = now  -- pace even when the roll below fails

    -- gunfire is loud: first report almost always comes in, follow-ups often
    local chance = (fight.calls == 0) and 90 or 65
    if math.random(100) > chance then return end
    fight.calls = fight.calls + 1

    local sustained = fight.calls >= 2
    local desc = GUNFIGHT_DESCS[math.random(#GUNFIGHT_DESCS)]
        .. ((shooters >= 4) and '. Caller believes several people are involved' or '')
        .. '. Location is approximate.'

    -- sound carries: callers localize gunfire roughly, faster than a drug tip
    local ang, dist = math.random() * 6.28318, 20.0 + math.random() * 40.0
    local fuzzed = { x = coords.x + math.cos(ang) * dist, y = coords.y + math.sin(ang) * dist, z = coords.z }

    SetTimeout(math.random(8000, 25000), function()
        pcall(function()
            exports['wasabi_mdt']:CreateDispatch({
                type = 'disturbance',
                title = sustained and '10-71 - Sustained Gunfire' or '10-71 - Shots Fired',
                description = desc,
                code = '10-71',
                coords = fuzzed,
                location = 'Approximate area - caller estimate',
                priority = sustained and 3 or 2,
                senderName = 'Anonymous Caller',
            })
        end)
    end)
end)


-- ============================================
-- ADMIN WAR TRIGGER (DPS)
-- Console or ace 'command' holders only. Drives the same rcore rivalry
-- events the bridge listens for, so the full chain runs: reinforcement
-- waves -> NPC combat -> ambient gunfight witness calls to the MDT.
--   gangwar [zone] [attacker] [defender]   e.g. gangwar davis families ballas
--   gangwar_end [zone] [winner]
-- ============================================
local function resolveDefender(zone)
    for _, territory in ipairs(Config.StandaloneTerritories or {}) do
        if territory.name == zone then return territory.owner end
    end
    return 'ballas'
end

RegisterCommand('gangwar', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command') then return end
    local zone = args[1] or 'davis'
    local rawDef = args[3] or resolveDefender(zone)
    local rawAtk = args[2] or (rawDef == 'families' and 'ballas' or 'families')
    local defender = GangBridge and GangBridge.ResolveGangName(rawDef)
    local attacker = GangBridge and GangBridge.ResolveGangName(rawAtk)
    if not defender or not attacker or defender == attacker then
        print(('^1[GangAI] gangwar: could not resolve both gangs (attacker=%s defender=%s). Zone "%s" may be unowned/mixed - pass gangs explicitly: gangwar <zone> <attacker> <defender>^7'):format(tostring(rawAtk), tostring(rawDef), zone))
        return
    end
    print(('^3[GangAI] ADMIN war trigger: %s attacking %s at %s^7'):format(attacker, defender, zone))
    -- drive OUR war system straight through the bridge: works under the
    -- standalone adapter too, and never spoofs rcore's internal rivalry event
    -- (which could start a real persistent rivalry in the third-party script)
    GangBridge._fireWarStart(zone, attacker, defender)
end, true)

RegisterCommand('gangwar_end', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command') then return end
    local zone = args[1] or 'davis'
    print(('^3[GangAI] ADMIN war end at %s^7'):format(zone))
    GangBridge._fireWarEnd(zone, args[2] and GangBridge.ResolveGangName(args[2]) or nil)
end, true)


RegisterCommand('gangvibe', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command') then return end
    local kind = args[1]
    if kind ~= 'taunt' and kind ~= 'driveby' and kind ~= 'skirmish' then kind = nil end
    print(('^3[GangAI] ADMIN vibe event trigger: %s^7'):format(kind or 'random'))
    -- only the admin who ran it sees the demo (was -1: spawned crews at EVERY
    -- player's nearest territory, often km away, then raced the despawn loop)
    TriggerClientEvent('gangai:client:forceVibe', source ~= 0 and source or -1, kind)
end, true)
