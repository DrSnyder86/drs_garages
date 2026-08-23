-- This part of the script could've been written much better, if you have the time to do so, create a PR.
-- TODO: Refactor

local busy, currentIndex, point, entities, lastCoords = false, nil, nil, {}, nil
local fadeTimeout = 5000
local interiorGeneration = 0
local currentSessionToken

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function exteriorReturnCoords(garage)
    local position = garage and (garage.Position or garage.PedPosition or garage.SpawnPosition)
    if not position or not isFiniteNumber(position.x) or not isFiniteNumber(position.y) or not isFiniteNumber(position.z) then
        return
    end

    local heading = position.w or position.heading

    if not isFiniteNumber(heading) then
        heading = garage.PedPosition and (garage.PedPosition.w or garage.PedPosition.heading)
            or garage.SpawnPosition and (garage.SpawnPosition.w or garage.SpawnPosition.heading)
    end

    if not isFiniteNumber(heading) then heading = GetEntityHeading(cache.ped) end
    return vector4(position.x, position.y, position.z, heading)
end

local function waitForFade(predicate)
    local deadline = GetGameTimer() + fadeTimeout

    while not predicate() and GetGameTimer() < deadline do
        Wait(50)
    end

    return predicate()
end

local function fadeOut()
    DoScreenFadeOut(500)
    return waitForFade(IsScreenFadedOut)
end

local function fadeIn()
    DoScreenFadeIn(500)
    return waitForFade(IsScreenFadedIn)
end

local function deleteDisplayVehicles()
    for _, entity in ipairs(entities) do
        if DoesEntityExist(entity) then
            DeleteEntity(entity)
        end
    end

    table.wipe(entities)
end

local function removeInteriorPoint()
    if not point then return end

    point:remove()
    point = nil
end

local function clearInterior(restorePosition, notifyServer)
    local sessionToken = currentSessionToken
    interiorGeneration += 1
    currentSessionToken = nil

    HideUI()
    Binds.first.removeListener('choose_vehicle')
    Binds.first.removeListener('exit_garage')
    deleteDisplayVehicles()
    removeInteriorPoint()

    currentIndex = nil

    if notifyServer then
        TriggerServerEvent('drs_garages:exitInterior', sessionToken)
    end

    if restorePosition and lastCoords and cache.ped and DoesEntityExist(cache.ped) then
        SetEntityCoords(cache.ped, lastCoords.x, lastCoords.y, lastCoords.z)
        if isFiniteNumber(lastCoords.w) then SetEntityHeading(cache.ped, lastCoords.w) end
    end

    lastCoords = nil
    busy = false
end

local function decodeVehicleProperties(vehicle)
    local encoded = vehicle and (vehicle.mods or vehicle.vehicle)
    if type(encoded) == 'table' then return encoded end
    if type(encoded) ~= 'string' or encoded == '' then return end

    local ok, props = pcall(json.decode, encoded)
    if ok and type(props) == 'table' then return props end
end

local function isSubmarineModel(model)
    return type(IsThisModelASubmarine) == 'function' and IsThisModelASubmarine(model)
        or type(IsThisModelASubmersible) == 'function' and IsThisModelASubmersible(model)
        or model == `avisa` or model == `kosatka` or model == `submersible` or model == `submersible2`
end

local function getVehicleGarageType(model)
    if IsThisModelABoat(model) or IsThisModelAJetski(model) or isSubmarineModel(model) then
        return 'boat'
    end

    if IsThisModelAPlane(model) or IsThisModelAHeli(model) then
        return 'air'
    end

    return 'car'
end

local function chooseVehicle(index)
    if busy then
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        return
    end

    Binds.first.removeListener('choose_vehicle')
    busy = true
    local vehicle = cache.vehicle
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        busy = false
        return
    end

    local props = lib.getVehicleProperties(vehicle)

    if not props then
        busy = false
        return
    end

    fadeOut()

    local returnCoords = lastCoords
    clearInterior(false, true)
    Wait(1000)

    if returnCoords then
        SetEntityCoords(cache.ped, returnCoords.x, returnCoords.y, returnCoords.z)
        if isFiniteNumber(returnCoords.w) then SetEntityHeading(cache.ped, returnCoords.w) end
    end

    SpawnVehicle({ index = index, props = props })
    fadeIn()
end

lib.onCache('vehicle', function(vehicle)
    if currentIndex then
        if vehicle then
            ShowUI(locale('choose_vehicle', Binds.first.currentKey))
            Binds.first.addListener('choose_vehicle', chooseVehicle, currentIndex)
        else
            HideUI()
            Binds.first.removeListener('choose_vehicle')
        end
    end
end)

---@param index integer|string The garage index
function EnterInterior(index)
    local garage = GetDrsGarage and GetDrsGarage(index) or Config.Garages[index]

    if not garage?.Interior then
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        return
    end

    local interior = Config.GarageInteriors[garage.Interior]

    if not interior then
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        return
    end

    if busy then
        if IsScreenFadedOut() then DoScreenFadeIn(500) end
        return
    end

    interiorGeneration += 1
    local generation = interiorGeneration
    currentSessionToken = generation
    busy, currentIndex = true, index

    fadeOut()

    lastCoords = exteriorReturnCoords(garage)

    if not lastCoords then
        lastCoords = vector4(cache.coords.x, cache.coords.y, cache.coords.z, GetEntityHeading(cache.ped))
    end

    -- Authorize while the server still sees the player at the exterior. The
    -- callback moves the player into the private routing bucket only after its
    -- access, type, and proximity checks pass.
    local vehicles = lib.callback.await('drs_garages:enterInterior', false, index, garage.Type, generation)

    if generation ~= interiorGeneration or currentSessionToken ~= generation or currentIndex ~= index then
        -- A logout/resource cleanup may have raced the callback. A token-scoped
        -- second exit safely clears a server session created after that cleanup.
        TriggerServerEvent('drs_garages:exitInterior', generation)
        return
    end

    if not vehicles then
        clearInterior(true, true)
        fadeIn()
        return
    end

    SetEntityCoords(cache.ped, interior.Coords.x, interior.Coords.y, interior.Coords.z)
    SetEntityHeading(cache.ped, interior.Coords.w)
    SetGameplayCamRelativeHeading(0.0)

    local vehicleIndex = 1
    for i = 1, #interior.Vehicles do
        local coords = interior.Vehicles[i]
        local spawned = false

        repeat
            local vehicle = vehicles[vehicleIndex]

            if not vehicle then goto skip end

            ---@type VehicleProperties
            local props = decodeVehicleProperties(vehicle)

            if props?.model and getVehicleGarageType(props.model) == garage.Type and IsModelValid(props.model) then
                lib.requestModel(props.model)

                if generation ~= interiorGeneration or currentSessionToken ~= generation or currentIndex ~= index then
                    TriggerServerEvent('drs_garages:exitInterior', generation)
                    return
                end

                Framework.spawnLocalVehicle(props.model, coords.xyz, coords.w, function(entity)
                    if generation ~= interiorGeneration or currentSessionToken ~= generation or currentIndex ~= index then
                        if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
                        return
                    end

                    lib.setVehicleProperties(entity, props)
                    
                    for _ = 1, 10 do
                        SetVehicleOnGroundProperly(entity)
                        Wait(0)
                    end

                    FreezeEntityPosition(entity, true)
                    table.insert(entities, entity)
                end)

                spawned = true
            end

            vehicleIndex += 1
        until spawned
    end

    ::skip::

    Wait(1000)

    if generation ~= interiorGeneration or currentSessionToken ~= generation or currentIndex ~= index then
        TriggerServerEvent('drs_garages:exitInterior', generation)
        return
    end

    fadeIn()

    busy = false

    if #vehicles > #interior.Vehicles then
        ShowNotification(locale('too_many_vehicles'), 'error')
    end

    point = lib.points.new({
        coords = interior.Coords.xyz,
        distance = 1.0,
        onEnter = function(self)
            ShowUI(locale('exit_garage', Binds.first.currentKey), 'door-open')
            Binds.first.addListener('exit_garage', function()
                if busy then return end

                busy = true
                fadeOut()
                clearInterior(true, true)
                Wait(1000)
                fadeIn()
            end)
        end,
        onExit = function()
            HideUI()
            Binds.first.removeListener('exit_garage')
        end
    })
end

RegisterNetEvent('drs_garages:client:enterInterior', function(index)
    EnterInterior(index)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    clearInterior(true, false)

    if IsScreenFadedOut() then
        DoScreenFadeIn(0)
    end
end)

local function handlePlayerLogout()
    if not currentIndex and not lastCoords and #entities == 0 then return end

    clearInterior(true, true)

    if IsScreenFadedOut() then
        DoScreenFadeIn(0)
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerUnload', handlePlayerLogout)
RegisterNetEvent('qbx_core:client:playerLoggedOut', handlePlayerLogout)
RegisterNetEvent('esx:onPlayerLogout', handlePlayerLogout)
