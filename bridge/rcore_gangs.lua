-- ============================================
-- GANG BRIDGE - rcore_gangs Adapter
-- Wraps rcore_gangs exports into the unified GangBridge API.
-- Functions are registered into GangBridge.adapters.rcore_gangs so they never
-- collide with the standalone adapter; init.lua dispatches to the active one.
-- ============================================

if not GangBridge then return end

local RESOURCE = 'rcore_gangs'
local adapter = GangBridge.adapters.rcore_gangs

local function IsRunning()
    return GetResourceState(RESOURCE) == 'started'
end

-- ============================================
-- ONE-TIME EXPORT FAILURE LOGGING
-- rcore export/event names are assumptions (rcore is escrowed). Surface a wrong
-- name once per distinct export so it doesn't fail silently forever. Logged
-- regardless of Config.Debug because a wrong name breaks the whole adapter.
-- ============================================

local loggedExportErrors = {}
local function LogExportError(exportName, err)
    if loggedExportErrors[exportName] then return end
    loggedExportErrors[exportName] = true
    print(('^1[GangAI] rcore_gangs export "%s" failed - verify the export name against your rcore_gangs version: %s^0')
        :format(exportName, tostring(err)))
end

-- ============================================
-- CLIENT-SIDE FUNCTIONS
-- ============================================

if not IsDuplicityVersion() then

    -- Compute center from a zone's parts array
    local function ComputeZoneCenter(zone)
        if zone.center then return zone.center end

        if zone.parts and #zone.parts > 0 then
            local sumX, sumY, sumZ = 0, 0, 0
            local count = 0
            for _, part in ipairs(zone.parts) do
                if part.points then
                    for _, point in ipairs(part.points) do
                        sumX = sumX + (point.x or 0)
                        sumY = sumY + (point.y or 0)
                        sumZ = sumZ + (point.z or 0)
                        count = count + 1
                    end
                end
            end
            if count > 0 then
                return vector3(sumX / count, sumY / count, sumZ / count)
            end
        end

        return nil
    end

    --- Get the zone at a given position
    --- @param coords vector3
    --- @return table|nil  { name, label, center, owner }
    function adapter.GetZoneAtPosition(coords)
        if not IsRunning() then return nil end

        local ok, zone = pcall(function()
            return exports[RESOURCE]:GetZoneAtPosition(coords)
        end)

        if not ok then
            LogExportError('GetZoneAtPosition', zone)
            return nil
        end
        if not zone then return nil end

        -- rcore returns a zone table; extract what we need
        local zoneName = zone.name or zone.label or 'unknown'
        local center = ComputeZoneCenter(zone)

        -- Owner is intentionally nil on the client: rcore's GetGangAtZone is
        -- server-only (behind `if IsDuplicityVersion()` in rcore's exports) and
        -- this function runs client-side. Ownership is resolved authoritatively
        -- server-side in gangai:server:requestAmbientSpawn from the zone name,
        -- so the client never needs it here. (This block previously sat inside a
        -- client-only guard and was statically dead, silently nil-ing owner.)
        local owner = nil

        return {
            name = zoneName,
            label = zone.label or zoneName,
            center = center or coords,
            owner = owner,
            _raw = zone, -- keep raw data for server-side lookups
        }
    end

    --- Get the local player's gang (client-side)
    --- @return table|nil  { tag, name }
    function adapter.GetPlayerGangClient()
        if not IsRunning() then return nil end

        local ok, result = pcall(function()
            return exports[RESOURCE]:GetPlayerGang()
        end)

        if not ok then
            LogExportError('GetPlayerGang', result)
            return nil
        end

        if result then
            if type(result) == 'table' then
                return result
            elseif type(result) == 'string' then
                return { tag = result, name = result }
            end
        end

        return nil
    end

end

-- ============================================
-- SERVER-SIDE FUNCTIONS
-- ============================================

if IsDuplicityVersion() then

    --- Get the owner of a zone by name/center coords
    --- @param zoneName string
    --- @param centerCoords vector3|nil  optional center coords for lookup
    --- @return string|nil  resolved gang name (lowercase, matching Config.GangData key)
    function adapter.GetZoneOwner(zoneName, centerCoords)
        if not IsRunning() then return nil end

        -- If we have center coords, use GetZoneAtPosition to get the zone, then GetGangAtZone
        if centerCoords then
            local okZone, zone = pcall(function()
                return exports[RESOURCE]:GetZoneAtPosition(centerCoords)
            end)

            if not okZone then
                LogExportError('GetZoneAtPosition', zone)
            elseif zone then
                local okGang, gang = pcall(function()
                    return exports[RESOURCE]:GetGangAtZone(zone)
                end)

                if not okGang then
                    LogExportError('GetGangAtZone', gang)
                elseif gang then
                    local rawTag = nil
                    if type(gang) == 'table' then
                        rawTag = gang.tag or gang.name or gang.label
                    elseif type(gang) == 'string' then
                        rawTag = gang
                    end
                    return GangBridge.ResolveGangName(rawTag)
                end
            end
        end

        return nil
    end

    --- Get a player's gang name (server-side)
    --- @param source number  player server ID
    --- @return string|nil  resolved gang name (lowercase)
    function adapter.GetPlayerGang(source)
        if not IsRunning() then return nil end

        local ok, result = pcall(function()
            return exports[RESOURCE]:GetPlayerGang(source)
        end)

        if not ok then
            LogExportError('GetPlayerGang', result)
            return nil
        end

        if result then
            local rawTag = nil
            if type(result) == 'table' then
                rawTag = result.tag or result.name or result.label
            elseif type(result) == 'string' then
                rawTag = result
            end
            return GangBridge.ResolveGangName(rawTag)
        end

        return nil
    end

    -- Register war event listeners for rcore_gangs.
    -- rcore fires start_rivalry / finish_rivalry server-side, so these are
    -- AddEventHandler (NOT RegisterNetEvent) — a networked handler would let any
    -- modified client trigger server-wide war reinforcement waves.
    -- NOTE: if a future rcore version fires these client->server via
    -- TriggerServerEvent, convert back to RegisterNetEvent AND validate source.
    AddEventHandler('rcore_gangs:server:start_rivalry', function(data)
        if GangBridge._adapter ~= 'rcore_gangs' then return end

        local zoneName = 'unknown'
        local attacker = nil
        local defender = nil

        if type(data) == 'table' then
            zoneName = data.zone_name or data.zoneName or data.zone or 'unknown'
            local rawAttacker = data.attacker_tag or data.attacker or data.attacking_gang
            local rawDefender = data.defender_tag or data.defender or data.defending_gang
            attacker = GangBridge.ResolveGangName(rawAttacker)
            defender = GangBridge.ResolveGangName(rawDefender)
        end

        if Config.Debug then
            print('[GangAI] rcore rivalry started: ' .. tostring(attacker) .. ' vs ' .. tostring(defender) .. ' at ' .. zoneName)
        end

        GangBridge._fireWarStart(zoneName, attacker, defender)
    end)

    AddEventHandler('rcore_gangs:server:finish_rivalry', function(data)
        if GangBridge._adapter ~= 'rcore_gangs' then return end

        local zoneName = 'unknown'
        local winner = nil

        if type(data) == 'table' then
            zoneName = data.zone_name or data.zoneName or data.zone or 'unknown'
            local rawWinner = data.winner_tag or data.winner or data.winning_gang
            winner = GangBridge.ResolveGangName(rawWinner)
        end

        if Config.Debug then
            print('[GangAI] rcore rivalry ended at ' .. zoneName .. '. Winner: ' .. tostring(winner))
        end

        GangBridge._fireWarEnd(zoneName, winner)
    end)

end
