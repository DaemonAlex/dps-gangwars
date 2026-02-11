-- ============================================
-- GANG BRIDGE - Standalone/Fallback Adapter
-- Uses Config.StandaloneTerritories when no gang script is detected
-- ============================================

if not GangBridge then return end

local function IsActive()
    return GangBridge._adapter == 'standalone'
end

-- ============================================
-- CLIENT-SIDE FUNCTIONS
-- ============================================

if not IsDuplicityVersion() then

    --- Get the zone at a given position by checking against standalone territories
    --- @param coords vector3
    --- @return table|nil  { name, label, center, owner }
    function GangBridge.GetZoneAtPosition(coords)
        if not IsActive() then return nil end

        if not Config.StandaloneTerritories then return nil end

        for _, territory in ipairs(Config.StandaloneTerritories) do
            local dist = #(coords - territory.center)
            if dist <= (territory.radius or 100.0) then
                return {
                    name = territory.name,
                    label = territory.label or territory.name,
                    center = territory.center,
                    owner = territory.owner,
                }
            end
        end

        return nil
    end

    --- Standalone has no client-side player gang detection
    --- @return nil
    function GangBridge.GetPlayerGangClient()
        if not IsActive() then return nil end
        return nil
    end

end

-- ============================================
-- SERVER-SIDE FUNCTIONS
-- ============================================

if IsDuplicityVersion() then

    --- Get the owner of a standalone zone by name
    --- @param zoneName string
    --- @param centerCoords vector3|nil  (unused for standalone)
    --- @return string|nil
    function GangBridge.GetZoneOwner(zoneName, centerCoords)
        if not IsActive() then return nil end

        if not Config.StandaloneTerritories then return nil end

        for _, territory in ipairs(Config.StandaloneTerritories) do
            if territory.name == zoneName then
                return territory.owner
            end
        end

        return nil
    end

    --- Get player's gang from QBCore gang data (fallback)
    --- @param source number
    --- @return string|nil
    function GangBridge.GetPlayerGang(source)
        if not IsActive() then return nil end

        local QBCore = exports['qb-core']:GetCoreObject()
        local Player = QBCore.Functions.GetPlayer(source)
        if not Player then return nil end

        local gangData = Player.PlayerData.gang
        if gangData and gangData.name and gangData.name ~= 'none' then
            return GangBridge.ResolveGangName(gangData.name)
        end

        return nil
    end

    -- Standalone has no war events — wars don't happen without a gang script

end
