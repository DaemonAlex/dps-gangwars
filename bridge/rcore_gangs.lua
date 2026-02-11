-- ============================================
-- GANG BRIDGE - rcore_gangs Adapter
-- Wraps rcore_gangs exports into the unified GangBridge API
-- ============================================

if not GangBridge then return end

local RESOURCE = 'rcore_gangs'

local function IsAvailable()
    return GangBridge._adapter == 'rcore_gangs' and GetResourceState(RESOURCE) == 'started'
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
    function GangBridge.GetZoneAtPosition(coords)
        if not IsAvailable() then return nil end

        local ok, zone = pcall(function()
            return exports[RESOURCE]:GetZoneAtPosition(coords)
        end)

        if not ok or not zone then return nil end

        -- rcore returns a zone table; extract what we need
        local zoneName = zone.name or zone.label or 'unknown'
        local center = ComputeZoneCenter(zone)

        -- Get owner gang
        local owner = nil
        local okOwner, gang = pcall(function()
            return exports[RESOURCE]:GetGangAtZone(zone)
        end)

        if okOwner and gang then
            -- rcore returns a gang table with a 'tag' field
            local rawTag = nil
            if type(gang) == 'table' then
                rawTag = gang.tag or gang.name or gang.label
            elseif type(gang) == 'string' then
                rawTag = gang
            end
            owner = GangBridge.ResolveGangName(rawTag)
        end

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
    function GangBridge.GetPlayerGangClient()
        if not IsAvailable() then return nil end

        local ok, result = pcall(function()
            return exports[RESOURCE]:GetPlayerGang()
        end)

        if ok and result then
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
    function GangBridge.GetZoneOwner(zoneName, centerCoords)
        if not IsAvailable() then return nil end

        -- If we have center coords, use GetZoneAtPosition to get the zone, then GetGangAtZone
        if centerCoords then
            local okZone, zone = pcall(function()
                return exports[RESOURCE]:GetZoneAtPosition(centerCoords)
            end)

            if okZone and zone then
                local okGang, gang = pcall(function()
                    return exports[RESOURCE]:GetGangAtZone(zone)
                end)

                if okGang and gang then
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
    function GangBridge.GetPlayerGang(source)
        if not IsAvailable() then return nil end

        local ok, result = pcall(function()
            return exports[RESOURCE]:GetPlayerGang(source)
        end)

        if ok and result then
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

    -- Register war event listeners for rcore_gangs
    -- rcore uses start_rivalry / finish_rivalry events
    RegisterNetEvent('rcore_gangs:server:start_rivalry', function(data)
        if not IsAvailable() then return end

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

    RegisterNetEvent('rcore_gangs:server:finish_rivalry', function(data)
        if not IsAvailable() then return end

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
