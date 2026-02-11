-- ============================================
-- GANG BRIDGE - Initialization
-- Auto-detects gang script and provides unified API
-- ============================================

GangBridge = {
    _adapter = nil,
    _warStartCallbacks = {},
    _warEndCallbacks = {},
    _activeWars = {},
}

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
