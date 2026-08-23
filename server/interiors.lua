local ROUTING_BUCKET_OFFSET <const> = 1000
local inside = {}
local resourceName = GetCurrentResourceName()

lib.callback.register('drs_garages:enterInterior', function(source, index, vehicleType, sessionToken)
    if type(CanUseDrsGarageDatabase) ~= 'function' or not CanUseDrsGarageDatabase(source) then return false end

    if (type(index) ~= 'number' and type(index) ~= 'string') or type(vehicleType) ~= 'string' then return false end
    if type(sessionToken) ~= 'number' or sessionToken % 1 ~= 0 or sessionToken < 1 then return false end

    local player = Framework.getPlayerFromId(source)
    
    if not player then return false end
    local identifier = player:getIdentifier()
    if type(identifier) ~= 'string' or identifier == '' then return false end
    if inside[source] then return false end
    if not CanEnterDrsGarageInterior or not CanEnterDrsGarageInterior(source, index, vehicleType) then return false end

    local queryOk, vehicles = pcall(MySQL.query.await, Queries.getStoredGarage, { identifier })

    if not queryOk or type(vehicles) ~= 'table' then return false end

    if not FilterDrsGarageVehicles then return false end
    player = Framework.getPlayerFromId(source)
    if not player or player:getIdentifier() ~= identifier then return false end
    vehicles = FilterDrsGarageVehicles(source, index, vehicles, false)
    if not BuildDrsGarageClientVehicles then return false end
    vehicles = BuildDrsGarageClientVehicles(vehicles)

    -- The database read yields. Re-run the complete access/proximity/type check
    -- before changing routing state.
    player = Framework.getPlayerFromId(source)
    if not player or player:getIdentifier() ~= identifier then return false end

    if inside[source] or not CanEnterDrsGarageInterior
        or not CanEnterDrsGarageInterior(source, index, vehicleType)
    then
        return false
    end

    local bucketId = ROUTING_BUCKET_OFFSET + source
    local previousBucket = GetPlayerRoutingBucket(source)
    local exitPosition = GetDrsGarageExitPosition and GetDrsGarageExitPosition(source, index)
    if not exitPosition then return false end

    inside[source] = {
        index = index,
        token = sessionToken,
        previousBucket = previousBucket,
        exitPosition = exitPosition
    }

    SetPlayerRoutingBucket(source, bucketId)
    SetRoutingBucketPopulationEnabled(bucketId, false)

    return vehicles
end)

lib.callback.register('drs_garages:getInteriorExitPosition', function(source, index, sessionToken)
    local session = inside[source]

    if not session or session.index ~= index then return end
    if sessionToken ~= nil and session.token ~= sessionToken then return end

    return session.exitPosition
end)

RegisterNetEvent('drs_garages:exitInterior', function(sessionToken)
    local source = source
    local session = inside[source]

    if session and (sessionToken == nil or session.token == sessionToken) then
        SetPlayerRoutingBucket(source, session.previousBucket or 0)
        inside[source] = nil
    end
end)

AddEventHandler('playerDropped', function()
    inside[source] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= resourceName then return end

    for source, session in pairs(inside) do
        if GetPlayerName(source) then
            SetPlayerRoutingBucket(source, session.previousBucket or 0)
        end
    end

    inside = {}
end)
