-- ============================================
-- GANG AMBIENT AI - Client
-- Handles NPC spawning, combat AI, vehicles, patrols, and throttling
-- Uses GangBridge for gang script abstraction
-- ============================================

-- State tracking
local spawnedNPCs = {}          -- Ambient spawned NPCs { entity, gangName, spawnTime, behavior }
local spawnedWarNPCs = {}       -- War-reinforcement NPCs (separate pool, separately capped)
local spawnedVehicles = {}      -- All spawned vehicles { entity, gangName, spawnTime }
local playerGang = nil          -- Player's gang name (lowercase)
local playerRelationshipHash = nil
local lastSpawnTime = {}        -- Cooldown tracking per zone name
local inCombat = false          -- Is player in combat
local recentGunshots = {}       -- Track recent gunshot timestamps per zone for tense detection
local lastPoliceNotify = 0      -- Rate limit police notifications

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
        SetRelationshipBetweenGroups(Config.Relationships.defaultToPlayer, hash1, GetHashKey('PLAYER'))
    end

    relationshipsInitialized = true

    if Config.Debug then
        print('[GangAI] Relationship groups initialized for ' .. #gangs .. ' gangs')
    end
end

-- ============================================
-- TIME OF DAY HELPERS
-- ============================================

local function GetTimeOfDay()
    local hour = GetClockHours()
    if hour >= 22 or hour < 6 then
        return 'night'
    elseif hour >= 6 and hour < 12 then
        return 'morning'
    elseif hour >= 12 and hour < 18 then
        return 'afternoon'
    else
        return 'evening'
    end
end

local function GetTimeDensityMultiplier()
    local tod = GetTimeOfDay()
    if tod == 'night' then
        return 1.4 -- More gang activity at night
    elseif tod == 'evening' then
        return 1.2
    elseif tod == 'morning' then
        return 0.7 -- Less activity in the morning
    end
    return 1.0
end

-- ============================================
-- TIERED PROXIMITY THROTTLING
-- ============================================

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
-- NPC BEHAVIOR SYSTEM
-- Patrol, wander, and time-of-day scenarios
-- ============================================

local function AssignBehavior(ped, gangData, coords)
    local tod = GetTimeOfDay()
    local roll = math.random(100)

    -- At night: more wandering and standing around, fewer scenarios
    -- During day: more scenarios (smoking, drinking, dealing)
    if tod == 'night' then
        if roll <= 35 then
            -- Wander around the territory
            TaskWanderInArea(ped, coords.x, coords.y, coords.z, Config.AmbientSpawning.spawnRadius * 0.4, 1.0, 3.0)
            return 'wander'
        elseif roll <= 60 then
            -- Guard/lookout behavior at night
            TaskGuardCurrentPosition(ped, 15.0, 15.0, true)
            return 'guard'
        end
    elseif tod == 'morning' then
        if roll <= 50 then
            -- More likely to just stand around in morning
            TaskWanderInArea(ped, coords.x, coords.y, coords.z, Config.AmbientSpawning.spawnRadius * 0.3, 0.5, 2.0)
            return 'wander'
        end
    else
        if roll <= 25 then
            -- Patrol/wander during afternoon/evening
            TaskWanderInArea(ped, coords.x, coords.y, coords.z, Config.AmbientSpawning.spawnRadius * 0.5, 1.0, 4.0)
            return 'wander'
        end
    end

    -- Default: use scenario from gang data
    if gangData.scenarios and #gangData.scenarios > 0 then
        local scenario = gangData.scenarios[math.random(#gangData.scenarios)]
        TaskStartScenarioInPlace(ped, scenario, 0, true)
        return 'scenario'
    end

    return 'idle'
end

-- ============================================
-- NPC SPAWNING
-- ============================================

-- Self-rescheduling despawn scheduler.
-- Removes an idle NPC after despawnDelay, but if the ped is still in combat it
-- reschedules instead of leaking the slot forever, and force-removes past a hard
-- max age regardless of combat. The pool-membership guard keeps the despawn
-- report symmetric (never double-decrements if the cleanup loop got there first).
local function ScheduleNPCDespawn(ped, pool, despawnEvent, spawnTime)
    local baseDelay = Config.AmbientSpawning.despawnDelay or 300000
    local maxAge = Config.AmbientSpawning.maxNPCAge or (baseDelay * 3)

    local function check()
        if not DoesEntityExist(ped) then
            if pool[ped] then
                pool[ped] = nil
                TriggerServerEvent(despawnEvent, 1)
            end
            return
        end

        local age = GetGameTimer() - spawnTime

        if age >= maxAge or not IsPedInCombat(ped) then
            DeleteEntity(ped)
            if pool[ped] then
                pool[ped] = nil
                TriggerServerEvent(despawnEvent, 1)
            end
            return
        end

        -- Still in combat and under max age: check again later.
        SetTimeout(30000, check)
    end

    SetTimeout(baseDelay, check)
end

--- @param isWar boolean|nil  route into the separate war-reinforcement pool
local function SpawnGangNPC(gangName, gangData, coords, isWar)
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

    -- Assign behavior (patrol, wander, scenario) based on time of day
    local behavior = 'idle'
    if not inCombat then
        behavior = AssignBehavior(ped, gangData, coords)
    end

    -- Only mark as enemy if player is in a DIFFERENT gang (not if player has no gang)
    if playerGang and playerGang ~= gangName then
        SetPedAsEnemy(ped, true)
    end

    SetModelAsNoLongerNeeded(modelHash)

    local spawnTime = GetGameTimer()
    local pool = isWar and spawnedWarNPCs or spawnedNPCs
    local despawnEvent = isWar and 'gangai:server:warNpcDespawned' or 'gangai:server:npcDespawned'

    local npcData = {
        entity = ped,
        gangName = gangName,
        spawnTime = spawnTime,
        coords = vector3(spawnX, spawnY, spawnZ),
        behavior = behavior,
        isWar = isWar or false
    }
    pool[ped] = npcData

    -- Despawn timer (reschedules while in combat, force-removes past max age)
    ScheduleNPCDespawn(ped, pool, despawnEvent, spawnTime)

    return ped
end

-- ============================================
-- VEHICLE SPAWNING
-- ============================================

local function SpawnGangVehicle(gangName, gangData, coords)
    if not gangData.vehicles or #gangData.vehicles == 0 then return nil end
    if not Config.VehicleSpawning or not Config.VehicleSpawning.enabled then return nil end

    -- Check vehicle cap
    local vehCount = 0
    for _ in pairs(spawnedVehicles) do vehCount = vehCount + 1 end
    if vehCount >= (Config.VehicleSpawning.maxVehicles or 10) then return nil end

    local vehicleName = gangData.vehicles[math.random(#gangData.vehicles)]
    local vehicleHash = GetHashKey(vehicleName)

    RequestModel(vehicleHash)
    local timeout = 0
    while not HasModelLoaded(vehicleHash) and timeout < 5000 do
        Wait(100)
        timeout = timeout + 100
    end

    if not HasModelLoaded(vehicleHash) then return nil end

    -- Spawn at random offset
    local angle = math.random() * 2 * math.pi
    local dist = math.random(20, math.floor(Config.AmbientSpawning.spawnRadius * 0.6))
    local spawnX = coords.x + dist * math.cos(angle)
    local spawnY = coords.y + dist * math.sin(angle)

    -- Find a road node near the spawn point
    local found, roadX, roadY, roadZ, heading = GetClosestVehicleNodeWithHeading(spawnX, spawnY, coords.z, 1, 3.0, 0)
    if not found then
        SetModelAsNoLongerNeeded(vehicleHash)
        return nil
    end

    local vehicle = CreateVehicle(vehicleHash, roadX, roadY, roadZ, heading, true, true)

    if not DoesEntityExist(vehicle) then
        SetModelAsNoLongerNeeded(vehicleHash)
        return nil
    end

    -- Set vehicle as mission entity briefly for placement, then release
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleDoorsLocked(vehicle, 2) -- Lock doors
    SetModelAsNoLongerNeeded(vehicleHash)

    spawnedVehicles[vehicle] = {
        entity = vehicle,
        gangName = gangName,
        spawnTime = GetGameTimer()
    }

    -- Despawn timer for vehicles — only remove if the driver seat is empty
    SetTimeout(Config.VehicleSpawning.despawnDelay or 600000, function()
        if DoesEntityExist(vehicle) and IsVehicleSeatFree(vehicle, -1) then
            DeleteEntity(vehicle)
            spawnedVehicles[vehicle] = nil
        end
    end)

    if Config.Debug then
        print('[GangAI] Spawned ' .. gangName .. ' vehicle: ' .. vehicleName)
    end

    return vehicle
end

-- ============================================
-- SPAWN EVENTS
-- ============================================

-- Spawn ambient NPCs event
RegisterNetEvent('gangai:client:spawnAmbientNPCs', function(data)
    if not data or not data.gangData then return end

    for i = 1, data.count do
        local ped = SpawnGangNPC(data.gangName, data.gangData, data.coords)
        if ped then
            Wait(100) -- Stagger spawns
        end
    end

    -- Also spawn a vehicle occasionally
    if data.gangData.vehicles and #data.gangData.vehicles > 0 then
        if math.random(100) <= (Config.VehicleSpawning and Config.VehicleSpawning.spawnChance or 30) then
            SpawnGangVehicle(data.gangName, data.gangData, data.coords)
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

    -- Per-client war NPC cap (war NPCs are pooled/capped separately from ambient)
    local maxWar = Config.WarReinforcements.maxWarNPCs or 40
    local warCount = 0
    for _ in pairs(spawnedWarNPCs) do warCount = warCount + 1 end

    local spawned = 0
    for i = 1, data.count do
        if warCount + spawned >= maxWar then break end
        local ped = SpawnGangNPC(data.gangName, data.gangData, data.coords, true)
        if ped then
            TaskCombatHatedTargetsAroundPed(ped, 150.0, 0)
            spawned = spawned + 1
            Wait(100)
        end
    end

    -- Report actual spawns so the server war tally stays symmetric with despawns
    if spawned > 0 then
        TriggerServerEvent('gangai:server:warNpcSpawned', spawned)
    end

    if Config.Debug then
        local role = data.isDefender and 'defenders' or 'attackers'
        print('[GangAI] Spawned ' .. spawned .. ' ' .. data.gangName .. ' ' .. role)
    end
end)

-- Clear all NPCs and vehicles
RegisterNetEvent('gangai:client:clearAllNPCs', function()
    local count = 0
    for ped, _ in pairs(spawnedNPCs) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
            count = count + 1
        end
    end
    spawnedNPCs = {}

    -- War-reinforcement pool (server resets its war tally in the same paths that
    -- fire this event, so no despawn report is needed here)
    for ped, _ in pairs(spawnedWarNPCs) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
            count = count + 1
        end
    end
    spawnedWarNPCs = {}

    for veh, _ in pairs(spawnedVehicles) do
        if DoesEntityExist(veh) then
            DeleteEntity(veh)
        end
    end
    spawnedVehicles = {}

    if Config.Debug then
        print('[GangAI] Cleared ' .. count .. ' NPCs and all vehicles')
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

                    -- Track gunshots for tense detection
                    local coords = GetEntityCoords(entity)
                    local zone = GangBridge and GangBridge._adapter and GangBridge.GetZoneAtPosition(coords)
                    if zone then
                        recentGunshots[zone.name] = GetGameTimer()
                    end

                    -- Rate-limited police notification (max once per 15 seconds)
                    if GetGameTimer() - lastPoliceNotify > 15000 then
                        TriggerServerEvent('gangai:server:notifyPolice', 'Shots fired in gang territory!', coords)
                        lastPoliceNotify = GetGameTimer()
                    end
                end
            end
        end
    end
end)

-- ============================================
-- HEAT LEVEL DETECTION
-- ============================================

local function GetZoneHeatLevel(zoneName)
    -- Wartime: active combat or zone at war
    if inCombat then
        return 'wartime'
    end
    if GangBridge and GangBridge.IsZoneAtWar and GangBridge.IsZoneAtWar(zoneName) then
        return 'wartime'
    end

    -- Tense: recent gunshots in this zone (within 5 minutes)
    local lastShot = recentGunshots[zoneName]
    if lastShot and (GetGameTimer() - lastShot) < 300000 then
        return 'tense'
    end

    -- Tense at night (gang areas are naturally more tense after dark)
    if GetTimeOfDay() == 'night' then
        if math.random(100) <= 30 then
            return 'tense'
        end
    end

    return 'peaceful'
end

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
                -- Gate spawns by proximity to the zone center (NPCs spawn near the
                -- center, so there's no point requesting them from far across a zone)
                local triggerDist = Config.AmbientSpawning.playerTriggerDistance or 80.0
                local distToCenter = zone.center
                    and #(coords - vector3(zone.center.x, zone.center.y, zone.center.z))
                    or 0.0

                -- Check cooldown per zone
                local lastSpawn = lastSpawnTime[zone.name] or 0
                if distToCenter <= triggerDist and GetGameTimer() - lastSpawn > Config.AmbientSpawning.respawnCooldown then

                    -- Determine heat level with full detection
                    local heatLevel = GetZoneHeatLevel(zone.name)

                    -- Time-of-day density multiplier (night = more gang activity)
                    local densityMult = GetTimeDensityMultiplier()

                    -- Request spawn from server (send zone name + center for server-side ownership verification)
                    TriggerServerEvent('gangai:server:requestAmbientSpawn', zone.name, zone.center, heatLevel, densityMult)
                    lastSpawnTime[zone.name] = GetGameTimer()

                    if Config.Debug then
                        print('[GangAI] Zone detected: ' .. zone.name .. ' owned by ' .. zone.owner .. ' (heat: ' .. heatLevel .. ', density x' .. densityMult .. ', time: ' .. GetTimeOfDay() .. ')')
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
-- Despawn distant NPCs and vehicles
-- ============================================

CreateThread(function()
    while true do
        Wait(Config.CleanupInterval or 60000)

        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local cleaned = 0
        local warCleaned = 0

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

        -- Same distance-based cleanup for the war-reinforcement pool
        for npcPed, npcData in pairs(spawnedWarNPCs) do
            if DoesEntityExist(npcPed) then
                local npcCoords = GetEntityCoords(npcPed)
                local dist = #(coords - npcCoords)

                if dist > Config.AmbientSpawning.despawnDistance and not IsPedInCombat(npcPed) then
                    DeleteEntity(npcPed)
                    spawnedWarNPCs[npcPed] = nil
                    warCleaned = warCleaned + 1
                end
            else
                spawnedWarNPCs[npcPed] = nil
                warCleaned = warCleaned + 1
            end
        end

        -- Cleanup distant vehicles
        for veh, vehData in pairs(spawnedVehicles) do
            if DoesEntityExist(veh) then
                local vehCoords = GetEntityCoords(veh)
                local dist = #(coords - vehCoords)

                if dist > Config.AmbientSpawning.despawnDistance and IsVehicleSeatFree(veh, -1) then
                    DeleteEntity(veh)
                    spawnedVehicles[veh] = nil
                end
            else
                spawnedVehicles[veh] = nil
            end
        end

        if cleaned > 0 then
            TriggerServerEvent('gangai:server:npcDespawned', cleaned)
        end
        if warCleaned > 0 then
            TriggerServerEvent('gangai:server:warNpcDespawned', warCleaned)
        end
        if Config.Debug and (cleaned > 0 or warCleaned > 0) then
            print('[GangAI] Cleaned up ' .. cleaned .. ' ambient + ' .. warCleaned .. ' war distant/dead NPCs')
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
