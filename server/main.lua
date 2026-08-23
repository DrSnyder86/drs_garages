-- Used to store vehicles that have been taken out
---@type table<string, number>
local activeVehicles = {}
local vehicleStorageOperations = {}
local vehicleRetrievalOperations = {}
local vehicleExternalOperations = {}
local vehicleReconciliationQuarantine = {}
local propertyGarages = {}

local UINT32 = 4294967296
local ACTIVE_VEHICLE_REGISTRATION_DISTANCE = 75.0
local VEHICLE_DELETE_RETRY_COUNT = 20
local VEHICLE_DELETE_RETRY_INTERVAL = 100
local VEHICLE_OWNER_TIMEOUT = 5000
local MAX_GARAGE_STORAGE_NAME_LENGTH = 50
local SERVER_DISTANCE_TOLERANCE = 2.0
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

local function validateVehicleForStorage(source, garage, netId, plate, model, expectedEntity)
    netId = tonumber(netId)

    if not netId or netId < 1 or netId % 1 ~= 0 then return end

    local entity = NetworkGetEntityFromNetworkId(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if expectedEntity and entity ~= expectedEntity then return end
    if GetEntityType(entity) ~= 2 then return end
    if NetworkGetNetworkIdFromEntity(entity) ~= netId then return end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(entity) then return end
    if GetPedInVehicleSeat(entity, -1) ~= GetPlayerPed(source) then return end
    if not isVehicleNearGarageParking(entity, garage) then return end
    if not liveVehicleTypeMatchesGarage(entity, garage) then return end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return end
    if normalizeModelHash(GetEntityModel(entity)) ~= model then return end

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

local function isVehicleStorageInProgress(plate)
    plate = normalizePlate(plate)

    return plate and (
        vehicleStorageOperations[plate] ~= nil
        or getRetrievalOperation(plate) ~= nil
        or vehicleExternalOperations[plate] ~= nil
        or vehicleReconciliationQuarantine[plate] ~= nil
    ) or false
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
        if GetPedInVehicleSeat(entity, -1) ~= GetPlayerPed(source) then return false end

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

function BuildDrsGarageClientVehicles(vehicles)
    local clientVehicles = {}

    for _, storedVehicle in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        clientVehicles[#clientVehicles + 1] = {
            plate = storedVehicle.plate,
            mods = storedVehicle.mods,
            vehicle = storedVehicle.vehicle,
            state = storedVehicle.state
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
    if not Config.UseKeySystem then return end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    if GetResourceState('qbx_vehiclekeys') == 'started' then
        exports.qbx_vehiclekeys:GiveKeys(source, vehicle, false)
        return
    end

    if GetResourceState('qb-vehiclekeys') == 'started' then
        local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
        if plate then exports['qb-vehiclekeys']:GiveKeys(source, plate) end
    end
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
    for plate, activeEntity in pairs(activeVehicles) do
        if activeEntity == entity and vehicleStorageOperations[normalizePlate(plate)] ~= entity then
            activeVehicles[plate] = nil
        end
    end
end)

AddEventHandler('playerDropped', function()
    databaseNotificationTimes[source] = nil
    -- A yielded callback still owns its exact token after disconnect. Its
    -- post-yield identity checks fail closed and its finally path releases the
    -- token; clearing it here would reopen the plate to a concurrent operation.
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Retrieval tokens intentionally never expire while their callback is live.
    -- Explicitly discard them on shutdown as the other safe terminal condition.
    vehicleRetrievalOperations = {}
    vehicleStorageOperations = {}
    vehicleExternalOperations = {}
    vehicleReconciliationQuarantine = {}
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
        if vehicleVisibleAtGarage(vehicle, index, garage, player, society == true) then
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
    local ok, props = pcall(json.decode, vehicle.mods or vehicle.vehicle)
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

local function reconciliationCandidateIsTrusted(entity, storedVehicle)
    if GetEntityRoutingBucket(entity) ~= 0 then return false, 'entity is not in routing bucket 0' end

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
    local quarantined = 0

    for _, storedVehicle in ipairs(outVehicles) do
        local normalizedPlate = normalizePlate(storedVehicle.plate)
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

        local quarantineReason

        if #matchingEntities > 1 then
            quarantineReason = 'multiple live entities match the stored plate/model'
        end

        if #matchingEntities == 0 and #(candidates or {}) > 0 then
            quarantineReason = 'a live entity uses the stored plate but has a different model'
        end

        local liveEntity = matchingEntities[1]

        if liveEntity and not quarantineReason then
            local trusted, reason = reconciliationCandidateIsTrusted(liveEntity, storedVehicle)
            if not trusted then quarantineReason = reason end
        end

        if liveEntity and not quarantineReason and isQb and databaseInteger(storedVehicle.state) == 2 then
            if deleteSpawnedVehicle(liveEntity) then
                liveEntity = nil
            else
                quarantineReason = 'an impounded state-2 vehicle is still live and could not be deleted'
            end
        end

        if quarantineReason and normalizedPlate then
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
        elseif isQb and databaseInteger(storedVehicle.state) == 2 and normalizedPlate then
            -- State 2 is the stock QB/Qbox impound state. Never let automatic
            -- restart recovery turn an impounded vehicle into a free garage car.
            if databaseInteger(storedVehicle.stored) ~= 0 then
                local updateOk, affected = pcall(MySQL.update.await, [[
                    UPDATE `player_vehicles`
                    SET `stored` = 0
                    WHERE `plate` = ? AND `state` = 2
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

    print(('[drs_garages] Restart reconciliation kept %s live vehicle(s) active, returned %s missing vehicle(s) to storage, preserved %s impound row(s), and quarantined %s suspicious plate(s).'):format(
        recovered,
        returned,
        preservedImpounds,
        quarantined
    ))

    return recovered, returned, preservedImpounds, quarantined
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

    activeVehicles = {} -- rebuild the cache from authoritative world/DB state
    vehicleReconciliationQuarantine = {}

    local reconciliationOk, recoveredOrError, returned, preservedImpounds, quarantined = xpcall(function()
        return moveOutVehiclesIntoGarages(Config.AutoRespawn == true)
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    startupReconciliationComplete = true
    startupReconciliationSuccessful = reconciliationOk == true

    if reconciliationOk then
        startupReconciliationDetail = ('reconciled %d live, %d missing, %d preserved impound, and %d quarantined vehicle(s)'):format(
            tonumber(recoveredOrError) or 0,
            tonumber(returned) or 0,
            tonumber(preservedImpounds) or 0,
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
            if vehicleMatchesOwnershipMode(vehicle, player, true) then authorizedVehicles[#authorizedVehicles + 1] = vehicle end
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

        player = revalidateVehicleListPlayer(source, identifier, job, true)
        if not player then return {} end

        local filtered = {}

        for _, vehicle in ipairs(vehicles) do
            local plate = normalizePlate(vehicle.plate)
            local entity = plate and getActiveVehicleByPlate(plate) or nil

            if not vehicleMatchesOwnershipMode(vehicle, player, true) or not plate
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
    pcall(giveVehicleKeys, source, entity)

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

lib.callback.register('drs_garages:saveVehicle', function(source, props, netId, index, spawnType)
    if not databaseIsUsable(source) then return false end

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    local garage = getGarage(index)
    if not garage then
        invalidIndexMessage('garage', source, index)
        return false
    end

    if not playerCanAccessGarage(player, garage) or not isNearGarageParking(source, garage) or not spawnTypeMatchesGarage(spawnType, garage) then
        return false
    end

    if type(props) ~= 'table' then return false end

    local plate = normalizePlate(props.plate)
    local model = normalizeModelHash(props.model)

    if not plate or not model or isVehicleStorageInProgress(plate) then return false end

    local entity = validateVehicleForStorage(source, garage, netId, plate, model)
    if not entity then return false end

    -- Only the server-registered entity for this plate may change persistent
    -- storage state. A client-created clone with a copied plate/model is rejected.
    if not isExactActiveVehicle(plate, entity) then return false end

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

    local function revalidateContext(expectedEntity)
        local currentPlayer = revalidateOwnershipContext()
        if not currentPlayer then return end

        local currentEntity = validateVehicleForStorage(source, garage, netId, plate, model, expectedEntity)

        if not currentEntity or not isExactActiveVehicle(plate, currentEntity) then return end

        return currentPlayer, currentEntity
    end

    -- Personal ownership always wins. Society ownership is considered only when
    -- no strict personal row exists and the destination is not a property garage.
    local storedVehicle = MySQL.single.await(Queries.getVehicleStrict, { identifier, plate })

    player, entity = revalidateContext(entity)
    if not player then return false end

    if not storedVehicle then
        if garage.Property or not isValidSocietyJobName(initialJob) or player:getJob() ~= initialJob then
            return false
        end

        ownershipMode = 'society'
        ownershipJob = initialJob
        storedVehicle = MySQL.single.await(Queries.getVehicleJobStrict, { ownershipJob, plate })

        player, entity = revalidateContext(entity)
        if not player or not storedVehicle then return false end
    end

    local storedIdentifier = Framework.name == 'es_extended' and storedVehicle.owner or storedVehicle.citizenid

    if normalizePlate(storedVehicle.plate) ~= plate then return false end

    if ownershipMode == 'personal' then
        if storedIdentifier ~= identifier or storedVehicle.job ~= nil then return false end
    elseif storedVehicle.job ~= ownershipJob then
        return false
    end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)
    if not hasStoredModel or not modelMatches or not rowTypeMatchesGarage(storedVehicle, garage) then return false end

    local trustedProps = buildTrustedParkingProperties(storedVehicle, entity, plate)
    if not trustedProps then return false end

    local encodedOk, encodedProps = pcall(json.encode, trustedProps)
    if not encodedOk or type(encodedProps) ~= 'string' then return false end

    local maxPropsBytes = tonumber(Config.MaxVehiclePropsBytes)
    if not maxPropsBytes or maxPropsBytes ~= maxPropsBytes or maxPropsBytes <= 0 then
        maxPropsBytes = 64 * 1024
    end

    maxPropsBytes = math.floor(maxPropsBytes)
    if #encodedProps > maxPropsBytes then return false end

    local garageName = garageStorageName(index, garage)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
    if isQb and not garageName then return false end

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
        updateQuery, updateParams = scopedUpdate(
            '`stored` = 1, `state` = 1, `garage` = ?, `mods` = ?',
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
    if not rowHasStorageState(storedVehicle, 0) then return false end
    if isQb and databaseInteger(storedVehicle.state) ~= 0 then return false end

    if vehicleStorageOperations[plate] ~= entity or not isExactActiveVehicle(plate, entity) then return false end

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

        return false
    end

    -- Deletion polling yields. Revalidate the selected personal/society session
    -- before committing the now-absent vehicle to storage.
    player = revalidateOwnershipContext()
    if not player or vehicleStorageOperations[plate] ~= entity or activeVehicles[plate] ~= entity then
        if activeVehicles[plate] == entity then activeVehicles[plate] = nil end
        return false
    end

    local updateOk, changed = pcall(MySQL.update.await, updateQuery, updateParams)

    -- The update yields as well; preserve the chosen identity/job check before
    -- releasing the reservation. A failed update leaves the deleted row out so it
    -- remains recoverable from impound rather than duplicating a live vehicle.
    revalidateOwnershipContext()

    local changedCount = tonumber(changed)
    local stored = updateOk and changedCount == 1

    if activeVehicles[plate] == entity then activeVehicles[plate] = nil end

    return stored == true
    end

    local operationOk, result = xpcall(performSave, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    if activeVehicles[plate] == entity and not DoesEntityExist(entity) then
        activeVehicles[plate] = nil
    end

    if vehicleStorageOperations[plate] == entity then vehicleStorageOperations[plate] = nil end

    if not operationOk then
        print(('[drs_garages] Unexpected parking error for plate %s: %s'):format(plate, tostring(result)))
        return false
    end

    return result == true
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

    local price = math.max(0, math.floor(tonumber(Config.ImpoundPrice) or 0))
    local balanceOk, balance = pcall(player.getAccountMoney, player, 'money')
    if not balanceOk or tonumber(balance) == nil or tonumber(balance) < price then return finish(false) end

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

    local sameId = vehicle.id == nil or currentVehicle and tostring(currentVehicle.id) == tostring(vehicle.id)
    if not player or not currentVehicle or not sameId or not rowHasStorageState(currentVehicle, 0)
        or not rowTypeMatchesGarage(currentVehicle, impound)
        or not vehicleMatchesOwnershipMode(currentVehicle, player, society)
    then
        return rejectSpawn(entity)
    end

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
    player = revalidateContext()
    if not player or not DoesEntityExist(entity) then
        local deleted = not DoesEntityExist(entity) or deleteSpawnedVehicle(entity)
        if deleted and price > 0 then refundImpoundCharge(chargedPlayer, price, source, plate) end
        return finish(false)
    end

    local function rollbackStateTwoRedemption()
        local where = '`plate` = ? AND `stored` = 0 AND `state` = 0'
        local params = { plate }

        if currentVehicle.id ~= nil then
            where = '`id` = ? AND ' .. where
            table.insert(params, 1, currentVehicle.id)
        end

        if society then
            where = where .. ' AND `job` = ?'
            params[#params + 1] = job
        else
            where = where .. ' AND `citizenid` = ? AND `job` IS NULL'
            params[#params + 1] = identifier
        end

        local rollbackOk, rolledBack = pcall(MySQL.update.await,
            ('UPDATE `player_vehicles` SET `state` = 2 WHERE %s LIMIT 1'):format(where),
            params
        )
        return rollbackOk and tonumber(rolledBack) == 1
    end

    local redeemedFromStateTwo = false
    if (Framework.name == 'qb-core' or Framework.name == 'qbx_core')
        and databaseInteger(currentVehicle.state) == 2
    then
        local where = '`plate` = ? AND `stored` = 0 AND `state` = 2'
        local params = { plate }

        if currentVehicle.id ~= nil then
            where = '`id` = ? AND ' .. where
            table.insert(params, 1, currentVehicle.id)
        end

        if society then
            where = where .. ' AND `job` = ?'
            params[#params + 1] = job
        else
            where = where .. ' AND `citizenid` = ? AND `job` IS NULL'
            params[#params + 1] = identifier
        end

        local updateOk, changed = pcall(MySQL.update.await,
            ('UPDATE `player_vehicles` SET `state` = 0 WHERE %s LIMIT 1'):format(where),
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

    activeVehicles[plate] = entity

    if not DoesEntityExist(entity) then
        if activeVehicles[plate] == entity then activeVehicles[plate] = nil end

        local safeToRefund = true
        if redeemedFromStateTwo then
            safeToRefund = rollbackStateTwoRedemption()
        end

        if safeToRefund and price > 0 then
            refundImpoundCharge(chargedPlayer, price, source, plate)
        elseif not safeToRefund then
            print(('[drs_garages] CRITICAL: Redeemed impound %s vanished and its state rollback failed; payment was left for staff reconciliation.'):format(plate))
        end
        return finish(false)
    end

    TriggerClientEvent('drs_garages:setVehicleProperties', owner, netId, props)
    pcall(giveVehicleKeys, source, entity)

    return finish(true, netId)
    end

    local results = table.pack(xpcall(performImpoundRetrieval, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end))

    if not results[1] then
        local cleanupOk, cleanupError = xpcall(function()
            if operationEntity and DoesEntityExist(operationEntity) then
                if not deleteSpawnedVehicle(operationEntity) then
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
    if isVehicleStorageInProgress(plate) then return end

    local entity = getActiveVehicleByPlate(plate)
    if not entity or not DoesEntityExist(entity) then return end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return end

    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, vehicle)
    if not hasStoredModel or not modelMatches then return end

    return GetEntityCoords(entity)
end)
