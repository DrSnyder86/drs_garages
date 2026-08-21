-- Used to store vehicles that have been taken out
---@type table<string, number>
local activeVehicles = {}
local vehicleStorageOperations = {}
local propertyGarages = {}

local UINT32 = 4294967296
local ACTIVE_VEHICLE_REGISTRATION_DISTANCE = 75.0
local VEHICLE_DELETE_RETRY_COUNT = 20
local VEHICLE_DELETE_RETRY_INTERVAL = 100
local MAX_GARAGE_STORAGE_NAME_LENGTH = 50
local databaseNotificationTimes = {}

local function stableHash(value)
    local hash = 2166136261

    for index = 1, #value do
        hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff
    end

    return ('%08x'):format(hash)
end

local function storageSafeGarageName(value)
    if value == nil then return end

    value = tostring(value):match('^%s*(.-)%s*$')
    if value == '' then return end
    if #value <= MAX_GARAGE_STORAGE_NAME_LENGTH then return value end

    local prefixLength = MAX_GARAGE_STORAGE_NAME_LENGTH - 17
    local prefix = value:gsub('[^%w_%-]', '_'):sub(1, prefixLength)
    local suffix = stableHash(value) .. stableHash(value:reverse())

    return ('%s_%s'):format(prefix, suffix)
end

local function notifyDatabaseUnavailable(source)
    source = tonumber(source)
    if not source or source < 1 then return end

    local now = GetGameTimer()
    if databaseNotificationTimes[source] and now - databaseNotificationTimes[source] < 5000 then return end

    databaseNotificationTimes[source] = now
    TriggerClientEvent('drs_garages:showNotification', source, 'Garages are temporarily unavailable because the vehicle database is not ready. Check the server console.', 'error')
end

local function databaseIsUsable(source)
    local databaseApi = rawget(_G, 'DRSGaragesDatabase')
    if type(databaseApi) ~= 'table' then return true end

    if type(databaseApi.isReady) == 'function' then
        local readyOk, ready = pcall(databaseApi.isReady)

        if not readyOk or not ready then
            notifyDatabaseUnavailable(source)
            return false, readyOk and 'database setup is still running' or tostring(ready)
        end
    end

    if type(databaseApi.wasSuccessful) == 'function' then
        local resultOk, successful, detail = pcall(databaseApi.wasSuccessful)

        if not resultOk or not successful then
            notifyDatabaseUnavailable(source)
            return false, resultOk and detail or tostring(successful)
        end
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

    if vehicleType == 'automobile' or vehicleType == 'bike' or vehicleType == 'bicycle' or vehicleType == 'quadbike' then
        return 'car'
    elseif vehicleType == 'plane' or vehicleType == 'heli' or vehicleType == 'helicopter' then
        return 'air'
    elseif vehicleType == 'jetski' then
        return 'boat'
    end

    return vehicleType
end

local function propertyGarageId(name)
    local value = tostring(name or '')

    if propertyGarages[value] then return value end

    value = value:lower():gsub('%s+', '_'):gsub('[^%w_%-]', '')

    if value:sub(1, 9) ~= 'property_' then
        value = ('property_%s'):format(value)
    end

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

local function vehicleMatchesOwnershipMode(vehicle, player, society)
    if society then
        return vehicle.job and vehicle.job ~= '' and vehicle.job == player:getJob()
    end

    return not vehicle.job or vehicle.job == ''
end

local function canAccessGarage(source, garage)
    local player = Framework.getPlayerFromId(source)
    if not player then return false end

    return playerCanAccessGarage(player, garage)
end

local function garageCoords(garage)
    return garage.Position or garage.PedPosition or garage.SpawnPosition
end

local function isNearCoords(source, coords)
    if not coords then return false end

    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 then return false end

    local playerCoords = GetEntityCoords(playerPed)
    local distance = math.max(Config.MaxDistance or 10.0, 25.0)

    return #(playerCoords - vector3(coords.x, coords.y, coords.z)) <= distance
end

local function isVehicleNearPlayer(source, vehicle)
    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 or not DoesEntityExist(playerPed) then return false end
    if GetPlayerRoutingBucket(source) ~= GetEntityRoutingBucket(vehicle) then return false end

    return #(GetEntityCoords(playerPed) - GetEntityCoords(vehicle)) <= ACTIVE_VEHICLE_REGISTRATION_DISTANCE
end

local function isNearGarage(source, garage)
    return isNearCoords(source, garageCoords(garage))
end

local function isNearGarageParking(source, garage)
    if garage.Property and garage.SpawnPosition then
        return isNearCoords(source, garage.SpawnPosition)
    end

    return isNearGarage(source, garage)
end

local function garageParkingCoords(garage)
    if garage.Property and garage.SpawnPosition then
        return garage.SpawnPosition
    end

    return garageCoords(garage)
end

local function isVehicleNearGarageParking(vehicle, garage)
    local coords = garageParkingCoords(garage)
    if not coords or not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return false end

    local distance = math.max(Config.MaxDistance or 10.0, 25.0)

    return #(GetEntityCoords(vehicle) - vector3(coords.x, coords.y, coords.z)) <= distance
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
    if not isVehicleNearGarageParking(entity, garage) then return end
    if not liveVehicleTypeMatchesGarage(entity, garage) then return end
    if normalizePlate(GetVehicleNumberPlateText(entity)) ~= plate then return end
    if normalizeModelHash(GetEntityModel(entity)) ~= model then return end

    return entity
end

local function getActiveVehicleByPlate(plate)
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

local function isExactActiveVehicle(plate, entity)
    getActiveVehicleByPlate(plate)

    return activeVehicles[plate] == entity
end

local function isVehicleStorageInProgress(plate)
    plate = normalizePlate(plate)

    return plate and vehicleStorageOperations[plate] ~= nil or false
end

local function deleteRegisteredVehicle(plate, entity, netId)
    netId = tonumber(netId)

    for _ = 1, VEHICLE_DELETE_RETRY_COUNT do
        if not DoesEntityExist(entity) then return true end
        if vehicleStorageOperations[plate] ~= entity or activeVehicles[plate] ~= entity then return false end
        if NetworkGetNetworkIdFromEntity(entity) ~= netId then return false end

        DeleteEntity(entity)

        if not DoesEntityExist(entity) then return true end

        Wait(VEHICLE_DELETE_RETRY_INTERVAL)
    end

    return not DoesEntityExist(entity)
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


local function giveVehicleKeys(source, vehicle)
    if not Config.UseKeySystem then return end
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    if GetResourceState('qbx_vehiclekeys') == 'started' then
        exports.qbx_vehiclekeys:GiveKeys(source, vehicle, false)
        return
    end

    -- qb-vehiclekeys is client/event based in most installs, so leave it to config/cl_edit.lua.
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
    if vehicleStorageOperations[plate] then return false, 'storage_in_progress' end

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
    if (Framework.name == 'qb-core' or Framework.name == 'qbx_core') and databaseInteger(storedVehicle.state) ~= 0 then
        return false, 'vehicle_not_out'
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

    activeVehicles[plate] = currentEntity

    return true, 'registered'
end

---@param plate string Persisted vehicle plate.
---@param netId? number Optional guard against unregistering a replacement entity.
---@return boolean success
---@return string reason
local function UnregisterActiveVehicle(plate, netId)
    plate = normalizePlate(plate)
    if not plate then return false, 'invalid_plate' end
    if vehicleStorageOperations[plate] then return false, 'storage_in_progress' end

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
end)

local function invalidIndexMessage(kind, source, index)
    print(('[drs_garages] Invalid %s index from source %s: %s'):format(kind, source or 'unknown', tostring(index)))
    TriggerClientEvent('drs_garages:showNotification', source, ('Invalid %s location. Check your garage config/client args.'):format(kind), 'error')
end

local function garageStorageName(index, garage)
    if not garage then return end

    if garage.Property then
        return storageSafeGarageName(index)
    end

    return storageSafeGarageName(garage.Garage or garage.Name or garage.Label)
end

local function setVehicleStored(plate, stored, garageName)
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


---@async
local function moveOutVehiclesIntoGarages(returnMissing)
    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        local outVehicles = MySQL.query.await([[
            SELECT *
            FROM player_vehicles
            WHERE `stored` = 0 OR `state` = 0
        ]]) or {}
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

        for _, storedVehicle in ipairs(outVehicles) do
            local normalizedPlate = normalizePlate(storedVehicle.plate)
            local candidates = normalizedPlate and worldVehicles[normalizedPlate] or nil
            local liveEntity = nil

            for _, entity in ipairs(candidates or {}) do
                if DoesEntityExist(entity) then
                    local modelMatches, hasStoredModel = vehicleMatchesStoredModel(entity, storedVehicle)

                    if hasStoredModel and modelMatches then
                        liveEntity = entity
                        break
                    end
                end
            end

            if liveEntity then
                activeVehicles[storedVehicle.plate] = liveEntity
                setVehicleStored(storedVehicle.plate, 0)
                recovered = recovered + 1
            elseif returnMissing then
                setVehicleStored(storedVehicle.plate, 1)
                returned = returned + 1
            end
        end

        print(('[drs_garages] Restart reconciliation kept %s live vehicle(s) active and returned %s missing vehicle(s) to storage.'):format(recovered, returned))
        return
    end

    if returnMissing then
        MySQL.update.await(Queries.setStoredVehicle:gsub('WHERE plate = ?', 'WHERE `stored` = 0'), { 1 })
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)

    if DRSGaragesDatabase and DRSGaragesDatabase.awaitReady then
        local waitOk, databaseReady, databaseError = pcall(DRSGaragesDatabase.awaitReady)

        if not waitOk or not databaseReady then
            print(('[drs_garages] Restart reconciliation skipped because database setup did not complete: %s'):format(
                tostring(waitOk and databaseError or databaseReady)
            ))
            return
        end
    end

    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' or Config.AutoRespawn then
        activeVehicles = {} -- rebuild the cache from authoritative world/DB state
        moveOutVehiclesIntoGarages(Config.AutoRespawn == true)
    end
end)



lib.callback.register('drs_garages:getOwnedVehicles', function(source, index, society)
    if not databaseIsUsable(source) then return {} end

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    
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
            player:getJob()
        })

        for _, vehicle in ipairs(vehicles) do
            if isVehicleStorageInProgress(vehicle.plate) then
                vehicle.state = 'out_garage'
            elseif vehicle.stored == 1 or vehicle.stored == true then
                vehicle.state = 'in_garage'
            elseif activeVehicles[vehicle.plate] then
                local entity = activeVehicles[vehicle.plate]
                if not DoesEntityExist(entity) then
                    activeVehicles[vehicle.plate] = nil
                    vehicle.state = 'in_impound'
                elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                    DeleteEntity(entity)
                    activeVehicles[vehicle.plate] = nil
                    vehicle.state = 'in_impound'
                else
                    vehicle.state = 'out_garage'
                end
            else
                vehicle.state = 'in_impound'
            end
        end

        return vehicles
    else
        local vehicles = MySQL.query.await(Queries.getGarage, {
            player:getIdentifier()
        })

        for _, vehicle in ipairs(vehicles) do
            if isVehicleStorageInProgress(vehicle.plate) then
                vehicle.state = 'out_garage'
            elseif vehicle.stored == 1 or vehicle.stored == true then
                vehicle.state = 'in_garage'
            elseif activeVehicles[vehicle.plate] then
                local entity = activeVehicles[vehicle.plate]
                if not DoesEntityExist(entity) then
                    activeVehicles[vehicle.plate] = nil
                    vehicle.state = 'in_impound'
                elseif not DoesEntityExist(entity) or GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                    DeleteEntity(entity)
                    activeVehicles[vehicle.plate] = nil
                    vehicle.state = 'in_impound'
                else
                    vehicle.state = 'out_garage'
                end
            else
                vehicle.state = 'in_impound'
            end
        end

        return vehicles
    end
end)


lib.callback.register('drs_garages:getImpoundedVehicles', function(source, index, society)
    if not databaseIsUsable(source) then return {} end

    local player = Framework.getPlayerFromId(source)
    if not player then return end
    
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
            player:getJob()
        })

        local filtered = {}

        for _, vehicle in ipairs(vehicles) do
            local entity = activeVehicles[vehicle.plate]

            if isVehicleStorageInProgress(vehicle.plate) then
                -- A verified store operation owns this plate until it commits.
            elseif not entity then
                table.insert(filtered, vehicle)
            elseif not DoesEntityExist(entity) then
                activeVehicles[vehicle.plate] = nil
                table.insert(filtered, vehicle)
            elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                DeleteEntity(entity)
                activeVehicles[vehicle.plate] = nil
                table.insert(filtered, vehicle)
            end
        end

        return filtered
    else
        local vehicles = MySQL.query.await(Queries.getImpound, {
            player:getIdentifier()
        })

        local filtered = {}

        for _, vehicle in ipairs(vehicles) do
            local entity = activeVehicles[vehicle.plate]

            if isVehicleStorageInProgress(vehicle.plate) then
                -- A verified store operation owns this plate until it commits.
            elseif not entity then
                table.insert(filtered, vehicle)
            elseif not DoesEntityExist(entity) then
                activeVehicles[vehicle.plate] = nil
                table.insert(filtered, vehicle)
            elseif GetVehiclePetrolTankHealth(entity) <= 0 or GetVehicleBodyHealth(entity) <= 0 then
                DeleteEntity(entity)
                activeVehicles[vehicle.plate] = nil
                table.insert(filtered, vehicle)
            end
        end

        return filtered
    end
end)

lib.callback.register('drs_garages:takeOutVehicle', function(source, index, plate, type, society)
    if not databaseIsUsable(source) then return end

    plate = normalizePlate(plate)
    if not plate or isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return end

    local player = Framework.getPlayerFromId(source)
    if not player then return end

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

    local vehicle = MySQL.single.await(Queries.getStoredVehicle, {
        player:getIdentifier(), player:getJob(), plate, 1
    })

    if isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return end

    if vehicle then
        if not vehicleMatchesOwnershipMode(vehicle, player, society) then
            return
        end

        local coords = garage.SpawnPosition
        local props = json.decode(vehicle.mods or vehicle.vehicle)
        local entity = Utils.createVehicle(props.model, coords, type)

        if entity == 0 then return end

        setVehicleStored(plate, 0)

        while NetworkGetEntityOwner(entity) == -1 do Wait(0) end

        local netId, owner = NetworkGetNetworkIdFromEntity(entity), NetworkGetEntityOwner(entity)
        
        TriggerClientEvent('drs_garages:setVehicleProperties', owner, netId, props)

        activeVehicles[plate] = entity
        giveVehicleKeys(source, entity)

        return netId
    end
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

    if not plate or not model then return false end

    local entity = validateVehicleForStorage(source, garage, netId, plate, model)
    if not entity then return false end

    -- Only the server-registered entity for this plate may change persistent
    -- storage state. A client-created clone with a copied plate/model is rejected.
    if not isExactActiveVehicle(plate, entity) then return false end

    local identifier = player:getIdentifier()
    local initialJob = player:getJob()
    local ownershipMode = 'personal'
    local ownershipJob

    local function revalidateOwnershipContext()
        local currentPlayer = Framework.getPlayerFromId(source)

        if not currentPlayer or currentPlayer:getIdentifier() ~= identifier then return end
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
        if garage.Property or type(initialJob) ~= 'string' or initialJob == '' or player:getJob() ~= initialJob then
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
    if not hasStoredModel or not modelMatches then return false end

    props.plate = plate
    local encodedOk, encodedProps = pcall(json.encode, props)
    if not encodedOk or type(encodedProps) ~= 'string' then return false end

    local maxPropsBytes = tonumber(Config.MaxVehiclePropsBytes)
    if not maxPropsBytes or maxPropsBytes ~= maxPropsBytes or maxPropsBytes <= 0 then
        maxPropsBytes = 64 * 1024
    end

    maxPropsBytes = math.floor(maxPropsBytes)
    if #encodedProps > maxPropsBytes then return false end

    local garageName = garageStorageName(index, garage)
    local isQb = Framework.name == 'qb-core' or Framework.name == 'qbx_core'
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

    local function scopedUpdate(setClause, setParams)
        for i = 1, #ownershipParams do
            setParams[#setParams + 1] = ownershipParams[i]
        end

        return ('UPDATE `%s` SET %s WHERE %s'):format(tableName, setClause, ownershipWhere), setParams
    end

    local updateQuery, updateParams

    if isQb then
        if garageName then
            updateQuery, updateParams = scopedUpdate(
                '`stored` = 1, `state` = 1, `garage` = ?, `mods` = ?',
                { garageName, encodedProps }
            )
        else
            updateQuery, updateParams = scopedUpdate(
                '`stored` = 1, `state` = 1, `mods` = ?',
                { encodedProps }
            )
        end
    else
        updateQuery, updateParams = scopedUpdate(
            '`stored` = 1, `vehicle` = ?',
            { encodedProps }
        )
    end

    -- The row must still describe an out vehicle. Deleting first means a failed
    -- deletion cannot alter its state or client-supplied properties at all.
    if databaseInteger(storedVehicle.stored) ~= 0 then return false end
    if isQb and databaseInteger(storedVehicle.state) ~= 0 then return false end

    if vehicleStorageOperations[plate] or not isExactActiveVehicle(plate, entity) then return false end
    vehicleStorageOperations[plate] = entity

    local deleted = deleteRegisteredVehicle(plate, entity, netId)

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

        vehicleStorageOperations[plate] = nil
        return false
    end

    -- Deletion polling yields. Revalidate the selected personal/society session
    -- before committing the now-absent vehicle to storage.
    player = revalidateOwnershipContext()
    if not player or vehicleStorageOperations[plate] ~= entity or activeVehicles[plate] ~= entity then
        if activeVehicles[plate] == entity then activeVehicles[plate] = nil end
        vehicleStorageOperations[plate] = nil
        return false
    end

    local updateOk, changed = pcall(MySQL.update.await, updateQuery, updateParams)

    -- The update yields as well; preserve the chosen identity/job check before
    -- releasing the reservation. A failed update leaves the deleted row out so it
    -- remains recoverable from impound rather than duplicating a live vehicle.
    revalidateOwnershipContext()

    local changedCount = tonumber(changed)
    local stored = updateOk and changedCount and changedCount >= 1

    if activeVehicles[plate] == entity then activeVehicles[plate] = nil end
    vehicleStorageOperations[plate] = nil

    return stored == true
end)

lib.callback.register('drs_garages:retrieveVehicle', function(source, index, plate, type, society)
    if not databaseIsUsable(source) then return false end

    plate = normalizePlate(plate)
    if not plate or isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return end

    local player = Framework.getPlayerFromId(source)
    if not player then return end

    local impound = Config.Impounds[index]
    if not impound then
        invalidIndexMessage('impound', source, index)
        return false
    end

    if not playerCanAccessGarage(player, impound) or not isNearGarage(source, impound) or not spawnTypeMatchesGarage(type, impound) then
        return false
    end

    local vehicle = MySQL.single.await(Queries.getOwnedVehicle, {
        player:getIdentifier(), player:getJob(), plate
    })

    if isVehicleStorageInProgress(plate) or getActiveVehicleByPlate(plate) then return false end

    if vehicle then
        if not vehicleMatchesOwnershipMode(vehicle, player, society) then
            return false
        end

        if player:getAccountMoney('money') < Config.ImpoundPrice then return false end

        player:removeAccountMoney('money', Config.ImpoundPrice)

        local coords = impound.SpawnPosition
        local props = json.decode(vehicle.mods or vehicle.vehicle)
        local entity = Utils.createVehicle(props.model, coords, type)

        if entity == 0 then return end

        setVehicleStored(plate, 0)

        while NetworkGetEntityOwner(entity) == -1 do Wait(0) end

        local netId, owner = NetworkGetNetworkIdFromEntity(entity), NetworkGetEntityOwner(entity)
        
        TriggerClientEvent('drs_garages:setVehicleProperties', owner, netId, props)

        activeVehicles[props.plate] = entity
        giveVehicleKeys(source, entity)

        return true, netId
    end

    return false
end)

lib.callback.register('drs_garages:getVehicleCoords', function(source, plate)
    local entity = activeVehicles[plate]

    if not entity then return end

    return GetEntityCoords(entity)
end)
