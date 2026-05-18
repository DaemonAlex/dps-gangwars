-- ============================================
-- GANG AMBIENT AI - Server
-- Uses GangBridge for gang script abstraction
-- ============================================

local QBCore = exports['qb-core']:GetCoreObject()

-- State tracking
local spawnedNPCCount = 0           -- Track total spawned NPCs
local playerSpawnCounts = {}        -- Per-player spawn tracking for cleanup on disconnect
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

RegisterNetEvent('gangai:server:requestAmbientSpawn', function(zoneName, coords, heatLevel)
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

    -- Determine gang owner via bridge (server-side authority)
    local gangName = nil

    if GangBridge and GangBridge.GetZoneOwner then
        gangName = GangBridge.GetZoneOwner(zoneName, coords)
    end

    -- If bridge couldn't determine owner (e.g. standalone), trust the zone data
    if not gangName and zoneName then
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

    -- Determine spawn count based on heat level
    local density = Config.AmbientSpawning.spawnDensity[heatLevel] or Config.AmbientSpawning.spawnDensity.peaceful
    local spawnCount = math.random(density.min, density.max)

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

    playerSpawnCounts[src] = nil
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

QBCore.Commands.Add('gangai', 'Gang AI admin commands', {{ name = 'action', help = 'status/spawn/clear' }, { name = 'gang', help = 'Gang name (optional)' }}, false, function(source, args)
    local action = args[1]

    if action == 'status' then
        local adapterName = GangBridge and GangBridge._adapter or 'unknown'
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Gang AI Status',
            description = 'Active NPCs: ' .. spawnedNPCCount .. '/' .. Config.MaxSpawnedNPCs .. '\nBridge: ' .. adapterName,
            type = 'info',
            duration = 5000
        })
    elseif action == 'spawn' and args[2] then
        local gangName = args[2]:lower()
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
                description = 'Unknown gang: ' .. args[2],
                type = 'error'
            })
        end
    elseif action == 'clear' then
        TriggerClientEvent('gangai:client:clearAllNPCs', -1)
        spawnedNPCCount = 0
        playerSpawnCounts = {}
        TriggerClientEvent('ox_lib:notify', source, {
            title = 'Gang AI',
            description = 'All gang NPCs cleared',
            type = 'success'
        })
    end
end, 'admin')

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
