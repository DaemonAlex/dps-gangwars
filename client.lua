-- ============================================
-- GANG AMBIENT AI - Client
-- Handles NPC spawning, combat AI, and throttling
-- Uses GangBridge for gang script abstraction
-- ============================================

local QBCore = exports['qb-core']:GetCoreObject()

-- State tracking
local spawnedNPCs = {}          -- All spawned NPCs { entity, gangName, spawnTime }
local playerGang = nil          -- Player's gang name (lowercase)
local playerRelationshipHash = nil
local lastSpawnTime = {}        -- Cooldown tracking per zone name
local inCombat = false          -- Is player in combat

-- ============================================
-- RELATIONSHIP GROUP MANAGEMENT (Client-side)
-- These natives only work on client
-- ============================================

local gangRelationshipGroups = {}
local relationshipsInitialized = false

local function GetOrCreateGangRelationship(gangName)
    if gangRelationshipGroups[gangName] then
        return gangRelationshipGroups[gangName]
    end

    local groupName = 'GANG_' .. string.upper(gangName)
    local groupHash = GetHashKey(groupName)

    AddRelationshipGroup(groupName)
    gangRelationshipGroups[gangName] = groupHash

    return groupHash
end

local function SetupGangRelationships()
    if relationshipsInitialized then return end

    local gangs = {}
    for gangName, _ in pairs(Config.GangData) do
        gangs[#gangs + 1] = gangName
        GetOrCreateGangRelationship(gangName)
    end

    for _, gang1 in ipairs(gangs) do
        local hash1 = gangRelationshipGroups[gang1]

        for _, gang2 in ipairs(gangs) do
            local hash2 = gangRelationshipGroups[gang2]

            if gang1 == gang2 then
                SetRelationshipBetweenGroups(Config.Relationships.defaultToSameGang, hash1, hash2)
            else
                SetRelationshipBetweenGroups(Config.Relationships.defaultToRivals, hash1, hash2)
            end
        end

        SetRelationshipBetweenGroups(Config.Relationships.defaultToPolice, hash1, GetHashKey('COP'))
        SetRelationshipBetweenGroups(1, hash1, GetHashKey('PLAYER'))
    end

    relationshipsInitialized = true

    if Config.Debug then
        print('[GangAI] Relationship groups initialized for ' .. #gangs .. ' gangs')
    end
end

-- ============================================
-- TIERED PROXIMITY THROTTLING
-- ============================================

local currentTickRate = Config.AmbientSpawning.tickRates.background

local function GetOptimalTickRate()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)

    if IsPedInMeleeCombat(ped) or IsPedShooting(ped) then
        inCombat = true
        return Config.AmbientSpawning.tickRates.combat
    end

    local nearestNPCDist = 999.0
    for _, npcData in pairs(spawnedNPCs) do
        if DoesEntityExist(npcData.entity) then
            local npcCoords = GetEntityCoords(npcData.entity)
            local dist = #(coords - npcCoords)
            if dist < nearestNPCDist then
                nearestNPCDist = dist
            end
        end
    end

    inCombat = false

    if nearestNPCDist < 20.0 then
        return Config.AmbientSpawning.tickRates.combat
    elseif nearestNPCDist < 50.0 then
        return Config.AmbientSpawning.tickRates.nearby
    elseif nearestNPCDist < 150.0 then
        return Config.AmbientSpawning.tickRates.distant
    end

    return Config.AmbientSpawning.tickRates.background
end

-- ============================================
-- PLAYER RELATIONSHIP SYNC
-- ============================================

RegisterNetEvent('gangai:client:setPlayerRelationship', function(gang)
    playerGang = gang

    SetupGangRelationships()

    if gang and gangRelationshipGroups[gang] then
        local ped = PlayerPedId()
        playerRelationshipHash = gangRelationshipGroups[gang]
        SetPedRelationshipGroupHash(ped, playerRelationshipHash)

        for gangName, hash in pairs(gangRelationshipGroups) do
            if gangName == gang then
                SetRelationshipBetweenGroups(Config.Relationships.defaultToSameGang, hash, GetHashKey('PLAYER'))
                SetRelationshipBetweenGroups(Config.Relationships.defaultToSameGang, GetHashKey('PLAYER'), hash)
            else
                SetRelationshipBetweenGroups(Config.Relationships.defaultToRivals, hash, GetHashKey('PLAYER'))
                SetRelationshipBetweenGroups(Config.Relationships.defaultToRivals, GetHashKey('PLAYER'), hash)
            end
        end

        if Config.Debug then
            print('[GangAI] Player relationship set to gang: ' .. gang)
        end
    else
        -- Player is not in a gang — set neutral to all gangs
        playerRelationshipHash = nil
        for _, hash in pairs(gangRelationshipGroups) do
            SetRelationshipBetweenGroups(Config.Relationships.defaultToPlayer, hash, GetHashKey('PLAYER'))
            SetRelationshipBetweenGroups(Config.Relationships.defaultToPlayer, GetHashKey('PLAYER'), hash)
        end
    end
end)

-- Sync relationship on spawn/load
AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    Wait(2000)
    -- Try client-side bridge first
    if GangBridge and GangBridge.GetPlayerGangClient then
        local gangData = GangBridge.GetPlayerGangClient()
        if gangData then
            local rawTag = type(gangData) == 'table' and (gangData.tag or gangData.name) or gangData
            if rawTag then
                playerGang = GangBridge.ResolveGangName(rawTag)
            end
        end
    end
    -- Also sync from server (authoritative)
    TriggerServerEvent('gangai:server:syncPlayerRelationship')
end)

AddEventHandler('QBCore:Client:OnGangUpdate', function(gang)
    TriggerServerEvent('gangai:server:syncPlayerRelationship')
end)

-- ============================================
-- ADVANCED COMBAT AI
-- ============================================

local function ApplyCombatAI(ped, gangData)
    local style = Config.CombatAI.styles[gangData.combatStyle] or Config.CombatAI.styles.balanced

    SetPedCombatMovement(ped, style.combatMovement)
    SetPedCombatRange(ped, style.combatRange)
    SetPedCombatAbility(ped, 2)

    local accuracy = math.random(Config.CombatAI.accuracy.min, Config.CombatAI.accuracy.max)
    SetPedAccuracy(ped, accuracy)

    SetPedSeeingRange(ped, 100.0)
    SetPedHearingRange(ped, 80.0)
    SetPedAlertness(ped, 3)

    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAttributes(ped, 5, true)
    SetPedCombatAttributes(ped, 0, true)

    if Config.CombatAI.enableCoverSystem and style.useCover then
        SetPedCombatAttributes(ped, 1, true)
        SetPedCombatAttributes(ped, 2, true)
    end

    if Config.CombatAI.enableRetreat and style.fleeHealthThreshold > 0 then
        SetPedFleeAttributes(ped, 0, false)
        CreateThread(function()
            while DoesEntityExist(ped) and not IsEntityDead(ped) do
                Wait(1000)
                local health = GetEntityHealth(ped)
                local maxHealth = GetEntityMaxHealth(ped)
                local healthPercent = (health / maxHealth) * 100

                if healthPercent <= style.fleeHealthThreshold then
                    TaskSmartFleePed(ped, PlayerPedId(), 100.0, -1, false, false)
                    break
                end
            end
        end)
    end
end

-- Recruitment system - NPC calls for backup
local function TriggerRecruitment(ped, gangName)
    if not Config.CombatAI.enableRecruitment then return end

    local gangData = Config.GangData[gangName]
    if not gangData then return end

    local style = Config.CombatAI.styles[gangData.combatStyle]
    if not style or not style.recruitNearby then return end

    local pedCoords = GetEntityCoords(ped)
    local recruits = 0

    for _, npcData in pairs(spawnedNPCs) do
        if npcData.gangName == gangName and DoesEntityExist(npcData.entity) and npcData.entity ~= ped then
            local dist = #(pedCoords - GetEntityCoords(npcData.entity))

            if dist < Config.CombatAI.recruitmentRadius then
                if not IsPedInCombat(npcData.entity) then
                    TaskCombatHatedTargetsAroundPed(npcData.entity, 100.0, 0)
                    recruits = recruits + 1

                    if recruits >= Config.CombatAI.maxRecruits then
                        break
                    end
                end
            end
        end
    end

    if Config.Debug and recruits > 0 then
        print('[GangAI] Recruited ' .. recruits .. ' nearby ' .. gangName .. ' NPCs')
    end
end

-- ============================================
-- NPC SPAWNING
-- ============================================

local function SpawnGangNPC(gangName, gangData, coords)
    SetupGangRelationships()

    local relationshipHash = GetOrCreateGangRelationship(gangName)

    local modelName = gangData.models[math.random(#gangData.models)]
    local modelHash = GetHashKey(modelName)

    RequestModel(modelHash)
    local timeout = 0
    while not HasModelLoaded(modelHash) and timeout < 5000 do
        Wait(100)
        timeout = timeout + 100
    end

    if not HasModelLoaded(modelHash) then
        if Config.Debug then
            print('[GangAI] Failed to load model: ' .. modelName)
        end
        return nil
    end

    -- Random offset from center
    local angle = math.random() * 2 * math.pi
    local dist = math.random() * Config.AmbientSpawning.spawnRadius * 0.5
    local spawnX = coords.x + dist * math.cos(angle)
    local spawnY = coords.y + dist * math.sin(angle)
    local spawnZ = coords.z

    -- Spawn ped and use PlaceOnGroundProperly for correct Z
    local ped = CreatePed(4, modelHash, spawnX, spawnY, spawnZ + 1.0, math.random(0, 360) + 0.0, true, true)

    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(modelHash)
        return nil
    end

    PlaceOnGroundProperly(ped)

    -- Set relationship group
    SetPedRelationshipGroupHash(ped, relationshipHash)

    -- Give weapon
    if gangData.weapons and #gangData.weapons > 0 then
        local weapon = gangData.weapons[math.random(#gangData.weapons)]
        GiveWeaponToPed(ped, GetHashKey(weapon), 255, false, true)
    end

    -- Apply combat AI
    ApplyCombatAI(ped, gangData)

    -- Apply scenario if peaceful
    if gangData.scenarios and #gangData.scenarios > 0 and not inCombat then
        local scenario = gangData.scenarios[math.random(#gangData.scenarios)]
        TaskStartScenarioInPlace(ped, scenario, 0, true)
    end

    -- Only mark as enemy if player is in a DIFFERENT gang (not if player has no gang)
    if playerGang and playerGang ~= gangName then
        SetPedAsEnemy(ped, true)
    end

    SetModelAsNoLongerNeeded(modelHash)

    local npcData = {
        entity = ped,
        gangName = gangName,
        spawnTime = GetGameTimer(),
        coords = vector3(spawnX, spawnY, spawnZ)
    }
    spawnedNPCs[ped] = npcData

    -- Despawn timer
    SetTimeout(Config.AmbientSpawning.despawnDelay, function()
        if DoesEntityExist(ped) and not IsPedInCombat(ped) then
            DeleteEntity(ped)
            spawnedNPCs[ped] = nil
            TriggerServerEvent('gangai:server:npcDespawned', 1)
        end
    end)

    return ped
end

-- Spawn ambient NPCs event
RegisterNetEvent('gangai:client:spawnAmbientNPCs', function(data)
    if not data or not data.gangData then return end

    for i = 1, data.count do
        local ped = SpawnGangNPC(data.gangName, data.gangData, data.coords)
        if ped then
            Wait(100) -- Stagger spawns
        end
    end

    if Config.Debug then
        print('[GangAI] Spawned ' .. data.count .. ' ' .. data.gangName .. ' NPCs')
    end
end)

-- Spawn war reinforcements
RegisterNetEvent('gangai:client:spawnWarReinforcements', function(data)
    if not data or not data.gangData then return end

    local playerCoords = GetEntityCoords(PlayerPedId())
    local dist = #(playerCoords - vector3(data.coords.x, data.coords.y, data.coords.z))

    if dist > 300.0 then return end

    for i = 1, data.count do
        local ped = SpawnGangNPC(data.gangName, data.gangData, data.coords)
        if ped then
            TaskCombatHatedTargetsAroundPed(ped, 150.0, 0)
            Wait(100)
        end
    end

    if Config.Debug then
        local role = data.isDefender and 'defenders' or 'attackers'
        print('[GangAI] Spawned ' .. data.count .. ' ' .. data.gangName .. ' ' .. role)
    end
end)

-- Clear all NPCs
RegisterNetEvent('gangai:client:clearAllNPCs', function()
    local count = 0
    for ped, _ in pairs(spawnedNPCs) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
            count = count + 1
        end
    end
    spawnedNPCs = {}

    if Config.Debug then
        print('[GangAI] Cleared ' .. count .. ' NPCs')
    end
end)

-- ============================================
-- COMBAT DETECTION
-- ============================================

CreateThread(function()
    while true do
        local tickRate = GetOptimalTickRate()
        Wait(tickRate)

        local ped = PlayerPedId()

        if IsPedShooting(ped) then
            local _, entity = GetEntityPlayerIsFreeAimingAt(PlayerId())

            if DoesEntityExist(entity) and not IsPedAPlayer(entity) then
                local npcData = spawnedNPCs[entity]
                if npcData then
                    TriggerRecruitment(entity, npcData.gangName)

                    local coords = GetEntityCoords(entity)
                    TriggerServerEvent('gangai:server:notifyPolice', 'Shots fired in gang territory!', coords)
                end
            end
        end
    end
end)

-- ============================================
-- AMBIENT SPAWNING LOOP
-- Uses GangBridge for territory detection
-- ============================================

CreateThread(function()
    Wait(5000) -- Initial delay for bridge to initialize

    while true do
        local tickRate = GetOptimalTickRate()
        Wait(tickRate)

        if not Config.AmbientSpawning.enabled then
            Wait(5000)
            goto continue
        end

        -- Wait for bridge to be ready
        if not GangBridge or not GangBridge._adapter then
            Wait(2000)
            goto continue
        end

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)

        -- Use bridge to detect if player is in a gang territory
        local zone = GangBridge.GetZoneAtPosition(coords)

        if zone and zone.owner then
            local gangData = Config.GangData[zone.owner]

            if gangData then
                -- Check cooldown per zone
                local lastSpawn = lastSpawnTime[zone.name] or 0
                if GetGameTimer() - lastSpawn > Config.AmbientSpawning.respawnCooldown then

                    -- Determine heat level
                    local heatLevel = 'peaceful'
                    if inCombat then
                        heatLevel = 'wartime'
                    elseif GangBridge.IsZoneAtWar and GangBridge.IsZoneAtWar(zone.name) then
                        heatLevel = 'wartime'
                    end

                    -- Request spawn from server (send zone name + center for server-side ownership verification)
                    TriggerServerEvent('gangai:server:requestAmbientSpawn', zone.name, zone.center, heatLevel)
                    lastSpawnTime[zone.name] = GetGameTimer()

                    if Config.Debug then
                        print('[GangAI] Zone detected: ' .. zone.name .. ' owned by ' .. zone.owner .. ' (heat: ' .. heatLevel .. ')')
                    end
                end
            elseif Config.Debug then
                print('[GangAI] Zone ' .. zone.name .. ' owner "' .. tostring(zone.owner) .. '" not in Config.GangData')
            end
        end

        ::continue::
    end
end)

-- ============================================
-- CLEANUP LOOP
-- Despawn distant NPCs
-- ============================================

CreateThread(function()
    while true do
        Wait(Config.CleanupInterval or 60000)

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local cleaned = 0

        for npcPed, npcData in pairs(spawnedNPCs) do
            if DoesEntityExist(npcPed) then
                local npcCoords = GetEntityCoords(npcPed)
                local dist = #(coords - npcCoords)

                if dist > Config.AmbientSpawning.despawnDistance and not IsPedInCombat(npcPed) then
                    DeleteEntity(npcPed)
                    spawnedNPCs[npcPed] = nil
                    cleaned = cleaned + 1
                end
            else
                spawnedNPCs[npcPed] = nil
                cleaned = cleaned + 1
            end
        end

        if cleaned > 0 then
            TriggerServerEvent('gangai:server:npcDespawned', cleaned)
            if Config.Debug then
                print('[GangAI] Cleaned up ' .. cleaned .. ' distant/dead NPCs')
            end
        end
    end
end)

-- ============================================
-- INITIALIZATION
-- ============================================

CreateThread(function()
    Wait(3000)

    SetupGangRelationships()

    -- Try client-side bridge for player gang
    if GangBridge and GangBridge.GetPlayerGangClient then
        local gangData = GangBridge.GetPlayerGangClient()
        if gangData then
            local rawTag = type(gangData) == 'table' and (gangData.tag or gangData.name) or gangData
            if rawTag then
                playerGang = GangBridge.ResolveGangName(rawTag)
            end
        end
    end

    -- Sync from server (authoritative)
    TriggerServerEvent('gangai:server:syncPlayerRelationship')

    if Config.Debug then
        print('[GangAI] Client initialized')
        print('[GangAI] Bridge adapter: ' .. tostring(GangBridge and GangBridge._adapter or 'not ready'))
        print('[GangAI] Tick rates: combat=' .. Config.AmbientSpawning.tickRates.combat ..
              'ms, nearby=' .. Config.AmbientSpawning.tickRates.nearby ..
              'ms, distant=' .. Config.AmbientSpawning.tickRates.distant ..
              'ms, background=' .. Config.AmbientSpawning.tickRates.background .. 'ms')
    end
end)
