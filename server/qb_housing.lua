-- Read-only bridge for the stock qb-houses garage schema.
-- Housing remains authoritative: this file never handles client payloads and never
-- writes to houselocations or player_houses.

if not Framework or Framework.name ~= 'qb-core' then return end

local integrations = Config.Integrations or {}
local housingConfig = integrations.QbHousing or {}

if housingConfig.Enabled == false then return end

local currentResource = GetCurrentResourceName()
local housingResource = type(housingConfig.Resource) == 'string' and housingConfig.Resource:match('^%s*(.-)%s*$') or ''
local syncInterval = tonumber(housingConfig.SyncInterval or housingConfig.PollInterval or housingConfig.PollIntervalMs) or 60000

if housingResource == '' then housingResource = 'qb-houses' end
syncInterval = math.max(math.floor(syncInterval), 1000)

local apartmentsConfig = integrations.QbApartments or {}
local apartmentsEnabled = apartmentsConfig.Enabled ~= false
local apartmentsResource = type(apartmentsConfig.Resource) == 'string' and apartmentsConfig.Resource:match('^%s*(.-)%s*$') or ''

if apartmentsResource == '' then apartmentsResource = 'qb-apartments' end

local importedGarages = {}
local limitedNotices = {}
local apartmentsLogged = false
local syncRunning = false
local syncPending = false
local pendingReason = 'startup'
local housingEpoch = 0
local databaseGateResolved = false
local databaseGateSucceeded = true
local PROPERTY_GARAGE_ID_MAX_LENGTH = 50
local PROPERTY_GARAGE_ID_PREFIX = 'property_qbhouse_'

local HOUSE_QUERY = [[
    SELECT
        h.name AS house_name,
        h.label AS house_label,
        h.garage AS garage_data,
        p.id AS ownership_id,
        p.citizenid AS owner_citizenid,
        p.keyholders AS keyholders_data
    FROM `houselocations` AS h
    INNER JOIN `player_houses` AS p ON p.house = h.name
    WHERE h.owned = 1
      AND p.citizenid IS NOT NULL
      AND p.citizenid <> ''
    ORDER BY h.name ASC, p.id ASC
]]

local function log(message)
    print(('[%s:qb-housing] %s'):format(currentResource, message))
end

local function logLimited(key, message, seconds)
    local now = os.time()
    local previous = limitedNotices[key]

    if not previous or previous.message ~= message or now - previous.time >= (seconds or 300) then
        limitedNotices[key] = { message = message, time = now }
        log(message)
    end
end

local function trimmedString(value, maximumLength)
    if type(value) ~= 'string' then return end

    value = value:match('^%s*(.-)%s*$')

    if value == '' or (maximumLength and #value > maximumLength) then return end

    return value
end

local function finiteNumber(value)
    value = tonumber(value)

    if not value or value ~= value or value == math.huge or value == -math.huge then return end

    return value
end

local function decodeJsonTable(value)
    if type(value) == 'table' then return value end
    if type(value) ~= 'string' then return end

    local encoded = value:match('^%s*(.-)%s*$')

    if encoded == '' or encoded == 'null' then return end

    local ok, decoded = pcall(json.decode, encoded)

    if ok and type(decoded) == 'table' then return decoded end
end

local function decodeGarageCoords(value)
    local decoded = decodeJsonTable(value)
    if not decoded then return end

    -- A few stock-derived installs wrap the same stock coordinate. Supporting
    -- those wrappers does not make them authoritative; the database row still is.
    if type(decoded.takeVehicle) == 'table' then
        decoded = decoded.takeVehicle
    elseif type(decoded.coords) == 'table' then
        decoded = decoded.coords
    end

    local x = finiteNumber(decoded.x)
    local y = finiteNumber(decoded.y)
    local z = finiteNumber(decoded.z)
    local heading = finiteNumber(decoded.w or decoded.h or decoded.heading) or 0.0

    if not x or not y or not z then return end

    -- Stock qb-houses uses 0,0,0,0 as its "garage not configured" sentinel.
    if x == 0.0 and y == 0.0 and z == 0.0 then return end

    return { x = x, y = y, z = z, w = heading }
end

local function decodeKeyholders(value)
    local decoded = decodeJsonTable(value)
    local keyholders = {}
    local seen = {}

    if not decoded then return keyholders, value == nil or value == '' or value == 'null' end

    local function addCitizenId(candidate)
        candidate = trimmedString(candidate, 128)

        if candidate and not seen[candidate] then
            seen[candidate] = true
            keyholders[#keyholders + 1] = candidate
        end
    end

    for key, candidate in pairs(decoded) do
        if type(candidate) == 'string' then
            addCitizenId(candidate)
        elseif type(candidate) == 'table' then
            addCitizenId(candidate.citizenid)
        elseif (candidate == true or candidate == 1) and type(key) == 'string' then
            addCitizenId(key)
        end
    end

    table.sort(keyholders)

    return keyholders, true
end

local function fnv1a(value, seed, reverse)
    local hash = seed

    if reverse then
        for index = #value, 1, -1 do
            hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
        end
    else
        for index = 1, #value do
            hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
        end
    end

    return ('%08x'):format(hash)
end

local function propertyGarageId(houseName)
    local hash = fnv1a(houseName, 2166136261, false) .. fnv1a(houseName, 2246822519, true)
    local slugMaxLength = PROPERTY_GARAGE_ID_MAX_LENGTH - #PROPERTY_GARAGE_ID_PREFIX - #hash - 1
    local slug = houseName:lower():gsub('%s+', '_'):gsub('[^%w_%-]', ''):sub(1, slugMaxLength)

    if slug == '' then slug = 'house' end

    -- The readable component is not assumed unique. Two independent hashes of
    -- the exact database key keep punctuation/case variants from colliding while
    -- the complete id remains safe for stock player_vehicles.garage VARCHAR(50).
    local id = ('%s%s_%s'):format(PROPERTY_GARAGE_ID_PREFIX, slug, hash)

    assert(#id <= PROPERTY_GARAGE_ID_MAX_LENGTH, 'generated property garage id exceeds database limit')

    return id
end

local function signatureField(value)
    value = tostring(value or '')
    return ('%d:%s'):format(#value, value)
end

local function garageSignature(houseName, label, coords, owner, keyholders)
    local values = {
        houseName,
        label,
        ('%.12g'):format(coords.x),
        ('%.12g'):format(coords.y),
        ('%.12g'):format(coords.z),
        ('%.12g'):format(coords.w),
        owner
    }

    for _, citizenId in ipairs(keyholders) do
        values[#values + 1] = citizenId
    end

    for index, value in ipairs(values) do
        values[index] = signatureField(value)
    end

    return table.concat(values, '|')
end

local function awaitDatabaseSetup()
    if databaseGateResolved then return databaseGateSucceeded end

    local databaseApi = rawget(_G, 'DRSGaragesDatabase')

    -- Older builds have no setup gate. oxmysql's await query remains the fallback.
    if type(databaseApi) ~= 'table' or type(databaseApi.awaitReady) ~= 'function' then
        return true
    end

    local callOk, ready, detail = pcall(databaseApi.awaitReady)

    databaseGateResolved = true
    databaseGateSucceeded = callOk and ready == true

    if not databaseGateSucceeded then
        logLimited('database-gate', ('Housing sync is paused because database setup did not complete: %s'):format(
            tostring(callOk and detail or ready)
        ))
    end

    return databaseGateSucceeded
end


local function registerGarage(entry)
    local callOk, result = pcall(function()
        return exports[currentResource]:RegisterPropertyGarage(entry.houseName, {
            id = entry.id,
            label = entry.label,
            entryCoords = entry.coords,
            spawnCoords = entry.coords,
            owner = entry.owner,
            keyholders = entry.keyholders,
            vehicleType = 'car'
        })
    end)

    if not callOk or result == false or result == nil then
        logLimited(('register:%s'):format(entry.id), ('Could not register garage for house %s: %s'):format(
            entry.houseName,
            tostring(callOk and result or result)
        ))
        return false
    end

    limitedNotices[('register:%s'):format(entry.id)] = nil
    return true
end

local function removeGarage(id)
    local callOk, result = pcall(function()
        return exports[currentResource]:RemovePropertyGarage(id)
    end)

    if not callOk or result == false then
        logLimited(('remove:%s'):format(id), ('Could not unregister imported garage %s: %s'):format(
            id,
            tostring(callOk and result or result)
        ))
        return false
    end

    limitedNotices[('remove:%s'):format(id)] = nil
    return true
end

local function clearImportedGarages(reason)
    local removed = 0

    for id in pairs(importedGarages) do
        if removeGarage(id) then
            importedGarages[id] = nil
            removed = removed + 1
        end
    end

    if removed > 0 then
        log(('Unregistered %d imported house garage(s) (%s).'):format(removed, reason))
    end
end

local function buildDesiredGarages(rows)
    local desired = {}
    local invalidGarages = 0
    local malformedKeyholders = 0
    local ambiguous = {}

    for _, row in ipairs(rows) do
        local houseName = trimmedString(row.house_name, 255)
        local owner = trimmedString(row.owner_citizenid, 128)
        local coords = decodeGarageCoords(row.garage_data)

        if houseName and owner and coords then
            local id = propertyGarageId(houseName)
            local label = trimmedString(row.house_label) or houseName
            local keyholders, keyholdersValid = decodeKeyholders(row.keyholders_data)
            local existing = desired[id]

            if not keyholdersValid then malformedKeyholders = malformedKeyholders + 1 end

            if ambiguous[id] then
                -- An already-detected duplicate/collision remains excluded.
            elseif existing and (existing.houseName ~= houseName or existing.owner ~= owner) then
                desired[id] = nil
                ambiguous[id] = true
                invalidGarages = invalidGarages + 1
                logLimited(('ambiguous:%s'):format(id), ('Skipped ambiguous house ownership rows for garage id %s.'):format(id))
            elseif not existing then
                desired[id] = {
                    id = id,
                    houseName = houseName,
                    label = label,
                    coords = coords,
                    owner = owner,
                    keyholders = keyholders,
                    signature = garageSignature(houseName, label, coords, owner, keyholders)
                }
            end
        else
            invalidGarages = invalidGarages + 1
        end
    end

    if malformedKeyholders > 0 then
        logLimited('malformed-keyholders', ('Ignored malformed keyholder JSON on %d house row(s); owner access remains intact.'):format(
            malformedKeyholders
        ))
    else
        limitedNotices['malformed-keyholders'] = nil
    end

    if invalidGarages > 0 then
        logLimited('invalid-garages', ('Skipped %d owned house row(s) without one unambiguous owner and a usable garage coordinate.'):format(
            invalidGarages
        ))
    else
        limitedNotices['invalid-garages'] = nil
    end

    return desired
end

local function reconcileHousing(reason)
    if GetResourceState(housingResource) ~= 'started' then
        clearImportedGarages(('%s is not started'):format(housingResource))
        return
    end

    if not awaitDatabaseSetup() then return end

    local queryEpoch = housingEpoch
    local queryOk, rows = pcall(function()
        return MySQL.query.await(HOUSE_QUERY, {})
    end)

    if not queryOk or type(rows) ~= 'table' then
        logLimited('query', ('Could not read the stock qb-houses tables; existing imports were retained: %s'):format(
            tostring(rows)
        ))
        return
    end

    limitedNotices.query = nil

    -- The database await yields. Never restore data from a query that began before
    -- qb-houses stopped/restarted.
    if queryEpoch ~= housingEpoch or GetResourceState(housingResource) ~= 'started' then
        clearImportedGarages(('%s changed state during sync'):format(housingResource))
        return
    end

    local desired = buildDesiredGarages(rows)
    local added = 0
    local updated = 0
    local removed = 0

    for id, entry in pairs(desired) do
        local imported = importedGarages[id]

        if not imported or imported.signature ~= entry.signature then
            if registerGarage(entry) then
                importedGarages[id] = {
                    signature = entry.signature,
                    houseName = entry.houseName
                }

                if imported then
                    updated = updated + 1
                else
                    added = added + 1
                end
            end
        end
    end

    for id in pairs(importedGarages) do
        if not desired[id] and removeGarage(id) then
            importedGarages[id] = nil
            removed = removed + 1
        end
    end

    if added > 0 or updated > 0 or removed > 0 then
        log(('Housing sync (%s): %d added, %d updated, %d removed.'):format(reason, added, updated, removed))
    end
end

local function requestSync(reason)
    pendingReason = reason or 'requested'

    if syncRunning then
        syncPending = true
        return
    end

    syncRunning = true

    CreateThread(function()
        repeat
            syncPending = false
            local activeReason = pendingReason

            reconcileHousing(activeReason)
        until not syncPending

        syncRunning = false
    end)
end

local function reportApartments()
    if not apartmentsEnabled or apartmentsLogged then return end
    if GetResourceState(apartmentsResource) ~= 'started' then return end

    apartmentsLogged = true
    log(('%s detected. Stock QB apartments do not expose private garage coordinates; residents use the public garages configured in Config.Garages.'):format(
        apartmentsResource
    ))
end

AddEventHandler('onResourceStart', function(resource)
    if resource == currentResource then
        SetTimeout(250, function()
            reportApartments()
            requestSync('DRS resource start')
        end)
    elseif resource == housingResource then
        housingEpoch = housingEpoch + 1
        SetTimeout(250, function()
            requestSync(('%s start'):format(housingResource))
        end)
    elseif apartmentsEnabled and resource == apartmentsResource then
        SetTimeout(250, reportApartments)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == housingResource then
        housingEpoch = housingEpoch + 1
        clearImportedGarages(('%s stopped'):format(housingResource))
    elseif apartmentsEnabled and resource == apartmentsResource then
        apartmentsLogged = false
    end
end)

CreateThread(function()
    -- Also covers unusual load orders where this script is evaluated after the
    -- current resource's start notification has already been dispatched.
    Wait(500)
    reportApartments()
    requestSync('startup detection')

    while true do
        Wait(syncInterval)
        requestSync('poll')
    end
end)
