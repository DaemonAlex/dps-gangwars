-- ============================================
-- GANG BRIDGE - Standalone/Fallback Adapter
-- Uses Config.StandaloneTerritories when no gang script is detected.
-- Functions are registered into GangBridge.adapters.standalone so they never
-- collide with the rcore_gangs adapter; init.lua dispatches to the active one.
-- ============================================

if not GangBridge then return end

local adapter = GangBridge.adapters.standalone

-- ============================================
-- CLIENT-SIDE FUNCTIONS
-- ============================================

if not IsDuplicityVersion() then

    --- Get the zone at a given position by checking against standalone territories
    --- @param coords vector3
    --- @return table|nil  { name, label, center, owner }
    function adapter.GetZoneAtPosition(coords)
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
    function adapter.GetPlayerGangClient()
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
    function adapter.GetZoneOwner(zoneName, centerCoords)
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
    function adapter.GetPlayerGang(source)
        -- qbx_core is native (no GetCoreObject); call the discrete export directly.
        local Player = exports.qbx_core:GetPlayer(source)
        if not Player then return nil end

        local gangData = Player.PlayerData.gang
        if gangData and gangData.name and gangData.name ~= 'none' then
            return GangBridge.ResolveGangName(gangData.name)
        end

        return nil
    end

    -- Standalone has no war events — wars don't happen without a gang script

end
