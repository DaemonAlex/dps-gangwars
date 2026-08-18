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
    -- qbx reports gangless players as the STRING 'none' - normalize to nil,
    -- otherwise every 'is the player a rival?' check treats civilians as rivals
    if gang == 'none' or gang == '' then gang = nil end
    playerGang = gang

    SetupGangRelationships()

    -- Players are civilians to the ambient AI. Do NOT put the ped into a gang
    -- relationship group: membership alone makes same-gang NPCs allies (companion)
    -- and rival NPCs hostile (hate) via the group<->group table, regardless of the
    -- PLAYER-hash relationships. Keep the ped in the vanilla PLAYER group and set
    -- PLAYER<->every-gang to neutral. Hostility must be EARNED (attack them and
    -- game perception reacts) - a future colors-in-rival-turf mechanic can add it.
    SetPedRelationshipGroupHash(PlayerPedId(), GetHashKey('PLAYER'))
    playerRelationshipHash = nil
    for _, hash in pairs(gangRelationshipGroups) do
        SetRelationshipBetweenGroups(Config.Relationships.defaultToPlayer, hash, GetHashKey('PLAYER'))
        SetRelationshipBetweenGroups(Config.Relationships.defaultToPlayer, GetHashKey('PLAYER'), hash)
    end
    if gang and Config.Debug then
        print('[GangAI] Player gang recorded (civilian to ambient AI): ' .. gang)
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

    -- snap to ground: there is no ped version of PlaceObjectOnGroundProperly,
    -- so resolve ground Z at the spawn point and place the ped on it
    do
        local found, groundZ = GetGroundZFor_3dCoord(spawnX, spawnY, spawnZ + 50.0, false)
        if found then
            SetEntityCoords(ped, spawnX, spawnY, groundZ, false, false, false, false)
        end
    end

    -- Set relationship group
    SetPedRelationshipGroupHash(ped, relationshipHash)

    -- Give weapon
    if gangData.weapons and #gangData.weapons > 0 then
        local weapon = gangData.weapons[math.random(#gangData.weapons)]
        GiveWeaponToPed(ped, GetHashKey(weapon), 255, false, true)
    end

    -- Apply combat AI
    ApplyCombatAI(ped, gangData)
    SetCanAttackFriendly(ped, false, false)  -- a gang does not shoot its own

    -- Assign behavior (patrol, wander, scenario) based on time of day
    local behavior = 'idle'
    if isWar then
        -- war reinforcements fight the enemy GANG, not whatever wanders past.
        -- BlockNonTemporaryEvents stops them re-targeting players/ambient events;
        -- the combat pump below hands them explicit enemy-gang targets.
        SetPedFleeAttributes(ped, 0, false)
        SetPedCombatAttributes(ped, 46, true)   -- BF_AlwaysFight
        SetPedCombatAttributes(ped, 26, true)   -- BF_ForceCheckAttackAngleForCharge
        SetBlockingOfNonTemporaryEvents(ped, true)
    elseif not inCombat then
        behavior = AssignBehavior(ped, gangData, coords)
    end

    -- NPCs cannot know a player's affiliation by looking at them. Hostility
    -- toward players must be EARNED (attack them and game perception reacts)
    -- or, later, triggered by visibly wearing gang colors in rival territory
    -- (planned mechanic). Never database-driven auto-enmity.

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
            -- targeting handled by the war combat pump (explicit enemy-gang peds only)
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

        -- Gate on zone PRESENCE, not client-known owner: under the rcore adapter
        -- the client can't resolve ownership (GetGangAtZone is server-only), so
        -- zone.owner is always nil there. The server resolves the owner
        -- authoritatively from the zone name in requestAmbientSpawn - the client
        -- only needs to be standing in a named zone near its center.
        if zone and zone.name then
            local triggerDist = Config.AmbientSpawning.playerTriggerDistance or 80.0
            local distToCenter = zone.center
                and #(coords - vector3(zone.center.x, zone.center.y, zone.center.z))
                or 0.0

            local lastSpawn = lastSpawnTime[zone.name] or 0
            if distToCenter <= triggerDist and GetGameTimer() - lastSpawn > Config.AmbientSpawning.respawnCooldown then
                local heatLevel = GetZoneHeatLevel(zone.name)
                local densityMult = GetTimeDensityMultiplier()
                TriggerServerEvent('gangai:server:requestAmbientSpawn', zone.name, zone.center, heatLevel, densityMult)
                lastSpawnTime[zone.name] = GetGameTimer()
                if Config.Debug then
                    print('[GangAI] Zone detected: ' .. zone.name .. ' (owner resolved server-side, heat: ' .. heatLevel .. ', density x' .. densityMult .. ')')
                end
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


-- ============================================
-- AMBIENT GUNFIGHT WITNESS REPORTS (DPS)
-- Gang wars are rare, admin-triggered events; when this resource's own NPCs
-- start shooting at each other (no player involved), civilians call it in.
-- Each client reports at most once per 60s; the server dedupes across clients.
-- ============================================
local lastGunfightReport = 0
CreateThread(function()
    while true do
        Wait(3000)
        if GetGameTimer() - lastGunfightReport > 60000 then
            -- gather every shooting NPC across all three pools (one loop, no dup)
            local shots = {}
            for _, pool in ipairs({ spawnedNPCs, spawnedWarNPCs, VibePeds }) do
                if pool then
                    for entity in pairs(pool) do
                        if DoesEntityExist(entity) and IsPedShooting(entity) then
                            shots[#shots + 1] = GetEntityCoords(entity)
                        end
                    end
                end
            end
            -- Report ONE local cluster, not a map-wide centroid: seed on the shot
            -- nearest the player and average only shots within 100m of it, so two
            -- simultaneous fights in different districts can't produce a phantom
            -- dispatch at their empty midpoint.
            if #shots >= 2 then
                local pc = GetEntityCoords(PlayerPedId())
                local seed, seedDist = shots[1], #(shots[1] - pc)
                for i = 2, #shots do
                    local d = #(shots[i] - pc)
                    if d < seedDist then seed, seedDist = shots[i], d end
                end
                local n, cx, cy, cz = 0, 0.0, 0.0, 0.0
                for _, s in ipairs(shots) do
                    if #(s - seed) < 100.0 then
                        n, cx, cy, cz = n + 1, cx + s.x, cy + s.y, cz + s.z
                    end
                end
                if n >= 2 then
                    lastGunfightReport = GetGameTimer()
                    TriggerServerEvent('gangai:server:reportGunfight',
                        { x = cx / n, y = cy / n, z = cz / n }, n)
                end
            end
        end
    end
end)


-- ============================================
-- WAR COMBAT PUMP (DPS)
-- Every few seconds, hand every war NPC an explicit target: the nearest living
-- war NPC of the OTHER gang. Players are never valid targets - this is an
-- ambient war between gangs, and bystanders stay bystanders unless they shoot
-- first (at which point normal game perception rules apply, not our tasking).
-- ============================================
CreateThread(function()
    while true do
        Wait(3000)
        -- bucket living war NPCs by gang
        local byGang = {}
        for entity, data in pairs(spawnedWarNPCs) do
            if DoesEntityExist(entity) and not IsPedDeadOrDying(entity, true) then
                local g = data.gangName or 'unknown'
                byGang[g] = byGang[g] or {}
                byGang[g][#byGang[g] + 1] = entity
            end
        end
        local gangs = {}
        for g in pairs(byGang) do gangs[#gangs + 1] = g end
        if #gangs >= 2 then
            -- cache each living war ped's coords once (was recomputed per pair -> O(n^2) natives)
            local pos = {}
            for _, list in pairs(byGang) do
                for _, e in ipairs(list) do pos[e] = GetEntityCoords(e) end
            end
            for _, g in ipairs(gangs) do
                -- enemies: every war NPC not of my gang
                local enemies = {}
                for _, g2 in ipairs(gangs) do
                    if g2 ~= g then
                        for _, e in ipairs(byGang[g2]) do enemies[#enemies + 1] = e end
                    end
                end
                for _, ped in ipairs(byGang[g]) do
                    if not IsPedInCombat(ped, 0) then
                        local myPos, best, bestDist = pos[ped], nil, 1e9
                        for _, e in ipairs(enemies) do
                            local d = #(pos[e] - myPos)
                            if d < bestDist then best, bestDist = e, d end
                        end
                        if best then
                            ClearPedTasks(ped)
                            TaskCombatPed(ped, best, 0, 16)
                        end
                    end
                end
            end
        end
    end
end)


-- ============================================
-- STREET VIBE LAYER (DPS)
-- Corner crews hold their territory in their colors; rivals occasionally roll
-- through. Most encounters are theater (taunt stand-offs), some are drive-bys,
-- few are real skirmishes. Players are civilians throughout.
-- ============================================
VibePeds = {}                      -- global: gunfight witness detector reads it
local vibeCrews = {}               -- [territoryName] = { peds = {}, spots = {} }
local vibeCooldown = {}            -- [territoryName] = next-allowed event time
local vibeEventActive = false

local VIBE = {
    crewSpots = 2,                 -- hangout spots per territory
    crewSize = { 3, 5 },           -- peds per spot (min, max)
    presenceRange = 220.0,         -- player distance that keeps a territory alive
    eventRange = 130.0,            -- player must be this close for events to fire
    eventChance = 22,              -- % roll per minute-per-territory when in range
    cooldown = { 240000, 480000 }, -- 4-8 min between events per territory
    weights = { taunt = 50, driveby = 30, skirmish = 20 },
    armedShare = 0.6,              -- share of crew carrying (concealed until provoked)
}

local TAUNTS = { 'GENERIC_INSULT_HIGH', 'GENERIC_CURSE_HIGH', 'CHALLENGE_THREATEN', 'PROVOKE_GENERIC', 'GENERIC_WHATEVER' }

local function vibeLoadModel(hash)
    if not IsModelValid(hash) then return false end
    RequestModel(hash)
    for _ = 1, 60 do
        if HasModelLoaded(hash) then return true end
        Wait(25)
    end
    return false
end

local function groundAt(x, y, zHint)
    local found, z = GetGroundZFor_3dCoord(x, y, zHint + 50.0, false)
    return found and z or zHint
end

local function spawnVibePed(gangName, gangData, x, y, z, heading)
    local model = gangData.models[math.random(#gangData.models)]
    local hash = GetHashKey(model)
    if not vibeLoadModel(hash) then return nil end
    local ped = CreatePed(4, hash, x, y, z, heading or math.random(0, 359) + 0.0, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not DoesEntityExist(ped) then return nil end
    SetEntityCoords(ped, x, y, groundAt(x, y, z), false, false, false, false)
    SetPedRelationshipGroupHash(ped, GetOrCreateGangRelationship(gangName))
    SetPedDropsWeaponsWhenDead(ped, false)
    if math.random() < VIBE.armedShare and gangData.weapons then
        GiveWeaponToPed(ped, GetHashKey(gangData.weapons[math.random(#gangData.weapons)]), 120, false, false)
    end
    ApplyCombatAI(ped, gangData)
    -- corner crews are defensive: no AlwaysFight, so they never initiate on
    -- police (or anyone) unless attacked first - then normal retaliation applies
    SetPedCombatAttributes(ped, 46, false)
    SetCanAttackFriendly(ped, false, false)  -- never target own gang, even after stray hits
    VibePeds[ped] = { gang = gangName }
    return ped
end

local function despawnVibePed(ped)
    VibePeds[ped] = nil
    if DoesEntityExist(ped) then DeleteEntity(ped) end
end

-- corner crew: cluster of peds around a spot doing corner things
local function spawnCrew(territory)
    local crew = { peds = {}, spots = {} }
    if territory.style == 'stroll' then
        -- boardwalk mode: 3 small groups, random gang each, just walking around
        local gangNames = {}
        for g in pairs(Config.GangData) do gangNames[#gangNames + 1] = g end
        for grp = 1, 3 do
            local gName = gangNames[math.random(#gangNames)]
            local gd = Config.GangData[gName]
            local ang = math.random() * 6.28318
            local gx = territory.center.x + math.cos(ang) * territory.radius * 0.6
            local gy = territory.center.y + math.sin(ang) * territory.radius * 0.6
            local okS, safe = GetSafeCoordForPed(gx, gy, territory.center.z, true, 16)
            local px, py, pz
            if okS then px, py, pz = safe.x, safe.y, safe.z else px, py, pz = gx, gy, groundAt(gx, gy, territory.center.z) end
            for i = 1, math.random(2, 3) do
                local ped = spawnVibePed(gName, gd, px + math.random(-3, 3), py + math.random(-3, 3), pz)
                if ped then
                    crew.peds[#crew.peds + 1] = ped
                    TaskWanderInArea(ped, territory.center.x, territory.center.y, territory.center.z, territory.radius * 0.8, 4.0, 8.0)
                    Wait(50)
                end
            end
        end
        return #crew.peds > 0 and crew or nil
    end
    local gangData = Config.GangData[territory.owner]
    if not gangData then return nil end
    for s = 1, VIBE.crewSpots do
        local ang = (s / VIBE.crewSpots) * 6.28318 + math.random() * 0.8
        local dist = 25.0 + math.random() * (territory.radius * 0.45)
        local sx = territory.center.x + math.cos(ang) * dist
        local sy = territory.center.y + math.sin(ang) * dist
        local ok, safe = GetSafeCoordForPed(sx, sy, territory.center.z, true, 16)
        local px, py, pz
        if ok then px, py, pz = safe.x, safe.y, safe.z else px, py, pz = sx, sy, groundAt(sx, sy, territory.center.z) end
        crew.spots[s] = vector3(px, py, pz)
        local n = math.random(VIBE.crewSize[1], VIBE.crewSize[2])
        for i = 1, n do
            local ox, oy = px + math.random(-4, 4) + math.random(), py + math.random(-4, 4) + math.random()
            local ped = spawnVibePed(territory.owner, gangData, ox, oy, pz)
            if ped then
                crew.peds[#crew.peds + 1] = ped
                if i == 1 or math.random() < 0.7 then
                    local scen = gangData.scenarios and gangData.scenarios[math.random(#gangData.scenarios)]
                    if scen then TaskStartScenarioInPlace(ped, scen, 0, true) end
                else
                    TaskWanderInArea(ped, px, py, pz, 15.0, 2.0, 4.0)
                end
                Wait(50)
            end
        end
    end
    return #crew.peds > 0 and crew or nil
end

local function despawnCrew(territory)
    local crew = vibeCrews[territory.name]
    if not crew then return end
    if type(crew) == 'table' and crew.peds then
        for _, ped in ipairs(crew.peds) do despawnVibePed(ped) end
    end
    vibeCrews[territory.name] = nil
end

local function livingCrew(crew)
    local out = {}
    for _, p in ipairs(crew.peds) do
        if DoesEntityExist(p) and not IsPedDeadOrDying(p, true) then out[#out + 1] = p end
    end
    return out
end

local function pickRivalGang(owner)
    local names = {}
    for g in pairs(Config.GangData) do if g ~= owner then names[#names + 1] = g end end
    return names[math.random(#names)]
end

-- EVENT: rivals walk up, both sides yell, nobody swings. Tension theater.
local function eventTaunt(territory, crew)
    if not crew.spots or #crew.spots == 0 then return end
    if #livingCrew(crew) == 0 then return end
    local rivalGang = pickRivalGang(territory.owner)
    local rd = Config.GangData[rivalGang]
    if not rd then return end
    local spot = crew.spots[math.random(#crew.spots)]
    local rivals = {}
    for i = 1, math.random(2, 3) do
        local ped = spawnVibePed(rivalGang, rd, spot.x + 25 + math.random(0, 6), spot.y + math.random(-6, 6), spot.z)
        if ped then rivals[#rivals + 1] = ped; SetBlockingOfNonTemporaryEvents(ped, true) end
    end
    if #rivals == 0 then return end
    local defenders = livingCrew(crew)
    for _, r in ipairs(rivals) do TaskGoStraightToCoord(r, spot.x + 10.0, spot.y, spot.z, 1.0, 10000, 0.0, 0.5) end
    Wait(8000)
    for round = 1, 5 do
        local a = rivals[math.random(#rivals)]
        local b = defenders[math.random(#defenders)]
        if a and b and DoesEntityExist(a) and DoesEntityExist(b) then
            TaskTurnPedToFaceEntity(a, b, 1500); TaskTurnPedToFaceEntity(b, a, 1500)
            PlayAmbientSpeechNative(a, TAUNTS[math.random(#TAUNTS)], 'SPEECH_PARAMS_FORCE_SHOUTED')
            Wait(1800)
            PlayAmbientSpeechNative(b, TAUNTS[math.random(#TAUNTS)], 'SPEECH_PARAMS_FORCE_SHOUTED')
            Wait(1800)
        end
    end
    Wait(2000)
    -- sometimes the talking stops working - and dark corners embolden people
    local escalateChance = (GetTimeOfDay() == 'night') and 35 or 25
    if math.random(100) <= escalateChance then
        if Config.Debug then print('[GangAI] taunt stand-off escalated to a shootout') end
        for _, r in ipairs(rivals) do
            if DoesEntityExist(r) and not IsPedDeadOrDying(r, true) then
                GiveWeaponToPed(r, GetHashKey(rd.weapons and rd.weapons[1] or 'WEAPON_PISTOL'), 60, false, true)
                local tgt = defenders[math.random(#defenders)]
                if tgt and DoesEntityExist(tgt) then TaskCombatPed(r, tgt, 0, 16) end
            end
        end
        for _, d in ipairs(livingCrew(crew)) do
            Wait(math.random(300, 800))  -- reaction time
            local tgt
            for _, r in ipairs(rivals) do
                if DoesEntityExist(r) and not IsPedDeadOrDying(r, true) then tgt = r break end
            end
            if tgt and DoesEntityExist(d) then ClearPedTasks(d) TaskCombatPed(d, tgt, 0, 16) end
        end
        Wait(math.random(15000, 25000))
    end
    for _, r in ipairs(rivals) do
        if DoesEntityExist(r) and not IsPedDeadOrDying(r, true) then
            ClearPedTasks(r)
            TaskSmartFleeCoord(r, spot.x, spot.y, spot.z, 120.0, 20000, false, false)
        end
    end
    Wait(15000)
    for _, r in ipairs(rivals) do despawnVibePed(r) end
    -- survivors go back to holding their corner
    local od = Config.GangData[territory.owner]
    for _, d in ipairs(livingCrew(crew)) do
        ClearPedTasks(d)
        local scen = od and od.scenarios
        if scen then TaskStartScenarioInPlace(d, scen[math.random(#scen)], 0, true) end
    end
end

-- EVENT: rival car sprays the corner and keeps rolling
local function eventDriveBy(territory, crew)
    if not crew.spots or #crew.spots == 0 then return end
    if #livingCrew(crew) == 0 then return end
    local rivalGang = pickRivalGang(territory.owner)
    local rd = Config.GangData[rivalGang]
    if not rd then return end
    local spot = crew.spots[math.random(#crew.spots)]
    local carModel = rd.vehicles and rd.vehicles[math.random(#rd.vehicles)] or 'buccaneer'
    local carHash = GetHashKey(carModel)
    if not vibeLoadModel(carHash) then return end
    -- approach from a road node ~140m out, exit through the opposite side
    local ang = math.random() * 6.28318
    local fromX, fromY = spot.x + math.cos(ang) * 140.0, spot.y + math.sin(ang) * 140.0
    local okN, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(fromX, fromY, spot.z, 1, 3.0, 0)
    if not okN then SetModelAsNoLongerNeeded(carHash) return end
    local car = CreateVehicle(carHash, nodePos.x, nodePos.y, nodePos.z, nodeHeading, false, true)
    SetModelAsNoLongerNeeded(carHash)
    if not DoesEntityExist(car) then return end
    SetVehicleDoorsLocked(car, 2)
    local crewPeds = { }
    for seat = -1, 1 do
        local ped = spawnVibePed(rivalGang, rd, nodePos.x, nodePos.y, nodePos.z)
        if ped then
            SetPedIntoVehicle(ped, car, seat)
            SetBlockingOfNonTemporaryEvents(ped, true)
            if seat >= 0 then GiveWeaponToPed(ped, GetHashKey('WEAPON_MICROSMG'), 200, false, true) end
            crewPeds[#crewPeds + 1] = ped
        end
    end
    if #crewPeds == 0 then DeleteEntity(car) return end
    local exitX, exitY = spot.x - math.cos(ang) * 200.0, spot.y - math.sin(ang) * 200.0
    TaskVehicleDriveToCoordLongrange(crewPeds[1], car, exitX, exitY, spot.z, 22.0, 787004, 15.0)
    local targets = livingCrew(crew)
    CreateThread(function()
        local fired = false
        for _ = 1, 120 do  -- up to 60s
            Wait(500)
            if not DoesEntityExist(car) then break end
            local d = #(GetEntityCoords(car) - spot)
            if d < 55.0 and not fired then
                fired = true
                for i = 2, #crewPeds do
                    local tgt = (#targets > 0) and targets[math.random(#targets)] or nil
                    if tgt and DoesEntityExist(tgt) then
                        TaskDriveBy(crewPeds[i], tgt, 0, 0.0, 0.0, 0.0, 80.0, 60, true, 'FIRING_PATTERN_BURST_FIRE_DRIVEBY')
                    end
                end
            end
            if fired and d > 160.0 then break end
        end
        Wait(4000)
        for _, p in ipairs(crewPeds) do despawnVibePed(p) end
        if DoesEntityExist(car) then DeleteEntity(car) end
    end)
end

-- EVENT: it actually pops off on foot - brief, then survivors break contact
local function eventSkirmish(territory, crew)
    if not crew.spots or #crew.spots == 0 then return end
    if #livingCrew(crew) == 0 then return end
    local rivalGang = pickRivalGang(territory.owner)
    local rd = Config.GangData[rivalGang]
    if not rd then return end
    local spot = crew.spots[math.random(#crew.spots)]
    local rivals = {}
    for i = 1, math.random(2, 3) do
        local ped = spawnVibePed(rivalGang, rd, spot.x + 35 + math.random(0, 8), spot.y + math.random(-8, 8), spot.z)
        if ped then
            rivals[#rivals + 1] = ped
            SetBlockingOfNonTemporaryEvents(ped, true)
            GiveWeaponToPed(ped, GetHashKey(rd.weapons and rd.weapons[1] or 'WEAPON_PISTOL'), 60, false, true)
        end
    end
    if #rivals == 0 then return end
    local defenders = livingCrew(crew)
    for i, r in ipairs(rivals) do
        local tgt = defenders[((i - 1) % #defenders) + 1]
        if tgt then TaskCombatPed(r, tgt, 0, 16) end
    end
    for _, d in ipairs(defenders) do
        Wait(math.random(300, 900))  -- reaction time
        local tgt = rivals[math.random(#rivals)]
        if DoesEntityExist(d) and tgt and DoesEntityExist(tgt) then
            ClearPedTasks(d); TaskCombatPed(d, tgt, 0, 16)
        end
    end
    Wait(math.random(20000, 35000))
    for _, r in ipairs(rivals) do
        if DoesEntityExist(r) and not IsPedDeadOrDying(r, true) then
            ClearPedTasks(r)
            TaskSmartFleeCoord(r, spot.x, spot.y, spot.z, 150.0, 25000, false, false)
        end
    end
    Wait(20000)
    for _, r in ipairs(rivals) do despawnVibePed(r) end
    -- crew that survived goes back to holding the corner
    local od = Config.GangData[territory.owner]
    for _, d in ipairs(livingCrew(crew)) do
        ClearPedTasks(d)
        local scen = od and od.scenarios
        if scen then TaskStartScenarioInPlace(d, scen[math.random(#scen)], 0, true) end
    end
end

local function runVibeEvent(territory, crew, forced)
    if vibeEventActive then return end
    vibeEventActive = true
    local roll, kind = math.random(100), 'taunt'
    if forced then kind = forced
    elseif roll <= VIBE.weights.skirmish then kind = 'skirmish'
    elseif roll <= VIBE.weights.skirmish + VIBE.weights.driveby then kind = 'driveby' end
    if Config.Debug then print('[GangAI] vibe event: ' .. kind .. ' at ' .. territory.name) end
    local ok, err = pcall(function()
        if kind == 'driveby' then eventDriveBy(territory, crew)
        elseif kind == 'skirmish' then eventSkirmish(territory, crew)
        else eventTaunt(territory, crew) end
    end)
    if not ok and Config.Debug then print('[GangAI] vibe event error: ' .. tostring(err)) end
    vibeEventActive = false
end

-- main vibe loop: keep crews alive near the player, roll for events
CreateThread(function()
    Wait(8000)
    while true do
        Wait(5000)
        if Config.StandaloneTerritories then
            local pc = GetEntityCoords(PlayerPedId())
            for _, territory in ipairs(Config.StandaloneTerritories) do
                local dist = #(pc - territory.center)
                if dist < VIBE.presenceRange and not vibeCrews[territory.name] then
                    if Config.Debug then print('[GangAI] spawning corner crews: ' .. territory.name) end
                    vibeCrews[territory.name] = true  -- sentinel: reserve so the loop doesn't re-enter while the crew builds
                    local terr = territory
                    CreateThread(function()
                        local built = spawnCrew(terr)
                        vibeCrews[terr.name] = built or nil
                    end)
                elseif dist > VIBE.presenceRange + 80.0 and vibeCrews[territory.name] then
                    despawnCrew(territory)
                end
                local crew = vibeCrews[territory.name]
                if type(crew) == 'table' and dist < VIBE.eventRange and territory.style ~= 'stroll' then
                    local nextAt = vibeCooldown[territory.name] or 0
                    if GetGameTimer() > nextAt and (math.random() * 100) < (VIBE.eventChance / 12) then
                        vibeCooldown[territory.name] = GetGameTimer() + math.random(VIBE.cooldown[1], VIBE.cooldown[2])
                        CreateThread(function() runVibeEvent(territory, crew) end)
                    end
                end
            end
        end
    end
end)

-- admin demo trigger: gangvibe [taunt|driveby|skirmish]
RegisterNetEvent('gangai:client:forceVibe', function(kind)
    local pc = GetEntityCoords(PlayerPedId())
    local best, bestD = nil, 1e9
    for _, territory in ipairs(Config.StandaloneTerritories or {}) do
        local d = #(pc - territory.center)
        if d < bestD then best, bestD = territory, d end
    end
    if not best then return end
    if type(vibeCrews[best.name]) ~= 'table' then vibeCrews[best.name] = spawnCrew(best) end
    local crew = vibeCrews[best.name]
    if type(crew) == 'table' then CreateThread(function() runVibeEvent(best, crew, kind) end) end
end)


-- ============================================
-- COP TAUNTS (DPS)
-- Corner crews talk shit to police who roll past - face them, bark a line,
-- and that is ALL. Hostility toward cops only ever comes from being attacked
-- (handled by normal game retaliation, never by tasking here).
-- ============================================
local COP_GROUP = GetHashKey('COP')
local COP_LINES = { 'GENERIC_INSULT_MED', 'GENERIC_CURSE_MED', 'GENERIC_WHATEVER', 'PROVOKE_GENERIC', 'GENERIC_DEJECTED' }

CreateThread(function()
    while true do
        Wait(8000)  -- taunts have a 25-60s per-ped cooldown; 8s resolution is plenty
        if next(VibePeds) then
            -- test the COP group FIRST (cops are ~0% of the pool) so we skip the
            -- other two natives on the overwhelming non-cop majority
            local cops = {}
            for _, ped in ipairs(GetGamePool('CPed')) do
                if GetPedRelationshipGroupHash(ped) == COP_GROUP
                    and not IsPedAPlayer(ped) and not IsPedDeadOrDying(ped, true) then
                    cops[#cops + 1] = ped
                end
            end
            if #cops > 0 then
                local now = GetGameTimer()
                -- cooldown lives IN the per-ped record, so it's freed with the ped
                -- (the old handle-keyed table leaked and mis-fired on recycled handles)
                for ped, rec in pairs(VibePeds) do
                    if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true)
                        and not IsPedInCombat(ped, 0)
                        and now > (rec.nextTaunt or 0) then
                        local myPos = GetEntityCoords(ped)
                        for _, cop in ipairs(cops) do
                            if #(GetEntityCoords(cop) - myPos) < 16.0 and math.random(100) <= 40 then
                                rec.nextTaunt = now + math.random(25000, 60000)
                                TaskTurnPedToFaceEntity(ped, cop, 2000)
                                PlayAmbientSpeechNative(ped, COP_LINES[math.random(#COP_LINES)], 'SPEECH_PARAMS_FORCE_SHOUTED')
                                break
                            end
                        end
                    end
                end
            end
        end
    end
end)
