-- ============================================
-- GANG BRIDGE - Initialization
-- Auto-detects gang script and provides unified API
-- ============================================

GangBridge = {
    _adapter = nil,
    _warStartCallbacks = {},
    _warEndCallbacks = {},
    _activeWars = {},

    -- Each adapter registers its implementation into its own namespace so the
    -- two adapters never overwrite each other (they share one Lua state per
    -- context). The public GangBridge.* functions below dispatch to whichever
    -- adapter _adapter selects at runtime.
    adapters = {
        rcore_gangs = {},
        standalone = {},
    },
}

-- ============================================
-- PUBLIC API DISPATCH
-- Routes each call to the currently selected adapter's implementation.
-- Adapters only register the functions valid for their context
-- (client or server), so wrong-context calls simply resolve to nil.
-- ============================================

local function dispatch(fnName, ...)
    local adapterName = GangBridge._adapter
    if not adapterName then return nil end

    local adapter = GangBridge.adapters[adapterName]
    if not adapter then return nil end

    local fn = adapter[fnName]
    if not fn then return nil end

    return fn(...)
end

--- Get the zone at a given position (client). Returns { name, label, center, owner } or nil.
function GangBridge.GetZoneAtPosition(coords)
    return dispatch('GetZoneAtPosition', coords)
end

--- Get the local player's gang (client). Returns { tag, name } or nil.
function GangBridge.GetPlayerGangClient()
    return dispatch('GetPlayerGangClient')
end

--- Get the owner of a zone (server). Returns resolved gang name or nil.
function GangBridge.GetZoneOwner(zoneName, centerCoords)
    return dispatch('GetZoneOwner', zoneName, centerCoords)
end

--- Get a player's gang name (server). Returns resolved gang name or nil.
function GangBridge.GetPlayerGang(source)
    return dispatch('GetPlayerGang', source)
end

-- Register a callback for when a territory war starts
function GangBridge.OnWarStart(cb)
    GangBridge._warStartCallbacks[#GangBridge._warStartCallbacks + 1] = cb
end

-- Register a callback for when a territory war ends
function GangBridge.OnWarEnd(cb)
    GangBridge._warEndCallbacks[#GangBridge._warEndCallbacks + 1] = cb
end

-- Fire all war-start callbacks
function GangBridge._fireWarStart(zoneName, attacker, defender)
    GangBridge._activeWars[zoneName] = { attacker = attacker, defender = defender }
    for _, cb in ipairs(GangBridge._warStartCallbacks) do
        local ok, err = pcall(cb, zoneName, attacker, defender)
        if not ok then
            print('[GangAI] War start callback error: ' .. tostring(err))
        end
    end
end

-- Fire all war-end callbacks
function GangBridge._fireWarEnd(zoneName, winner)
    GangBridge._activeWars[zoneName] = nil
    for _, cb in ipairs(GangBridge._warEndCallbacks) do
        local ok, err = pcall(cb, zoneName, winner)
        if not ok then
            print('[GangAI] War end callback error: ' .. tostring(err))
        end
    end
end

-- Check if a zone is currently at war
function GangBridge.IsZoneAtWar(zoneName)
    return GangBridge._activeWars[zoneName] ~= nil
end

-- Resolve a gang tag/name to a Config.GangData key
function GangBridge.ResolveGangName(rawName)
    if not rawName then return nil end

    local lower = rawName:lower()
    -- Direct match
    if Config.GangData[lower] then
        return lower
    end

    -- Try tag map (uppercase lookup)
    local mapped = Config.GangTagMap and Config.GangTagMap[rawName:upper()]
    if mapped and Config.GangData[mapped] then
        return mapped
    end

    -- Try tag map with original casing
    mapped = Config.GangTagMap and Config.GangTagMap[rawName]
    if mapped and Config.GangData[mapped] then
        return mapped
    end

    return nil
end

-- Detect and set adapter
CreateThread(function()
    Wait(1000)

    local gangScript = Config.Integration.gangScript or 'auto'

    if gangScript == 'auto' then
        if GetResourceState('rcore_gangs') == 'started' then
            gangScript = 'rcore_gangs'
        else
            gangScript = 'standalone'
        end
    end

    GangBridge._adapter = gangScript
    print('[GangAI] Using gang script bridge: ' .. gangScript)
end)
