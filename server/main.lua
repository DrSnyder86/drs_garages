-- Used to store vehicles that have been taken out
---@type table<string, number>
local activeVehicles = {}
local vehicleStorageOperations = {}
local vehicleRetrievalOperations = {}
local vehicleExternalOperations = {}
local vehicleReconciliationQuarantine = {}
local pendingEnforcementRemovals = {}
local ambientRemovalOperations = {}
local propertyGarages = {}
local parkingInspectionOperations = {}
local parkingInspectionCooldowns = {}

local UINT32 = 4294967296
local ACTIVE_VEHICLE_REGISTRATION_DISTANCE = 75.0
local VEHICLE_DELETE_RETRY_COUNT = 20
local VEHICLE_DELETE_RETRY_INTERVAL = 100
local VEHICLE_OWNER_TIMEOUT = 5000
local UNATTENDED_VEHICLE_STORAGE_DISTANCE = 20.0
local MAX_GARAGE_STORAGE_NAME_LENGTH = 50
local SERVER_DISTANCE_TOLERANCE = 2.0
local PARKING_INSPECTION_COOLDOWN = 750
local databaseNotificationTimes = {}
local storageWarnings = {}
local publicStorageCatalogValid = true
local getActiveVehicleByPlate
local startupReconciliationComplete = false
local startupReconciliationSuccessful = false
local startupReconciliationDetail = 'startup vehicle reconciliation is still running'
local missingDatabaseApiWarned = false

local function stableHash(value)
    local hash = 2166136261

    for index = 1, #value do
        hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
    end

    return ('%08x'):format(hash)
end

local function isStorageSafeGarageName(value)
    if type(value) ~= 'string' then return false end

    value = value:match('^%s*(.-)%s*$')

    return value ~= ''
        and #value <= MAX_GARAGE_STORAGE_NAME_LENGTH
        and value:match('^[%w_%-]+$') ~= nil
end

local function storageSafeGarageName(value)
    if value == nil then return end

    value = tostring(value):match('^%s*(.-)%s*$')
    if value == '' then return end
    value = value:gsub('[^%w_%-]', '_')
    if #value <= MAX_GARAGE_STORAGE_NAME_LENGTH then return value end

    local prefixLength = MAX_GARAGE_STORAGE_NAME_LENGTH - 17
    local prefix = value:gsub('[^%w_%-]', '_'):sub(1, prefixLength)
    local suffix = stableHash(value) .. stableHash(value:reverse())

    return ('%s_%s'):format(prefix, suffix)
end

local function storageWarningOnce(key, message)
    if storageWarnings[key] then return end

    storageWarnings[key] = true
    print(('[drs_garages] WARNING: %s'):format(message))
end

local function normalizeStorageName(value)
    if value == nil then return end

    value = tostring(value):match('^%s*(.-)%s*$')
    if not value or value == '' then return end

    return value:lower()
end

local function getStorageConfig()
    return type(Config.Storage) == 'table' and Config.Storage or {}
end

local function getRequestedStorageMode()
    return tostring(getStorageConfig().Mode or 'global'):lower()
end

local function getStorageMode()
    local mode = getRequestedStorageMode()

    if mode ~= 'global' and mode ~= 'garage' and mode ~= 'property' then
        storageWarningOnce(('invalid-mode:%s'):format(mode), ('Config.Storage.Mode `%s` is invalid; using `global`.'):format(mode))
        mode = 'global'
    end

    if mode ~= 'global' and Framework.name == 'es_extended' then
        storageWarningOnce('esx-storage-mode', ('Config.Storage.Mode `%s` needs a verified ESX garage column; using `global` to protect the existing owned_vehicles schema.'):format(mode))
        mode = 'global'
    end

    if mode ~= 'global' and not publicStorageCatalogValid then
        storageWarningOnce('invalid-storage-catalog-mode', ('Config.Storage.Mode `%s` cannot run with duplicate or invalid public garage ids; using `global` until the catalog is corrected.'):format(mode))
        mode = 'global'
    end

    return mode
end

local function recoveryEnabled(name)
    return getStorageConfig()[name] ~= false
end

local function notifyDatabaseUnavailable(source)
    source = tonumber(source)
    if not source or source < 1 then return end

    local now = GetGameTimer()
    if databaseNotificationTimes[source] and now - databaseNotificationTimes[source] < 5000 then return end

    databaseNotificationTimes[source] = now
    TriggerClientEvent('drs_garages:showNotification', source, locale('database_unavailable'), 'error')
end

local function refundImpoundCharge(player, amount, source, plate)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return true end

    if not player or type(player.addAccountMoney) ~= 'function' then
        print(('[drs_garages] CRITICAL impound refund failure (source=%s, plate=%s, amount=%s): player adapter is unavailable'):format(
            tostring(source),
            tostring(plate),
            tostring(amount)
        ))
        return false
    end

    local refundOk, refundResult = pcall(player.addAccountMoney, player, 'money', amount)
    if refundOk and refundResult == true then return true end

    print(('[drs_garages] CRITICAL impound refund failure (source=%s, plate=%s, amount=%s): %s'):format(
        tostring(source),
        tostring(plate),
        tostring(amount),
        tostring(refundOk and refundResult or refundResult)
    ))
    TriggerClientEvent('drs_garages:showNotification', source, locale('impound_refund_failed'), 'error')

    return false
end

local function databaseIsUsable(source)
    local databaseApi = rawget(_G, 'DRSGaragesDatabase')
    if type(databaseApi) ~= 'table' or type(databaseApi.isUsable) ~= 'function' then
        if not missingDatabaseApiWarned then
            missingDatabaseApiWarned = true
            print('[drs_garages] ERROR: database readiness API is unavailable or incomplete; database-backed actions are disabled.')
        end

        notifyDatabaseUnavailable(source)
        return false, 'database readiness API is unavailable or incomplete'
    end

    local databaseOk, databaseUsable, databaseDetail = pcall(databaseApi.isUsable)
    if not databaseOk or not databaseUsable then
        notifyDatabaseUnavailable(source)
        return false, databaseOk and databaseDetail or tostring(databaseUsable)
    end

    if not startupReconciliationComplete or not startupReconciliationSuccessful then
        notifyDatabaseUnavailable(source)
        return false, startupReconciliationDetail
    end

    return true
end

function CanUseDrsGarageDatabase(source)
    return databaseIsUsable(source)
end

-- oxmysql casts TINYINT(1) values to booleans. Normalize database flags before
-- comparing them with the numeric garage state used by QB/Qbox schemas.
local function databaseInteger(value)
    if value == true then return 1 end
    if value == false then return 0 end
    return tonumber(value)
end

local function normalizePlate(plate)
    if type(plate) ~= 'string' then return end

    plate = plate:upper():match('^%s*(.-)%s*$')

    if not plate or plate == '' or #plate > 8 or not plate:match('^[A-Z0-9 ]+$') then
        return
    end

    return plate
end

local function getEnforcementImpoundConfig()
    return type(Config.EnforcementImpound) == 'table' and Config.EnforcementImpound or {}
end

local function enforcementImpoundEnabled()
    return getEnforcementImpoundConfig().Enabled == true
end

local function getEnforcementRemovalDelay()
    local delay = tonumber(getEnforcementImpoundConfig().RemovalDelay) or 30000
    if delay ~= delay or delay == math.huge or delay == -math.huge then delay = 30000 end

    return math.min(300000, math.max(0, math.floor(delay)))
end

local function getAmbientImpoundConfig()
    local settings = getEnforcementImpoundConfig().AmbientVehicles
    return type(settings) == 'table' and settings or {}
end

local function vehicleTableHasColumn(columnName)
    local databaseApi = rawget(_G, 'DRSGaragesDatabase')
    if type(databaseApi) ~= 'table' or type(databaseApi.hasVehicleColumn) ~= 'function' then return false end

    local ok, available = pcall(databaseApi.hasVehicleColumn, columnName)
    return ok and available == true
end

local function sanitizedText(value, maximumLength)
    if type(value) ~= 'string' and type(value) ~= 'number' then return end

    value = tostring(value):gsub('[%z\1-\31\127]', ''):match('^%s*(.-)%s*$')
    if value == '' then return end
    if maximumLength and #value > maximumLength then value = value:sub(1, maximumLength) end

    return value
end

local function normalizeEnforcementJobRule(rule)
    if type(rule) == 'number' then
        return { minGrade = math.max(0, math.floor(rule)), requireDuty = false }
    end

    if type(rule) ~= 'table' then return end
    return {
        minGrade = math.max(0, math.floor(tonumber(rule.MinGrade or rule.minGrade or rule.Grade or rule.grade) or 0)),
        requireDuty = rule.RequireDuty == true or rule.requireDuty == true
    }
end

local function getEnforcementAuthorization(player)
    if not enforcementImpoundEnabled() or not player then return end

    local jobData = type(player.getJobData) == 'function' and player:getJobData() or nil
    if type(jobData) ~= 'table' then
        jobData = { name = player:getJob(), grade = 0, onDuty = false }
    end

    local jobName = type(jobData.name) == 'string' and jobData.name:lower() or nil
    local jobType = type(jobData.type) == 'string' and jobData.type:lower() or nil
    local settings = getEnforcementImpoundConfig()
    local jobs = type(settings.Jobs) == 'table' and settings.Jobs or {}
    local jobTypes = type(settings.JobTypes) == 'table' and settings.JobTypes or {}
    local rule = jobName and (jobs[jobName] or jobs[jobData.name]) or nil
    if rule == nil and jobType then rule = jobTypes[jobType] or jobTypes[jobData.type] end

    rule = normalizeEnforcementJobRule(rule)
    if not rule or (tonumber(jobData.grade) or 0) < rule.minGrade then return end
    if rule.requireDuty and jobData.onDuty ~= true then return end

    return {
        name = jobName,
        type = jobType,
        grade = math.floor(tonumber(jobData.grade) or 0),
        onDuty = jobData.onDuty == true
    }
end

local function boundedImpoundFee(value)
    local settings = getEnforcementImpoundConfig()
    local minimum = math.max(0, math.floor(tonumber(settings.MinimumFee) or 0))
    local maximum = math.max(minimum, math.floor(tonumber(settings.MaximumFee) or 25000))
    local fee = tonumber(value)

    if not fee or fee ~= fee or fee == math.huge or fee == -math.huge or fee % 1 ~= 0 then return end
    fee = math.floor(fee)
    if fee < minimum or fee > maximum then return end

    return fee
end

local function displayImpoundFee(value)
    local fee = tonumber(value)
    if not fee or fee ~= fee or fee == math.huge or fee == -math.huge then return 0 end

    local configuredMaximum = math.max(0, math.floor(tonumber(getEnforcementImpoundConfig().MaximumFee) or 25000))
    return math.min(configuredMaximum, math.max(0, math.floor(fee)))
end

local function getRetrievalOperation(plate)
    return vehicleRetrievalOperations[plate]
end

local function beginRetrievalOperation(plate, source)
    plate = normalizePlate(plate)
    if not plate or vehicleStorageOperations[plate] or getRetrievalOperation(plate)
        or vehicleExternalOperations[plate] or vehicleReconciliationQuarantine[plate]
    then
        return
    end
    if getActiveVehicleByPlate and getActiveVehicleByPlate(plate) then return end

    local token = {}
    vehicleRetrievalOperations[plate] = {
        token = token,
        source = tonumber(source)
    }

    return token
end

-- Contract ownership changes share the same plate-level exclusion domain as
-- parking, garage takeout, impound retrieval, and companion registration.
function BeginDrsGaragePlateOperation(rawPlate, source, operationName)
    local plate = normalizePlate(rawPlate)

    if not plate or vehicleStorageOperations[plate] or vehicleRetrievalOperations[plate]
        or vehicleExternalOperations[plate] or vehicleReconciliationQuarantine[plate]
    then
        return
    end

    local token = {}
    vehicleExternalOperations[plate] = {
        token = token,
        source = tonumber(source),
        operation = tostring(operationName or 'external')
    }

    return token
end

function EndDrsGaragePlateOperation(rawPlate, token)
    local plate = normalizePlate(rawPlate)
    local operation = plate and vehicleExternalOperations[plate] or nil

    if operation and operation.token == token then
        vehicleExternalOperations[plate] = nil
        return true
    end

    return false
end

local function endRetrievalOperation(plate, token)
    local operation = vehicleRetrievalOperations[plate]

    if operation and operation.token == token then
        vehicleRetrievalOperations[plate] = nil
    end
end

local function normalizeModelHash(value)
    if value == nil then return end

    if type(value) == 'table' then
        return normalizeModelHash(value.model or value.hash)
    end

    local hash = tonumber(value)

    if not hash and type(value) == 'string' then
        local trimmed = value:match('^%s*(.-)%s*$')

        if trimmed:sub(1, 1) == '{' then
            local ok, decoded = pcall(json.decode, trimmed)

            if ok and type(decoded) == 'table' then
                return normalizeModelHash(decoded.model or decoded.hash)
            end
        end

        local hasher = joaat or GetHashKey

        if hasher and trimmed ~= '' then
            local ok, result = pcall(hasher, trimmed)
            if ok then hash = tonumber(result) end
        end
    end

    if not hash then return end

    return math.floor(hash) % UINT32
end

local function vehicleMatchesStoredModel(vehicle, storedVehicle)
    local entityModel = normalizeModelHash(GetEntityModel(vehicle))
    if not entityModel then return false, false end

    local foundModel = false
    local candidates = {
        storedVehicle.hash,
        storedVehicle.vehicle,
        storedVehicle.model
    }

    for _, candidate in pairs(candidates) do
        local trustedModel = normalizeModelHash(candidate)

        if trustedModel then
            foundModel = true

            if trustedModel == entityModel then
                return true, true
            end
        end
    end

    return false, foundModel
end

local function normalizeGarageType(vehicleType)
    vehicleType = tostring(vehicleType or 'car'):lower()

    if vehicleType == 'automobile' or vehicleType == 'bike' or vehicleType == 'bicycle'
        or vehicleType == 'quadbike' or vehicleType == 'trailer' or vehicleType == 'train'
    then
        return 'car'
    elseif vehicleType == 'plane' or vehicleType == 'heli' or vehicleType == 'helicopter' then
        return 'air'
    elseif vehicleType == 'jetski' or vehicleType == 'submarine' or vehicleType == 'submarines' or vehicleType == 'submersible' then
        return 'boat'
    end

    return vehicleType
end

local publicStorageCatalog
local publicStorageByType

local function generatedPublicStorageName(garage)
    local coords = garage.SpawnPosition or garage.Position or garage.PedPosition
    if not coords then return end

    local signature = ('%s|%.6f|%.6f|%.6f|%.6f'):format(
        normalizeGarageType(garage.Type),
        tonumber(coords.x) or 0.0,
        tonumber(coords.y) or 0.0,
        tonumber(coords.z) or 0.0,
        tonumber(coords.w or coords.heading) or 0.0
    )

    return storageSafeGarageName(('drs_%s_%s%s'):format(
        normalizeGarageType(garage.Type),
        stableHash(signature),
        stableHash(signature:reverse())
    ))
end

local function publicGarageStorageName(garage)
    if not garage then return end

    local configured = garage.Garage or garage.Id or garage.ID or garage.StorageId or garage.Name or garage.Label

    if isStorageSafeGarageName(configured) then
        return tostring(configured):match('^%s*(.-)%s*$')
    end

    return generatedPublicStorageName(garage), configured
end

local function buildPublicStorageCatalog()
    if publicStorageCatalog then return end

    publicStorageCatalog = {}
    publicStorageByType = {}

    for index, garage in ipairs(Config.Garages or {}) do
        local garageType = normalizeGarageType(garage.Type)
        local storageName, invalidConfiguredName = publicGarageStorageName(garage)
        local normalizedName = normalizeStorageName(storageName)

        if invalidConfiguredName ~= nil then
            storageWarningOnce(('invalid-public:%d'):format(index), ('Public garage config index %d has invalid storage id `%s`; a coordinate-derived id will be used.'):format(
                index,
                tostring(invalidConfiguredName)
            ))
        end

        if normalizedName and normalizedName:sub(1, 9) == 'property_' then
            storageWarningOnce(('reserved-public:%d'):format(index), ('Public garage config index %d uses reserved `property_` storage id `%s`; a coordinate-derived id will be used.'):format(
                index,
                storageName
            ))
            storageName = generatedPublicStorageName(garage)
            normalizedName = normalizeStorageName(storageName)
        end

        if normalizedName then
            garage.Garage = storageName

            if publicStorageCatalog[normalizedName] then
                publicStorageCatalogValid = false
                storageWarningOnce(('duplicate-public:%s'):format(normalizedName), ('Public garage storage id `%s` is used more than once (latest config index %d). Non-global storage modes will remain disabled.'):format(
                    storageName,
                    index
                ))
            end

            publicStorageCatalog[normalizedName] = garageType
            publicStorageByType[garageType] = publicStorageByType[garageType] or {}
            publicStorageByType[garageType][#publicStorageByType[garageType] + 1] = storageName
        else
            publicStorageCatalogValid = false
            storageWarningOnce(('invalid-public:%d'):format(index), ('Public garage config index %d has no usable explicit id or coordinates; storage operations there will fail closed.'):format(index))
        end
    end
end

local function defaultStorageName(garageType)
    garageType = normalizeGarageType(garageType)
    buildPublicStorageCatalog()

    local configuredDefaults = getStorageConfig().DefaultGarages
    local configured = type(configuredDefaults) == 'table' and storageSafeGarageName(configuredDefaults[garageType]) or nil
    local normalizedConfigured = normalizeStorageName(configured)

    if normalizedConfigured and publicStorageCatalog[normalizedConfigured] == garageType then
        return configured
    end

    local fallback = publicStorageByType[garageType] and publicStorageByType[garageType][1]

    if configured and fallback then
        storageWarningOnce(('invalid-default:%s'):format(garageType), ('Storage default `%s` is not a configured %s garage; using `%s`.'):format(
            configured,
            garageType,
            fallback
        ))
    elseif not fallback then
        storageWarningOnce(('missing-default:%s'):format(garageType), ('No public %s garage exists for legacy storage recovery.'):format(garageType))
    end

    return fallback
end

-- Publish every static garage's canonical id for diagnostics and companion
-- integrations as soon as this server script loads.
buildPublicStorageCatalog()

local function countTableEntries(value)
    local count = 0

    for _ in pairs(type(value) == 'table' and value or {}) do
        count = count + 1
    end

    return count
end

function GetDrsGaragesDiagnosticSnapshot()
    buildPublicStorageCatalog()

    local parkingOperationCount = countTableEntries(vehicleStorageOperations)
    local retrievalOperationCount = countTableEntries(vehicleRetrievalOperations)
    local externalOperationCount = countTableEntries(vehicleExternalOperations)

    return {
        requestedStorageMode = getRequestedStorageMode(),
        storageMode = getStorageMode(),
        activeVehicleCount = countTableEntries(activeVehicles),
        propertyGarageCount = countTableEntries(propertyGarages),
        storageOperationCount = parkingOperationCount + retrievalOperationCount + externalOperationCount,
        pendingEnforcementRemovalCount = countTableEntries(pendingEnforcementRemovals),
        ambientRemovalOperationCount = countTableEntries(ambientRemovalOperations),
        parkingOperationCount = parkingOperationCount,
        retrievalOperationCount = retrievalOperationCount,
        externalOperationCount = externalOperationCount,
        quarantinedVehicleCount = countTableEntries(vehicleReconciliationQuarantine),
        reconciliationComplete = startupReconciliationComplete,
        reconciliationSuccessful = startupReconciliationSuccessful,
        reconciliationDetail = startupReconciliationDetail,
        staticGarageCount = countTableEntries(Config.Garages),
        staticGarageCatalogCount = countTableEntries(publicStorageCatalog),
        staticGarageCatalogValid = publicStorageCatalogValid == true
    }
end

exports('GetDrsGaragesDiagnosticSnapshot', GetDrsGaragesDiagnosticSnapshot)

local function propertyGarageId(name)
    if type(name) ~= 'string' and type(name) ~= 'number' then return end

    local value = tostring(name):match('^%s*(.-)%s*$')
    if not value or value == '' then return end

    if propertyGarages[value] then return value end

    value = value:lower():gsub('%s+', '_'):gsub('[^%w_%-]', '')
    if value == '' then return end

    if value:sub(1, 9) ~= 'property_' then
        value = ('property_%s'):format(value)
    end

    if value == 'property_' then return end

    return storageSafeGarageName(value)
end

local function coordsToVector4(coords)
    if not coords then return end

    local x = tonumber(coords.x)
    local y = tonumber(coords.y)
    local z = tonumber(coords.z)

    if not x or not y or not z then return end

    return vector4(x, y, z, tonumber(coords.w or coords.heading or coords.h) or 0.0)
end

local function vecToTable(coords)
    if not coords then return end

    return {
        x = coords.x,
        y = coords.y,
        z = coords.z,
        w = coords.w or coords.heading or 0.0
    }
end

local function copyKeyholders(keyholders)
    local result = {}

    if type(keyholders) ~= 'table' then return result end

    for _, citizenid in pairs(keyholders) do
        result[#result + 1] = citizenid
    end

    return result
end

local function tableContains(list, value)
    for _, item in pairs(list or {}) do
        if item == value then return true end
    end

    return false
end

local function hasConfiguredJob(player, jobs)
    if not jobs then return true end

    local job = player:getJob()

    if type(jobs) == 'string' then
        return job == jobs
    end

    for _, name in ipairs(jobs) do
        if job == name then return true end
    end

    return false
end

local function getGarage(index)
    if type(index) == 'number' then
        return Config.Garages[index]
    elseif type(index) == 'string' then
        return propertyGarages[index]
    end
end

local function playerCanAccessGarage(player, garage)
    if not garage then return false end
    if not hasConfiguredJob(player, garage.Jobs) then return false end
    if not garage.Property then return true end

    local identifier = player:getIdentifier()

    return garage.Owner == identifier or tableContains(garage.Keyholders, identifier)
end

local function isValidSocietyJobName(job)
    return type(job) == 'string' and job ~= '' and job ~= 'unemployed'
end

local function vehicleMatchesOwnershipMode(vehicle, player, society)
    if society then
        local job = player:getJob()
        return isValidSocietyJobName(job)
            and vehicle.job and vehicle.job ~= '' and vehicle.job == job
    end

    return not vehicle.job or vehicle.job == ''
end

local function jobFleetEnabled()
    return type(Config.JobFleet) == 'table' and Config.JobFleet.Enabled ~= false
end

local function canAccessJobFleetVehicle(source, vehicle)
    if not vehicle or not vehicle.job or vehicle.job == '' then return true end

    local checker = rawget(_G, 'CanAccessDrsFleetVehicle')
    if type(checker) ~= 'function' then
        -- A partially loaded fleet service must never expose society assets.
        return not jobFleetEnabled()
    end

    local ok, allowed = pcall(checker, source, vehicle)
    return ok and allowed == true
end

local function getJobFleetMetadata(vehicle)
    if not vehicle or not vehicle.job or vehicle.job == '' then return end

    local provider = rawget(_G, 'GetDrsFleetVehicleMetadata')
    if type(provider) ~= 'function' then return end

    local ok, metadata = pcall(provider, vehicle)
    return ok and type(metadata) == 'table' and metadata or nil
end

local function canAccessGarage(source, garage)
    local player = Framework.getPlayerFromId(source)
    if not player then return false end

    return playerCanAccessGarage(player, garage)
end

local function interactionRadius(configured)
    local radius = tonumber(configured) or tonumber(Config.MaxDistance) or 10.0

    if radius ~= radius or radius == math.huge or radius == -math.huge then radius = 10.0 end
    return math.max(radius, 0.0) + SERVER_DISTANCE_TOLERANCE
end

local function isNearCoords(source, coords, radius)
    if not coords then return false end

    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 then return false end

    local playerCoords = GetEntityCoords(playerPed)
    return #(playerCoords - vector3(coords.x, coords.y, coords.z)) <= interactionRadius(radius)
end

local function isVehicleNearPlayer(source, vehicle)
    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 or not DoesEntityExist(playerPed) then return false end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(vehicle) then return false end

    return #(GetEntityCoords(playerPed) - GetEntityCoords(vehicle)) <= ACTIVE_VEHICLE_REGISTRATION_DISTANCE
end

local function isNearGarage(source, garage)
    local radius = garage.Property and (Config.PropertyGarageDistance or 3.0) or Config.MaxDistance

    return isNearCoords(source, garage.Position, radius)
        or isNearCoords(source, garage.PedPosition, radius)
        or (not garage.Position and not garage.PedPosition and isNearCoords(source, garage.SpawnPosition, radius))
end

local function isNearGarageParking(source, garage)
    if garage.Property and garage.SpawnPosition then
        return isNearCoords(
            source,
            garage.SpawnPosition,
            Config.PropertyGarageParkingDistance or Config.PropertyGarageDistance or 3.0
        )
    end

    return isNearGarage(source, garage)
end

local function isVehicleNearGarageParking(vehicle, garage)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local vehicleCoords = GetEntityCoords(vehicle)
    local radius = garage.Property
        and (Config.PropertyGarageParkingDistance or Config.PropertyGarageDistance or 3.0)
        or Config.MaxDistance
    local maximumDistance = interactionRadius(radius)
    local function near(coords)
        return coords and #(vehicleCoords - vector3(coords.x, coords.y, coords.z)) <= maximumDistance
    end

    if garage.Property then return near(garage.SpawnPosition or garage.Position or garage.PedPosition) end
    return near(garage.Position) or near(garage.PedPosition) or near(garage.SpawnPosition)
end

local function spawnTypeMatchesGarage(spawnType, garage)
    return normalizeGarageType(spawnType) == normalizeGarageType(garage.Type)
end

local function liveVehicleTypeMatchesGarage(vehicle, garage)
    local ok, vehicleType = pcall(GetVehicleType, vehicle)

    return ok
        and type(vehicleType) == 'string'
        and normalizeGarageType(vehicleType) == normalizeGarageType(garage.Type)
end

local function vehicleHasOccupantOtherThan(vehicle, allowedPed)
    -- Target-based garages are used on foot, so an owned vehicle may be parked
    -- after its driver steps out. Never delete a vehicle that still contains a
    -- player/NPC, including passenger-only edge cases.
    local maximumPassengerSeat = 15
    local seatsOk, configuredPassengerSeats = pcall(GetVehicleMaxNumberOfPassengers, vehicle)
    if seatsOk then maximumPassengerSeat = math.max(maximumPassengerSeat, tonumber(configuredPassengerSeats) or 0) end

    for seat = -1, maximumPassengerSeat do
        local occupant = GetPedInVehicleSeat(vehicle, seat)
        if occupant ~= 0 and occupant ~= allowedPed then return true end
    end

    return false
end

local function playerCanControlVehicleForStorage(source, vehicle)
    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 or not DoesEntityExist(playerPed) then
        return false, 'player_not_found'
    end

    if GetPedInVehicleSeat(vehicle, -1) == playerPed then
        if vehicleHasOccupantOtherThan(vehicle, playerPed) then return false, 'vehicle_occupied' end
        return true, 'driver'
    end

    if vehicleHasOccupantOtherThan(vehicle) then return false, 'vehicle_occupied' end

    local maximumDistance = interactionRadius(UNATTENDED_VEHICLE_STORAGE_DISTANCE)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(vehicle)) > maximumDistance then
        return false, 'vehicle_too_far'
    end

    return true, 'nearby_empty'
end

local function vehicleIsStationaryForStorage(vehicle)
    local settings = type(Config.Parking) == 'table' and Config.Parking or {}
    local maximumSpeed = tonumber(settings.MaximumSpeed) or 0.5
    if maximumSpeed ~= maximumSpeed or maximumSpeed == math.huge or maximumSpeed == -math.huge then maximumSpeed = 0.5 end
    maximumSpeed = math.max(0.0, maximumSpeed)

    local speedOk, speed = pcall(GetEntitySpeed, vehicle)
    return speedOk and (tonumber(speed) or maximumSpeed + 1.0) <= maximumSpeed
end

local function validateEnforcementImpoundEntity(source, netId, expectedEntity)
    netId = tonumber(netId)
    if not netId or netId < 1 or netId % 1 ~= 0 then return nil, 'vehicle_not_managed' end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'vehicle_not_managed' end
    if expectedEntity and entity ~= expectedEntity then return nil, 'vehicle_not_managed' end
    if GetEntityType(entity) ~= 2 or NetworkGetNetworkIdFromEntity(entity) ~= netId then
        return nil, 'vehicle_not_managed'
    end

    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 or not DoesEntityExist(playerPed) then return nil, 'not_authorized' end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(entity) then return nil, 'vehicle_too_far' end
    if vehicleHasOccupantOtherThan(entity) then return nil, 'vehicle_occupied' end

    local settings = getEnforcementImpoundConfig()
    local maximumDistance = interactionRadius(settings.Distance or 3.0)
    if #(GetEntityCoords(playerPed) - GetEntityCoords(entity)) > maximumDistance then
        return nil, 'vehicle_too_far'
    end

    local maximumSpeed = math.max(0.0, tonumber(settings.MaximumSpeed) or 1.0)
    local speedOk, speed = pcall(GetEntitySpeed, entity)
    if not speedOk or (tonumber(speed) or maximumSpeed + 1.0) > maximumSpeed then
        return nil, 'vehicle_moving'
    end

    return entity
end

local function validateVehicleForStorage(source, garage, netId, plate, model, expectedEntity)
    netId = tonumber(netId)

    if not netId or netId < 1 or netId % 1 ~= 0 then return nil, 'invalid_net_id' end

    local entity = NetworkGetEntityFromNetworkId(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'entity_not_found' end
    if expectedEntity and entity ~= expectedEntity then return nil, 'entity_changed' end
    if GetEntityType(entity) ~= 2 then return nil, 'entity_not_vehicle' end
    if NetworkGetNetworkIdFromEntity(entity) ~= netId then return nil, 'network_id_mismatch' end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(entity) then return nil, 'routing_bucket_mismatch' end

    local canControl, controlReason = playerCanControlVehicleForStorage(source, entity)
    if not canControl then return nil, controlReason end
    if not vehicleIsStationaryForStorage(entity) then return nil, 'vehicle_moving' end
    if not isVehicleNearGarageParking(entity, garage) then return nil, 'vehicle_outside_parking_area' end
    if not liveVehicleTypeMatchesGarage(entity, garage) then return nil, 'vehicle_type_mismatch' end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return nil, 'plate_mismatch' end
    if normalizeModelHash(GetEntityModel(entity)) ~= model then return nil, 'model_mismatch' end

    return entity
end

getActiveVehicleByPlate = function(plate)
    local entity = activeVehicles[plate]

    if entity then
        if DoesEntityExist(entity) then return entity end
        activeVehicles[plate] = nil
    end

    for registeredPlate, registeredEntity in pairs(activeVehicles) do
        if normalizePlate(registeredPlate) == plate then
            if not DoesEntityExist(registeredEntity) then
                activeVehicles[registeredPlate] = nil
            else
                -- Canonicalize legacy/raw plate keys so subsequent security checks
                -- always compare activeVehicles[normalizedPlate] directly.
                activeVehicles[registeredPlate] = nil
                activeVehicles[plate] = registeredEntity
                return registeredEntity
            end
        end
    end
end

local function findContractVehicle(source, plate)
    local entity = getActiveVehicleByPlate(plate)
    local playerPed = GetPlayerPed(source)

    if not entity or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return end
    if not playerPed or playerPed == 0 or not DoesEntityExist(playerPed) then return end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(entity) then return end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return end

    local contractDistance = type(Config.Contract) == 'table' and Config.Contract.VehicleDistance or 5.0
    if #(GetEntityCoords(playerPed) - GetEntityCoords(entity)) > interactionRadius(contractDistance) then return end

    return entity
end

function InspectDrsGarageContractVehicle(source, rawPlate)
    source = tonumber(source)
    local plate = normalizePlate(rawPlate)

    if not source or not plate or vehicleStorageOperations[plate]
        or vehicleRetrievalOperations[plate] or vehicleExternalOperations[plate]
    then
        return
    end

    return findContractVehicle(source, plate)
end

function ValidateDrsGarageContractVehicle(source, rawPlate, token)
    source = tonumber(source)
    local plate = normalizePlate(rawPlate)
    local operation = plate and vehicleExternalOperations[plate] or nil

    if not source or not plate or not operation or operation.token ~= token or operation.source ~= source then return end
    if vehicleStorageOperations[plate] or vehicleRetrievalOperations[plate] then return end

    return findContractVehicle(source, plate)
end

local function isExactActiveVehicle(plate, entity)
    getActiveVehicleByPlate(plate)

    return activeVehicles[plate] == entity
end

local function isDurableOperationPlateBlocked(rawPlate)
    local plate = normalizePlate(rawPlate)
    if not plate then return true end

    local checks = {
        {
            expected = type(Config.Contract) == 'table',
            callback = rawget(_G, 'IsDrsGarageContractPlateBlocked')
        },
        {
            expected = type(Config.JobFleet) == 'table' and Config.JobFleet.Enabled ~= false,
            callback = rawget(_G, 'IsDrsGarageFleetPlateBlocked')
        }
    }

    for _, check in ipairs(checks) do
        if check.expected then
            if type(check.callback) ~= 'function' then return true end
            local ok, blocked = pcall(check.callback, plate)
            if not ok or blocked ~= false then return true end
        end
    end

    return false
end

local function isVehicleStorageInProgress(plate)
    plate = normalizePlate(plate)

    return plate and (
        vehicleStorageOperations[plate] ~= nil
        or getRetrievalOperation(plate) ~= nil
        or vehicleExternalOperations[plate] ~= nil
        or vehicleReconciliationQuarantine[plate] ~= nil
        or isDurableOperationPlateBlocked(plate)
    ) or false
end

local function readVehicleDoorLockStatus(entity)
    local ok, status = pcall(GetVehicleDoorLockStatus, entity)
    status = ok and tonumber(status) or nil
    return status and math.floor(status) or 1
end

local function setEnforcementRemovalState(entity, pending, removalAt, previousLockState)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end

    pcall(function()
        local state = Entity(entity).state
        state:set('drsEnforcementImpoundPending', pending == true and true or nil, true)
        state:set('drsEnforcementImpoundRemovalAt', pending == true and removalAt or nil, true)
    end)

    pcall(FreezeEntityPosition, entity, pending == true)
    pcall(SetVehicleDoorsLocked, entity, pending == true and 2 or (tonumber(previousLockState) or 1))
end

local function requestVehicleDeletion(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return true end

    if GetResourceState('qbx_core') == 'started' then
        local qboxDeleteOk, qboxDeleteResult = pcall(function()
            -- Qbox clears the persisted state before deletion. Using the raw
            -- native alone can make a semi-persisted vehicle respawn.
            return exports.qbx_core:DeleteVehicle(entity)
        end)

        if not qboxDeleteOk or qboxDeleteResult == false then
            local stateReadOk, persisted = pcall(function()
                return Entity(entity).state.persisted == true
            end)

            if not stateReadOk or persisted then
                return not DoesEntityExist(entity)
            end
        end
    end

    if DoesEntityExist(entity) then DeleteEntity(entity) end
    return true
end

local function deleteRegisteredVehicle(source, plate, entity, netId)
    netId = tonumber(netId)

    for _ = 1, VEHICLE_DELETE_RETRY_COUNT do
        if not DoesEntityExist(entity) then return true end
        if vehicleStorageOperations[plate] ~= entity or activeVehicles[plate] ~= entity then return false end
        if NetworkGetNetworkIdFromEntity(entity) ~= netId then return false end

        local canControl = playerCanControlVehicleForStorage(source, entity)
        if not canControl then return false end
        if not vehicleIsStationaryForStorage(entity) then return false end

        if not requestVehicleDeletion(entity) then return not DoesEntityExist(entity) end

        if not DoesEntityExist(entity) then return true end

        Wait(VEHICLE_DELETE_RETRY_INTERVAL)
    end

    return not DoesEntityExist(entity)
end

local function deleteSpawnedVehicle(entity)
    if not entity or entity == 0 then return true end

    for _ = 1, VEHICLE_DELETE_RETRY_COUNT do
        if not DoesEntityExist(entity) then return true end

        if not requestVehicleDeletion(entity) then return not DoesEntityExist(entity) end
        if not DoesEntityExist(entity) then return true end

        Wait(VEHICLE_DELETE_RETRY_INTERVAL)
    end

    return not DoesEntityExist(entity)
end

local function deleteDestroyedActiveVehicle(plate, entity)
    plate = normalizePlate(plate)

    if not plate or not entity or entity == 0 then return false end
    if isVehicleStorageInProgress(plate) or activeVehicles[plate] ~= entity then return false end

    vehicleStorageOperations[plate] = entity
    local deleted = deleteSpawnedVehicle(entity)

    if deleted and activeVehicles[plate] == entity then
        activeVehicles[plate] = nil
    end

    if vehicleStorageOperations[plate] == entity then
        vehicleStorageOperations[plate] = nil
    end

    return deleted
end

local function awaitVehicleOwner(entity)
    local deadline = GetGameTimer() + VEHICLE_OWNER_TIMEOUT

    while DoesEntityExist(entity) and GetGameTimer() < deadline do
        local owner = NetworkGetEntityOwner(entity)
        if owner and owner > 0 then return owner end

        Wait(0)
    end
end

local function clientGarageData(garage)
    return {
        Label = garage.Label,
        Type = garage.Type,
        Position = vecToTable(garage.Position),
        SpawnPosition = vecToTable(garage.SpawnPosition),
        Interior = garage.Interior,
        Property = true,
        Visible = false
    }
end

local function getVehicleOwnershipSnapshot(vehicle)
    if type(vehicle) ~= 'table' then return end

    if vehicle.job ~= nil and vehicle.job ~= '' then
        local job = sanitizedText(vehicle.job, 80)
        return job and 'society' or nil, job
    end

    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local owner = sanitizedText(isQb and vehicle.citizenid or vehicle.owner, 80)
    return owner and 'personal' or nil, owner
end

local function getEncodedVehicleProperties(vehicle)
    if type(vehicle) ~= 'table' then return end

    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        return vehicle.mods
    end

    return vehicle.vehicle
end

local function getVehicleImpoundMarker(vehicle)
    if type(vehicle) ~= 'table' then return end

    local encoded = getEncodedVehicleProperties(vehicle)
    if type(encoded) ~= 'string' or encoded == '' then return end

    local ok, props = pcall(json.decode, encoded)
    if not ok or type(props) ~= 'table' then return end

    return sanitizedText(props._drsImpoundId, 64)
end

local function impoundRecordMatchesVehicle(record, vehicle)
    if type(record) ~= 'table' or type(vehicle) ~= 'table' then
        return false, 'record or vehicle row is unavailable'
    end

    local plate = normalizePlate(vehicle.plate)
    if not plate or normalizePlate(record.plate) ~= plate then
        return false, 'plate does not match the vehicle row'
    end

    local ownershipType, ownerKey = getVehicleOwnershipSnapshot(vehicle)
    if not ownershipType or record.ownership_type ~= ownershipType or record.owner_key ~= ownerKey then
        return false, 'ownership snapshot does not match the vehicle row'
    end

    local rowId = vehicle.id ~= nil and tostring(vehicle.id) or plate
    if tostring(record.vehicle_row_id or '') ~= rowId then
        return false, 'vehicle row identity does not match the active record'
    end

    if getVehicleImpoundMarker(vehicle) ~= record.impound_id then
        return false, 'persisted vehicle marker does not match the active record'
    end

    return true
end

local function vehicleRowsShareIdentity(first, second)
    if type(first) ~= 'table' or type(second) ~= 'table' then return false end
    if normalizePlate(first.plate) ~= normalizePlate(second.plate) then return false end

    if first.id ~= nil or second.id ~= nil then
        if first.id == nil or second.id == nil or tostring(first.id) ~= tostring(second.id) then return false end
    end

    local firstType, firstOwner = getVehicleOwnershipSnapshot(first)
    local secondType, secondOwner = getVehicleOwnershipSnapshot(second)
    return firstType ~= nil and firstType == secondType and firstOwner == secondOwner
end

local function impoundRecordValues(record)
    return {
        record.impound_id,
        record.plate,
        record.vehicle_row_id or record.plate,
        record.ownership_type,
        record.owner_key,
        record.reason,
        record.fee,
        record.release_mode,
        record.impounded_by_identifier,
        record.impounded_by_name,
        record.impounded_by_job,
        record.impounded_by_grade,
        record.source_resource,
        record.impounded_at
    }
end

local function loadActiveImpoundRecordMap()
    local ok, records = pcall(MySQL.query.await, ImpoundQueries.getAll)
    if not ok or type(records) ~= 'table' then
        print(('[drs_garages] ERROR: Could not load enforcement impound records: %s'):format(tostring(records)))
        return nil
    end

    local byPlate = {}
    for _, record in ipairs(records) do
        local plate = normalizePlate(record.plate)
        if plate then byPlate[plate] = record end
    end

    return byPlate
end

local function getActiveImpoundRecord(plate)
    local ok, record = pcall(MySQL.single.await, ImpoundQueries.getByPlate, { normalizePlate(plate) })
    if not ok then
        print(('[drs_garages] ERROR: Could not read the impound record for plate %s: %s'):format(tostring(plate), tostring(record)))
        return nil, false
    end

    return record, true
end

local function decorateImpoundedVehicles(vehicles)
    local records = loadActiveImpoundRecordMap()
    if records == nil then return false end

    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local legacyHolds = getEnforcementImpoundConfig().LegacyStateTwoHold ~= false

    for _, vehicle in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        local plate = normalizePlate(vehicle.plate)
        local record = plate and records[plate] or nil

        if record then
            local matches, mismatchReason = impoundRecordMatchesVehicle(record, vehicle)
            if matches then
                vehicle.impound_id = record.impound_id
                vehicle.impound_reason = record.reason
                vehicle.impound_fee = displayImpoundFee(record.fee)
                vehicle.impound_release_mode = record.release_mode
                vehicle.impounded_by_name = record.impounded_by_name
                vehicle.impounded_by_job = record.impounded_by_job
                vehicle.impounded_at = tonumber(record.impounded_at)
                vehicle.impounded_at_label = vehicle.impounded_at and os.date('%Y-%m-%d %H:%M', vehicle.impounded_at) or nil
                vehicle.impound_hold = record.release_mode ~= 'payable'
            else
                vehicleReconciliationQuarantine[plate] = ('impound record mismatch: %s'):format(mismatchReason)
                vehicle.impound_fee = 0
                vehicle.impound_hold = true
            end
        else
            vehicle.impound_fee = isQb and vehicle.depotprice ~= nil
                and displayImpoundFee(vehicle.depotprice)
                or math.max(0, math.floor(tonumber(Config.ImpoundPrice) or 0))
            vehicle.impound_hold = isQb and legacyHolds and databaseInteger(vehicle.state) == 2 or false
        end
    end

    return true
end

function BuildDrsGarageClientVehicles(vehicles)
    local clientVehicles = {}

    for _, storedVehicle in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        local fleetMetadata = getJobFleetMetadata(storedVehicle)

        clientVehicles[#clientVehicles + 1] = {
            plate = storedVehicle.plate,
            mods = storedVehicle.mods,
            vehicle = storedVehicle.vehicle,
            state = storedVehicle.state,
            impound_reason = storedVehicle.impound_reason,
            impound_fee = storedVehicle.impound_fee,
            impound_hold = storedVehicle.impound_hold == true,
            impounded_by_name = storedVehicle.impounded_by_name,
            impounded_by_job = storedVehicle.impounded_by_job,
            impounded_at = storedVehicle.impounded_at,
            impounded_at_label = storedVehicle.impounded_at_label,
            fleet_managed = fleetMetadata ~= nil,
            fleet_min_grade = fleetMetadata and tonumber(fleetMetadata.minGrade) or nil,
            fleet_garage = fleetMetadata and fleetMetadata.garage or nil
        }
    end

    return clientVehicles
end

local function refreshPropertyGarageForPlayer(source, id)
    local garage = propertyGarages[id]

    if garage and canAccessGarage(source, garage) then
        TriggerClientEvent('drs_garages:client:registerPropertyGarage', source, id, clientGarageData(garage))
    else
        TriggerClientEvent('drs_garages:client:removePropertyGarage', source, id)
    end
end

local function refreshPropertyGarage(id)
    for _, playerId in ipairs(GetPlayers()) do
        refreshPropertyGarageForPlayer(tonumber(playerId), id)
    end
end

local function RegisterPropertyGarage(name, data)
    if type(data) ~= 'table' then return false end

    local accessPoint = data.accessPoints and data.accessPoints[1] or data.AccessPoints and data.AccessPoints[1]
    local entryData = data.entryCoords or data.EntryCoords or data.Position or data.position or data.coords or data.Coords
    local spawnData = data.spawnCoords or data.SpawnCoords or data.SpawnPosition or data.spawnPosition or data.coords or data.Coords

    if not entryData and accessPoint then
        entryData = accessPoint.coords or accessPoint.entry or accessPoint.entryCoords
    end

    if not spawnData and accessPoint then
        spawnData = accessPoint.spawn or accessPoint.spawnCoords or accessPoint.coords
    end

    local entryCoords = coordsToVector4(entryData)
    local spawnCoords = coordsToVector4(spawnData)

    if not entryCoords or not spawnCoords then return false end

    local interior = data.interior or data.Interior

    if interior == '' or interior == 'none' or not Config.GarageInteriors[interior] then
        interior = nil
    end

    local id = propertyGarageId(data.id or data.Id or name)
    if not id then return false end

    propertyGarages[id] = {
        Label = data.label or data.Label or tostring(name),
        Type = normalizeGarageType(data.vehicleType or data.VehicleType or data.Type or data.type or 'car'),
        Position = vector3(entryCoords.x, entryCoords.y, entryCoords.z),
        SpawnPosition = spawnCoords,
        Interior = interior,
        Owner = data.owner or data.Owner,
        Keyholders = copyKeyholders(data.keyholders or data.Keyholders),
        Property = true,
        Visible = false
    }

    refreshPropertyGarage(id)

    return id
end

local function RemovePropertyGarage(name)
    local id = propertyGarageId(name)
    if not id then return false end

    propertyGarages[id] = nil
    TriggerClientEvent('drs_garages:client:removePropertyGarage', -1, id)

    return true
end

local function RefreshPropertyGarage(name)
    local id = propertyGarageId(name)
    if not id or not propertyGarages[id] then return false end

    refreshPropertyGarage(id)
    return true
end

exports('RegisterPropertyGarage', RegisterPropertyGarage)
exports('RemovePropertyGarage', RemovePropertyGarage)
exports('RefreshPropertyGarage', RefreshPropertyGarage)

function CanEnterDrsGarageInterior(source, index, vehicleType)
    local player = Framework.getPlayerFromId(source)
    if not player then return false end

    local garage = getGarage(index)
    if not garage or not garage.Interior then return false end
    if vehicleType and not spawnTypeMatchesGarage(vehicleType, garage) then return false end
    if not playerCanAccessGarage(player, garage) then return false end

    return isNearGarage(source, garage)
end

lib.callback.register('drs_garages:getPropertyGarages', function(source)
    local player = Framework.getPlayerFromId(source)
    if not player then return {} end

    local garages = {}

    for id, garage in pairs(propertyGarages) do
        if playerCanAccessGarage(player, garage) then
            garages[id] = clientGarageData(garage)
        end
    end

    return garages
end)


local function applyVehicleIdentityState(entity, storedVehicle)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end

    local ok, errorMessage = pcall(function()
        local state = Entity(entity).state
        local vehicleId = tonumber(storedVehicle and storedVehicle.id)
        local plate = normalizePlate(storedVehicle and storedVehicle.plate)

        state:set('drsGarageManaged', true, false)
        if plate then state:set('drsGaragePlate', plate, false) end
        if vehicleId then state:set('drsGarageRowId', vehicleId, false) end

        if Framework.name == 'qbx_core' then
            local personal = storedVehicle and (storedVehicle.job == nil or storedVehicle.job == '')
            local owner = personal and storedVehicle.citizenid or nil

            if vehicleId then state:set('vehicleid', vehicleId, false) end
            state:set('owner', type(owner) == 'string' and owner ~= '' and owner or nil, true)
        end
    end)

    if not ok then
        print(('[drs_garages] WARNING: Could not apply managed vehicle identity state to entity %s: %s'):format(
            tostring(entity),
            tostring(errorMessage)
        ))
    end

    return ok
end

local function giveVehicleKeys(source, vehicle)
    if not Config.UseKeySystem then return true end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return false, 'vehicle entity is unavailable'
    end

    if GetResourceState('qbx_vehiclekeys') == 'started' then
        local ok, result = pcall(function()
            return exports.qbx_vehiclekeys:GiveKeys(source, vehicle, false)
        end)

        if not ok then return false, ('qbx_vehiclekeys export error: %s'):format(tostring(result)) end
        if result == false then return false, 'qbx_vehiclekeys rejected the key grant' end

        local verified, hasKeys = pcall(function()
            return exports.qbx_vehiclekeys:HasKeys(source, vehicle)
        end)

        if not verified then
            return false, ('qbx_vehiclekeys verification error: %s'):format(tostring(hasKeys))
        end

        if hasKeys ~= true then
            return false, 'qbx_vehiclekeys did not confirm the granted keys'
        end

        return true
    end

    if GetResourceState('qb-vehiclekeys') == 'started' then
        local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
        if not plate then return false, 'spawned vehicle has no valid plate for qb-vehiclekeys' end

        local ok, result = pcall(function()
            return exports['qb-vehiclekeys']:GiveKeys(source, plate)
        end)

        if not ok then return false, ('qb-vehiclekeys export error: %s'):format(tostring(result)) end
        if result == false then return false, 'qb-vehiclekeys rejected the key grant' end

        local verified, hasKeys = pcall(function()
            return exports['qb-vehiclekeys']:HasKeys(source, plate)
        end)

        if not verified then
            return false, ('qb-vehiclekeys verification error: %s'):format(tostring(hasKeys))
        end

        if hasKeys ~= true then
            return false, 'qb-vehiclekeys did not confirm the granted keys'
        end

        return true
    end

    return false, 'no supported vehicle-key resource is started'
end

local function giveVehicleKeysOrWarn(source, vehicle, plate)
    local granted, reason = giveVehicleKeys(source, vehicle)
    if granted then return true end

    if not plate and vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
    end

    print(('[drs_garages] WARNING: Vehicle key handoff failed for source %s, plate %s: %s'):format(
        tostring(source),
        tostring(plate or 'unknown'),
        tostring(reason or 'unknown error')
    ))

    return false
end

---@param source number Player server id that owns the persisted vehicle.
---@param plate string Persisted vehicle plate.
---@param netId number Network id for the delivered, server-created entity.
---@return boolean success
---@return string reason
local function RegisterActiveVehicle(source, plate, netId)
    if not databaseIsUsable(source) then return false, 'database_unavailable' end

    source = tonumber(source)
    plate = normalizePlate(plate)
    netId = tonumber(netId)

    if not source or source < 1 then return false, 'invalid_source' end
    if not plate then return false, 'invalid_plate' end
    if not netId or netId < 1 or netId % 1 ~= 0 then return false, 'invalid_net_id' end
    if isVehicleStorageInProgress(plate) then return false, 'storage_in_progress' end

    local player = Framework.getPlayerFromId(source)
    if not player then return false, 'player_not_found' end

    local identifier = player:getIdentifier()

    local entity = NetworkGetEntityFromNetworkId(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return false, 'entity_not_found'
    end

    if GetEntityType(entity) ~= 2 then return false, 'entity_not_vehicle' end
    if NetworkGetNetworkIdFromEntity(entity) ~= netId then return false, 'network_id_mismatch' end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(entity) then return false, 'routing_bucket_mismatch' end
    if not isVehicleNearPlayer(source, entity) then return false, 'vehicle_too_far' end

    local entityPlate = normalizePlate(GetVehicleNumberPlateText(entity))
    if entityPlate ~= plate then return false, 'plate_mismatch' end

    local registrationToken = beginRetrievalOperation(plate, source)
    if not registrationToken then return false, 'storage_in_progress' end

    local function performRegistration()

    local storedVehicle = MySQL.single.await(Queries.getVehicleStrict, {
        identifier,
        plate
    })

    if not storedVehicle then return false, 'vehicle_not_owned' end

    player = Framework.getPlayerFromId(source)
    if not player or player:getIdentifier() ~= identifier then return false, 'player_changed' end

    local storedIdentifier = Framework.name == 'es_extended' and storedVehicle.owner or storedVehicle.citizenid

    if storedIdentifier ~= identifier or normalizePlate(storedVehicle.plate) ~= plate or storedVehicle.job ~= nil then
        return false, 'ownership_changed'
    end

    if databaseInteger(storedVehicle.stored) ~= 0 then return false, 'vehicle_not_out' end
    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        if databaseInteger(storedVehicle.state) ~= 0 then return false, 'vehicle_not_out' end
    end

    -- The ownership lookup yields to the database. Re-resolve and revalidate the
    -- entity before caching it so a deletion/network-id reuse cannot leave a
    -- stale active-vehicle entry behind.
    local currentEntity = NetworkGetEntityFromNetworkId(netId)

    if not currentEntity or currentEntity == 0 or currentEntity ~= entity or not DoesEntityExist(currentEntity) then
        return false, 'entity_changed'
    end

    if GetEntityType(currentEntity) ~= 2 then return false, 'entity_not_vehicle' end
    if NetworkGetNetworkIdFromEntity(currentEntity) ~= netId then return false, 'network_id_mismatch' end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(currentEntity) then return false, 'routing_bucket_mismatch' end
    if normalizePlate(GetVehicleNumberPlateText(currentEntity)) ~= plate then return false, 'plate_mismatch' end
    if not isVehicleNearPlayer(source, currentEntity) then return false, 'vehicle_too_far' end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(currentEntity, storedVehicle)

    if not hasStoredModel then return false, 'stored_model_missing' end
    if not modelMatches then return false, 'model_mismatch' end

    for registeredPlate, registeredEntity in pairs(activeVehicles) do
        if not DoesEntityExist(registeredEntity) then
            activeVehicles[registeredPlate] = nil
        elseif normalizePlate(registeredPlate) == plate then
            if registeredEntity == entity then
                if registeredPlate ~= plate then
                    activeVehicles[registeredPlate] = nil
                    activeVehicles[plate] = entity
                end

                return true, 'already_registered'
            end

            return false, 'plate_already_active'
        elseif registeredEntity == entity then
            return false, 'entity_already_registered'
        end
    end

    if not applyVehicleIdentityState(currentEntity, storedVehicle) then
        return false, 'identity_state_failed'
    end

    activeVehicles[plate] = currentEntity

    return true, 'registered'
    end

    local operationOk, success, reason = xpcall(performRegistration, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    endRetrievalOperation(plate, registrationToken)

    if not operationOk then
        print(('[drs_garages] Unexpected active-vehicle registration error for plate %s: %s'):format(plate, tostring(success)))
        return false, 'unexpected_error'
    end

    return success, reason
end

---@param plate string Persisted vehicle plate.
---@param netId? number Optional guard against unregistering a replacement entity.
---@return boolean success
---@return string reason
local function UnregisterActiveVehicle(plate, netId)
    plate = normalizePlate(plate)
    if not plate then return false, 'invalid_plate' end
    if isVehicleStorageInProgress(plate) then return false, 'storage_in_progress' end

    if netId ~= nil then
        netId = tonumber(netId)
        if not netId or netId < 1 or netId % 1 ~= 0 then return false, 'invalid_net_id' end
    end

    for registeredPlate, entity in pairs(activeVehicles) do
        if normalizePlate(registeredPlate) == plate then
            if netId and DoesEntityExist(entity) and NetworkGetNetworkIdFromEntity(entity) ~= netId then
                return false, 'entity_mismatch'
            end

            activeVehicles[registeredPlate] = nil
            return true, 'unregistered'
        end
    end

    return true, 'not_registered'
end

exports('RegisterActiveVehicle', RegisterActiveVehicle)
exports('UnregisterActiveVehicle', UnregisterActiveVehicle)

AddEventHandler('entityRemoved', function(entity)
    local ambientOperation = ambientRemovalOperations[entity]
    if ambientOperation and ambientOperation.entity == entity then
        ambientRemovalOperations[entity] = nil
    end

    for plate, activeEntity in pairs(activeVehicles) do
        if activeEntity == entity and vehicleStorageOperations[normalizePlate(plate)] ~= entity then
            activeVehicles[plate] = nil
        end
    end
end)

AddEventHandler('playerDropped', function()
    databaseNotificationTimes[source] = nil
    parkingInspectionOperations[source] = nil
    parkingInspectionCooldowns[source] = nil
    -- A yielded callback still owns its exact token after disconnect. Its
    -- post-yield identity checks fail closed and its finally path releases the
    -- token; clearing it here would reopen the plate to a concurrent operation.
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for _, operation in pairs(pendingEnforcementRemovals) do
        local restored = {}
        local candidates = {
            { entity = operation.entity, netId = operation.netId },
            { entity = operation.currentEntity, netId = operation.currentNetId }
        }
        for _, candidate in ipairs(candidates) do
            if candidate.entity and not restored[candidate.entity] and DoesEntityExist(candidate.entity)
                and NetworkGetNetworkIdFromEntity(candidate.entity) == candidate.netId
            then
                restored[candidate.entity] = true
                setEnforcementRemovalState(candidate.entity, false, nil, operation.previousLockState)
            end
        end
    end
    for _, operation in pairs(ambientRemovalOperations) do
        if DoesEntityExist(operation.entity)
            and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
        then
            setEnforcementRemovalState(operation.entity, false, nil, operation.previousLockState)
        end
    end

    -- Retrieval tokens intentionally never expire while their callback is live.
    -- Explicitly discard them on shutdown as the other safe terminal condition.
    vehicleRetrievalOperations = {}
    vehicleStorageOperations = {}
    vehicleExternalOperations = {}
    vehicleReconciliationQuarantine = {}
    pendingEnforcementRemovals = {}
    ambientRemovalOperations = {}
    parkingInspectionOperations = {}
    parkingInspectionCooldowns = {}
end)

local function invalidIndexMessage(kind, source, index)
    print(('[drs_garages] Invalid %s index from source %s: %s'):format(kind, source or 'unknown', tostring(index)))
    local localeKey = kind == 'impound' and 'invalid_impound' or 'invalid_garage'
    TriggerClientEvent('drs_garages:showNotification', source, locale(localeKey), 'error')
end

local function garageStorageName(index, garage)
    if not garage then return end

    if garage.Property then
        return storageSafeGarageName(index)
    end

    return publicGarageStorageName(garage)
end

local function isPropertyStorageName(value)
    value = normalizeStorageName(value)

    return value and value:sub(1, 9) == 'property_' or false
end

local function getAssignedPropertyGarage(value)
    value = normalizeStorageName(value)
    if not value then return end
    if propertyGarages[value] then return propertyGarages[value] end

    for id, garage in pairs(propertyGarages) do
        if normalizeStorageName(id) == value then return garage end
    end
end

local function rowHasStorageState(vehicle, stored)
    if databaseInteger(vehicle and vehicle.stored) ~= stored then return false end

    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        local frameworkState = databaseInteger(vehicle.state)
        if stored == 0 then return frameworkState == 0 or frameworkState == 2 end
        return frameworkState == 1
    end

    return true
end

local function rowTypeMatchesGarage(vehicle, garage)
    if Framework.name == 'es_extended' and (not vehicle or type(vehicle.type) ~= 'string' or vehicle.type == '') then
        -- Stock ESX schemas do not guarantee a type column. The spawned entity is
        -- validated against the requested garage before its claimed row can stay out.
        return true
    end

    return normalizeGarageType(vehicle and vehicle.type or 'car') == normalizeGarageType(garage and garage.Type)
end

local function vehicleVisibleAtGarage(vehicle, index, garage, player, society)
    if not vehicle or not garage or not player or not rowTypeMatchesGarage(vehicle, garage) then return false end

    -- Managed fleet assets always honor their explicit assignment, even when
    -- personal storage remains globally visible. Legacy job rows retain the
    -- configured storage policy until a boss/admin adopts them in Fleet Manager.
    if society == true then
        local metadata = getJobFleetMetadata(vehicle)
        if metadata then
            if metadata.status ~= 'active' then return false end

            local targetName = normalizeStorageName(garageStorageName(index, garage))
            local assignedName = normalizeStorageName(metadata.garage)
            return targetName ~= nil and assignedName == targetName
        end
    end

    local mode = getStorageMode()
    if mode == 'global' then return true end

    local targetName = normalizeStorageName(garageStorageName(index, garage))
    if not targetName then return false end

    local assignedName = normalizeStorageName(vehicle.garage)
    local assignedIsProperty = isPropertyStorageName(assignedName)

    if mode == 'property' then
        if garage.Property then
            return assignedName == targetName
        end

        if not assignedIsProperty then return true end
        if not recoveryEnabled('RecoverInaccessibleProperties') then return false end

        local assignedProperty = getAssignedPropertyGarage(assignedName)

        return society == true or not assignedProperty or not playerCanAccessGarage(player, assignedProperty)
    end

    if assignedName == targetName then return true end

    if assignedIsProperty then
        local assignedProperty = getAssignedPropertyGarage(assignedName)

        if assignedProperty and society ~= true and playerCanAccessGarage(player, assignedProperty) then
            return false
        end

        if not recoveryEnabled('RecoverInaccessibleProperties') then return false end
    else
        buildPublicStorageCatalog()

        if assignedName and publicStorageCatalog[assignedName] then return false end
        if not recoveryEnabled('RecoverUnassigned') then return false end
    end

    return targetName == normalizeStorageName(defaultStorageName(vehicle.type or garage.Type))
end

function FilterDrsGarageVehicles(source, index, vehicles, society)
    local player = Framework.getPlayerFromId(source)
    local garage = getGarage(index)
    if not player or not garage or not playerCanAccessGarage(player, garage) then return {} end

    local filtered = {}

    for _, vehicle in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        if vehicleVisibleAtGarage(vehicle, index, garage, player, society == true)
            and not isDurableOperationPlateBlocked(vehicle.plate)
            and (society ~= true or canAccessJobFleetVehicle(source, vehicle))
        then
            filtered[#filtered + 1] = vehicle
        end
    end

    return filtered
end

function GetDrsGarageExitPosition(source, index)
    local player = Framework.getPlayerFromId(source)
    local garage = getGarage(index)

    if not player or not garage or not playerCanAccessGarage(player, garage) then return end

    return vecToTable(garage.Position or garage.PedPosition or garage.SpawnPosition)
end

local function queryStrictVehicle(player, plate, society, stored)
    local query
    local params

    if society then
        local job = player:getJob()
        if not isValidSocietyJobName(job) then return end

        query = stored and Queries.getStoredVehicleSociety or Queries.getOutVehicleSociety
        params = { job, plate }
    else
        query = stored and Queries.getStoredVehiclePersonal or Queries.getOutVehiclePersonal
        params = { player:getIdentifier(), plate }
    end

    local ok, vehicle = pcall(MySQL.single.await, query, params)
    if not ok then
        print(('[drs_garages] Vehicle lookup failed for plate %s: %s'):format(plate, tostring(vehicle)))
        return
    end

    return vehicle
end


local function transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, expected, target)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local tableName = isQb and 'player_vehicles' or 'owned_vehicles'
    local where = {}
    local params = { target }

    if isQb then params[#params + 1] = target end

    if vehicle.id ~= nil then
        where[#where + 1] = '`id` = ?'
        params[#params + 1] = vehicle.id
    end

    if ownershipMode == 'society' then
        where[#where + 1] = '`job` = ?'
        params[#params + 1] = job
    else
        where[#where + 1] = isQb and '`citizenid` = ?' or '`owner` = ?'
        params[#params + 1] = identifier
        where[#where + 1] = '`job` IS NULL'
    end

    where[#where + 1] = '`plate` = ?'
    params[#params + 1] = vehicle.plate
    where[#where + 1] = '`stored` = ?'
    params[#params + 1] = expected

    if isQb then
        where[#where + 1] = '`state` = ?'
        params[#params + 1] = expected
    end

    local setClause = isQb and '`stored` = ?, `state` = ?' or '`stored` = ?'
    local sql = ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, setClause, table.concat(where, ' AND '))
    local ok, changed = pcall(MySQL.update.await, sql, params)

    if not ok then
        print(('[drs_garages] Storage transition failed for plate %s: %s'):format(tostring(vehicle.plate), tostring(changed)))
        return false
    end

    return tonumber(changed) == 1
end

local function decodeStoredVehicleProperties(vehicle, plate)
    local ok, props = pcall(json.decode, getEncodedVehicleProperties(vehicle))
    if not ok or type(props) ~= 'table' or not normalizeModelHash(props.model) then return end

    props.plate = plate
    return props
end

local function readBoundedVehicleValue(nativeName, entity, minimum, maximum)
    local getter = rawget(_G, nativeName)
    if type(getter) ~= 'function' then return end

    local ok, value = pcall(getter, entity)
    value = ok and tonumber(value) or nil
    if not value or value ~= value or value == math.huge or value == -math.huge then return end

    return math.min(math.max(value, minimum), maximum)
end

local function buildTrustedParkingProperties(storedVehicle, entity, plate)
    local trusted = decodeStoredVehicleProperties(storedVehicle, plate)
    if not trusted then return end

    -- Operation markers prove exact impound/release transitions in SQL. They
    -- are not vehicle modifications and are retired on the next normal park.
    trusted._drsImpoundId = nil
    trusted._drsReleaseId = nil

    -- Cosmetic/performance modifications remain database-authoritative. The
    -- parking callback is client-callable, so only bounded values read from the
    -- exact server entity may refresh volatile condition fields.
    local runtimeFields = {
        engineHealth = { 'GetVehicleEngineHealth', -4000.0, 1000.0 },
        bodyHealth = { 'GetVehicleBodyHealth', 0.0, 1000.0 },
        tankHealth = { 'GetVehiclePetrolTankHealth', -1000.0, 1000.0 },
        dirtLevel = { 'GetVehicleDirtLevel', 0.0, 15.0 },
        fuelLevel = { 'GetVehicleFuelLevel', 0.0, 100.0 }
    }

    for property, definition in pairs(runtimeFields) do
        local value = readBoundedVehicleValue(definition[1], entity, definition[2], definition[3])
        if value ~= nil then trusted[property] = value end
    end

    trusted.plate = plate
    return trusted
end

local VALID_SERVER_SETTER_TYPES = {
    automobile = true,
    bike = true,
    boat = true,
    heli = true,
    plane = true,
    submarine = true,
    trailer = true,
    train = true
}
local SETTER_TYPE_EXCEPTIONS = {
    airtug = 'automobile',
    avisa = 'submarine',
    blimp = 'heli',
    blimp2 = 'heli',
    blimp3 = 'heli',
    caddy = 'automobile',
    caddy2 = 'automobile',
    caddy3 = 'automobile',
    chimera = 'automobile',
    docktug = 'automobile',
    forklift = 'automobile',
    kosatka = 'submarine',
    mower = 'automobile',
    policeb = 'bike',
    ripley = 'automobile',
    rrocket = 'automobile',
    sadler = 'automobile',
    sadler2 = 'automobile',
    scrap = 'automobile',
    slamtruck = 'automobile',
    stryder = 'automobile',
    submersible = 'submarine',
    submersible2 = 'submarine',
    thruster = 'heli',
    towtruck = 'automobile',
    towtruck2 = 'automobile',
    tractor = 'automobile',
    tractor2 = 'automobile',
    tractor3 = 'automobile',
    trailersmall2 = 'trailer',
    utillitruck = 'automobile',
    utillitruck2 = 'automobile',
    utillitruck3 = 'automobile'
}
local setterTypeByModelHash

local function cacheSetterMetadataEntry(key, metadata)
    if type(metadata) ~= 'table' then return end

    local setterType = tostring(metadata.type or ''):lower()
    if not VALID_SERVER_SETTER_TYPES[setterType] then return end

    local modelHash = normalizeModelHash(metadata.hash or metadata.model or key)
    if modelHash then setterTypeByModelHash[modelHash] = setterType end
end

local function loadSetterTypeMetadata()
    if setterTypeByModelHash then return end

    setterTypeByModelHash = {}

    if Framework.name == 'qbx_core' then
        local byHashOk, byHash = pcall(function() return exports.qbx_core:GetVehiclesByHash() end)
        local byNameOk, byName = pcall(function() return exports.qbx_core:GetVehiclesByName() end)

        for key, metadata in pairs(byHashOk and type(byHash) == 'table' and byHash or {}) do
            cacheSetterMetadataEntry(key, metadata)
        end

        for key, metadata in pairs(byNameOk and type(byName) == 'table' and byName or {}) do
            cacheSetterMetadataEntry(key, metadata)
        end
    elseif Framework.name == 'qb-core' then
        local vehicles = type(QBCore) == 'table' and QBCore.Shared and QBCore.Shared.Vehicles or nil

        for key, metadata in pairs(type(vehicles) == 'table' and vehicles or {}) do
            cacheSetterMetadataEntry(key, metadata)
        end
    end

    for modelName, setterType in pairs(SETTER_TYPE_EXCEPTIONS) do
        local modelHash = normalizeModelHash(modelName)
        if modelHash then setterTypeByModelHash[modelHash] = setterType end
    end
end

local function metadataSetterType(model)
    loadSetterTypeMetadata()
    return setterTypeByModelHash[normalizeModelHash(model)]
end

local function trustedSetterType(requestedType, vehicle, model)
    local requested = tostring(requestedType or ''):lower()
    local hasStoredType = vehicle and type(vehicle.type) == 'string' and vehicle.type ~= ''
    local storedType = hasStoredType and tostring(vehicle.type):lower() or false
    local garageType = Framework.name == 'es_extended' and not hasStoredType
        and normalizeGarageType(requested)
        or normalizeGarageType(vehicle and vehicle.type or 'car')

    if normalizeGarageType(requested) ~= garageType then return end

    -- The model exception table is folded into metadataSetterType and is
    -- authoritative. Otherwise prefer the client-derived native subtype over
    -- framework metadata, which is often only a broad service category.
    local modelType = metadataSetterType(model)
    local exceptionType
    for modelName, setterType in pairs(SETTER_TYPE_EXCEPTIONS) do
        if normalizeModelHash(modelName) == normalizeModelHash(model) then
            exceptionType = setterType
            break
        end
    end

    local candidates = { exceptionType or false, requested, modelType or false, storedType }
    for index = 1, #candidates do
        local setterType = candidates[index]

        if VALID_SERVER_SETTER_TYPES[setterType] and normalizeGarageType(setterType) == garageType then
            return setterType
        end
    end

    if garageType == 'car' then
        if requested == 'bike' or requested == 'bicycle' then return 'bike' end
        if requested == 'automobile' or requested == 'quadbike' then return 'automobile' end
    elseif garageType == 'boat' then
        if requested == 'submarine' or requested == 'submersible' then return 'submarine' end
        if requested == 'boat' or requested == 'jetski' then return 'boat' end
    elseif garageType == 'air' and (requested == 'plane' or requested == 'heli' or requested == 'helicopter') then
        return requested == 'plane' and 'plane' or 'heli'
    end
end

local function spawnStoredVehicle(vehicle, garage, plate, requestedType)
    local props = decodeStoredVehicleProperties(vehicle, plate)
    local setterType = props and trustedSetterType(requestedType, vehicle, props.model) or nil
    if not setterType or not props then return nil, nil, nil, true end

    local ok, entity = pcall(Utils.createVehicle, props.model, garage.SpawnPosition, setterType)

    if not ok or not entity or entity == 0 or not DoesEntityExist(entity) then
        local deleted = not entity or entity == 0 or not DoesEntityExist(entity) or deleteSpawnedVehicle(entity)
        if not deleted and entity and DoesEntityExist(entity) then activeVehicles[plate] = entity end
        return nil, nil, nil, deleted
    end

    -- Match qbx_vehiclekeys' policy using the spawned entity's native type,
    -- including custom vehicles whose metadata class differs from the model.
    -- The decoded properties are for this spawn only; the database is unchanged.
    local typeOk, liveType = pcall(GetVehicleType, entity)
    local locklessBike = Framework.name == 'qbx_core'
        and typeOk
        and tostring(liveType):lower() == 'bike'
    props.lockState = locklessBike and 1 or 2

    if locklessBike then
        pcall(SetVehicleDoorsLocked, entity, 1)

        pcall(function()
            Entity(entity).state:set('doorslockstate', 1, true)
        end)
    end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, vehicle)

    if not hasStoredModel or not modelMatches or not liveVehicleTypeMatchesGarage(entity, garage) then
        local deleted = deleteSpawnedVehicle(entity)
        if not deleted and DoesEntityExist(entity) then activeVehicles[plate] = entity end
        return nil, nil, nil, deleted
    end

    local owner = awaitVehicleOwner(entity)

    if owner == nil then
        local deleted = deleteSpawnedVehicle(entity)
        if not deleted and DoesEntityExist(entity) then activeVehicles[plate] = entity end
        return nil, nil, nil, deleted
    end

    return entity, owner, props, true
end

local function setVehicleStored(plate, stored, garageName)
    plate = normalizePlate(plate)
    if not plate then return end

    stored = databaseInteger(stored) or 0

    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        if garageName then
            return MySQL.update.await('UPDATE player_vehicles SET `stored` = ?, `state` = ?, `garage` = ? WHERE plate = ?', {
                stored,
                stored,
                garageName,
                plate
            })
        end

        return MySQL.update.await('UPDATE player_vehicles SET `stored` = ?, `state` = ? WHERE plate = ?', {
            stored,
            stored,
            plate
        })
    end

    return MySQL.update.await(Queries.setStoredVehicle, { stored, plate })
end

local function reconciliationCandidateIsTrusted(entity, storedVehicle, expectedRoutingBucket)
    expectedRoutingBucket = tonumber(expectedRoutingBucket) or 0
    if GetEntityRoutingBucket(entity) ~= expectedRoutingBucket then
        return false, ('entity is not in routing bucket %s'):format(expectedRoutingBucket)
    end

    local stateOk, state = pcall(function()
        local entityState = Entity(entity).state

        return {
            managed = entityState.drsGarageManaged,
            plate = entityState.drsGaragePlate,
            rowId = entityState.drsGarageRowId,
            vehicleId = entityState.vehicleid,
            owner = entityState.owner
        }
    end)

    if not stateOk then return false, 'entity identity state could not be read' end

    local plate = normalizePlate(storedVehicle.plate)
    local storedId = tonumber(storedVehicle.id)

    if state.plate ~= nil and normalizePlate(state.plate) ~= plate then
        return false, 'managed plate marker conflicts with the database row'
    end

    if state.rowId ~= nil and (not storedId or tonumber(state.rowId) ~= storedId) then
        return false, 'managed row marker conflicts with the database row'
    end

    if Framework.name == 'qbx_core' and state.vehicleId ~= nil
        and (not storedId or tonumber(state.vehicleId) ~= storedId)
    then
        return false, 'Qbox vehicleid conflicts with the database row'
    end

    local personalOwner = storedVehicle.job == nil or storedVehicle.job == ''
    if Framework.name == 'qbx_core' and personalOwner and state.owner ~= nil
        and tostring(state.owner) ~= tostring(storedVehicle.citizenid)
    then
        return false, 'Qbox owner marker conflicts with the database row'
    end

    local exactManagedMarker = state.managed == true
        and state.plate ~= nil
        and normalizePlate(state.plate) == plate
        and (not storedId or tonumber(state.rowId) == storedId)
    local exactQboxVehicleId = Framework.name == 'qbx_core'
        and storedId ~= nil
        and tonumber(state.vehicleId) == storedId

    if not exactManagedMarker and not exactQboxVehicleId then
        return false, 'entity has no exact server-managed row identity marker'
    end

    return true
end

local function hasConflictingPlateEntity(plate, expectedEntity)
    for _, entity in ipairs(GetAllVehicles()) do
        if entity ~= expectedEntity and DoesEntityExist(entity)
            and normalizePlate(GetVehicleNumberPlateText(entity)) == plate
        then
            return true
        end
    end

    return false
end


---@async
local function moveOutVehiclesIntoGarages(returnMissing)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local outVehicles

    if isQb then
        outVehicles = MySQL.query.await([[
            SELECT *
            FROM player_vehicles
            WHERE `stored` = 0 OR `state` IN (0, 2)
        ]])
    else
        outVehicles = MySQL.query.await([[
            SELECT *
            FROM owned_vehicles
            WHERE `stored` = 0
        ]])
    end

    if type(outVehicles) ~= 'table' then
        error('startup reconciliation vehicle query did not return a table')
    end

    local impoundRecords = loadActiveImpoundRecordMap()
    if impoundRecords == nil then error('startup reconciliation could not load enforcement impound records') end

    local worldVehicles = {}

    for _, entity in ipairs(GetAllVehicles()) do
        if entity and entity ~= 0 and DoesEntityExist(entity) and GetEntityType(entity) == 2 then
            local plate = normalizePlate(GetVehicleNumberPlateText(entity))

            if plate then
                worldVehicles[plate] = worldVehicles[plate] or {}
                worldVehicles[plate][#worldVehicles[plate] + 1] = entity
            end
        end
    end

    local recovered = 0
    local returned = 0
    local preservedImpounds = 0
    local preservedDurableOperations = 0
    local quarantined = 0
    local processedImpoundRecords = {}

    for _, storedVehicle in ipairs(outVehicles) do
        local normalizedPlate = normalizePlate(storedVehicle.plate)
        local impoundRecord = normalizedPlate and impoundRecords[normalizedPlate] or nil
        local impoundRecordMismatch
        if impoundRecord then
            processedImpoundRecords[normalizedPlate] = true
            local recordMatches, mismatchReason = impoundRecordMatchesVehicle(impoundRecord, storedVehicle)
            if not recordMatches then
                impoundRecordMismatch = ('impound record mismatch: %s'):format(mismatchReason)
                impoundRecord = nil
            end
        end
        local legacyPaidDepot = isQb
            and vehicleTableHasColumn('depotprice')
            and (databaseInteger(storedVehicle.depotprice) or 0) > 0
        local candidates = normalizedPlate and worldVehicles[normalizedPlate] or nil
        local matchingEntities = {}

        for _, entity in ipairs(candidates or {}) do
            if DoesEntityExist(entity) then
                local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)

                if hasStoredModel and modelMatches then
                    matchingEntities[#matchingEntities + 1] = entity
                end
            end
        end

        local durableOperationPreserved = normalizedPlate and isDurableOperationPlateBlocked(normalizedPlate)
        local quarantineReason = durableOperationPreserved
            and 'an unresolved contract or fleet journal owns this plate'
            or impoundRecordMismatch

        if #matchingEntities > 1 then
            quarantineReason = quarantineReason or 'multiple live entities match the stored plate/model'
        end

        if #matchingEntities == 0 and #(candidates or {}) > 0 then
            quarantineReason = quarantineReason or 'a live entity uses the stored plate but has a different model'
        end

        local liveEntity = matchingEntities[1]

        if liveEntity and not quarantineReason then
            local trusted, reason = reconciliationCandidateIsTrusted(liveEntity, storedVehicle)
            if not trusted then quarantineReason = reason end
        end

        if liveEntity and not quarantineReason
            and (impoundRecord or legacyPaidDepot or isQb and databaseInteger(storedVehicle.state) == 2)
        then
            if deleteSpawnedVehicle(liveEntity) then
                liveEntity = nil
            else
                quarantineReason = 'an impounded vehicle is still live and could not be deleted'
            end
        end

        if durableOperationPreserved then
            preservedDurableOperations = preservedDurableOperations + 1
            print(('[drs_garages] Preserved plate %s without reconciliation because a contract or fleet journal owns it.'):format(
                normalizedPlate
            ))
        elseif quarantineReason and normalizedPlate then
            vehicleReconciliationQuarantine[normalizedPlate] = quarantineReason
            quarantined = quarantined + 1
            print(('[drs_garages] WARNING: Quarantined plate %s during restart reconciliation: %s. Remove the conflicting entity and restart drs_garages.'):format(
                normalizedPlate,
                tostring(quarantineReason)
            ))
        elseif liveEntity then

            if not applyVehicleIdentityState(liveEntity, storedVehicle) then
                error(('failed to apply managed identity state to recovered plate %s'):format(normalizedPlate))
            end

            activeVehicles[normalizedPlate] = liveEntity

            local storedState = databaseInteger(storedVehicle.stored)
            local qbState = isQb and databaseInteger(storedVehicle.state) or 0
            if storedState ~= 0 or qbState ~= 0 then
                local affected = tonumber(setVehicleStored(normalizedPlate, 0))
                if affected ~= 1 then
                    error(('failed to synchronize live vehicle storage state for plate %s (affected=%s)'):format(
                        normalizedPlate,
                        tostring(affected)
                    ))
                end
            end

            recovered = recovered + 1
        elseif normalizedPlate
            and (impoundRecord or legacyPaidDepot or isQb and databaseInteger(storedVehicle.state) == 2)
        then
            -- DRS records are authoritative across every framework. State 2 is
            -- also the stock QB/Qbox authority-hold state. Never let automatic
            -- restart recovery return either kind of impound to a free garage.
            if isQb and databaseInteger(storedVehicle.stored) ~= 0 then
                local updateOk, affected = pcall(MySQL.update.await, [[
                    UPDATE `player_vehicles`
                    SET `stored` = 0
                    WHERE `plate` = ? AND (`state` = 2 OR `state` = 0)
                    LIMIT 1
                ]], { normalizedPlate })

                if not updateOk or tonumber(affected) ~= 1 then
                    error(('failed to synchronize impounded vehicle %s (affected=%s)'):format(
                        normalizedPlate,
                        tostring(affected)
                    ))
                end
            end

            preservedImpounds = preservedImpounds + 1
        elseif returnMissing and normalizedPlate then
            local affected = tonumber(setVehicleStored(normalizedPlate, 1))
            if affected ~= 1 then
                error(('failed to return missing vehicle %s to storage (affected=%s)'):format(
                    normalizedPlate,
                    tostring(affected)
                ))
            end

            returned = returned + 1
        end
    end

    for plate in pairs(impoundRecords) do
        if not processedImpoundRecords[plate] then
            local reason = 'orphan impound record has no matching out vehicle row'
            vehicleReconciliationQuarantine[plate] = reason
            quarantined = quarantined + 1
            print(('[drs_garages] WARNING: Quarantined plate %s during restart reconciliation: %s. Repair or remove the stale DRS record, then restart drs_garages.'):format(
                plate,
                reason
            ))
        end
    end

    print(('[drs_garages] Restart reconciliation kept %s live vehicle(s) active, returned %s missing vehicle(s) to storage, preserved %s impound row(s), preserved %s durable-operation row(s), and quarantined %s suspicious plate(s).'):format(
        recovered,
        returned,
        preservedImpounds,
        preservedDurableOperations,
        quarantined
    ))

    return recovered, returned, preservedImpounds, preservedDurableOperations, quarantined
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)

    local databaseApi = rawget(_G, 'DRSGaragesDatabase')

    if type(databaseApi) ~= 'table' or type(databaseApi.awaitReady) ~= 'function' then
        startupReconciliationComplete = true
        startupReconciliationSuccessful = false
        startupReconciliationDetail = 'database readiness API is unavailable; startup reconciliation did not run'
        print(('[drs_garages] ERROR: %s.'):format(startupReconciliationDetail))
        return
    end

    local waitOk, databaseReady, databaseDetail = pcall(databaseApi.awaitReady)

    if not waitOk or not databaseReady then
        startupReconciliationComplete = true
        startupReconciliationSuccessful = false
        startupReconciliationDetail = ('database setup did not complete: %s'):format(
            tostring(waitOk and databaseDetail or databaseReady)
        )
        print(('[drs_garages] ERROR: Restart reconciliation failed because %s.'):format(startupReconciliationDetail))
        return
    end

    local guardDeadline = GetGameTimer() + 30000
    while isDurableOperationPlateBlocked('DRSWAIT') and GetGameTimer() < guardDeadline do
        Wait(100)
    end
    if isDurableOperationPlateBlocked('DRSWAIT') then
        startupReconciliationComplete = true
        startupReconciliationSuccessful = false
        startupReconciliationDetail = 'contract/fleet durable-operation guards did not become ready within 30 seconds'
        print(('[drs_garages] ERROR: Restart reconciliation failed because %s.'):format(startupReconciliationDetail))
        return
    end

    activeVehicles = {} -- rebuild the cache from authoritative world/DB state
    vehicleReconciliationQuarantine = {}

    local reconciliationOk, recoveredOrError, returned, preservedImpounds, preservedDurableOperations, quarantined = xpcall(function()
        return moveOutVehiclesIntoGarages(Config.AutoRespawn == true)
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    startupReconciliationComplete = true
    startupReconciliationSuccessful = reconciliationOk == true

    if reconciliationOk then
        startupReconciliationDetail = ('reconciled %d live, %d missing, %d preserved impound, %d preserved durable operation, and %d quarantined vehicle(s)'):format(
            tonumber(recoveredOrError) or 0,
            tonumber(returned) or 0,
            tonumber(preservedImpounds) or 0,
            tonumber(preservedDurableOperations) or 0,
            tonumber(quarantined) or 0
        )
    else
        startupReconciliationDetail = ('startup reconciliation raised an error: %s'):format(tostring(recoveredOrError))
        print(('[drs_garages] ERROR: %s'):format(startupReconciliationDetail))
    end
end)

local function revalidateVehicleListPlayer(source, identifier, job, society)
    local player = Framework.getPlayerFromId(source)
    if not player or player:getIdentifier() ~= identifier then return end

    if society and (not isValidSocietyJobName(job) or player:getJob() ~= job) then return end

    return player
end


lib.callback.register('drs_garages:getOwnedVehicles', function(source, index, society)
    if not databaseIsUsable(source) then return {} end

    society = society == true

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    if society and not isValidSocietyJobName(player:getJob()) then return {} end

    local identifier = player:getIdentifier()
    local job = society and player:getJob() or nil

    local garage = getGarage(index)
    if not garage then
        invalidIndexMessage('garage', source, index)
        return {}
    end

    if not playerCanAccessGarage(player, garage) or not isNearGarage(source, garage) then
        return {}
    end

    if garage.Property and society then
        return {}
    end

    if society then
        local vehicles = MySQL.query.await(Queries.getGarageSociety, {
            job
        }) or {}

        player = revalidateVehicleListPlayer(source, identifier, job, true)
        if not player then return {} end

        vehicles = FilterDrsGarageVehicles(source, index, vehicles, true)

        for _, vehicle in ipairs(vehicles) do
            local plate = normalizePlate(vehicle.plate)

            if not vehicleMatchesOwnershipMode(vehicle, player, true) then
                vehicle.state = nil
            elseif not plate then
                vehicle.state = 'in_impound'
            elseif isVehicleStorageInProgress(plate) then
                vehicle.state = 'out_garage'
            elseif rowHasStorageState(vehicle, 1) then
                vehicle.state = 'in_garage'
            elseif getActiveVehicleByPlate(plate) then
                local entity = activeVehicles[plate]
                if not DoesEntityExist(entity) then
                    activeVehicles[plate] = nil
                    vehicle.state = 'in_impound'
                elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                    vehicle.state = deleteDestroyedActiveVehicle(plate, entity) and 'in_impound' or 'out_garage'
                else
                    vehicle.state = 'out_garage'
                end
            else
                vehicle.state = 'in_impound'
            end
        end

        if not revalidateVehicleListPlayer(source, identifier, job, true) then return {} end

        local authorizedVehicles = {}
        for _, vehicle in ipairs(vehicles) do
            if vehicleMatchesOwnershipMode(vehicle, player, true) and canAccessJobFleetVehicle(source, vehicle) then
                authorizedVehicles[#authorizedVehicles + 1] = vehicle
            end
        end

        return BuildDrsGarageClientVehicles(authorizedVehicles)
    else
        local vehicles = MySQL.query.await(Queries.getGarage, {
            identifier
        }) or {}

        player = revalidateVehicleListPlayer(source, identifier, nil, false)
        if not player then return {} end

        vehicles = FilterDrsGarageVehicles(source, index, vehicles, false)

        for _, vehicle in ipairs(vehicles) do
            local plate = normalizePlate(vehicle.plate)

            if not vehicleMatchesOwnershipMode(vehicle, player, false) then
                vehicle.state = nil
            elseif not plate then
                vehicle.state = 'in_impound'
            elseif isVehicleStorageInProgress(plate) then
                vehicle.state = 'out_garage'
            elseif rowHasStorageState(vehicle, 1) then
                vehicle.state = 'in_garage'
            elseif getActiveVehicleByPlate(plate) then
                local entity = activeVehicles[plate]
                if not DoesEntityExist(entity) then
                    activeVehicles[plate] = nil
                    vehicle.state = 'in_impound'
                elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                    vehicle.state = deleteDestroyedActiveVehicle(plate, entity) and 'in_impound' or 'out_garage'
                else
                    vehicle.state = 'out_garage'
                end
            else
                vehicle.state = 'in_impound'
            end
        end

        if not revalidateVehicleListPlayer(source, identifier, nil, false) then return {} end

        local authorizedVehicles = {}
        for _, vehicle in ipairs(vehicles) do
            if vehicleMatchesOwnershipMode(vehicle, player, false) then authorizedVehicles[#authorizedVehicles + 1] = vehicle end
        end

        return BuildDrsGarageClientVehicles(authorizedVehicles)
    end
end)


lib.callback.register('drs_garages:getImpoundedVehicles', function(source, index, society)
    if not databaseIsUsable(source) then return {} end

    society = society == true

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    if society and not isValidSocietyJobName(player:getJob()) then return {} end

    local identifier = player:getIdentifier()
    local job = society and player:getJob() or nil

    local impound = Config.Impounds[index]
    if not impound then
        invalidIndexMessage('impound', source, index)
        return {}
    end

    if not playerCanAccessGarage(player, impound) or not isNearGarage(source, impound) then
        return {}
    end

    if society then
        local vehicles = MySQL.query.await(Queries.getImpoundSociety, {
            job
        }) or {}

        if not decorateImpoundedVehicles(vehicles) then return {} end

        player = revalidateVehicleListPlayer(source, identifier, job, true)
        if not player then return {} end

        local filtered = {}

        for _, vehicle in ipairs(vehicles) do
            local plate = normalizePlate(vehicle.plate)
            local entity = plate and getActiveVehicleByPlate(plate) or nil

            if not vehicleMatchesOwnershipMode(vehicle, player, true) or not canAccessJobFleetVehicle(source, vehicle) or not plate
                or not rowTypeMatchesGarage(vehicle, impound) or not rowHasStorageState(vehicle, 0)
            then
                -- Invalid/mismatched rows never cross vehicle-type impounds.
            elseif isVehicleStorageInProgress(plate) then
                -- A verified store operation owns this plate until it commits.
            elseif not entity then
                table.insert(filtered, vehicle)
            elseif not DoesEntityExist(entity) then
                activeVehicles[plate] = nil
                table.insert(filtered, vehicle)
            elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                if deleteDestroyedActiveVehicle(plate, entity) then table.insert(filtered, vehicle) end
            end
        end

        if not revalidateVehicleListPlayer(source, identifier, job, true) then return {} end
        return BuildDrsGarageClientVehicles(filtered)
    else
        local vehicles = MySQL.query.await(Queries.getImpound, {
            identifier
        }) or {}

        if not decorateImpoundedVehicles(vehicles) then return {} end

        player = revalidateVehicleListPlayer(source, identifier, nil, false)
        if not player then return {} end

        local filtered = {}

        for _, vehicle in ipairs(vehicles) do
            local plate = normalizePlate(vehicle.plate)
            local entity = plate and getActiveVehicleByPlate(plate) or nil

            if not vehicleMatchesOwnershipMode(vehicle, player, false) or not plate
                or not rowTypeMatchesGarage(vehicle, impound) or not rowHasStorageState(vehicle, 0)
            then
                -- Invalid/mismatched rows never cross vehicle-type impounds.
            elseif isVehicleStorageInProgress(plate) then
                -- A verified store operation owns this plate until it commits.
            elseif not entity then
                table.insert(filtered, vehicle)
            elseif not DoesEntityExist(entity) then
                activeVehicles[plate] = nil
                table.insert(filtered, vehicle)
            elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                if deleteDestroyedActiveVehicle(plate, entity) then table.insert(filtered, vehicle) end
            end
        end

        if not revalidateVehicleListPlayer(source, identifier, nil, false) then return {} end
        return BuildDrsGarageClientVehicles(filtered)
    end
end)

lib.callback.register('drs_garages:takeOutVehicle', function(source, index, plate, type, society)
    if not databaseIsUsable(source) then return end

    society = society == true

    plate = normalizePlate(plate)
    if not plate or isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return end

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    if society and not isValidSocietyJobName(player:getJob()) then return end

    local garage = getGarage(index)
    if not garage then
        invalidIndexMessage('garage', source, index)
        return
    end

    if not playerCanAccessGarage(player, garage) or not isNearGarage(source, garage) or not spawnTypeMatchesGarage(type, garage) then
        return
    end

    if garage.Property and society then
        return
    end

    local token = beginRetrievalOperation(plate, source)
    if not token then return end

    local operationEntity
    local function performTakeout()
    local function finish(...)
        return ...
    end

    local identifier = player:getIdentifier()
    local job = player:getJob()
    local ownershipMode = society and 'society' or 'personal'

    local function revalidateContext()
        local currentPlayer = Framework.getPlayerFromId(source)
        local operation = getRetrievalOperation(plate)

        if not operation or operation.token ~= token or not currentPlayer then return end
        if getGarage(index) ~= garage then return end
        if currentPlayer:getIdentifier() ~= identifier then return end
        if society and currentPlayer:getJob() ~= job then return end
        if garage.Property and society then return end
        if not playerCanAccessGarage(currentPlayer, garage) or not isNearGarage(source, garage) then return end
        if not spawnTypeMatchesGarage(type, garage) then return end

        return currentPlayer
    end

    local vehicle = queryStrictVehicle(player, plate, society == true, true)
    player = revalidateContext()

    if not player or not vehicle or normalizePlate(vehicle.plate) ~= plate then return finish() end
    if not rowHasStorageState(vehicle, 1) or not vehicleMatchesOwnershipMode(vehicle, player, society) then return finish() end
    if society and not canAccessJobFleetVehicle(source, vehicle) then return finish() end
    if not vehicleVisibleAtGarage(vehicle, index, garage, player, society == true) then return finish() end

    -- Claim the exact stored row before creating an entity. A resource/process
    -- crash can then only leave an out/impound-recoverable row, never a stored
    -- row plus a live duplicate.
    local transitioned = transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 1, 0)
    if not transitioned then return finish() end

    local entity, owner, props, cleanupSafe = spawnStoredVehicle(vehicle, garage, plate, type)
    operationEntity = entity
    if not entity then
        if cleanupSafe then transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 0, 1) end
        return finish()
    end

    player = revalidateContext()
    local currentVehicle = player and queryStrictVehicle(player, plate, society == true, false) or nil
    player = revalidateContext()
    local sameId = vehicle.id == nil or currentVehicle and tostring(currentVehicle.id) == tostring(vehicle.id)
    local currentModelMatches, currentHasStoredModel = false, false

    if currentVehicle then
        currentModelMatches, currentHasStoredModel = vehicleMatchesStoredModel(entity, currentVehicle)
    end

    if not player or not currentVehicle or not sameId or not DoesEntityExist(entity)
        or normalizePlate(currentVehicle.plate) ~= plate
        or not rowHasStorageState(currentVehicle, 0)
        or not vehicleMatchesOwnershipMode(currentVehicle, player, society)
        or society and not canAccessJobFleetVehicle(source, currentVehicle)
        or not vehicleVisibleAtGarage(currentVehicle, index, garage, player, society == true)
        or not currentHasStoredModel or not currentModelMatches
        or getActiveVehicleByPlate(plate)
    then
        local existing = getActiveVehicleByPlate(plate)
        local deleted = deleteSpawnedVehicle(entity)

        if deleted and not existing then
            transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 0, 1)
        elseif not deleted and DoesEntityExist(entity) then
            activeVehicles[plate] = entity
        end

        return finish()
    end

    if not DoesEntityExist(entity) then
        transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 0, 1)
        return finish()
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId < 1 then
        local deleted = deleteSpawnedVehicle(entity)
        if deleted then
            transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 0, 1)
        elseif DoesEntityExist(entity) then
            activeVehicles[plate] = entity
        end
        return finish()
    end

    if not applyVehicleIdentityState(entity, currentVehicle) then
        local deleted = deleteSpawnedVehicle(entity)

        if deleted then
            transitionVehicleStorageState(vehicle, ownershipMode, identifier, job, 0, 1)
        elseif DoesEntityExist(entity) then
            activeVehicles[plate] = entity
        end

        return finish()
    end

    activeVehicles[plate] = entity
    TriggerClientEvent('drs_garages:setVehicleProperties', owner, netId, props)
    giveVehicleKeysOrWarn(source, entity, plate)

    return finish(netId)
    end

    local results = table.pack(xpcall(performTakeout, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end))

    if not results[1] then
        local cleanupOk, cleanupError = xpcall(function()
            if operationEntity and DoesEntityExist(operationEntity) then
                if not deleteSpawnedVehicle(operationEntity) then
                    activeVehicles[plate] = operationEntity
                    vehicleReconciliationQuarantine[plate] = 'unexpected takeout failure left a live entity'
                end
            end
        end, function(errorMessage)
            return debug.traceback(errorMessage, 2)
        end)
        if not cleanupOk then
            if operationEntity then
                activeVehicles[plate] = operationEntity
                vehicleReconciliationQuarantine[plate] = 'unexpected takeout cleanup failure may have left a live entity'
            end
            print(('[drs_garages] Unexpected takeout cleanup error for plate %s: %s'):format(plate, tostring(cleanupError)))
        end
        endRetrievalOperation(plate, token)
        print(('[drs_garages] Unexpected takeout error for plate %s: %s'):format(plate, tostring(results[2])))
        return
    end

    endRetrievalOperation(plate, token)
    return table.unpack(results, 2, results.n)
end)

local function inspectParkingVehicle(source, netId, index)
    if not databaseIsUsable(source) then return false, 'database_unavailable' end

    local player = Framework.getPlayerFromId(source)
    local garage = getGarage(index)
    if not player then return false, 'player_not_found' end
    if not garage then return false, 'invalid_garage' end
    if not playerCanAccessGarage(player, garage) then return false, 'garage_access_denied' end
    if not isNearGarageParking(source, garage) then return false, 'player_outside_parking_area' end

    netId = tonumber(netId)
    if not netId or netId < 1 or netId % 1 ~= 0 then return false, 'invalid_net_id' end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'entity_not_found'
    end

    local plate = normalizePlate(GetVehicleNumberPlateText(entity))
    local model = normalizeModelHash(GetEntityModel(entity))
    if not plate or not model then return false, 'invalid_vehicle_data' end
    if isVehicleStorageInProgress(plate) then return false, 'storage_in_progress' end

    local validationReason
    entity, validationReason = validateVehicleForStorage(source, garage, netId, plate, model)
    if not entity then return false, validationReason or 'vehicle_validation_failed' end

    local registeredEntity = getActiveVehicleByPlate(plate)
    if registeredEntity and registeredEntity ~= entity then return false, 'active_vehicle_mismatch' end
    if hasConflictingPlateEntity(plate, entity) then return false, 'duplicate_plate_entity' end

    local identifier = player:getIdentifier()
    local initialJob = player:getJob()
    local ownershipMode = 'personal'
    local ownershipJob

    local function revalidate(expectedEntity)
        local currentPlayer = Framework.getPlayerFromId(source)
        if not currentPlayer or currentPlayer:getIdentifier() ~= identifier then
            return nil, nil, 'parking_context_changed'
        end
        if getGarage(index) ~= garage then return nil, nil, 'parking_context_changed' end
        if ownershipMode == 'society' and currentPlayer:getJob() ~= ownershipJob then
            return nil, nil, 'parking_context_changed'
        end
        if not playerCanAccessGarage(currentPlayer, garage) or not isNearGarageParking(source, garage) then
            return nil, nil, 'parking_context_changed'
        end
        if isVehicleStorageInProgress(plate) then return nil, nil, 'storage_in_progress' end

        local currentEntity, currentReason = validateVehicleForStorage(
            source,
            garage,
            netId,
            plate,
            model,
            expectedEntity
        )
        if not currentEntity then return nil, nil, currentReason or 'vehicle_validation_failed' end

        local currentRegistered = getActiveVehicleByPlate(plate)
        if currentRegistered and currentRegistered ~= currentEntity then
            return nil, nil, 'active_vehicle_mismatch'
        end
        if hasConflictingPlateEntity(plate, currentEntity) then
            return nil, nil, 'duplicate_plate_entity'
        end

        return currentPlayer, currentEntity
    end

    local storedVehicle = MySQL.single.await(Queries.getVehicleStrict, { identifier, plate })
    player, entity, validationReason = revalidate(entity)
    if not player then return false, validationReason end

    if not storedVehicle then
        if garage.Property or not isValidSocietyJobName(initialJob) or player:getJob() ~= initialJob then
            return false, 'vehicle_not_owned'
        end

        ownershipMode = 'society'
        ownershipJob = initialJob
        storedVehicle = MySQL.single.await(Queries.getVehicleJobStrict, { ownershipJob, plate })
        player, entity, validationReason = revalidate(entity)
        if not player then return false, validationReason end
        if not storedVehicle then return false, 'vehicle_not_owned' end
    end

    local storedIdentifier = Framework.name == 'es_extended' and storedVehicle.owner or storedVehicle.citizenid
    if normalizePlate(storedVehicle.plate) ~= plate then return false, 'vehicle_identity_mismatch' end

    if ownershipMode == 'personal' then
        if storedIdentifier ~= identifier or storedVehicle.job ~= nil then return false, 'vehicle_not_owned' end
    elseif storedVehicle.job ~= ownershipJob then
        return false, 'vehicle_not_owned'
    end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)
    if not hasStoredModel or not modelMatches then return false, 'vehicle_identity_mismatch' end
    if not rowTypeMatchesGarage(storedVehicle, garage) then return false, 'vehicle_type_mismatch' end
    if not rowHasStorageState(storedVehicle, 0) then return false, 'vehicle_state_changed' end

    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        if databaseInteger(storedVehicle.state) ~= 0 then return false, 'vehicle_state_changed' end
    end

    registeredEntity = getActiveVehicleByPlate(plate)
    if registeredEntity and registeredEntity ~= entity then return false, 'active_vehicle_mismatch' end
    if not registeredEntity then
        local trusted = reconciliationCandidateIsTrusted(entity, storedVehicle)
        if not trusted then return false, 'active_vehicle_untrusted' end
    end

    return true
end

lib.callback.register('drs_garages:inspectParkingVehicle', function(source, netId, index)
    local now = GetGameTimer()
    if parkingInspectionOperations[source]
        or now < (parkingInspectionCooldowns[source] or 0)
    then
        return false, 'storage_in_progress'
    end

    local inspectionToken = {}
    parkingInspectionOperations[source] = inspectionToken
    local inspectionOk, eligible, reason = xpcall(function()
        return inspectParkingVehicle(source, netId, index)
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)
    if parkingInspectionOperations[source] == inspectionToken then
        parkingInspectionOperations[source] = nil
        parkingInspectionCooldowns[source] = GetGameTimer() + PARKING_INSPECTION_COOLDOWN
    end

    if inspectionOk then return eligible, reason end

    print(('[drs_garages] Unexpected parking inspection error for source %s: %s'):format(
        tostring(source),
        tostring(eligible)
    ))
    return false, 'database_unavailable'
end)

lib.callback.register('drs_garages:saveVehicle', function(source, props, netId, index, spawnType)
    local parkingPlate = 'unknown'
    local function reject(reason)
        print(('[drs_garages] Parking rejected for source %s, plate %s: %s'):format(
            tostring(source),
            parkingPlate,
            tostring(reason or 'parking_rejected')
        ))
        return false, reason
    end

    if not databaseIsUsable(source) then return reject('database_unavailable') end

    local player = Framework.getPlayerFromId(source)
    if not player then return reject('player_not_found') end
    local garage = getGarage(index)
    if not garage then
        invalidIndexMessage('garage', source, index)
        return reject('invalid_garage')
    end

    if not playerCanAccessGarage(player, garage) then return reject('garage_access_denied') end
    if not isNearGarageParking(source, garage) then return reject('player_outside_parking_area') end
    if not spawnTypeMatchesGarage(spawnType, garage) then return reject('vehicle_type_mismatch') end

    if type(props) ~= 'table' then return reject('invalid_vehicle_data') end

    local plate = normalizePlate(props.plate)
    local model = normalizeModelHash(props.model)
    parkingPlate = plate or 'invalid'

    if not plate or not model then return reject('invalid_vehicle_data') end
    if isVehicleStorageInProgress(plate) then return reject('storage_in_progress') end

    local entity, validationReason = validateVehicleForStorage(source, garage, netId, plate, model)
    if not entity then return reject(validationReason or 'vehicle_validation_failed') end

    local registeredEntity = getActiveVehicleByPlate(plate)
    if registeredEntity and registeredEntity ~= entity then return reject('active_vehicle_mismatch') end
    local activeMappingNeedsRecovery = registeredEntity == nil

    -- Reserve before the first database yield so ownership contracts and other
    -- storage flows cannot transfer or replace this plate mid-save.
    vehicleStorageOperations[plate] = entity

    local function performSave()

    local identifier = player:getIdentifier()
    local initialJob = player:getJob()
    local ownershipMode = 'personal'
    local ownershipJob

    local function revalidateOwnershipContext()
        local currentPlayer = Framework.getPlayerFromId(source)

        if not currentPlayer or currentPlayer:getIdentifier() ~= identifier then return end
        if getGarage(index) ~= garage then return end
        if ownershipMode == 'society' and (garage.Property or currentPlayer:getJob() ~= ownershipJob) then return end
        if not playerCanAccessGarage(currentPlayer, garage) or not isNearGarageParking(source, garage) then return end
        if not spawnTypeMatchesGarage(spawnType, garage) then return end

        return currentPlayer
    end

    local function revalidateContext(expectedEntity, allowUnregistered)
        local currentPlayer = revalidateOwnershipContext()
        if not currentPlayer then return nil, nil, 'parking_context_changed' end

        local currentEntity, currentValidationReason = validateVehicleForStorage(
            source,
            garage,
            netId,
            plate,
            model,
            expectedEntity
        )

        if not currentEntity then return nil, nil, currentValidationReason or 'vehicle_validation_failed' end

        local currentRegisteredEntity = getActiveVehicleByPlate(plate)
        if allowUnregistered then
            if currentRegisteredEntity and currentRegisteredEntity ~= currentEntity then
                return nil, nil, 'active_vehicle_mismatch'
            end
        elseif currentRegisteredEntity ~= currentEntity then
            return nil, nil, 'active_vehicle_mismatch'
        end

        return currentPlayer, currentEntity
    end

    -- Personal ownership always wins. Society ownership is considered only when
    -- no strict personal row exists and the destination is not a property garage.
    local storedVehicle = MySQL.single.await(Queries.getVehicleStrict, { identifier, plate })

    local contextReason
    player, entity, contextReason = revalidateContext(entity, activeMappingNeedsRecovery)
    if not player then return reject(contextReason) end

    if not storedVehicle then
        if garage.Property or not isValidSocietyJobName(initialJob) or player:getJob() ~= initialJob then
            return reject('vehicle_not_owned')
        end

        ownershipMode = 'society'
        ownershipJob = initialJob
        storedVehicle = MySQL.single.await(Queries.getVehicleJobStrict, { ownershipJob, plate })

        player, entity, contextReason = revalidateContext(entity, activeMappingNeedsRecovery)
        if not player then return reject(contextReason) end
        if not storedVehicle then return reject('vehicle_not_owned') end
    end

    local storedIdentifier = Framework.name == 'es_extended' and storedVehicle.owner or storedVehicle.citizenid

    if normalizePlate(storedVehicle.plate) ~= plate then return reject('vehicle_identity_mismatch') end

    if ownershipMode == 'personal' then
        if storedIdentifier ~= identifier or storedVehicle.job ~= nil then return reject('vehicle_not_owned') end
    elseif storedVehicle.job ~= ownershipJob then
        return reject('vehicle_not_owned')
    end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)
    if not hasStoredModel or not modelMatches then return reject('vehicle_identity_mismatch') end
    if not rowTypeMatchesGarage(storedVehicle, garage) then return reject('vehicle_type_mismatch') end

    if not rowHasStorageState(storedVehicle, 0) then return reject('vehicle_state_changed') end
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    if isQb and databaseInteger(storedVehicle.state) ~= 0 then return reject('vehicle_state_changed') end
    if hasConflictingPlateEntity(plate, entity) then return reject('duplicate_plate_entity') end

    if activeMappingNeedsRecovery then
        local currentRegisteredEntity = getActiveVehicleByPlate(plate)
        if currentRegisteredEntity and currentRegisteredEntity ~= entity then
            return reject('active_vehicle_mismatch')
        end

        local identityTrusted, identityReason = reconciliationCandidateIsTrusted(entity, storedVehicle)
        if not identityTrusted then
            print(('[drs_garages] Parking could not restore the active mapping for plate %s: %s'):format(
                plate,
                tostring(identityReason)
            ))
            return reject('active_vehicle_untrusted')
        end

        -- Qbox semi persistence can replace a culled entity while retaining its
        -- server-owned vehicleid. Re-adopt only this exact owned row after the
        -- duplicate, state, model, plate, and identity checks above all pass.
        activeVehicles[plate] = entity
        activeMappingNeedsRecovery = false
    end

    local trustedProps = buildTrustedParkingProperties(storedVehicle, entity, plate)
    if not trustedProps then return reject('vehicle_properties_invalid') end

    local encodedOk, encodedProps = pcall(json.encode, trustedProps)
    if not encodedOk or type(encodedProps) ~= 'string' then return reject('vehicle_properties_invalid') end

    local maxPropsBytes = tonumber(Config.MaxVehiclePropsBytes)
    if not maxPropsBytes or maxPropsBytes ~= maxPropsBytes or maxPropsBytes <= 0 then
        maxPropsBytes = 64 * 1024
    end

    maxPropsBytes = math.floor(maxPropsBytes)
    if #encodedProps > maxPropsBytes then return reject('vehicle_properties_too_large') end

    local garageName = garageStorageName(index, garage)
    if isQb and not garageName then return reject('invalid_garage_storage') end

    local tableName = isQb and 'player_vehicles' or 'owned_vehicles'
    local ownershipWhere
    local ownershipParams = {}

    if storedVehicle.id ~= nil then
        ownershipWhere = '`id` = ? AND '
        ownershipParams[#ownershipParams + 1] = storedVehicle.id
    else
        ownershipWhere = ''
    end

    if ownershipMode == 'personal' then
        ownershipWhere = ownershipWhere .. (isQb and '`citizenid` = ?' or '`owner` = ?')
            .. ' AND `plate` = ? AND `job` IS NULL'
        ownershipParams[#ownershipParams + 1] = identifier
        ownershipParams[#ownershipParams + 1] = plate
    else
        ownershipWhere = ownershipWhere .. '`job` = ? AND `plate` = ?'
        ownershipParams[#ownershipParams + 1] = ownershipJob
        ownershipParams[#ownershipParams + 1] = plate
    end

    ownershipWhere = ownershipWhere .. ' AND `stored` = 0'
    if isQb then ownershipWhere = ownershipWhere .. ' AND `state` = 0' end

    local function scopedUpdate(setClause, setParams)
        for i = 1, #ownershipParams do
            setParams[#setParams + 1] = ownershipParams[i]
        end

        return ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, setClause, ownershipWhere), setParams
    end

    local updateQuery, updateParams

    if isQb then
        local parkingSetClause = '`stored` = 1, `state` = 1, `garage` = ?, `mods` = ?'
        if vehicleTableHasColumn('depotprice') then parkingSetClause = parkingSetClause .. ', `depotprice` = 0' end
        updateQuery, updateParams = scopedUpdate(
            parkingSetClause,
            { garageName, encodedProps }
        )
    else
        updateQuery, updateParams = scopedUpdate(
            '`stored` = 1, `vehicle` = ?',
            { encodedProps }
        )
    end

    -- The row must still describe an out vehicle. Deleting first means a failed
    -- deletion cannot alter its state or client-supplied properties at all.
    if vehicleStorageOperations[plate] ~= entity or not isExactActiveVehicle(plate, entity) then
        return reject('active_vehicle_mismatch')
    end

    local deleted = deleteRegisteredVehicle(source, plate, entity, netId)

    if not deleted then
        -- Internal listing/unregister paths honor the operation lock. Repair the
        -- exact mapping defensively if the original entity is still trustworthy.
        if DoesEntityExist(entity)
            and NetworkGetNetworkIdFromEntity(entity) == netId
            and normalizePlate(GetVehicleNumberPlateText(entity)) == plate
            and normalizeModelHash(GetEntityModel(entity)) == model
        then
            activeVehicles[plate] = entity
        end

        return reject('vehicle_delete_failed')
    end

    -- Deletion polling yields. Revalidate the selected personal/society session
    -- before committing the now-absent vehicle to storage.
    player = revalidateOwnershipContext()
    if not player or vehicleStorageOperations[plate] ~= entity or activeVehicles[plate] ~= entity then
        if activeVehicles[plate] == entity then activeVehicles[plate] = nil end
        return reject('parking_context_changed')
    end

    local updateOk, changed = pcall(MySQL.update.await, updateQuery, updateParams)

    -- The update yields as well; preserve the chosen identity/job check before
    -- releasing the reservation. A failed update leaves the deleted row out so it
    -- remains recoverable from impound rather than duplicating a live vehicle.
    revalidateOwnershipContext()

    local changedCount = tonumber(changed)
    local stored = updateOk and changedCount == 1

    if activeVehicles[plate] == entity then activeVehicles[plate] = nil end

    if not stored then return reject('database_update_failed') end
    return true
    end

    local operationOk, result, reason = xpcall(performSave, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    if activeVehicles[plate] == entity and not DoesEntityExist(entity) then
        activeVehicles[plate] = nil
    end

    if vehicleStorageOperations[plate] == entity then vehicleStorageOperations[plate] = nil end

    if not operationOk then
        print(('[drs_garages] Unexpected parking error for plate %s: %s'):format(plate, tostring(result)))
        return reject('unexpected_error')
    end

    if result == true then return true end
    return false, reason or 'parking_rejected'
end)

local function normalizeImpoundReason(value)
    if type(value) == 'string' then
        value = value:gsub('[\r\n\t]+', ' '):gsub(' +', ' ')
    end
    local reason = sanitizedText(value)
    if not reason then return end

    local settings = getEnforcementImpoundConfig()
    local minimum = math.max(1, math.floor(tonumber(settings.MinimumReasonLength) or 3))
    local maximum = math.min(500, math.max(minimum, math.floor(tonumber(settings.MaximumReasonLength) or 200)))
    local length = utf8 and utf8.len and utf8.len(reason) or nil
    if not length or length < minimum or length > maximum then return end

    return reason
end

local function generateImpoundId(source, plate, officerIdentifier)
    local seed = ('%s|%s|%s|%s|%s'):format(
        tostring(os.time()),
        tostring(GetGameTimer()),
        tostring(source),
        tostring(plate),
        tostring(officerIdentifier)
    )

    return ('%08x-%s-%s'):format(
        os.time() % UINT32,
        stableHash(seed),
        stableHash(('%s|%s'):format(seed:reverse(), math.random(0, 0x7fffffff)))
    )
end

local function queryVehicleByPlate(plate)
    local tableName = Framework.name == 'es_extended' and 'owned_vehicles' or 'player_vehicles'
    local ok, vehicle = pcall(MySQL.single.await, ('SELECT * FROM `%s` WHERE `plate` = ? LIMIT 1'):format(tableName), { plate })
    if not ok then
        print(('[drs_garages] Vehicle lookup failed during enforcement impound for plate %s: %s'):format(plate, tostring(vehicle)))
        return nil, false
    end

    return vehicle, true
end

local function queryVehicleByRowId(rowId)
    rowId = tonumber(rowId)
    if not rowId or rowId < 1 or rowId % 1 ~= 0 then return nil, true end

    local tableName = Framework.name == 'es_extended' and 'owned_vehicles' or 'player_vehicles'
    local ok, vehicle = pcall(MySQL.single.await, ('SELECT * FROM `%s` WHERE `id` = ? LIMIT 1'):format(tableName), { rowId })
    if not ok then
        print(('[drs_garages] Vehicle row lookup failed during ambient classification for id %s: %s'):format(
            tostring(rowId),
            tostring(vehicle)
        ))
        return nil, false
    end

    return vehicle, true
end

local function readEnforcementEntityMarkers(entity)
    local ok, markers = pcall(function()
        local state = Entity(entity).state
        return {
            managed = state.drsGarageManaged,
            plate = state.drsGaragePlate,
            rowId = state.drsGarageRowId,
            vehicleId = state.vehicleid,
            owner = state.owner,
            persisted = state.persisted
        }
    end)

    if not ok then return nil, false end
    return markers, true
end

local function ambientPopulationTypeAllowed(entity)
    local settings = getAmbientImpoundConfig()
    if settings.Enabled ~= true then return false end

    local ok, populationType = pcall(GetEntityPopulationType, entity)
    populationType = ok and tonumber(populationType) or nil
    if not populationType then return false end
    populationType = math.floor(populationType)

    local allowed = type(settings.AllowedPopulationTypes) == 'table'
        and settings.AllowedPopulationTypes
        or { 1, 2, 3, 4, 5 }

    for key, value in pairs(allowed) do
        local configuredType
        if type(value) == 'boolean' then
            if value then configuredType = tonumber(key) end
        else
            configuredType = tonumber(value)
        end

        if configuredType and configuredType % 1 == 0 and configuredType >= 1 and configuredType <= 5
            and configuredType == populationType
        then
            return true
        end
    end

    return false
end

local function classifyEnforcementVehicle(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return nil, nil, 'vehicle_not_managed'
    end

    local plate = normalizePlate(GetVehicleNumberPlateText(entity))
    local storedVehicle
    if plate then
        local vehicleRead
        storedVehicle, vehicleRead = queryVehicleByPlate(plate)
        if not vehicleRead then return nil, nil, 'database_unavailable' end
        if storedVehicle then return 'owned', storedVehicle end
    end

    local markers, markersRead = readEnforcementEntityMarkers(entity)
    if not markersRead then return nil, nil, 'vehicle_not_managed' end

    local markedRowId = tonumber(markers.rowId) or tonumber(markers.vehicleId)
    if markedRowId then
        local markedVehicle, markedRead = queryVehicleByRowId(markedRowId)
        if not markedRead then return nil, nil, 'database_unavailable' end
        if markedVehicle then return 'owned', markedVehicle end
    end

    local hasManagedMarker = markers.managed == true
        or markers.plate ~= nil
        or markers.rowId ~= nil
        or markers.vehicleId ~= nil
        or markers.owner ~= nil
        or markers.persisted == true
    if hasManagedMarker then return nil, nil, 'vehicle_not_managed' end

    if plate then
        local record, recordRead = getActiveImpoundRecord(plate)
        if not recordRead then return nil, nil, 'database_unavailable' end
        if record then return nil, nil, 'impound_already_recorded' end
        if getActiveVehicleByPlate(plate) or isVehicleStorageInProgress(plate) then
            return nil, nil, 'storage_in_progress'
        end
    end

    if not ambientPopulationTypeAllowed(entity) then return nil, nil, 'vehicle_not_ambient' end
    return 'ambient'
end

local function buildExactVehicleWhere(vehicle, alias)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local where = {}
    local params = {}
    local prefix = alias and ('`%s`.'):format(alias) or ''
    local function column(name)
        return ('%s`%s`'):format(prefix, name)
    end

    if vehicle.id ~= nil then
        where[#where + 1] = column('id') .. ' = ?'
        params[#params + 1] = vehicle.id
    end

    where[#where + 1] = column('plate') .. ' = ?'
    params[#params + 1] = normalizePlate(vehicle.plate)

    if vehicle.job ~= nil and vehicle.job ~= '' then
        where[#where + 1] = column('job') .. ' = ?'
        params[#params + 1] = vehicle.job
    else
        where[#where + 1] = column('job') .. ' IS NULL'
        where[#where + 1] = (isQb and column('citizenid') or column('owner')) .. ' = ?'
        params[#params + 1] = isQb and vehicle.citizenid or vehicle.owner
    end

    return table.concat(where, ' AND '), params
end

local function appendValues(target, values)
    for index = 1, #values do target[#target + 1] = values[index] end
    return target
end

local function rollbackEnforcementImpound(vehicle, impoundId, committedProperties)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local tableName = isQb and 'player_vehicles' or 'owned_vehicles'
    local propertiesColumn = isQb and 'mods' or 'vehicle'
    if type(committedProperties) ~= 'string' or committedProperties == '' then return false end

    local where, whereParams = buildExactVehicleWhere(vehicle)
    local setClause
    local params

    if isQb then
        setClause = '`stored` = 0, `state` = 0, `mods` = ?'
        params = { vehicle.mods }
        if vehicleTableHasColumn('depotprice') then
            setClause = setClause .. ', `depotprice` = ?'
            params[#params + 1] = math.max(0, math.floor(tonumber(vehicle.depotprice) or 0))
        end
        where = where .. ' AND `stored` = 0 AND `state` = 2 AND BINARY `mods` = BINARY ?'
    else
        setClause = '`stored` = 0, `vehicle` = ?'
        params = { vehicle.vehicle }
        where = where .. ' AND `stored` = 0 AND BINARY `vehicle` = BINARY ?'
    end
    whereParams[#whereParams + 1] = committedProperties

    appendValues(params, whereParams)
    local transactionOk, rolledBack = pcall(MySQL.transaction.await, {
        {
            query = ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, setClause, where),
            values = params
        },
        {
            query = ImpoundQueries.deleteExactAfterChangedRow,
            values = { impoundId, normalizePlate(vehicle.plate) }
        }
    })

    if not transactionOk or rolledBack ~= true then return false end

    local currentVehicle, vehicleRead = queryVehicleByPlate(vehicle.plate)
    local currentRecord, recordRead = getActiveImpoundRecord(vehicle.plate)
    local outState = currentVehicle and databaseInteger(currentVehicle.stored) == 0
        and (not isQb or databaseInteger(currentVehicle.state) == 0)
        and currentVehicle[propertiesColumn] == vehicle[propertiesColumn]
        and (not isQb or not vehicleTableHasColumn('depotprice')
            or databaseInteger(currentVehicle.depotprice) == math.max(0, math.floor(tonumber(vehicle.depotprice) or 0)))

    return vehicleRead and recordRead and outState and currentRecord == nil
end

local function prepareImpoundReleaseProperties(vehicle, record)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local column = isQb and 'mods' or 'vehicle'
    local impoundedProperties = vehicle and vehicle[column]
    if type(impoundedProperties) ~= 'string' or impoundedProperties == '' then return end

    local decodedOk, releasedProps = pcall(json.decode, impoundedProperties)
    if not decodedOk or type(releasedProps) ~= 'table'
        or sanitizedText(releasedProps._drsImpoundId, 64) ~= record.impound_id
    then
        return
    end

    releasedProps._drsImpoundId = nil
    releasedProps._drsReleaseId = generateImpoundId(0, record.plate, 'release')
    local encodedOk, releasedProperties = pcall(json.encode, releasedProps)
    local maximumPropsBytes = math.max(1, math.floor(tonumber(Config.MaxVehiclePropsBytes) or 64 * 1024))
    if not encodedOk or type(releasedProperties) ~= 'string' or #releasedProperties > maximumPropsBytes then return end

    return column, impoundedProperties, releasedProperties
end

local function commitRecordedImpoundRelease(vehicle, record)
    local recordMatches = impoundRecordMatchesVehicle(record, vehicle)
    local recordFee = tonumber(record and record.fee)
    if not recordMatches or record.release_mode ~= 'payable'
        or not recordFee or recordFee ~= recordFee or recordFee == math.huge or recordFee == -math.huge
        or recordFee < 0 or recordFee % 1 ~= 0
    then
        return nil, false
    end
    recordFee = math.floor(recordFee)

    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    if isQb and databaseInteger(vehicle.state) ~= 2 then return nil, false end

    local column, impoundedProperties, releasedProperties = prepareImpoundReleaseProperties(vehicle, record)
    if not column then return nil, false end

    local previousDepotPrice = isQb and vehicleTableHasColumn('depotprice')
        and math.max(0, math.floor(tonumber(vehicle.depotprice) or 0))
        or nil
    local tableName = isQb and 'player_vehicles' or 'owned_vehicles'
    local vehicleAlias = 'vehicle_row'
    local impoundAlias = 'impound_row'
    local where, whereParams = buildExactVehicleWhere(vehicle, vehicleAlias)
    local setClause
    local updateParams = { releasedProperties }

    if isQb then
        setClause = vehicleTableHasColumn('depotprice')
            and ('`%s`.`mods` = ?, `%s`.`state` = 0, `%s`.`depotprice` = 0'):format(vehicleAlias, vehicleAlias, vehicleAlias)
            or ('`%s`.`mods` = ?, `%s`.`state` = 0'):format(vehicleAlias, vehicleAlias)
        where = where .. (' AND `%s`.`stored` = 0 AND `%s`.`state` = 2 AND BINARY `%s`.`mods` = BINARY ?'):format(
            vehicleAlias,
            vehicleAlias,
            vehicleAlias
        )
    else
        setClause = ('`%s`.`vehicle` = ?'):format(vehicleAlias)
        where = where .. (' AND `%s`.`stored` = 0 AND BINARY `%s`.`vehicle` = BINARY ?'):format(vehicleAlias, vehicleAlias)
    end

    appendValues(updateParams, whereParams)
    updateParams[#updateParams + 1] = impoundedProperties
    local joinedUpdateParams = {
        record.impound_id,
        record.plate,
        record.vehicle_row_id,
        record.ownership_type,
        record.owner_key,
        recordFee
    }
    appendValues(joinedUpdateParams, updateParams)

    local releasedAlias = 'released_vehicle'
    local deleteAlias = 'impound_delete'
    local deleteWhere, deleteWhereParams = buildExactVehicleWhere(vehicle, releasedAlias)
    if isQb then
        deleteWhere = deleteWhere
            .. (' AND `%s`.`stored` = 0 AND `%s`.`state` = 0 AND BINARY `%s`.`mods` = BINARY ?'):format(
                releasedAlias,
                releasedAlias,
                releasedAlias
            )
    else
        deleteWhere = deleteWhere
            .. (' AND `%s`.`stored` = 0 AND BINARY `%s`.`vehicle` = BINARY ?'):format(releasedAlias, releasedAlias)
    end

    local exactDeleteParams = {
        record.impound_id,
        record.plate,
        record.vehicle_row_id,
        record.ownership_type,
        record.owner_key,
        recordFee
    }
    appendValues(exactDeleteParams, deleteWhereParams)
    exactDeleteParams[#exactDeleteParams + 1] = releasedProperties

    local transactionOk, committed = pcall(MySQL.transaction.await, {
        {
            query = ([=[
                UPDATE `%s` AS `%s`
                INNER JOIN `drs_vehicle_impounds` AS `%s`
                    ON BINARY `%s`.`impound_id` = BINARY ?
                   AND BINARY `%s`.`plate` = BINARY ?
                   AND BINARY `%s`.`vehicle_row_id` = BINARY ?
                   AND BINARY `%s`.`ownership_type` = BINARY ?
                   AND BINARY `%s`.`owner_key` = BINARY ?
                   AND BINARY `%s`.`release_mode` = BINARY 'payable'
                   AND `%s`.`fee` = ?
                   AND BINARY `%s`.`plate` = BINARY UPPER(TRIM(`%s`.`plate`))
                SET %s
                WHERE %s
            ]=]):format(
                tableName,
                vehicleAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                impoundAlias,
                vehicleAlias,
                setClause,
                where
            ),
            values = joinedUpdateParams
        },
        {
            -- The freshly generated release marker couples deletion to this
            -- exact vehicle transition without depending on connector-specific
            -- affected-row counting for a joined UPDATE.
            query = ([=[
                DELETE `%s`
                FROM `drs_vehicle_impounds` AS `%s`
                INNER JOIN `%s` AS `%s`
                    ON BINARY `%s`.`plate` = BINARY UPPER(TRIM(`%s`.`plate`))
                WHERE BINARY `%s`.`impound_id` = BINARY ?
                  AND BINARY `%s`.`plate` = BINARY ?
                  AND BINARY `%s`.`vehicle_row_id` = BINARY ?
                  AND BINARY `%s`.`ownership_type` = BINARY ?
                  AND BINARY `%s`.`owner_key` = BINARY ?
                  AND BINARY `%s`.`release_mode` = BINARY 'payable'
                  AND `%s`.`fee` = ?
                  AND %s
            ]=]):format(
                deleteAlias,
                deleteAlias,
                tableName,
                releasedAlias,
                deleteAlias,
                releasedAlias,
                deleteAlias,
                deleteAlias,
                deleteAlias,
                deleteAlias,
                deleteAlias,
                deleteAlias,
                deleteAlias,
                deleteWhere
            ),
            values = exactDeleteParams
        }
    })
    if not transactionOk or committed ~= true then return nil, false end

    local releasedVehicle, vehicleRead = queryVehicleByPlate(record.plate)
    local currentRecord, recordRead = getActiveImpoundRecord(record.plate)
    local sameVehicle = vehicleRead and vehicleRowsShareIdentity(vehicle, releasedVehicle)
    local releaseApplied = sameVehicle
        and databaseInteger(releasedVehicle.stored) == 0
        and (not isQb or databaseInteger(releasedVehicle.state) == 0)
        and releasedVehicle[column] == releasedProperties
        and (not isQb or not vehicleTableHasColumn('depotprice') or databaseInteger(releasedVehicle.depotprice) == 0)
    local recordDeleted = recordRead and currentRecord == nil

    local function verifyRestored()
        local restoredVehicle, restoredVehicleRead = queryVehicleByPlate(record.plate)
        local restoredRecord, restoredRecordRead = getActiveImpoundRecord(record.plate)
        local restoredMatches = restoredVehicleRead and restoredRecordRead
            and vehicleRowsShareIdentity(vehicle, restoredVehicle)
            and restoredVehicle[column] == impoundedProperties
            and databaseInteger(restoredVehicle.stored) == 0
            and (not isQb or databaseInteger(restoredVehicle.state) == 2)
            and (not isQb or not vehicleTableHasColumn('depotprice')
                or databaseInteger(restoredVehicle.depotprice) == previousDepotPrice)
            and restoredRecord and restoredRecord.impound_id == record.impound_id
            and impoundRecordMatchesVehicle(restoredRecord, restoredVehicle) == true

        return restoredMatches == true
    end

    local function rollbackRelease()
        local beforeRecord, beforeRecordRead = getActiveImpoundRecord(record.plate)
        if not beforeRecordRead or beforeRecord and beforeRecord.impound_id ~= record.impound_id then return false end

        if beforeRecord then
            local beforeVehicle, beforeVehicleRead = queryVehicleByPlate(record.plate)
            local alreadyRestored = beforeVehicleRead
                and vehicleRowsShareIdentity(vehicle, beforeVehicle)
                and beforeVehicle[column] == impoundedProperties
                and databaseInteger(beforeVehicle.stored) == 0
                and (not isQb or databaseInteger(beforeVehicle.state) == 2)
                and impoundRecordMatchesVehicle(beforeRecord, beforeVehicle) == true
            if alreadyRestored then return true end
        end

        local rollbackWhere, rollbackWhereParams = buildExactVehicleWhere(vehicle)
        local rollbackSetClause
        local rollbackParams = { impoundedProperties }

        if isQb then
            rollbackSetClause = vehicleTableHasColumn('depotprice')
                and '`mods` = ?, `state` = 2, `depotprice` = ?'
                or '`mods` = ?, `state` = 2'
            if vehicleTableHasColumn('depotprice') then rollbackParams[#rollbackParams + 1] = previousDepotPrice end
            rollbackWhere = rollbackWhere .. ' AND `stored` = 0 AND `state` = 0 AND BINARY `mods` = BINARY ?'
        else
            rollbackSetClause = '`vehicle` = ?'
            rollbackWhere = rollbackWhere .. ' AND `stored` = 0 AND BINARY `vehicle` = BINARY ?'
        end

        if beforeRecord then
            rollbackWhere = rollbackWhere
                .. ' AND EXISTS (SELECT 1 FROM `drs_vehicle_impounds` WHERE `impound_id` = ? AND `plate` = ?)'
        end

        appendValues(rollbackParams, rollbackWhereParams)
        rollbackParams[#rollbackParams + 1] = releasedProperties
        if beforeRecord then
            rollbackParams[#rollbackParams + 1] = record.impound_id
            rollbackParams[#rollbackParams + 1] = record.plate
        end

        local rollbackOk, rolledBack
        if beforeRecord then
            rollbackOk, rolledBack = pcall(MySQL.update.await,
                ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, rollbackSetClause, rollbackWhere),
                rollbackParams
            )
            rollbackOk = rollbackOk and tonumber(rolledBack) == 1
        else
            rollbackOk, rolledBack = pcall(MySQL.transaction.await, {
                {
                    query = ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, rollbackSetClause, rollbackWhere),
                    values = rollbackParams
                },
                {
                    query = ImpoundQueries.insertAfterChangedRow,
                    values = impoundRecordValues(record)
                }
            })
            rollbackOk = rollbackOk and rolledBack == true
        end

        return rollbackOk and verifyRestored()
    end

    local noChange = sameVehicle
        and releasedVehicle[column] == impoundedProperties
        and databaseInteger(releasedVehicle.stored) == 0
        and (not isQb or databaseInteger(releasedVehicle.state) == 2)
        and currentRecord and currentRecord.impound_id == record.impound_id

    return {
        vehicle = releasedVehicle,
        rollback = noChange and function() return true end or rollbackRelease
    }, releaseApplied and recordDeleted
end

local function enforcementSourceStillAuthorized(source, identifier, authorization)
    local player = Framework.getPlayerFromId(source)
    local currentAuthorization = getEnforcementAuthorization(player)
    if not player or not currentAuthorization or player:getIdentifier() ~= identifier then return false end

    return currentAuthorization.name == authorization.name
        and currentAuthorization.type == authorization.type
end

local function inspectEnforcementImpoundVehicle(source, netId)
    if not databaseIsUsable(source) then return false, 'database_unavailable' end
    if not enforcementImpoundEnabled() then return false, 'not_authorized' end

    local player = Framework.getPlayerFromId(source)
    if not player or not getEnforcementAuthorization(player) then return false, 'not_authorized' end

    local entity, entityReason = validateEnforcementImpoundEntity(source, netId)
    if not entity then return false, entityReason end

    local mode, _, classificationReason = classifyEnforcementVehicle(entity)
    if not mode then return false, classificationReason end

    return true, mode
end


lib.callback.register('drs_garages:inspectEnforcementImpoundVehicle', inspectEnforcementImpoundVehicle)

local function ambientRemovalCountForSource(source)
    local count = 0
    for _, operation in pairs(ambientRemovalOperations) do
        if operation.source == source then count = count + 1 end
    end
    return count
end

local function ambientRawPlate(entity)
    local plate = GetVehicleNumberPlateText(entity)
    return type(plate) == 'string' and plate or ''
end

local function ambientRemovalMatches(operation, requireStationary)
    local entity = operation.entity
    if ambientRemovalOperations[entity] ~= operation then return false, 'storage_in_progress' end
    if not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return false, 'vehicle_not_managed' end
    if NetworkGetNetworkIdFromEntity(entity) ~= operation.netId then return false, 'vehicle_not_managed' end
    if NetworkGetEntityFromNetworkId(operation.netId) ~= entity then return false, 'vehicle_not_managed' end
    if normalizeModelHash(GetEntityModel(entity)) ~= operation.model then return false, 'vehicle_not_managed' end
    if ambientRawPlate(entity) ~= operation.rawPlate then return false, 'vehicle_not_managed' end
    if GetEntityRoutingBucket(entity) ~= operation.routingBucket then return false, 'vehicle_not_managed' end

    local populationOk, populationType = pcall(GetEntityPopulationType, entity)
    if not populationOk or tonumber(populationType) ~= operation.populationType then
        return false, 'vehicle_not_ambient'
    end

    if vehicleHasOccupantOtherThan(entity) then return false, 'vehicle_occupied' end

    if requireStationary then
        local maximumSpeed = math.max(0.0, tonumber(getEnforcementImpoundConfig().MaximumSpeed) or 1.0)
        local speedOk, speed = pcall(GetEntitySpeed, entity)
        if not speedOk or (tonumber(speed) or maximumSpeed + 1.0) > maximumSpeed then
            return false, 'vehicle_moving'
        end

        local currentCoords = GetEntityCoords(entity)
        local maximumDisplacement = math.min(100.0, math.max(
            0.0,
            tonumber(getAmbientImpoundConfig().MaximumDisplacement) or 5.0
        ))
        if #(currentCoords - operation.coords) > maximumDisplacement then
            return false, 'vehicle_moving'
        end
    end

    return true
end

local function clearAmbientRemoval(operation, restoreVehicle)
    if ambientRemovalOperations[operation.entity] == operation then
        ambientRemovalOperations[operation.entity] = nil
    end

    if restoreVehicle and DoesEntityExist(operation.entity)
        and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
        and normalizeModelHash(GetEntityModel(operation.entity)) == operation.model
        and ambientRawPlate(operation.entity) == operation.rawPlate
        and GetEntityRoutingBucket(operation.entity) == operation.routingBucket
    then
        setEnforcementRemovalState(operation.entity, false, nil, operation.previousLockState)
    end
end

local function cancelAmbientRemoval(operation)
    clearAmbientRemoval(operation, true)

    local player = Framework.getPlayerFromId(operation.source)
    if player and player:getIdentifier() == operation.officerIdentity then
        TriggerClientEvent(
            'drs_garages:showNotification',
            operation.source,
            locale('enforcement_ambient_cancelled'),
            'error'
        )
    end
end

local function finalizeAmbientRemoval(operation)
    if ambientRemovalOperations[operation.entity] ~= operation then return end
    if not DoesEntityExist(operation.entity) then
        clearAmbientRemoval(operation, false)
        return
    end

    local matches = ambientRemovalMatches(operation, true)
    if not matches then
        cancelAmbientRemoval(operation)
        return
    end

    local mode = classifyEnforcementVehicle(operation.entity)
    if ambientRemovalOperations[operation.entity] ~= operation then return end
    if mode ~= 'ambient' then
        cancelAmbientRemoval(operation)
        return
    end

    matches = ambientRemovalMatches(operation, true)
    if not matches then
        cancelAmbientRemoval(operation)
        return
    end

    for _ = 1, VEHICLE_DELETE_RETRY_COUNT do
        if ambientRemovalOperations[operation.entity] ~= operation then return end
        if not DoesEntityExist(operation.entity) then
            clearAmbientRemoval(operation, false)
            return
        end

        mode = classifyEnforcementVehicle(operation.entity)
        if ambientRemovalOperations[operation.entity] ~= operation then return end
        if mode ~= 'ambient' then
            cancelAmbientRemoval(operation)
            return
        end

        matches = ambientRemovalMatches(operation, true)
        if not matches or not requestVehicleDeletion(operation.entity) then break end
        if not DoesEntityExist(operation.entity) then
            clearAmbientRemoval(operation, false)
            return
        end

        Wait(VEHICLE_DELETE_RETRY_INTERVAL)
    end

    if not DoesEntityExist(operation.entity) then
        clearAmbientRemoval(operation, false)
    else
        cancelAmbientRemoval(operation)
    end
end

local function scheduleAmbientRemoval(source, netId)
    if not databaseIsUsable(source) then return false, 'database_unavailable' end
    if not enforcementImpoundEnabled() or getAmbientImpoundConfig().Enabled ~= true then
        return false, 'not_authorized'
    end

    local player = Framework.getPlayerFromId(source)
    local authorization = getEnforcementAuthorization(player)
    if not player or not authorization then return false, 'not_authorized' end

    local officerIdentity = player:getIdentifier()
    if not officerIdentity then return false, 'not_authorized' end

    local entity, entityReason = validateEnforcementImpoundEntity(source, netId)
    if not entity then return false, entityReason end
    if ambientRemovalOperations[entity] then return false, 'storage_in_progress' end

    local maximumPending = math.min(20, math.max(1,
        math.floor(tonumber(getAmbientImpoundConfig().MaximumPendingPerOfficer) or 3)
    ))
    if ambientRemovalCountForSource(source) >= maximumPending then return false, 'storage_in_progress' end

    local populationOk, populationType = pcall(GetEntityPopulationType, entity)
    populationType = populationOk and tonumber(populationType) or nil
    if not populationType or not ambientPopulationTypeAllowed(entity) then return false, 'vehicle_not_ambient' end

    local operation = {
        token = {},
        source = source,
        officerIdentity = officerIdentity,
        authorization = authorization,
        entity = entity,
        netId = tonumber(netId),
        model = normalizeModelHash(GetEntityModel(entity)),
        rawPlate = ambientRawPlate(entity),
        plate = normalizePlate(GetVehicleNumberPlateText(entity)),
        populationType = populationType,
        routingBucket = GetEntityRoutingBucket(entity),
        coords = GetEntityCoords(entity),
        previousLockState = readVehicleDoorLockStatus(entity)
    }
    ambientRemovalOperations[entity] = operation

    local mode, _, classificationReason = classifyEnforcementVehicle(entity)
    local currentEntity, currentReason = validateEnforcementImpoundEntity(source, netId, entity)
    if ambientRemovalOperations[entity] ~= operation then return false, 'storage_in_progress' end
    if not enforcementSourceStillAuthorized(source, officerIdentity, authorization) then
        clearAmbientRemoval(operation, false)
        return false, 'not_authorized'
    end
    if not currentEntity then
        clearAmbientRemoval(operation, false)
        return false, currentReason
    end
    if mode ~= 'ambient' then
        clearAmbientRemoval(operation, false)
        return false, classificationReason or 'vehicle_not_managed'
    end

    local exactMatch, matchReason = ambientRemovalMatches(operation, true)
    if not exactMatch then
        clearAmbientRemoval(operation, false)
        return false, matchReason
    end

    local delay = getEnforcementRemovalDelay()
    operation.removeAt = os.time() + math.ceil(delay / 1000)
    setEnforcementRemovalState(entity, true, operation.removeAt, operation.previousLockState)

    CreateThread(function()
        if delay > 0 then Wait(delay) end
        local ok, errorMessage = xpcall(function()
            finalizeAmbientRemoval(operation)
        end, function(message)
            return debug.traceback(message, 2)
        end)

        if not ok and ambientRemovalOperations[operation.entity] == operation then
            print(('[drs_garages] Unexpected ambient removal error for entity %s: %s'):format(
                tostring(operation.entity),
                tostring(errorMessage)
            ))
            cancelAmbientRemoval(operation)
        end
    end)

    return true, nil, 'ambient', delay
end

lib.callback.register('drs_garages:removeAmbientVehicle', scheduleAmbientRemoval)

local function clearPendingEnforcementRemoval(operation, entity, restoreVehicle)
    if pendingEnforcementRemovals[operation.plate] == operation then
        pendingEnforcementRemovals[operation.plate] = nil
    end
    if vehicleStorageOperations[operation.plate] == operation.entity then
        vehicleStorageOperations[operation.plate] = nil
    end

    local requestedEntity = entity
    entity = nil
    if requestedEntity and DoesEntityExist(requestedEntity) then
        local trackedOriginal = requestedEntity == operation.entity
            and NetworkGetNetworkIdFromEntity(requestedEntity) == operation.netId
        local trackedCurrent = requestedEntity == operation.currentEntity
            and NetworkGetNetworkIdFromEntity(requestedEntity) == operation.currentNetId
        local trustedCandidate = normalizePlate(GetVehicleNumberPlateText(requestedEntity)) == operation.plate
            and normalizeModelHash(GetEntityModel(requestedEntity)) == operation.model
            and reconciliationCandidateIsTrusted(
                requestedEntity,
                operation.storedVehicle,
                operation.routingBucket
            ) == true
        if trackedOriginal or trackedCurrent or trustedCandidate then entity = requestedEntity end
    end
    if not entity and DoesEntityExist(operation.entity)
        and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
    then
        entity = operation.entity
    end
    if not entity and operation.currentEntity and DoesEntityExist(operation.currentEntity)
        and NetworkGetNetworkIdFromEntity(operation.currentEntity) == operation.currentNetId
    then
        entity = operation.currentEntity
    end
    if restoreVehicle and entity then
        setEnforcementRemovalState(entity, false, nil, operation.previousLockState)
    end

    return entity
end

local function notifyEnforcementRemovalFailure(operation)
    local player = Framework.getPlayerFromId(operation.source)
    if player and player:getIdentifier() == operation.officerIdentity then
        TriggerClientEvent(
            'drs_garages:showNotification',
            operation.source,
            locale('enforcement_impound_removal_failed'),
            'error'
        )
    end
end

local function quarantinePendingEnforcementRemoval(operation, detail, entity)
    vehicleReconciliationQuarantine[operation.plate] = detail

    local trackedEntity
    if entity and DoesEntityExist(entity) then
        local trackedOriginal = entity == operation.entity
            and NetworkGetNetworkIdFromEntity(entity) == operation.netId
        local trackedCurrent = entity == operation.currentEntity
            and NetworkGetNetworkIdFromEntity(entity) == operation.currentNetId
        local trustedCandidate = normalizePlate(GetVehicleNumberPlateText(entity)) == operation.plate
            and normalizeModelHash(GetEntityModel(entity)) == operation.model
            and reconciliationCandidateIsTrusted(
                entity,
                operation.storedVehicle,
                operation.routingBucket
            ) == true
        if trackedOriginal or trackedCurrent or trustedCandidate then trackedEntity = entity end
    end

    if trackedEntity then
        operation.currentEntity = trackedEntity
        operation.currentNetId = NetworkGetNetworkIdFromEntity(trackedEntity)
        activeVehicles[operation.plate] = trackedEntity
    end
    notifyEnforcementRemovalFailure(operation)
    print(('[drs_garages] CRITICAL: Delayed removal quarantined plate %s: %s'):format(
        operation.plate,
        detail
    ))
end

local findPendingEnforcementCandidates

local function rollbackPendingEnforcementRemoval(operation, entity, detail)
    local rolledBack = rollbackEnforcementImpound(
        operation.storedVehicle,
        operation.impoundId,
        operation.committedProperties
    )

    if pendingEnforcementRemovals[operation.plate] ~= operation then return end
    if not rolledBack then
        quarantinePendingEnforcementRemoval(operation, detail, entity)
        return
    end

    local candidates, conflicting, conflictingEntity = findPendingEnforcementCandidates(operation, operation.storedVehicle)
    if pendingEnforcementRemovals[operation.plate] ~= operation then return end

    if #candidates == 1 and not conflicting then
        entity = clearPendingEnforcementRemoval(operation, candidates[1], true)
        activeVehicles[operation.plate] = entity
        notifyEnforcementRemovalFailure(operation)
        return
    end

    local originalStillExists = DoesEntityExist(operation.entity)
        and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
    local currentStillExists = operation.currentEntity
        and operation.currentEntity ~= 0
        and DoesEntityExist(operation.currentEntity)
        and NetworkGetNetworkIdFromEntity(operation.currentEntity) == operation.currentNetId
    if #candidates == 0 and not conflicting and not originalStillExists and not currentStillExists then
        local activeEntity = activeVehicles[operation.plate]
        if activeEntity == operation.entity
            or activeEntity == operation.currentEntity
            or activeEntity == entity
        then
            activeVehicles[operation.plate] = nil
        end
        clearPendingEnforcementRemoval(operation, nil, false)
        notifyEnforcementRemovalFailure(operation)
        return
    end

    quarantinePendingEnforcementRemoval(
        operation,
        detail .. '; rollback succeeded but live entity identity became ambiguous',
        candidates[1] or conflictingEntity or entity
    )
end

findPendingEnforcementCandidates = function(operation, storedVehicle)
    local trusted = {}
    local conflicting = false
    local conflictingEntity
    local storedRowId = tonumber(storedVehicle and storedVehicle.id)

    for _, entity in ipairs(GetAllVehicles()) do
        if entity and entity ~= 0 and DoesEntityExist(entity) and GetEntityType(entity) == 2 then
            local physicalPlateMatches = normalizePlate(GetVehicleNumberPlateText(entity)) == operation.plate
            local modelMatches = normalizeModelHash(GetEntityModel(entity)) == operation.model
            local identityMatches = reconciliationCandidateIsTrusted(
                entity,
                storedVehicle,
                operation.routingBucket
            ) == true
            local markerMatchesRow = false
            if storedRowId then
                local markers, markersRead = readEnforcementEntityMarkers(entity)
                markerMatchesRow = markersRead and (
                    tonumber(markers.rowId) == storedRowId or tonumber(markers.vehicleId) == storedRowId
                )
            end

            if identityMatches and physicalPlateMatches and modelMatches then
                trusted[#trusted + 1] = entity
            elseif physicalPlateMatches or identityMatches or markerMatchesRow then
                conflicting = true
                conflictingEntity = conflictingEntity or entity
            end
        end
    end

    return trusted, conflicting, conflictingEntity
end

local function deletePendingEnforcementCandidate(operation, entity)
    for _ = 1, VEHICLE_DELETE_RETRY_COUNT do
        if pendingEnforcementRemovals[operation.plate] ~= operation then return false end
        if not DoesEntityExist(entity) then return true end
        if GetEntityType(entity) ~= 2
            or normalizePlate(GetVehicleNumberPlateText(entity)) ~= operation.plate
            or normalizeModelHash(GetEntityModel(entity)) ~= operation.model
            or vehicleHasOccupantOtherThan(entity)
            or reconciliationCandidateIsTrusted(entity, operation.storedVehicle, operation.routingBucket) ~= true
        then
            return false
        end

        if not requestVehicleDeletion(entity) then return not DoesEntityExist(entity) end
        if not DoesEntityExist(entity) then return true end
        Wait(VEHICLE_DELETE_RETRY_INTERVAL)
    end

    return not DoesEntityExist(entity)
end

local function finalizePendingEnforcementRemoval(operation)
    if pendingEnforcementRemovals[operation.plate] ~= operation then return end

    local storedVehicle, vehicleRead = queryVehicleByPlate(operation.plate)
    local record, recordRead = getActiveImpoundRecord(operation.plate)
    if pendingEnforcementRemovals[operation.plate] ~= operation then return end

    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local stateStillCommitted = vehicleRead and storedVehicle
        and vehicleRowsShareIdentity(operation.storedVehicle, storedVehicle)
        and databaseInteger(storedVehicle.stored) == 0
        and (not isQb or databaseInteger(storedVehicle.state) == 2)
        and getEncodedVehicleProperties(storedVehicle) == operation.committedProperties
    local recordStillCommitted = recordRead and storedVehicle and record
        and record.impound_id == operation.impoundId
        and impoundRecordMatchesVehicle(record, storedVehicle) == true

    if not stateStillCommitted or not recordStillCommitted then
        quarantinePendingEnforcementRemoval(
            operation,
            'delayed enforcement removal found an altered database row or impound record',
            operation.entity
        )
        return
    end

    local lastEntity
    for _ = 1, 3 do
        local candidates, conflicting, conflictingEntity = findPendingEnforcementCandidates(operation, storedVehicle)
        if pendingEnforcementRemovals[operation.plate] ~= operation then return end

        if #candidates == 0 and not conflicting then
            local trackedEntity = DoesEntityExist(operation.entity)
                and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
                and operation.entity
                or operation.currentEntity and DoesEntityExist(operation.currentEntity)
                    and NetworkGetNetworkIdFromEntity(operation.currentEntity) == operation.currentNetId
                    and operation.currentEntity
                or nil
            if trackedEntity then
                quarantinePendingEnforcementRemoval(
                    operation,
                    'delayed enforcement removal found a tracked entity with a changed fingerprint',
                    trackedEntity
                )
                return
            end

            if activeVehicles[operation.plate] == lastEntity
                or activeVehicles[operation.plate] == operation.entity
            then
                activeVehicles[operation.plate] = nil
            end
            clearPendingEnforcementRemoval(operation, nil, false)
            return
        end
        if #candidates ~= 1 or conflicting then
            quarantinePendingEnforcementRemoval(
                operation,
                'delayed enforcement removal found conflicting or duplicate live entities',
                candidates[1] or conflictingEntity or operation.entity
            )
            return
        end

        local entity = candidates[1]
        lastEntity = entity
        if vehicleHasOccupantOtherThan(entity) then
            rollbackPendingEnforcementRemoval(operation, entity, 'delayed enforcement removal found an occupied vehicle')
            return
        end

        activeVehicles[operation.plate] = entity
        operation.currentEntity = entity
        operation.currentNetId = NetworkGetNetworkIdFromEntity(entity)
        setEnforcementRemovalState(entity, true, operation.removeAt, operation.previousLockState)
        if not deletePendingEnforcementCandidate(operation, entity) then
            rollbackPendingEnforcementRemoval(operation, entity, 'delayed enforcement vehicle deletion failed')
            return
        end
    end

    local candidates, conflicting, conflictingEntity = findPendingEnforcementCandidates(operation, storedVehicle)
    if #candidates == 0 and not conflicting then
        local trackedEntity = DoesEntityExist(operation.entity)
            and NetworkGetNetworkIdFromEntity(operation.entity) == operation.netId
            and operation.entity
            or operation.currentEntity and DoesEntityExist(operation.currentEntity)
                and NetworkGetNetworkIdFromEntity(operation.currentEntity) == operation.currentNetId
                and operation.currentEntity
            or nil
        if trackedEntity then
            quarantinePendingEnforcementRemoval(
                operation,
                'delayed enforcement removal exhausted retries with a changed tracked entity',
                trackedEntity
            )
            return
        end

        if activeVehicles[operation.plate] == lastEntity or activeVehicles[operation.plate] == operation.entity then
            activeVehicles[operation.plate] = nil
        end
        clearPendingEnforcementRemoval(operation, nil, false)
        return
    end

    quarantinePendingEnforcementRemoval(
        operation,
        'delayed enforcement removal exceeded the entity replacement limit',
        candidates[1] or conflictingEntity or lastEntity or operation.entity
    )
end

local function schedulePendingEnforcementRemoval(source, officerIdentity, plate, model, entity, netId, storedVehicle, impoundId, committedProperties)
    if pendingEnforcementRemovals[plate] then return end

    local delay = getEnforcementRemovalDelay()
    local operation = {
        token = {},
        source = source,
        officerIdentity = officerIdentity,
        plate = plate,
        model = model,
        entity = entity,
        netId = tonumber(netId),
        currentEntity = entity,
        currentNetId = tonumber(netId),
        routingBucket = GetEntityRoutingBucket(entity),
        storedVehicle = storedVehicle,
        impoundId = impoundId,
        committedProperties = committedProperties,
        previousLockState = readVehicleDoorLockStatus(entity),
        removeAt = os.time() + math.ceil(delay / 1000)
    }

    pendingEnforcementRemovals[plate] = operation
    activeVehicles[plate] = entity
    setEnforcementRemovalState(entity, true, operation.removeAt, operation.previousLockState)

    CreateThread(function()
        if delay > 0 then Wait(delay) end
        local ok, errorMessage = xpcall(function()
            finalizePendingEnforcementRemoval(operation)
        end, function(message)
            return debug.traceback(message, 2)
        end)

        if not ok and pendingEnforcementRemovals[operation.plate] == operation then
            print(('[drs_garages] Unexpected delayed enforcement removal error for plate %s: %s'):format(
                operation.plate,
                tostring(errorMessage)
            ))

            local recoveryOk, recoveryError = xpcall(function()
                rollbackPendingEnforcementRemoval(
                    operation,
                    operation.currentEntity or operation.entity,
                    'unexpected delayed enforcement removal error'
                )
            end, function(message)
                return debug.traceback(message, 2)
            end)

            if not recoveryOk and pendingEnforcementRemovals[operation.plate] == operation then
                quarantinePendingEnforcementRemoval(
                    operation,
                    'unexpected delayed removal and recovery handler error: ' .. tostring(recoveryError),
                    operation.currentEntity or operation.entity
                )
            end
        end
    end)

    return delay
end

local function performEnforcementImpound(source, netId, rawReason, rawFee)
    if not databaseIsUsable(source) then return false, 'database_unavailable' end
    if not enforcementImpoundEnabled() then return false, 'not_authorized' end

    local reason = normalizeImpoundReason(rawReason)
    if not reason then return false, 'invalid_reason' end

    local fee = boundedImpoundFee(rawFee)
    if fee == nil then return false, 'invalid_fee' end

    local player = Framework.getPlayerFromId(source)
    local authorization = getEnforcementAuthorization(player)
    if not player or not authorization then return false, 'not_authorized' end

    local officerIdentity = player:getIdentifier()
    local officerIdentifier = sanitizedText(officerIdentity, 80)
    if not officerIdentifier then return false, 'not_authorized' end
    local officerName = sanitizedText(('%s %s'):format(player:getFirstName() or '', player:getLastName() or ''), 100)
        or sanitizedText(GetPlayerName(source), 100)
        or 'Unknown officer'
    local officerJob = sanitizedText(authorization.name or authorization.type, 50) or 'unknown'

    local entity, entityReason = validateEnforcementImpoundEntity(source, netId)
    if not entity then return false, entityReason end

    local plate = normalizePlate(GetVehicleNumberPlateText(entity))
    local model = normalizeModelHash(GetEntityModel(entity))
    if not plate or not model then return false, 'vehicle_not_managed' end
    if isVehicleStorageInProgress(plate) then return false, 'storage_in_progress' end

    local registeredEntity = getActiveVehicleByPlate(plate)
    if registeredEntity and registeredEntity ~= entity then return false, 'vehicle_not_managed' end

    vehicleStorageOperations[plate] = entity
    local operationCommitted = false
    local rollbackVehicle
    local rollbackImpoundId
    local rollbackCommittedProperties

    local function revalidateOfficerAndEntity(expectedEntity)
        local currentPlayer = Framework.getPlayerFromId(source)
        local currentAuthorization = getEnforcementAuthorization(currentPlayer)
        if not currentPlayer or currentPlayer:getIdentifier() ~= officerIdentity or not currentAuthorization then
            return nil, nil, 'not_authorized'
        end
        if currentAuthorization.name ~= authorization.name or currentAuthorization.type ~= authorization.type then
            return nil, nil, 'not_authorized'
        end
        if vehicleStorageOperations[plate] ~= expectedEntity then return nil, nil, 'storage_in_progress' end

        local currentEntity, currentReason = validateEnforcementImpoundEntity(source, netId, expectedEntity)
        if not currentEntity then return nil, nil, currentReason end
        if normalizePlate(GetVehicleNumberPlateText(currentEntity)) ~= plate
            or normalizeModelHash(GetEntityModel(currentEntity)) ~= model
        then
            return nil, nil, 'vehicle_not_managed'
        end

        return currentPlayer, currentEntity
    end

    local function execute()
        local storedVehicle, vehicleRead = queryVehicleByPlate(plate)
        player, entity, entityReason = revalidateOfficerAndEntity(entity)
        if not vehicleRead then return false, 'database_unavailable' end
        if not player or not entity then return false, entityReason end
        if not storedVehicle then return false, 'vehicle_not_owned' end
        if normalizePlate(storedVehicle.plate) ~= plate then return false, 'vehicle_not_managed' end
        if not rowHasStorageState(storedVehicle, 0) then return false, 'vehicle_not_managed' end

        local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
        if isQb and databaseInteger(storedVehicle.state) ~= 0 then return false, 'impound_already_recorded' end

        local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)
        if not hasStoredModel or not modelMatches or hasConflictingPlateEntity(plate, entity) then
            return false, 'vehicle_not_managed'
        end

        local activeRecord, recordRead = getActiveImpoundRecord(plate)
        if not recordRead then return false, 'database_unavailable' end
        if activeRecord then return false, 'impound_already_recorded' end

        if registeredEntity == nil then
            local trusted = reconciliationCandidateIsTrusted(entity, storedVehicle)
            if not trusted then return false, 'vehicle_not_managed' end
            activeVehicles[plate] = entity
            registeredEntity = entity
        end
        if not isExactActiveVehicle(plate, entity) then return false, 'vehicle_not_managed' end

        local impoundId = generateImpoundId(source, plate, officerIdentifier)
        local trustedProps = buildTrustedParkingProperties(storedVehicle, entity, plate)
        if trustedProps then
            trustedProps._drsImpoundId = impoundId
            trustedProps._drsReleaseId = nil
        end
        local encodedOk, encodedProps = pcall(json.encode, trustedProps)
        if not trustedProps or not encodedOk or type(encodedProps) ~= 'string' then
            return false, 'vehicle_not_managed'
        end

        local maximumPropsBytes = math.max(1, math.floor(tonumber(Config.MaxVehiclePropsBytes) or 64 * 1024))
        if #encodedProps > maximumPropsBytes then return false, 'vehicle_not_managed' end

        local ownershipType, ownerKey = getVehicleOwnershipSnapshot(storedVehicle)
        if not ownershipType or not ownerKey then return false, 'vehicle_not_owned' end

        local impoundedAt = os.time()
        local impoundRecord = {
            impound_id = impoundId,
            plate = plate,
            vehicle_row_id = storedVehicle.id ~= nil and tostring(storedVehicle.id) or plate,
            ownership_type = ownershipType,
            owner_key = ownerKey,
            reason = reason,
            fee = fee,
            release_mode = 'payable',
            impounded_by_identifier = officerIdentifier,
            impounded_by_name = officerName,
            impounded_by_job = officerJob,
            impounded_by_grade = authorization.grade,
            source_resource = GetCurrentResourceName(),
            impounded_at = impoundedAt
        }
        local tableName = isQb and 'player_vehicles' or 'owned_vehicles'
        local where, whereParams = buildExactVehicleWhere(storedVehicle)
        local setClause
        local updateParams

        if isQb then
            setClause = '`stored` = 0, `state` = 2, `mods` = ?'
            updateParams = { encodedProps }
            if vehicleTableHasColumn('depotprice') then
                setClause = setClause .. ', `depotprice` = ?'
                updateParams[#updateParams + 1] = fee
            end
            where = where .. ' AND `stored` = 0 AND `state` = 0 AND BINARY `mods` = BINARY ?'
        else
            setClause = '`stored` = 0, `vehicle` = ?'
            updateParams = { encodedProps }
            where = where .. ' AND `stored` = 0 AND BINARY `vehicle` = BINARY ?'
        end
        appendValues(updateParams, whereParams)
        updateParams[#updateParams + 1] = getEncodedVehicleProperties(storedVehicle)
        rollbackVehicle = storedVehicle
        rollbackImpoundId = impoundId
        rollbackCommittedProperties = encodedProps

        player, entity, entityReason = revalidateOfficerAndEntity(entity)
        if not player or not entity then return false, entityReason end

        local transactionOk, committed = pcall(MySQL.transaction.await, {
            {
                query = ('UPDATE `%s` SET %s WHERE %s LIMIT 1'):format(tableName, setClause, where),
                values = updateParams
            },
            {
                query = ImpoundQueries.insertAfterChangedRow,
                values = impoundRecordValues(impoundRecord)
            }
        })

        if not transactionOk or committed ~= true then
            return false, 'database_unavailable'
        end
        operationCommitted = true

        local committedVehicle, committedVehicleRead = queryVehicleByPlate(plate)
        local committedRecord, committedRecordRead = getActiveImpoundRecord(plate)
        local stateCommitted = committedVehicle and databaseInteger(committedVehicle.stored) == 0
            and (not isQb or databaseInteger(committedVehicle.state) == 2)
            and (isQb and committedVehicle.mods == encodedProps or not isQb and committedVehicle.vehicle == encodedProps)
        local recordMatches = committedRecord and impoundRecordMatchesVehicle(committedRecord, committedVehicle)
        local recordCommitted = committedRecord and committedRecord.impound_id == impoundId and recordMatches == true

        if not committedVehicleRead or not committedRecordRead or not stateCommitted or not recordCommitted then
            local drsStateApplied = committedVehicle
                and (isQb and committedVehicle.mods == encodedProps or not isQb and committedVehicle.vehicle == encodedProps)
            local drsRecordApplied = committedRecord and committedRecord.impound_id == impoundId

            if (drsStateApplied or drsRecordApplied)
                and not rollbackEnforcementImpound(storedVehicle, impoundId, encodedProps)
            then
                vehicleReconciliationQuarantine[plate] = 'enforcement impound post-commit verification and rollback failed'
                print(('[drs_garages] CRITICAL: Enforcement impound verification/rollback failed for plate %s.'):format(plate))
            end
            operationCommitted = false
            return false, (drsStateApplied or drsRecordApplied) and 'database_unavailable' or 'impound_already_recorded'
        end

        player, entity, entityReason = revalidateOfficerAndEntity(entity)
        if not player or not entity then
            if not rollbackEnforcementImpound(storedVehicle, impoundId, encodedProps) then
                vehicleReconciliationQuarantine[plate] = 'enforcement context changed and rollback failed'
            end
            operationCommitted = false
            return false, entityReason
        end

        local removalDelay = schedulePendingEnforcementRemoval(
            source,
            officerIdentity,
            plate,
            model,
            entity,
            netId,
            storedVehicle,
            impoundId,
            encodedProps
        )
        if removalDelay == nil then
            if not rollbackEnforcementImpound(storedVehicle, impoundId, encodedProps) then
                vehicleReconciliationQuarantine[plate] = 'enforcement removal scheduling and rollback failed'
                print(('[drs_garages] CRITICAL: Vehicle %s could not schedule delayed removal and its impound rollback failed.'):format(plate))
            end
            operationCommitted = false
            return false, 'storage_in_progress'
        end

        operationCommitted = false
        rollbackVehicle = nil
        rollbackImpoundId = nil
        rollbackCommittedProperties = nil
        print(('[drs_garages] %s (%s/%s) impounded plate %s for $%d; physical removal scheduled in %dms: %s'):format(
            officerName,
            officerJob,
            officerIdentifier,
            plate,
            fee,
            removalDelay,
            reason
        ))

        return true, nil, 'owned', removalDelay
    end

    local operationOk, result, failureReason, resultMode, resultDelay = xpcall(execute, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    if not operationOk then
        print(('[drs_garages] Unexpected enforcement impound error for plate %s: %s'):format(plate, tostring(result)))
        if operationCommitted and rollbackVehicle and rollbackImpoundId and rollbackCommittedProperties then
            if not rollbackEnforcementImpound(rollbackVehicle, rollbackImpoundId, rollbackCommittedProperties) then
                vehicleReconciliationQuarantine[plate] = 'unexpected enforcement failure could not be rolled back automatically'
            end
        end
        result, failureReason = false, 'database_unavailable'
    end

    if activeVehicles[plate] == entity and not DoesEntityExist(entity) then activeVehicles[plate] = nil end
    if vehicleStorageOperations[plate] == entity and not pendingEnforcementRemovals[plate] then
        vehicleStorageOperations[plate] = nil
    end

    return result == true, result == true and nil or failureReason, resultMode, resultDelay
end

lib.callback.register('drs_garages:enforcementImpoundVehicle', performEnforcementImpound)

exports('ImpoundVehicle', function(source, netId, reason, fee)
    return performEnforcementImpound(tonumber(source), netId, reason, fee)
end)

lib.callback.register('drs_garages:retrieveVehicle', function(source, index, plate, type, society)
    if not databaseIsUsable(source) then return false end

    society = society == true

    plate = normalizePlate(plate)
    if not plate or isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return end

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    if society and not isValidSocietyJobName(player:getJob()) then return false end

    local impound = Config.Impounds[index]
    if not impound then
        invalidIndexMessage('impound', source, index)
        return false
    end

    if not playerCanAccessGarage(player, impound) or not isNearGarage(source, impound) or not spawnTypeMatchesGarage(type, impound) then
        return false
    end

    local token = beginRetrievalOperation(plate, source)
    if not token then return false end

    local operationEntity
    local rollbackRecordedImpoundRelease
    local operationRedeemedStateTwo = false
    local rollbackRetrievedStateTwo
    local restoreRetrievedLegacyDepotPrice
    local operationChargedPlayer
    local operationChargedAmount = 0
    local function performImpoundRetrieval()
    local function finish(...)
        return ...
    end

    local function rejectSpawn(entity)
        if not deleteSpawnedVehicle(entity) and DoesEntityExist(entity) then
            -- The persisted row is already out/impounded. Track an entity that
            -- could not be removed so another retrieval cannot create a clone.
            activeVehicles[plate] = entity
        end

        return finish(false)
    end

    local identifier = player:getIdentifier()
    local job = player:getJob()

    local function revalidateContext()
        local currentPlayer = Framework.getPlayerFromId(source)
        local operation = getRetrievalOperation(plate)

        if not operation or operation.token ~= token or not currentPlayer then return end
        if currentPlayer:getIdentifier() ~= identifier then return end
        if society and currentPlayer:getJob() ~= job then return end
        if not playerCanAccessGarage(currentPlayer, impound) or not isNearGarage(source, impound) then return end
        if not spawnTypeMatchesGarage(type, impound) then return end

        return currentPlayer
    end

    local vehicle = queryStrictVehicle(player, plate, society == true, false)
    player = revalidateContext()

    if not player or not vehicle or normalizePlate(vehicle.plate) ~= plate then return finish(false) end
    if not rowHasStorageState(vehicle, 0) or not rowTypeMatchesGarage(vehicle, impound) then return finish(false) end
    if not vehicleMatchesOwnershipMode(vehicle, player, society) then return finish(false) end
    if society and not canAccessJobFleetVehicle(source, vehicle) then return finish(false) end

    local impoundRecord, recordRead = getActiveImpoundRecord(plate)
    if not recordRead then return finish(false, nil, 'database_unavailable') end

    local isQbFramework = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    local qbStateTwo = isQbFramework and databaseInteger(vehicle.state) == 2
    if impoundRecord and impoundRecordMatchesVehicle(impoundRecord, vehicle) ~= true then
        vehicleReconciliationQuarantine[plate] = 'impound record no longer matches the vehicle row during retrieval'
        return finish(false, nil, 'impound_on_hold')
    end
    if impoundRecord and isQbFramework and not qbStateTwo then
        vehicleReconciliationQuarantine[plate] = 'DRS impound record exists but the QB/Qbox row is not in state 2'
        return finish(false, nil, 'impound_on_hold')
    end
    if impoundRecord and impoundRecord.release_mode ~= 'payable' then
        if impoundRecord.release_mode ~= 'hold' then
            vehicleReconciliationQuarantine[plate] = 'impound record has an invalid release mode'
        end
        return finish(false, nil, 'impound_on_hold')
    end
    if qbStateTwo and not impoundRecord and getEnforcementImpoundConfig().LegacyStateTwoHold ~= false then
        return finish(false, nil, 'impound_on_hold')
    end

    local price = impoundRecord and displayImpoundFee(impoundRecord.fee)
        or isQbFramework and vehicle.depotprice ~= nil and displayImpoundFee(vehicle.depotprice)
        or math.max(0, math.floor(tonumber(Config.ImpoundPrice) or 0))
    local balanceOk, balance = pcall(player.getAccountMoney, player, 'money')
    if not balanceOk or tonumber(balance) == nil or tonumber(balance) < price then
        return finish(false, nil, 'not_enough_money')
    end

    local entity, owner, props = spawnStoredVehicle(vehicle, impound, plate, type)
    operationEntity = entity
    if not entity then return finish(false) end

    player = revalidateContext()
    if not player or getActiveVehicleByPlate(plate) then
        return rejectSpawn(entity)
    end

    -- Re-read after the bounded OneSync ownership wait. The row must still be
    -- the same authorized out vehicle before any money can be removed.
    local currentVehicle = queryStrictVehicle(player, plate, society == true, false)
    player = revalidateContext()

    local sameVehicleRow = currentVehicle and vehicleRowsShareIdentity(vehicle, currentVehicle)
    if not player or not currentVehicle or not sameVehicleRow or not rowHasStorageState(currentVehicle, 0)
        or not rowTypeMatchesGarage(currentVehicle, impound)
        or not vehicleMatchesOwnershipMode(currentVehicle, player, society)
        or society and not canAccessJobFleetVehicle(source, currentVehicle)
    then
        return rejectSpawn(entity)
    end

    local currentRecord, currentRecordRead = getActiveImpoundRecord(plate)
    local sameRecord = impoundRecord == nil and currentRecord == nil
        or impoundRecord and currentRecord and currentRecord.impound_id == impoundRecord.impound_id
            and impoundRecordMatchesVehicle(currentRecord, currentVehicle) == true
    if not currentRecordRead or not sameRecord then return rejectSpawn(entity) end
    if currentRecord and currentRecord.release_mode ~= 'payable' then
        if currentRecord.release_mode ~= 'hold' then
            vehicleReconciliationQuarantine[plate] = 'impound record acquired an invalid release mode during retrieval'
        end
        return rejectSpawn(entity)
    end

    local currentPrice = currentRecord and displayImpoundFee(currentRecord.fee)
        or isQbFramework and currentVehicle.depotprice ~= nil and displayImpoundFee(currentVehicle.depotprice)
        or math.max(0, math.floor(tonumber(Config.ImpoundPrice) or 0))
    if currentPrice ~= price then return rejectSpawn(entity) end
    impoundRecord = currentRecord

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not DoesEntityExist(entity) or not netId or netId < 1 then
        return rejectSpawn(entity)
    end

    if not applyVehicleIdentityState(entity, currentVehicle) then
        return rejectSpawn(entity)
    end

    if price > 0 then
        local beforeOk, beforeValue = pcall(player.getAccountMoney, player, 'money')
        local beforeBalance = beforeOk and tonumber(beforeValue) or nil
        if not beforeBalance or beforeBalance < price then
            return rejectSpawn(entity)
        end

        local paymentOk, paymentResult = pcall(player.removeAccountMoney, player, 'money', price)
        local afterOk, afterValue = pcall(player.getAccountMoney, player, 'money')
        local afterBalance = afterOk and tonumber(afterValue) or nil
        local deducted = afterBalance and afterBalance == beforeBalance - price

        if not paymentOk or paymentResult == false or not deducted then
            local refundAmount
            if afterBalance and afterBalance < beforeBalance then
                refundAmount = beforeBalance - afterBalance
            elseif not afterBalance and paymentOk and paymentResult ~= false then
                refundAmount = price
            end

            local deleted = deleteSpawnedVehicle(entity)
            if deleted and refundAmount and refundAmount > 0 then
                refundImpoundCharge(player, refundAmount, source, plate)
            elseif not deleted and DoesEntityExist(entity) then
                activeVehicles[plate] = entity
                print(('[drs_garages] CRITICAL: Impound payment failed for plate %s, but its spawned entity could not be deleted; no automatic refund was issued.'):format(plate))
            end

            return finish(false)
        end
    end

    local chargedPlayer = player
    operationChargedPlayer = chargedPlayer
    operationChargedAmount = price
    player = revalidateContext()
    if not player or not DoesEntityExist(entity) then
        local deleted = not DoesEntityExist(entity) or deleteSpawnedVehicle(entity)
        if deleted and price > 0 then refundImpoundCharge(chargedPlayer, price, source, plate) end
        return finish(false)
    end

    if impoundRecord then
        local releaseOperation, released = commitRecordedImpoundRelease(currentVehicle, impoundRecord)
        if not releaseOperation or not released then
            local deleted = deleteSpawnedVehicle(entity)
            local rolledBack = not releaseOperation or deleted and releaseOperation.rollback()

            if deleted and rolledBack then
                if price > 0 then refundImpoundCharge(chargedPlayer, price, source, plate) end
            elseif not deleted and DoesEntityExist(entity) then
                activeVehicles[plate] = entity
                vehicleReconciliationQuarantine[plate] = 'recorded impound release failed while a live retrieval entity remained'
            else
                vehicleReconciliationQuarantine[plate] = 'recorded impound release could not be rolled back exactly'
            end

            print(('[drs_garages] CRITICAL: Recorded impound release failed for plate %s (deleted=%s, rolledBack=%s).'):format(
                plate,
                tostring(deleted),
                tostring(rolledBack)
            ))
            return finish(false)
        end

        currentVehicle = releaseOperation.vehicle
        rollbackRecordedImpoundRelease = releaseOperation.rollback
    end

    local stateTwoImpoundedProperties
    local stateTwoReleasedProperties
    if isQbFramework and databaseInteger(currentVehicle.state) == 2 then
        stateTwoImpoundedProperties = currentVehicle.mods
        local decodedOk, releasedProps = pcall(json.decode, stateTwoImpoundedProperties)
        if decodedOk and type(releasedProps) == 'table' then
            releasedProps._drsImpoundId = nil
            releasedProps._drsReleaseId = generateImpoundId(0, plate, 'legacy-release')
            local encodedOk, encodedProps = pcall(json.encode, releasedProps)
            local maximumPropsBytes = math.max(1, math.floor(tonumber(Config.MaxVehiclePropsBytes) or 64 * 1024))
            if encodedOk and type(encodedProps) == 'string' and #encodedProps <= maximumPropsBytes then
                stateTwoReleasedProperties = encodedProps
            end
        end

        if not stateTwoReleasedProperties then
            local deleted = deleteSpawnedVehicle(entity)
            if deleted and price > 0 then refundImpoundCharge(chargedPlayer, price, source, plate) end
            return finish(false)
        end
    end

    local stateTwoPreviousDepotPrice = vehicleTableHasColumn('depotprice')
        and math.max(0, math.floor(tonumber(currentVehicle.depotprice) or 0))
        or nil

    local function rollbackStateTwoRedemption()
        local existingVehicle, existingRead = queryVehicleByPlate(plate)
        local alreadyRestored = existingRead
            and vehicleRowsShareIdentity(currentVehicle, existingVehicle)
            and databaseInteger(existingVehicle.stored) == 0
            and databaseInteger(existingVehicle.state) == 2
            and existingVehicle.mods == stateTwoImpoundedProperties
            and (not vehicleTableHasColumn('depotprice')
                or databaseInteger(existingVehicle.depotprice) == stateTwoPreviousDepotPrice)
        if alreadyRestored then return true end

        local where, whereParams = buildExactVehicleWhere(currentVehicle)
        where = where .. ' AND `stored` = 0 AND `state` = 0 AND BINARY `mods` = BINARY ?'
        whereParams[#whereParams + 1] = stateTwoReleasedProperties
        local setClause = vehicleTableHasColumn('depotprice')
            and '`mods` = ?, `state` = 2, `depotprice` = ?'
            or '`mods` = ?, `state` = 2'
        local params = { stateTwoImpoundedProperties }
        if vehicleTableHasColumn('depotprice') then params[#params + 1] = stateTwoPreviousDepotPrice end
        appendValues(params, whereParams)

        local rollbackOk, rolledBack = pcall(MySQL.update.await,
            ('UPDATE `player_vehicles` SET %s WHERE %s LIMIT 1'):format(setClause, where),
            params
        )
        if not rollbackOk or tonumber(rolledBack) ~= 1 then return false end

        local restoredVehicle, restoredRead = queryVehicleByPlate(plate)
        return restoredRead
            and vehicleRowsShareIdentity(currentVehicle, restoredVehicle)
            and databaseInteger(restoredVehicle.stored) == 0
            and databaseInteger(restoredVehicle.state) == 2
            and restoredVehicle.mods == stateTwoImpoundedProperties
            and (not vehicleTableHasColumn('depotprice')
                or databaseInteger(restoredVehicle.depotprice) == stateTwoPreviousDepotPrice)
    end
    rollbackRetrievedStateTwo = rollbackStateTwoRedemption

    local redeemedFromStateTwo = false
    if (Framework.name == 'qb-core' or Framework.name == 'qbx_core')
        and databaseInteger(currentVehicle.state) == 2
    then
        local where, whereParams = buildExactVehicleWhere(currentVehicle)
        where = where .. ' AND `stored` = 0 AND `state` = 2 AND BINARY `mods` = BINARY ?'
        whereParams[#whereParams + 1] = stateTwoImpoundedProperties

        local stateSetClause = vehicleTableHasColumn('depotprice')
            and '`mods` = ?, `state` = 0, `depotprice` = 0'
            or '`mods` = ?, `state` = 0'
        local params = { stateTwoReleasedProperties }
        appendValues(params, whereParams)
        local updateOk, changed = pcall(MySQL.update.await,
            ('UPDATE `player_vehicles` SET %s WHERE %s LIMIT 1'):format(stateSetClause, where),
            params
        )
        local changedCount = tonumber(changed)

        if not updateOk or changedCount ~= 1 then
            local deleted = deleteSpawnedVehicle(entity)
            if deleted and price > 0 then
                refundImpoundCharge(chargedPlayer, price, source, plate)
            elseif not deleted and DoesEntityExist(entity) then
                activeVehicles[plate] = entity
                print(('[drs_garages] CRITICAL: Impound state commit failed for plate %s and the live entity could not be deleted; no automatic refund was issued.'):format(plate))
            end

            return finish(false)
        end

        redeemedFromStateTwo = true
        operationRedeemedStateTwo = true

        local verifyQuery
        local verifyParams
        if currentVehicle.id ~= nil then
            verifyQuery = 'SELECT * FROM `player_vehicles` WHERE `id` = ? LIMIT 1'
            verifyParams = { currentVehicle.id }
        else
            verifyQuery = 'SELECT * FROM `player_vehicles` WHERE `plate` = ? LIMIT 1'
            verifyParams = { plate }
        end

        local verifyOk, redeemedVehicle = pcall(MySQL.single.await, verifyQuery, verifyParams)
        local sameRedeemedId = currentVehicle.id == nil
            or redeemedVehicle and tostring(redeemedVehicle.id) == tostring(currentVehicle.id)
        local ownershipMatches = redeemedVehicle and (society
            and redeemedVehicle.job == job
            or not society and redeemedVehicle.citizenid == identifier and redeemedVehicle.job == nil)
        local redeemed = verifyOk and redeemedVehicle and sameRedeemedId
            and normalizePlate(redeemedVehicle.plate) == plate
            and databaseInteger(redeemedVehicle.stored) == 0
            and databaseInteger(redeemedVehicle.state) == 0
            and redeemedVehicle.mods == stateTwoReleasedProperties
            and (not vehicleTableHasColumn('depotprice') or databaseInteger(redeemedVehicle.depotprice) == 0)
            and ownershipMatches

        if not redeemed then
            local deleted = deleteSpawnedVehicle(entity)
            local rolledBack = deleted and rollbackStateTwoRedemption() or false

            if deleted and rolledBack then
                if price > 0 then refundImpoundCharge(chargedPlayer, price, source, plate) end
            elseif DoesEntityExist(entity) then
                activeVehicles[plate] = entity
                vehicleReconciliationQuarantine[plate] = verifyOk
                    and 'impound post-commit ownership verification failed'
                    or 'impound post-commit database verification was unavailable'
            end

            print(('[drs_garages] CRITICAL: Impound state committed for plate %s, but exact post-commit verification failed (query=%s, deleted=%s, rolledBack=%s); no vehicle or keys were delivered.'):format(
                plate,
                tostring(verifyOk),
                tostring(deleted),
                tostring(rolledBack)
            ))
            return finish(false)
        end

        currentVehicle = redeemedVehicle
    end

    if (Framework.name == 'qb-core' or Framework.name == 'qbx_core')
        and not redeemedFromStateTwo
        and vehicleTableHasColumn('depotprice')
        and (databaseInteger(currentVehicle.depotprice) or 0) > 0
    then
        local previousDepotPrice = math.max(0, math.floor(tonumber(currentVehicle.depotprice) or 0))
        local depotWhere, depotParams = buildExactVehicleWhere(currentVehicle)
        depotWhere = depotWhere .. ' AND `stored` = 0 AND `state` = 0 AND `depotprice` = ?'
        depotParams[#depotParams + 1] = previousDepotPrice
        local clearedOk, cleared = pcall(MySQL.update.await,
            ('UPDATE `player_vehicles` SET `depotprice` = 0 WHERE %s LIMIT 1'):format(depotWhere),
            depotParams
        )
        if clearedOk and tonumber(cleared) == 1 then
            restoreRetrievedLegacyDepotPrice = function()
                local restoreWhere, restoreWhereParams = buildExactVehicleWhere(currentVehicle)
                restoreWhere = restoreWhere .. ' AND `stored` = 0 AND `state` = 0 AND `depotprice` = 0'

                local restoreParams = { previousDepotPrice }
                appendValues(restoreParams, restoreWhereParams)
                local restoreOk, restored = pcall(MySQL.update.await,
                    ('UPDATE `player_vehicles` SET `depotprice` = ? WHERE %s LIMIT 1'):format(restoreWhere),
                    restoreParams
                )

                return restoreOk and tonumber(restored) == 1
            end
        else
            local deleted = deleteSpawnedVehicle(entity)
            if deleted and price > 0 then
                refundImpoundCharge(chargedPlayer, price, source, plate)
            elseif not deleted and DoesEntityExist(entity) then
                activeVehicles[plate] = entity
                vehicleReconciliationQuarantine[plate] = 'legacy depot release changed while a live retrieval entity remained'
            end

            print(('[drs_garages] Legacy depot release changed for plate %s before its exact price could be cleared; retrieval was cancelled.'):format(plate))
            return finish(false)
        end
    end

    activeVehicles[plate] = entity

    if not DoesEntityExist(entity) then
        if activeVehicles[plate] == entity then activeVehicles[plate] = nil end

        local safeToRefund = true
        if redeemedFromStateTwo then
            safeToRefund = rollbackStateTwoRedemption()
        end
        if rollbackRecordedImpoundRelease then
            safeToRefund = rollbackRecordedImpoundRelease() and safeToRefund
        end
        if restoreRetrievedLegacyDepotPrice then
            safeToRefund = restoreRetrievedLegacyDepotPrice() and safeToRefund
        end

        if safeToRefund and price > 0 then
            refundImpoundCharge(chargedPlayer, price, source, plate)
        elseif not safeToRefund then
            print(('[drs_garages] CRITICAL: Redeemed impound %s vanished and its state rollback failed; payment was left for staff reconciliation.'):format(plate))
        end
        return finish(false)
    end

    TriggerClientEvent('drs_garages:setVehicleProperties', owner, netId, props)
    giveVehicleKeysOrWarn(source, entity, plate)

    return finish(true, netId)
    end

    local results = table.pack(xpcall(performImpoundRetrieval, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end))

    if not results[1] then
        local cleanupDeleted = true
        local cleanupOk, cleanupError = xpcall(function()
            if operationEntity and DoesEntityExist(operationEntity) then
                if not deleteSpawnedVehicle(operationEntity) then
                    cleanupDeleted = false
                    activeVehicles[plate] = operationEntity
                    vehicleReconciliationQuarantine[plate] = 'unexpected impound retrieval failure left a live entity'
                end
            end
        end, function(errorMessage)
            return debug.traceback(errorMessage, 2)
        end)
        if not cleanupOk then
            if operationEntity then
                activeVehicles[plate] = operationEntity
                vehicleReconciliationQuarantine[plate] = 'unexpected impound cleanup failure may have left a live entity'
            end
            print(('[drs_garages] Unexpected impound cleanup error for plate %s: %s'):format(plate, tostring(cleanupError)))
        end

        local stateRestored = not operationRedeemedStateTwo
            or cleanupDeleted and rollbackRetrievedStateTwo and rollbackRetrievedStateTwo()
        local recordRestored = not rollbackRecordedImpoundRelease
            or cleanupDeleted and rollbackRecordedImpoundRelease()
        local legacyPriceRestored = not restoreRetrievedLegacyDepotPrice
            or cleanupDeleted and restoreRetrievedLegacyDepotPrice()

        if cleanupOk and cleanupDeleted and stateRestored and recordRestored and legacyPriceRestored and operationChargedAmount > 0 then
            refundImpoundCharge(operationChargedPlayer, operationChargedAmount, source, plate)
        elseif operationChargedAmount > 0 and (not cleanupDeleted or not stateRestored or not recordRestored or not legacyPriceRestored) then
            print(('[drs_garages] CRITICAL: Unexpected retrieval failure for %s could not be safely rolled back; payment requires staff review.'):format(plate))
        end
        endRetrievalOperation(plate, token)
        print(('[drs_garages] Unexpected impound retrieval error for plate %s: %s'):format(plate, tostring(results[2])))
        return false
    end

    endRetrievalOperation(plate, token)
    return table.unpack(results, 2, results.n)
end)

lib.callback.register('drs_garages:getVehicleCoords', function(source, plate, society)
    if not databaseIsUsable(source) then return end

    plate = normalizePlate(plate)
    if not plate or isVehicleStorageInProgress(plate) then return end

    local player = Framework.getPlayerFromId(source)
    if not player then return end

    society = society == true
    local vehicle = queryStrictVehicle(player, plate, society, false)

    if not vehicle or normalizePlate(vehicle.plate) ~= plate or not rowHasStorageState(vehicle, 0) then return end
    if not vehicleMatchesOwnershipMode(vehicle, player, society) then return end
    if society and not canAccessJobFleetVehicle(source, vehicle) then return end
    if isVehicleStorageInProgress(plate) then return end

    local entity = getActiveVehicleByPlate(plate)
    if not entity or not DoesEntityExist(entity) then return end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, vehicle)
    if not hasStoredModel or not modelMatches then return end

    return GetEntityCoords(entity)
end)
