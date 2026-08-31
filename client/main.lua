local propertyGarages = {}
local propertyGarageZones = {}
local propertyGarageParkZones = {}
local propertyGaragePedPoints = {}
local staticGarageZones = {}
local impoundZones = {}
local staticGarageRadialZones = {}
local propertyGarageRadialZones = {}
local nearbyGarageRadialContexts = {}
local currentGarageIndex
local currentGarageMode
local networkTimeout = 10000
local propertyRequestGeneration = 0
local nuiReady = false
local nuiSession
local nuiSessionGeneration = 0
local invalidInterfaceModeWarned = false
local enforcementImpoundBusy = false
local parkingOperation
local parkingInspectionBusy = false
local nearbyGarageRadialHandle
local RADIAL_GARAGE_OPTION_ID <const> = 'drs_garages_open_nearby'

local function applyTakeoutVehicleProperties(vehicle, props)
    lib.setVehicleProperties(vehicle, props)

    -- Keep the native lock authoritative even on ox_lib builds that do not
    -- apply lockState from vehicle properties by default.
    if Framework.name == 'qbx_core'
        and props.lockState == 1
        and GetVehicleType(vehicle) == 'bike'
    then
        SetVehicleDoorsLocked(vehicle, 1)
    end
end

local function waitForNetworkVehicle(netId, timeout)
    if type(netId) ~= 'number' or netId <= 0 then return end

    local deadline = GetGameTimer() + (timeout or networkTimeout)

    while not NetworkDoesEntityExistWithNetworkId(netId) and GetGameTimer() < deadline do
        Wait(0)
    end

    if not NetworkDoesEntityExistWithNetworkId(netId) then return end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) then return end

    return vehicle
end

local function applyVehiclePropertiesWhenOwned(vehicle, props)
    CreateThread(function()
        local deadline = GetGameTimer() + networkTimeout

        while DoesEntityExist(vehicle) and GetGameTimer() < deadline do
            if NetworkGetEntityOwner(vehicle) == cache.playerId then
                applyTakeoutVehicleProperties(vehicle, props)
                return
            end

            if GetVehicleNumberPlateText(vehicle):strtrim(' ') == props.plate then
                return
            end

            Wait(0)
        end
    end)
end

local function decodeVehicleProperties(vehicle)
    local encoded = vehicle and (vehicle.mods or vehicle.vehicle)
    if type(encoded) == 'table' then return encoded end
    if type(encoded) ~= 'string' or encoded == '' then return end

    local ok, props = pcall(json.decode, encoded)
    if ok and type(props) == 'table' then return props end

    warn(('[drs_garages] Ignoring invalid vehicle properties for plate %s.'):format(tostring(vehicle.plate)))
end

local VEHICLE_SETTER_TYPE_EXCEPTIONS = {
    [`airtug`] = 'automobile',
    [`avisa`] = 'submarine',
    [`blimp`] = 'heli',
    [`blimp2`] = 'heli',
    [`blimp3`] = 'heli',
    [`caddy`] = 'automobile',
    [`caddy2`] = 'automobile',
    [`caddy3`] = 'automobile',
    [`chimera`] = 'automobile',
    [`docktug`] = 'automobile',
    [`forklift`] = 'automobile',
    [`kosatka`] = 'submarine',
    [`mower`] = 'automobile',
    [`policeb`] = 'bike',
    [`ripley`] = 'automobile',
    [`rrocket`] = 'automobile',
    [`sadler`] = 'automobile',
    [`sadler2`] = 'automobile',
    [`scrap`] = 'automobile',
    [`slamtruck`] = 'automobile',
    [`stryder`] = 'automobile',
    [`submersible`] = 'submarine',
    [`submersible2`] = 'submarine',
    [`thruster`] = 'heli',
    [`towtruck`] = 'automobile',
    [`towtruck2`] = 'automobile',
    [`tractor`] = 'automobile',
    [`tractor2`] = 'automobile',
    [`tractor3`] = 'automobile',
    [`trailersmall2`] = 'trailer',
    [`utillitruck`] = 'automobile',
    [`utillitruck2`] = 'automobile',
    [`utillitruck3`] = 'automobile'
}

local VEHICLE_CLASS_TO_SETTER_TYPE = {
    [8] = 'bike',
    [11] = 'trailer',
    [13] = 'bike',
    [14] = 'boat',
    [15] = 'heli',
    [16] = 'plane',
    [21] = 'train'
}

local function isSubmarineModel(model)
    return VEHICLE_SETTER_TYPE_EXCEPTIONS[model] == 'submarine'
        or type(IsThisModelASubmarine) == 'function' and IsThisModelASubmarine(model)
        or type(IsThisModelASubmersible) == 'function' and IsThisModelASubmersible(model)
end

local function getVehicleSpawnType(model)
    local exception = VEHICLE_SETTER_TYPE_EXCEPTIONS[model]
    if exception then return exception end

    local vehicleClass = GetVehicleClassFromName(model)
    return VEHICLE_CLASS_TO_SETTER_TYPE[vehicleClass] or 'automobile'
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

local function getVehicleTakeoutLockState(vehicle)
    -- Stock qbx_vehiclekeys treats native `bike` vehicles as no-lock. Forcing
    -- them locked here leaves Qbox with no supported path to unlock them.
    if Framework.name == 'qbx_core' and GetVehicleType(vehicle) == 'bike' then
        return 1
    end

    return 2
end

local function prepareVehicleTakeoutProperties(vehicle, props)
    local takeoutProps = {}

    for key, value in pairs(props) do
        takeoutProps[key] = value
    end

    takeoutProps.lockState = getVehicleTakeoutLockState(vehicle)
    return takeoutProps
end

local function getGarage(index)
    if type(index) == 'string' then
        return propertyGarages[index]
    end

    return Config.Garages[index]
end

function GetDrsGarage(index)
    return getGarage(index)
end

-- Taken from ox_lib, but higher timeout value and modified
RegisterNetEvent('drs_garages:setVehicleProperties', function(netId, data)
    if type(data) ~= 'table' then return end

    local vehicle = waitForNetworkVehicle(netId)
    if not vehicle or NetworkGetEntityOwner(vehicle) ~= cache.playerId then return end

    applyTakeoutVehicleProperties(vehicle, data)
end)

local function finishVehicleTakeout(vehicle, props, location)
    local takeoutProps = prepareVehicleTakeoutProperties(vehicle, props)
    applyVehiclePropertiesWhenOwned(vehicle, takeoutProps)

    TaskTurnPedToFaceCoord(
        cache.ped,
        location.SpawnPosition.x,
        location.SpawnPosition.y,
        location.SpawnPosition.z,
        1000
    )

    Wait(1000)

    local stateBagValue = Entity(vehicle).state.doorslockstate
    if takeoutProps.lockState ~= 1 and stateBagValue then
        SetVehicleDoorsLocked(vehicle, stateBagValue)
    end

    SetVehicleLockState(vehicle, takeoutProps.lockState)

    SetVehicleLights(vehicle, 2)
    Wait(250)
    SetVehicleLights(vehicle, 1)
    Wait(200)
    SetVehicleLights(vehicle, 0)

    SetVehicleFuel(vehicle, takeoutProps.fuelLevel or 100.0)
    SetVehicleOwner(props.plate, vehicle)

    ShowNotification(locale('vehicle_retrieved'), 'success')
end

function SpawnVehicle(args)
    ---@type integer, VehicleProperties
    local index, props = args and args.index, args and args.props

    local garage = getGarage(index)
    if not garage or type(props) ~= 'table' or not props.model or not props.plate then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    if Config.SpawnpointCheck and lib.getClosestVehicle(garage.SpawnPosition.xyz, 3.0, false) then
        ShowNotification(locale('spawn_occupied'), 'error')
        return
    end

    lib.progressBar({
        duration = 3000,
        label = locale('retrieving_vehicle'),
        useWhileDead = false,
        canCancel = false,
        disable = {
            move = true,
            car = true,
            combat = true
        }
    })

    lib.requestModel(props.model)
    local spawnType = getVehicleSpawnType(props.model)
    local netId = lib.callback.await('drs_garages:takeOutVehicle', false, index, props.plate, spawnType, args.society)
    if not netId then
        SetModelAsNoLongerNeeded(props.model)
        ShowNotification(locale('vehicle_retrieve_failed'), 'error')
        return
    end

    local vehicle = waitForNetworkVehicle(netId)
    SetModelAsNoLongerNeeded(props.model)

    if not vehicle then
        ShowNotification(locale('vehicle_network_timeout'), 'error')
        return
    end

    finishVehicleTakeout(vehicle, props, garage)
end

function GetVehicleLabel(model)
    local label = GetLabelText(GetDisplayNameFromVehicleModel(model))

    if label == 'NULL' then
        label = GetDisplayNameFromVehicleModel(model)
    end

    return label
end

local function getClassIcon(class)
    if class == 8 then
        return 'motorcycle'
    elseif class == 13 then
        return 'bicycle'
    elseif class == 14 then
        return 'ship'
    elseif class == 15 then
        return 'helicopter'
    elseif class == 16 then
        return 'plane'
    else
        return 'car'
    end
end

local function getFuelBarColor(fuel)
    -- fuelLevel not defined in vehicleProps??
    if not fuel then return 'lime' end

    if fuel > 75.0 then
        return 'lime'
    elseif fuel > 50.0 then
        return 'yellow'
    elseif fuel > 25.0 then
        return 'orange'
    else
        return 'red'
    end
end

local function openGarageVehicles(args)
    local index, society = args.index, args.society
    if not index then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    local garage = getGarage(index)
    if not garage then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    local vehicles = lib.callback.await('drs_garages:getOwnedVehicles', false, index, society) or {}

    ---@type ContextMenuArrayItem[]
    local options = {}

    for _, vehicle in ipairs(vehicles) do
        ---@type VehicleProperties
        local props = decodeVehicleProperties(vehicle)

        if props?.model and getVehicleGarageType(props.model) == garage.Type then
            local class = GetVehicleClassFromName(GetDisplayNameFromVehicleModel(props.model))
            local fuelLevel = props.fuelLevel or 100.0

            ---@type ContextMenuArrayItem
            local option = {
                title = locale('vehicle_info', GetVehicleLabel(props.model), props.plate),
                icon = getClassIcon(class),
                progress = class ~= 13 and fuelLevel,
                colorScheme = class ~= 13 and getFuelBarColor(fuelLevel),
                metadata = {
                    ---@diagnostic disable-next-line: assign-type-mismatch
                    { label = locale('status'), value = locale(vehicle.state) },

                    ---@diagnostic disable-next-line: assign-type-mismatch
                    { label = locale('fuel'), value = class ~= 13 and fuelLevel .. '%' or locale('no_fueltank') }
                },
                args = { index = index, props = props, society = society },
                onSelect = vehicle.state == 'in_garage' and SpawnVehicle or function()
                    if vehicle.state == 'out_garage' then
                        local coords = lib.callback.await('drs_garages:getVehicleCoords', false, vehicle.plate, society)
                        if coords then
                            SetNewWaypoint(coords.x, coords.y)
                            ShowNotification(locale('out_garage_message'))
                        else
                            ShowNotification(locale('in_impound_message'), 'error')
                        end
                    elseif vehicle.state == 'in_impound' then
                        ShowNotification(locale('in_impound_message'), 'error')
                    end
                end
            }

            table.insert(options, option)
        end
    end

    if #options == 0 then
        ShowNotification(society and locale('no_society_vehicles') or locale('no_owned_vehicles'), 'error')
        return
    end

    lib.registerContext({
        id = 'garage_vehicles',
        title = society and locale('society_vehicles') or locale('player_vehicles'),
        menu = 'garage_menu',
        options = options
    })

    lib.showContext('garage_vehicles')
end

local function getFleetManagerAccess(index, garage)
    local settings = type(Config.JobFleet) == 'table' and Config.JobFleet or {}
    if settings.Enabled == false or not garage or garage.Property or garage.Jobs == nil then return end

    local called, response = pcall(lib.callback.await, 'drs_garages:fleet:canManage', false, index)
    if not called or type(response) ~= 'table' then return end
    if response.ok ~= true and response.needsJob ~= true then return end

    return {
        job = type(response.job) == 'string' and response.job or nil,
        admin = response.admin == true,
        needsJob = response.needsJob == true
    }
end

local function openFleetManager(index, access)
    TriggerEvent('drs_garages:fleet:open', index, access and access.job or nil)
end

local function openGarageContext(index)
    local garage = getGarage(index)
    if not garage then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    local options = {
        {
            title = locale('player_vehicles'),
            description = locale('player_vehicles_desc'),
            icon = 'user',
            arrow = true,
            args = { index = index, society = false },
            onSelect = openGarageVehicles
        }
    }

    if not garage.Property then
        options[#options + 1] = {
            title = locale('society_vehicles'),
            description = locale('society_vehicles_desc'),
            icon = 'users',
            arrow = true,
            args = { index = index, society = true },
            onSelect = openGarageVehicles
        }
    end

    local fleetAccess = getFleetManagerAccess(index, garage)
    if fleetAccess then
        options[#options + 1] = {
            title = locale('fleet_manager'),
            description = locale('fleet_manager_desc'),
            icon = 'warehouse',
            arrow = true,
            onSelect = function() openFleetManager(index, fleetAccess) end
        }
    end

    lib.registerContext({
        id = 'garage_menu',
        title = garage.Label or locale('garage_menu'),
        options = options
    })

    lib.showContext('garage_menu')
end

local function getParkingSettings()
    local settings = type(Config.Parking) == 'table' and Config.Parking or {}
    local duration = tonumber(settings.ProgressDuration) or 5000
    local maximumSpeed = tonumber(settings.MaximumSpeed) or 0.5
    local targetDistance = tonumber(settings.TargetDistance) or 3.0

    if duration ~= duration or duration == math.huge or duration == -math.huge then duration = 5000 end
    if maximumSpeed ~= maximumSpeed or maximumSpeed == math.huge or maximumSpeed == -math.huge then maximumSpeed = 0.5 end
    if targetDistance ~= targetDistance or targetDistance == math.huge or targetDistance == -math.huge then targetDistance = 3.0 end

    return settings,
        math.min(60000, math.max(0, math.floor(duration))),
        math.max(0.0, maximumSpeed),
        math.min(20.0, math.max(0.5, targetDistance))
end

local function garageRadius(configured, fallback)
    local radius = tonumber(configured) or tonumber(fallback) or 3.0
    if radius ~= radius or radius == math.huge or radius == -math.huge then radius = tonumber(fallback) or 3.0 end
    return math.max(0.0, radius)
end

local function distanceFromCoords(point, coords)
    if not coords then return end
    return #(point - vector3(coords.x, coords.y, coords.z))
end

local function vehicleIsEmpty(vehicle)
    local maximumPassengerSeat = 15
    local seatsOk, configuredPassengerSeats = pcall(GetVehicleMaxNumberOfPassengers, vehicle)
    if seatsOk then maximumPassengerSeat = math.max(maximumPassengerSeat, tonumber(configuredPassengerSeats) or 0) end

    for seat = -1, maximumPassengerSeat do
        if GetPedInVehicleSeat(vehicle, seat) ~= 0 then return false end
    end

    return true
end


local function vehicleHasOccupantOtherThan(vehicle, allowedPed)
    local maximumPassengerSeat = 15
    local seatsOk, configuredPassengerSeats = pcall(GetVehicleMaxNumberOfPassengers, vehicle)
    if seatsOk then maximumPassengerSeat = math.max(maximumPassengerSeat, tonumber(configuredPassengerSeats) or 0) end

    for seat = -1, maximumPassengerSeat do
        local occupant = GetPedInVehicleSeat(vehicle, seat)
        if occupant ~= 0 and occupant ~= allowedPed then return true end
    end

    return false
end

local function garageParkingScore(index, garage, vehicle)
    if not garage or not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end
    if garage.Jobs and not Utils.hasJobs(garage.Jobs) then return end
    if getVehicleGarageType(GetEntityModel(vehicle)) ~= tostring(garage.Type or 'car'):lower() then return end

    local playerCoords = GetEntityCoords(cache.ped)
    local vehicleCoords = GetEntityCoords(vehicle)
    local playerNear, nearestVehicleDistance = false, math.huge

    if garage.Property then
        local radius = garageRadius(
            Config.PropertyGarageParkingDistance,
            Config.PropertyGarageDistance or 3.0
        )
        local playerDistance = distanceFromCoords(playerCoords, garage.SpawnPosition)
        local vehicleDistance = distanceFromCoords(vehicleCoords, garage.SpawnPosition)

        if not playerDistance or not vehicleDistance or playerDistance > radius or vehicleDistance > radius then return end
        return playerDistance + vehicleDistance
    end

    local radius = garageRadius(Config.MaxDistance, 10.0)
    local function checkPlayer(coords)
        local distance = distanceFromCoords(playerCoords, coords)
        if distance and distance <= radius then playerNear = true end
    end

    checkPlayer(garage.Position)
    checkPlayer(garage.PedPosition)

    if not garage.Position and not garage.PedPosition then
        local distance = distanceFromCoords(playerCoords, garage.SpawnPosition)
        if distance and distance <= radius then playerNear = true end
    end

    if not playerNear then return end

    local function checkVehicle(coords)
        local distance = distanceFromCoords(vehicleCoords, coords)
        if distance and distance <= radius then nearestVehicleDistance = math.min(nearestVehicleDistance, distance) end
    end

    checkVehicle(garage.Position)
    checkVehicle(garage.PedPosition)
    checkVehicle(garage.SpawnPosition)

    if nearestVehicleDistance == math.huge then return end
    return nearestVehicleDistance
end

local function resolveParkingGarage(vehicle, preferredIndex)
    if preferredIndex ~= nil then
        local preferredGarage = getGarage(preferredIndex)
        local score = garageParkingScore(preferredIndex, preferredGarage, vehicle)
        if score then return preferredIndex, preferredGarage, score end
        return
    end

    local bestIndex, bestGarage, bestScore, bestKey
    local function consider(index, garage)
        local score = garageParkingScore(index, garage, vehicle)
        if not score then return end

        local key = ('%s:%s'):format(type(index), tostring(index))
        if not bestScore or score < bestScore or score == bestScore and key < bestKey then
            bestIndex, bestGarage, bestScore, bestKey = index, garage, score, key
        end
    end

    for index, garage in ipairs(Config.Garages) do
        consider(index, garage)
    end

    for index, garage in pairs(propertyGarages) do
        consider(index, garage)
    end

    return bestIndex, bestGarage, bestScore
end

local function validateClientParkingContext(operation, requireDriver)
    local vehicle = operation.vehicle
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then
        return false, 'parking_context_changed'
    end
    if getGarage(operation.index) ~= operation.garage then return false, 'parking_context_changed' end
    if NetworkGetNetworkIdFromEntity(vehicle) ~= operation.netId then return false, 'parking_context_changed' end
    if GetEntityModel(vehicle) ~= operation.model then return false, 'vehicle_identity_mismatch' end
    if GetVehicleNumberPlateText(vehicle):strtrim(' ') ~= operation.plate then return false, 'vehicle_identity_mismatch' end
    if not garageParkingScore(operation.index, operation.garage, vehicle) then return false, 'parking_context_changed' end

    local stateOk, removalPending = pcall(function()
        return Entity(vehicle).state.drsEnforcementImpoundPending == true
    end)
    if stateOk and removalPending then return false, 'storage_in_progress' end

    local _, _, maximumSpeed = getParkingSettings()
    if GetEntitySpeed(vehicle) > maximumSpeed then return false, 'vehicle_moving' end

    if requireDriver then
        if GetPedInVehicleSeat(vehicle, -1) ~= cache.ped then return false, 'parking_context_changed' end
        if vehicleHasOccupantOtherThan(vehicle, cache.ped) then return false, 'vehicle_occupied' end
    else
        if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false, 'not_driver' end
        if not vehicleIsEmpty(vehicle) then return false, 'vehicle_occupied' end
        if #(GetEntityCoords(cache.ped) - GetEntityCoords(vehicle)) > 20.0 then return false, 'vehicle_too_far' end
    end

    return true
end

---@param vehicle number?
local PARKING_FAILURE_LOCALES = {
    active_vehicle_mismatch = 'vehicle_registration_failed',
    active_vehicle_untrusted = 'vehicle_registration_failed',
    database_unavailable = 'database_unavailable',
    duplicate_plate_entity = 'vehicle_registration_failed',
    invalid_garage = 'invalid_garage',
    player_outside_parking_area = 'vehicle_not_in_parking_area',
    storage_in_progress = 'vehicle_save_busy',
    vehicle_not_owned = 'not_your_vehicle',
    vehicle_occupied = 'vehicle_must_be_empty',
    vehicle_moving = 'vehicle_must_be_stationary',
    vehicle_outside_parking_area = 'vehicle_not_in_parking_area',
    vehicle_too_far = 'vehicle_not_in_parking_area',
    vehicle_type_mismatch = 'vehicle_wrong_garage_type',
    parking_context_changed = 'vehicle_parking_context_changed',
    vehicle_identity_mismatch = 'vehicle_parking_context_changed'
}

local function saveVehicle(index, vehicle)
    if type(index) ~= 'number' and type(index) ~= 'string' then
        vehicle = index
        index = currentGarageIndex
    end

    if parkingOperation then
        ShowNotification(locale('vehicle_save_busy'), 'error')
        return
    end

    local garage = index and getGarage(index) or nil
    if not index or not garage then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    local explicitVehicle = vehicle
    vehicle = explicitVehicle or cache.vehicle

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        ShowNotification(locale('vehicle_parking_context_changed'), 'error')
        return
    end

    local playerVehicle = GetVehiclePedIsIn(cache.ped, false)
    local startedAsDriver = playerVehicle == vehicle and GetPedInVehicleSeat(vehicle, -1) == cache.ped
    if playerVehicle ~= 0 and not startedAsDriver then
        ShowNotification(locale('not_driver'), 'error')
        return
    end

    local props = lib.getVehicleProperties(vehicle)

    if not props then return end

    props.plate = props.plate:strtrim(' ') -- Trim whitespace
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local spawnType = getVehicleSpawnType(props.model)
    if not NetworkGetEntityIsNetworked(vehicle) or not netId or netId < 1 then
        ShowNotification(locale('vehicle_registration_failed'), 'error')
        return
    end

    local operation = {
        index = index,
        garage = garage,
        vehicle = vehicle,
        netId = netId,
        model = props.model,
        plate = props.plate,
        startedAsDriver = startedAsDriver,
        progressFinished = false
    }

    local contextValid, contextReason = validateClientParkingContext(operation, startedAsDriver)
    if not contextValid then
        ShowNotification(locale(PARKING_FAILURE_LOCALES[contextReason] or 'vehicle_save_failed'), 'error')
        return
    end

    local settings, duration = getParkingSettings()
    if type(lib.progressActive) == 'function' and lib.progressActive() then
        ShowNotification(locale('vehicle_save_busy'), 'error')
        return
    end

    parkingOperation = operation
    local operationOk, operationError = xpcall(function()
        if duration > 0 then
            CreateThread(function()
                while parkingOperation == operation and not operation.progressFinished do
                    local valid, reason = validateClientParkingContext(operation, operation.startedAsDriver)
                    if not valid then
                        operation.invalidReason = reason
                        pcall(lib.cancelProgress)
                        return
                    end

                    Wait(100)
                end
            end)

            local completed = lib.progressBar({
                duration = duration,
                label = locale('parking_vehicle'),
                useWhileDead = false,
                canCancel = settings.ProgressCanCancel ~= false,
                disable = {
                    move = true,
                    car = true,
                    combat = true
                },
                anim = not startedAsDriver and {
                    dict = 'mini@repair',
                    clip = 'fixing_a_ped'
                } or nil
            })

            operation.progressFinished = true
            if not completed then
                if operation.invalidReason then
                    ShowNotification(locale(PARKING_FAILURE_LOCALES[operation.invalidReason] or 'vehicle_parking_context_changed'), 'error')
                else
                    ShowNotification(locale('vehicle_parking_cancelled'))
                end
                return
            end
        else
            operation.progressFinished = true
        end

        local valid, reason = validateClientParkingContext(operation, operation.startedAsDriver)
        if not valid then
            ShowNotification(locale(PARKING_FAILURE_LOCALES[reason] or 'vehicle_parking_context_changed'), 'error')
            return
        end

        if operation.startedAsDriver then
            TaskLeaveVehicle(cache.ped, vehicle, 0)
            local exitDeadline = GetGameTimer() + 3000
            while GetVehiclePedIsIn(cache.ped, false) == vehicle and GetGameTimer() < exitDeadline do
                Wait(0)
            end

            -- Boats, aircraft, and some large vehicles can take longer to exit.
            -- Preserve the actual mode after the courtesy wait: the server
            -- authoritatively accepts either this exact sole driver or the same
            -- empty nearby vehicle, and revalidates it throughout the save.
            operation.startedAsDriver = GetVehiclePedIsIn(cache.ped, false) == vehicle
                and GetPedInVehicleSeat(vehicle, -1) == cache.ped
            valid, reason = validateClientParkingContext(operation, operation.startedAsDriver)
            if not valid then
                ShowNotification(locale(PARKING_FAILURE_LOCALES[reason] or 'vehicle_parking_context_changed'), 'error')
                return
            end
        end

        local result, serverReason = lib.callback.await('drs_garages:saveVehicle', false, {
            plate = operation.plate,
            model = operation.model
        }, operation.netId, operation.index, spawnType)

        if result then
            ShowNotification(locale('vehicle_saved'), 'success')
        else
            ShowNotification(locale(PARKING_FAILURE_LOCALES[serverReason] or 'vehicle_save_failed'), 'error')
        end
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    operation.progressFinished = true
    if parkingOperation == operation then parkingOperation = nil end

    if not operationOk then
        warn(('[drs_garages] Parking client error: %s'):format(tostring(operationError)))
        ShowNotification(locale('vehicle_save_failed'), 'error')
    end
end

local function normalizeEnforcementRule(rule)
    if type(rule) == 'number' then
        return { MinGrade = math.floor(rule), RequireDuty = false }
    end

    if type(rule) ~= 'table' then return end
    return {
        MinGrade = math.max(0, math.floor(tonumber(rule.MinGrade or rule.minGrade or rule.Grade or rule.grade) or 0)),
        RequireDuty = rule.RequireDuty == true or rule.requireDuty == true
    }
end

local function getEnforcementJobAuthorization()
    local settings = type(Config.EnforcementImpound) == 'table' and Config.EnforcementImpound or nil
    if not settings or settings.Enabled ~= true then return end

    local jobData = type(Framework.getJobData) == 'function' and Framework.getJobData() or nil
    if type(jobData) ~= 'table' then
        local name = Framework.getJob()
        if not name then return end
        jobData = { name = name, grade = 0, onDuty = false }
    end

    local jobName = type(jobData.name) == 'string' and jobData.name:lower() or nil
    local jobType = type(jobData.type) == 'string' and jobData.type:lower() or nil
    local jobs = type(settings.Jobs) == 'table' and settings.Jobs or {}
    local jobTypes = type(settings.JobTypes) == 'table' and settings.JobTypes or {}
    local rule = jobName and (jobs[jobName] or jobs[jobData.name]) or nil
    if rule == nil and jobType then rule = jobTypes[jobType] or jobTypes[jobData.type] end

    rule = normalizeEnforcementRule(rule)
    if not rule or (tonumber(jobData.grade) or 0) < rule.MinGrade then return end
    if rule.RequireDuty and jobData.onDuty ~= true then return end

    return true, jobData, rule
end

local function canTargetVehicleForImpound(vehicle, distance, ignoreBusy)
    local settings = type(Config.EnforcementImpound) == 'table' and Config.EnforcementImpound or nil
    if (enforcementImpoundBusy and not ignoreBusy) or not settings or settings.Enabled ~= true or not getEnforcementJobAuthorization() then return false end
    if cache.vehicle or type(vehicle) ~= 'number' or vehicle == 0 or not DoesEntityExist(vehicle) then return false end
    if GetEntityType(vehicle) ~= 2 then return false end

    local stateOk, removalPending = pcall(function()
        return Entity(vehicle).state.drsEnforcementImpoundPending == true
    end)
    if stateOk and removalPending then return false end

    local ambientSettings = type(settings.AmbientVehicles) == 'table' and settings.AmbientVehicles or {}
    if not NetworkGetEntityIsNetworked(vehicle) and ambientSettings.Enabled ~= true then return false end

    local maximumDistance = math.max(0.5, tonumber(settings.Distance) or 3.0)
    if tonumber(distance) and distance > maximumDistance then return false end
    if #(GetEntityCoords(cache.ped) - GetEntityCoords(vehicle)) > maximumDistance then return false end
    if GetEntitySpeed(vehicle) > math.max(0.0, tonumber(settings.MaximumSpeed) or 1.0) then return false end

    return vehicleIsEmpty(vehicle)
end

local ENFORCEMENT_IMPOUND_FAILURE_LOCALES = {
    database_unavailable = 'database_unavailable',
    impound_already_recorded = 'enforcement_impound_already_recorded',
    invalid_fee = 'enforcement_impound_invalid_fee',
    invalid_reason = 'enforcement_impound_invalid_reason',
    not_authorized = 'enforcement_impound_not_authorized',
    storage_in_progress = 'vehicle_save_busy',
    vehicle_occupied = 'vehicle_must_be_empty',
    vehicle_not_managed = 'enforcement_impound_not_managed',
    vehicle_not_ambient = 'enforcement_impound_not_ambient',
    vehicle_not_owned = 'enforcement_impound_not_owned',
    vehicle_too_far = 'enforcement_impound_too_far',
    vehicle_moving = 'enforcement_impound_moving'
}

local function getEnforcementVehicleNetworkId(vehicle, settings)
    if NetworkGetEntityIsNetworked(vehicle) then
        local netId = NetworkGetNetworkIdFromEntity(vehicle)
        if netId and netId > 0 and NetworkGetEntityFromNetworkId(netId) == vehicle then return netId end
    end

    local ambientSettings = type(settings.AmbientVehicles) == 'table' and settings.AmbientVehicles or {}
    if ambientSettings.Enabled ~= true then return end

    local timeout = math.min(5000, math.max(250, math.floor(tonumber(ambientSettings.NetworkTimeout) or 2000)))
    local deadline = GetGameTimer() + timeout

    while DoesEntityExist(vehicle) and GetGameTimer() < deadline do
        NetworkRegisterEntityAsNetworked(vehicle)

        if NetworkGetEntityIsNetworked(vehicle) then
            local netId = NetworkGetNetworkIdFromEntity(vehicle)
            if netId and netId > 0 and NetworkGetEntityFromNetworkId(netId) == vehicle then
                SetNetworkIdCanMigrate(netId, true)
                return netId
            end
        end

        Wait(0)
    end
end

local function startEnforcementImpound(vehicle, requestedDefaultFee)
    if not canTargetVehicleForImpound(vehicle) then return false end

    local settings = Config.EnforcementImpound
    enforcementImpoundBusy = true
    local netId = getEnforcementVehicleNetworkId(vehicle, settings)
    if not netId then
        enforcementImpoundBusy = false
        ShowNotification(locale('enforcement_impound_not_managed'), 'error')
        return false
    end

    local operationOk, operationError = xpcall(function()
        local inspectOk, vehicleMode = lib.callback.await('drs_garages:inspectEnforcementImpoundVehicle', false, netId)
        if not inspectOk then
            ShowNotification(locale(ENFORCEMENT_IMPOUND_FAILURE_LOCALES[vehicleMode] or 'enforcement_impound_failed'), 'error')
            return
        end

        local minimumFee = math.floor(tonumber(settings.MinimumFee) or 0)
        local maximumFee = math.floor(tonumber(settings.MaximumFee) or 25000)
        local defaultFee = math.floor(tonumber(requestedDefaultFee) or tonumber(settings.DefaultFee) or 0)
        defaultFee = math.max(minimumFee, math.min(maximumFee, defaultFee))
        local input

        if vehicleMode == 'ambient' then
            local confirmation = lib.alertDialog({
                header = locale('enforcement_ambient_title'),
                content = locale('enforcement_ambient_description'),
                centered = true,
                cancel = true,
                labels = {
                    confirm = locale('enforcement_ambient_confirm'),
                    cancel = locale('enforcement_ambient_cancel')
                }
            })

            if confirmation ~= 'confirm' then return end
        else
            input = lib.inputDialog(locale('enforcement_impound_title'), {
                {
                    type = 'input',
                    label = locale('enforcement_impound_reason'),
                    description = locale('enforcement_impound_reason_description'),
                    required = true,
                    min = math.max(1, math.floor(tonumber(settings.MinimumReasonLength) or 3)),
                    max = math.max(1, math.floor(tonumber(settings.MaximumReasonLength) or 200))
                },
                {
                    type = 'number',
                    label = locale('enforcement_impound_fee'),
                    description = locale('enforcement_impound_fee_description'),
                    required = true,
                    default = defaultFee,
                    min = minimumFee,
                    max = maximumFee,
                    precision = 0,
                    step = 1
                }
            })

            if not input then return end
        end

        local currentVehicle = NetworkGetEntityFromNetworkId(netId)
        if currentVehicle ~= vehicle or not canTargetVehicleForImpound(currentVehicle, nil, true) then
            ShowNotification(locale('enforcement_impound_vehicle_changed'), 'error')
            return
        end

        local completed = lib.progressCircle({
            duration = math.max(0, math.floor(tonumber(settings.Duration) or 5000)),
            label = locale(vehicleMode == 'ambient' and 'enforcement_ambient_progress' or 'enforcement_impound_progress'),
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = {
                move = true,
                car = true,
                combat = true
            },
            anim = {
                dict = 'amb@world_human_clipboard@male@base',
                clip = 'base'
            }
        })

        if not completed then return end

        currentVehicle = NetworkGetEntityFromNetworkId(netId)
        if currentVehicle ~= vehicle or not canTargetVehicleForImpound(currentVehicle, nil, true) then
            ShowNotification(locale('enforcement_impound_vehicle_changed'), 'error')
            return
        end

        local success, reason, completedMode, removalDelay
        if vehicleMode == 'ambient' then
            success, reason, completedMode, removalDelay = lib.callback.await(
                'drs_garages:removeAmbientVehicle',
                false,
                netId
            )
        else
            success, reason, completedMode, removalDelay = lib.callback.await(
                'drs_garages:enforcementImpoundVehicle',
                false,
                netId,
                input[1],
                input[2]
            )
        end

        if success then
            local delaySeconds = math.max(0, math.ceil((tonumber(removalDelay) or 0) / 1000))
            if completedMode == 'ambient' then
                ShowNotification(locale('enforcement_ambient_success', delaySeconds), 'success')
            else
                ShowNotification(locale(
                    'enforcement_impound_success',
                    math.floor(tonumber(input and input[2]) or 0),
                    delaySeconds
                ), 'success')
            end
        else
            ShowNotification(locale(ENFORCEMENT_IMPOUND_FAILURE_LOCALES[reason] or 'enforcement_impound_failed'), 'error')
        end
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)

    enforcementImpoundBusy = false
    if not operationOk then
        warn(('[drs_garages] Enforcement impound client error: %s'):format(tostring(operationError)))
        ShowNotification(locale('enforcement_impound_failed'), 'error')
    end

    return operationOk
end

-- Trusted client resources can open the exact same DRS dialog used by the
-- global target. The server callback still repeats every authorization and
-- vehicle check; this export only avoids duplicate police-job UI code.
exports('OpenEnforcementImpound', function(vehicle, defaultFee)
    return startEnforcementImpound(vehicle, defaultFee)
end)

local function retrieveVehicle(args)
    ---@type integer, VehicleProperties
    local index, props = args and args.index, args and args.props

    local impound = index and Config.Impounds[index] or nil
    if not impound or type(props) ~= 'table' or not props.model or not props.plate then
        ShowNotification(locale('invalid_impound'), 'error')
        return
    end

    if Config.SpawnpointCheck and lib.getClosestVehicle(impound.SpawnPosition.xyz, 3.0, false) then
        ShowNotification(locale('spawn_occupied'), 'error')
        return
    end

    lib.progressBar({
        duration = 3000,
        label = locale('retrieving_vehicle'),
        useWhileDead = false,
        canCancel = false,
        disable = {
            move = true,
            car = true,
            combat = true
        }
    })

    lib.requestModel(props.model)
    local type = getVehicleSpawnType(props.model)

    local success, netId, failureReason = lib.callback.await('drs_garages:retrieveVehicle', false, index, props.plate, type, args.society)

    if not success or not netId then
        SetModelAsNoLongerNeeded(props.model)
        local localeKey = failureReason == 'not_enough_money' and 'not_enough_money'
            or failureReason == 'impound_on_hold' and 'impound_on_hold'
            or failureReason == 'database_unavailable' and 'database_unavailable'
            or 'vehicle_retrieve_failed'
        ShowNotification(locale(localeKey), 'error')
        return
    end

    local vehicle = waitForNetworkVehicle(netId)
    SetModelAsNoLongerNeeded(props.model)

    if not vehicle then
        ShowNotification(locale('vehicle_network_timeout'), 'error')
        return
    end

    finishVehicleTakeout(vehicle, props, impound)
end

local function openImpoundVehicles(args)
    local index, society = args.index, args.society
    if not index then
        ShowNotification(locale('invalid_impound'), 'error')
        return
    end

    local impound = Config.Impounds[index]
    if not impound then
        ShowNotification(locale('invalid_impound'), 'error')
        return
    end

    local vehicles = lib.callback.await('drs_garages:getImpoundedVehicles', false, index, society) or {}

    ---@type ContextMenuArrayItem[]
    local options = {}

    for _, vehicle in ipairs(vehicles) do
        ---@type VehicleProperties
        local props = decodeVehicleProperties(vehicle)

        if props?.model and getVehicleGarageType(props.model) == impound.Type then
            local class = GetVehicleClassFromName(GetDisplayNameFromVehicleModel(props.model))
            local fuelLevel = props.fuelLevel or 100.0
            local impoundFee = math.max(0, math.floor(tonumber(vehicle.impound_fee) or tonumber(Config.ImpoundPrice) or 0))
            local metadata = {
                ---@diagnostic disable-next-line: assign-type-mismatch
                { label = locale('fuel'), value = class ~= 13 and fuelLevel .. '%' or locale('no_fueltank') },
                { label = locale('impound_fee'), value = ('$%s'):format(impoundFee) }
            }

            if vehicle.impound_reason then
                metadata[#metadata + 1] = { label = locale('impound_reason'), value = vehicle.impound_reason }
            end
            if vehicle.impounded_by_name then
                local officer = vehicle.impounded_by_job
                    and ('%s · %s'):format(vehicle.impounded_by_name, vehicle.impounded_by_job)
                    or vehicle.impounded_by_name
                metadata[#metadata + 1] = { label = locale('impounded_by'), value = officer }
            end
            if vehicle.impounded_at_label then
                metadata[#metadata + 1] = { label = locale('impounded_at'), value = vehicle.impounded_at_label }
            end

            ---@type ContextMenuArrayItem
            local option = {
                title = locale('vehicle_info', GetVehicleLabel(props.model), props.plate),
                icon = getClassIcon(class),
                progress = class ~= 13 and fuelLevel,
                colorScheme = class ~= 13 and getFuelBarColor(fuelLevel),
                metadata = metadata,
                description = vehicle.impound_hold and locale('impound_on_hold') or nil,
                disabled = vehicle.impound_hold == true,
                args = { index = index, props = props, society = society },
                onSelect = retrieveVehicle
            }

            table.insert(options, option)
        end
    end

    if #options == 0 then
        ShowNotification(locale('no_impounded_vehicles'), 'error')
        return
    end

    lib.registerContext({
        id = 'impound_vehicles',
        title = society and locale('society_vehicles') or locale('player_vehicles'),
        menu = 'impound_menu',
        options = options
    })

    lib.showContext('impound_vehicles')
end

local function openImpoundContext(index)
    lib.registerContext({
        id = 'impound_menu',
        title = locale('impound_menu'),
        options = {
            {
                title = locale('player_vehicles'),
                description = locale('player_vehicles_desc'),
                icon = 'user',
                arrow = true,
                args = { index = index, society = false },
                onSelect = openImpoundVehicles
            },
            {
                title = locale('society_vehicles'),
                description = locale('society_vehicles_desc'),
                icon = 'users',
                arrow = true,
                args = { index = index, society = true },
                onSelect = openImpoundVehicles
            },
        }
    })

    lib.showContext('impound_menu')
end

local validInterfaceModes = {
    auto = true,
    nui = true,
    context = true
}

local function getInterfaceSettings()
    local settings = type(Config.Interface) == 'table' and Config.Interface or {}
    local mode = type(settings.Mode) == 'string' and settings.Mode:lower() or 'auto'

    if not validInterfaceModes[mode] then
        if not invalidInterfaceModeWarned then
            invalidInterfaceModeWarned = true
            warn(('[drs_garages] Invalid Config.Interface.Mode %q; using auto.'):format(tostring(settings.Mode)))
        end

        mode = 'auto'
    end

    return settings, mode
end

local function safeInterfaceText(value, maxLength)
    if type(value) ~= 'string' and type(value) ~= 'number' then return end

    local text = tostring(value):gsub('[%z\1-\31\127]', '')
    maxLength = math.max(1, math.floor(tonumber(maxLength) or 96))

    if utf8 and utf8.len and utf8.offset then
        local length = utf8.len(text)
        if not length then return end
        if length > maxLength then
            local cutoff = utf8.offset(text, maxLength + 1)
            if cutoff then text = text:sub(1, cutoff - 1) end
        end
    elseif #text > maxLength then
        text = text:sub(1, maxLength)
    end

    return text ~= '' and text or nil
end

local function sanitizeModelName(value)
    if type(value) ~= 'string' then return end

    local model = value:match('^%s*([%w_-]+)%s*$')
    if not model or #model > 64 or model:match('^%d+$') then return end

    return model:lower()
end

local function getVehicleModelName(vehicle, props)
    local storedModel = vehicle and sanitizeModelName(vehicle.vehicle)
    if storedModel then return storedModel end

    if not props or not props.model then return end

    return sanitizeModelName(GetDisplayNameFromVehicleModel(props.model))
end

local function safeImageFilename(value)
    if type(value) ~= 'string' or #value > 128 then return end

    local filename = value:match('([^/\\]+)$')
    if not filename or not filename:match('^[%w_.-]+$') then return end

    local extension = filename:match('%.([%w]+)$')
    if not extension then
        filename = filename .. '.webp'
        extension = 'webp'
    end

    extension = extension:lower()
    if extension ~= 'webp' and extension ~= 'png' and extension ~= 'jpg' and extension ~= 'jpeg' and extension ~= 'avif' then
        return
    end

    return filename
end

local function safeImageUrl(value)
    if type(value) ~= 'string' or #value > 1024 or not value:match('^https://') then return end
    if value:find('[%z\1-\31\127]') then return end

    return value
end

local function getVehicleShopPresentation(modelIdentity, settings)
    if settings.UseVehicleShopImages == false or not modelIdentity then return end

    local resource = sanitizeModelName(settings.VehicleShopResource or 'drs_vehicleshop')
    if not resource or GetResourceState(resource) ~= 'started' then return end

    local ok, presentation = pcall(function()
        return exports[resource]:ResolveVehiclePresentation(modelIdentity)
    end)

    if not ok then return resource end
    if type(presentation) == 'string' then presentation = { image = presentation } end

    return resource, type(presentation) == 'table' and presentation or nil
end

local function buildVehicleImageCandidates(modelName, settings, shopResource, presentation)
    local candidates, seen = {}, {}

    local function addUrl(value)
        local url = safeImageUrl(value)
        if not url or seen[url] then return end

        seen[url] = true
        candidates[#candidates + 1] = url
    end

    local function addShopFile(value)
        if not shopResource then return end

        local filename = safeImageFilename(value)
        if filename then
            addUrl(('https://cfx-nui-%s/html/assets/vehicles/%s'):format(shopResource, filename))
        end
    end

    if presentation then
        local exportedCandidates = presentation.imageCandidates or presentation.candidates
        if type(exportedCandidates) == 'table' then
            for i = 1, math.min(#exportedCandidates, 8) do
                local candidate = exportedCandidates[i]
                addUrl(candidate)
                addShopFile(candidate)
            end
        end

        addUrl(presentation.imageUrl or presentation.url)
        addShopFile(presentation.image or presentation.imageFile or presentation.filename)
    end

    if settings.UseVehicleShopImages ~= false then
        addShopFile(modelName and (modelName .. '.webp'))
    end

    if settings.UseCfxImages ~= false and modelName then
        addUrl(('https://docs.fivem.net/vehicles/%s.webp'):format(modelName))
    end

    return candidates
end

local function clampPercentage(value, divisor)
    value = tonumber(value)
    if not value then return end

    value = value / (divisor or 1)
    return math.floor(math.max(0, math.min(100, value)) + 0.5)
end

local function getVehicleClassLabel(class)
    local label = GetLabelText(('VEH_CLASS_%s'):format(class))
    if label == 'NULL' or label == '' then return end

    return safeInterfaceText(label, 48)
end

local function closeGarageNui(sendMessage)
    local closingSession = nuiSession
    nuiSession = nil
    nuiSessionGeneration += 1

    SetNuiFocus(false, false)

    if sendMessage ~= false then
        SendNUIMessage({
            action = 'close',
            sessionId = closingSession and closingSession.id or nil
        })
    end
end

local function sendNuiBusy(session, busy)
    if nuiSession ~= session then return end

    SendNUIMessage({
        action = 'busy',
        sessionId = session.id,
        busy = busy == true
    })
end

local function getNuiScopes(session)
    local scopes = {
        { id = 'personal', label = locale('player_vehicles') }
    }

    if session.allowSociety then
        scopes[#scopes + 1] = { id = 'society', label = locale('society_vehicles') }
    end

    return scopes
end

local function buildNuiPayload(action, session, vehicles)
    local isSociety = session.scope == 'society'

    return {
        action = action,
        sessionId = session.id,
        title = safeInterfaceText(session.location.Label, 96)
            or (session.mode == 'impound' and locale('impound_menu') or locale('garage_menu')),
        subtitle = session.mode == 'impound' and locale('garage_ui_impound_subtitle') or locale('garage_ui_subtitle'),
        mode = session.mode,
        activeScope = session.scope,
        scopes = getNuiScopes(session),
        canManageFleet = session.canManageFleet == true,
        vehicles = vehicles,
        labels = {
            search = locale('garage_ui_search'),
            empty = session.mode == 'impound' and locale('no_impounded_vehicles')
                or (isSociety and locale('no_society_vehicles') or locale('no_owned_vehicles')),
            fuel = locale('fuel'),
            engine = locale('garage_ui_engine'),
            body = locale('garage_ui_body'),
            close = locale('garage_ui_close'),
            impoundReason = locale('impound_reason'),
            impoundFee = locale('impound_fee'),
            impoundedBy = locale('impounded_by'),
            impoundedAt = locale('impounded_at'),
            impoundHold = locale('garage_ui_hold'),
            impoundHoldDescription = locale('impound_on_hold'),
            vehicleSingular = locale('garage_ui_vehicle_singular'),
            vehiclePlural = locale('garage_ui_vehicle_plural'),
            filteredCount = locale('garage_ui_filtered_count'),
            unavailableTitle = locale('garage_ui_unavailable_title'),
            noResultsTitle = locale('garage_ui_no_results_title'),
            noResultsMessage = locale('garage_ui_no_results_message'),
            noImpoundedTitle = locale('garage_ui_no_impounded_title'),
            noStoredTitle = locale('garage_ui_no_stored_title'),
            modeImpound = locale('garage_ui_mode_impound'),
            modeGarage = locale('garage_ui_mode_garage'),
            sortVehicles = locale('garage_ui_sort_vehicles'),
            sortStatus = locale('garage_ui_sort_status'),
            sortNameAsc = locale('garage_ui_sort_name_asc'),
            sortNameDesc = locale('garage_ui_sort_name_desc'),
            sortFuelDesc = locale('garage_ui_sort_fuel_desc'),
            sortFuelAsc = locale('garage_ui_sort_fuel_asc'),
            sortImpoundedDesc = locale('garage_ui_sort_impounded_desc'),
            sortImpoundedAsc = locale('garage_ui_sort_impounded_asc'),
            sortFeeDesc = locale('garage_ui_sort_fee_desc'),
            sortFeeAsc = locale('garage_ui_sort_fee_asc'),
            manageFleet = locale('fleet_manager'),
            fleetMinGrade = locale('fleet_min_grade')
        }
    }
end

local function queryNuiVehicles(session, scope, revision)
    local society = scope == 'society'
    local callbackName = session.mode == 'impound'
        and 'drs_garages:getImpoundedVehicles'
        or 'drs_garages:getOwnedVehicles'
    local vehicles = lib.callback.await(callbackName, false, session.index, society) or {}
    local settings = getInterfaceSettings()
    local cards, items = {}, {}
    local legacyImpoundPrice = math.max(0, math.floor(tonumber(Config.ImpoundPrice) or 0))
    local enforcementSettings = type(Config.EnforcementImpound) == 'table' and Config.EnforcementImpound or {}
    local impoundReasonMax = math.min(500, math.max(1,
        math.floor(tonumber(enforcementSettings.MaximumReasonLength) or 200)
    ))

    for _, vehicle in ipairs(type(vehicles) == 'table' and vehicles or {}) do
        local props = decodeVehicleProperties(vehicle)

        -- Keep the exact vehicle-type filter used by the original context menus.
        if props and props.model and getVehicleGarageType(props.model) == session.location.Type then
            props.plate = props.plate or vehicle.plate

            local class = GetVehicleClassFromName(props.model)
            local modelName = getVehicleModelName(vehicle, props)
            local shopResource, presentation = getVehicleShopPresentation(props.model, settings)

            if not presentation and modelName then
                local fallbackResource, fallbackPresentation = getVehicleShopPresentation(modelName, settings)
                shopResource = shopResource or fallbackResource
                presentation = fallbackPresentation
            end

            local presentationModel = presentation and sanitizeModelName(presentation.model)
            if presentationModel then modelName = presentationModel end
            local status = session.mode == 'impound' and 'in_impound' or vehicle.state
            local actionKind, actionLabel
            local impoundPrice = math.max(0, math.floor(tonumber(vehicle.impound_fee) or legacyImpoundPrice))

            if session.mode == 'impound' then
                if vehicle.impound_hold then
                    actionKind = 'hold'
                    actionLabel = locale('garage_ui_hold')
                else
                    actionKind = 'retrieve'
                    actionLabel = locale('garage_ui_retrieve')
                end
            elseif status == 'in_garage' then
                actionKind = 'takeout'
                actionLabel = locale('garage_ui_take_out')
            elseif status == 'out_garage' then
                actionKind = 'locate'
                actionLabel = locale('garage_ui_locate')
            else
                status = 'in_impound'
                actionKind = 'impounded'
                actionLabel = locale('in_impound')
            end

            local itemId = ('v%s_%s'):format(revision, #cards + 1)
            local fuel = class ~= 13 and clampPercentage(props.fuelLevel or 100.0) or nil
            local presentationName = presentation and (presentation.name or presentation.label)

            cards[#cards + 1] = {
                id = itemId,
                name = safeInterfaceText(presentationName, 96) or safeInterfaceText(GetVehicleLabel(props.model), 96) or modelName,
                brand = presentation and safeInterfaceText(presentation.brand, 48) or nil,
                model = modelName,
                plate = safeInterfaceText(props.plate or vehicle.plate or '', 16) or '',
                status = status,
                statusLabel = locale(status),
                fuel = fuel,
                engine = clampPercentage(props.engineHealth, 10),
                body = clampPercentage(props.bodyHealth, 10),
                classLabel = getVehicleClassLabel(class),
                fleetManaged = vehicle.fleet_managed == true,
                fleetMinGrade = vehicle.fleet_managed == true and math.max(0, math.floor(tonumber(vehicle.fleet_min_grade) or 0)) or nil,
                imageCandidates = buildVehicleImageCandidates(modelName, settings, shopResource, presentation),
                actionLabel = actionLabel,
                actionKind = actionKind,
                price = session.mode == 'impound' and impoundPrice or nil,
                impoundReason = session.mode == 'impound' and safeInterfaceText(vehicle.impound_reason, impoundReasonMax) or nil,
                impoundFee = session.mode == 'impound' and impoundPrice or nil,
                impoundedBy = session.mode == 'impound' and safeInterfaceText(vehicle.impounded_by_name, 100) or nil,
                impoundedByJob = session.mode == 'impound' and safeInterfaceText(vehicle.impounded_by_job, 50) or nil,
                impoundedAt = session.mode == 'impound' and tonumber(vehicle.impounded_at) or nil,
                impoundHold = session.mode == 'impound' and vehicle.impound_hold == true or false,
                disabled = not props.plate
                    or session.mode == 'impound' and vehicle.impound_hold == true
                    or session.mode ~= 'impound' and status == 'in_impound'
            }

            items[itemId] = {
                props = props,
                plate = vehicle.plate or props.plate,
                state = status,
                society = society
            }
        end
    end

    return cards, items
end

local function waitForNuiReady()
    if nuiReady then return true end

    SendNUIMessage({ action = 'ping' })
    local deadline = GetGameTimer() + 750

    while not nuiReady and GetGameTimer() < deadline do
        Wait(0)
    end

    return nuiReady
end

local function openGarageNui(mode, index, location)
    if not waitForNuiReady() then return false end

    closeGarageNui()

    nuiSessionGeneration += 1
    local generation = nuiSessionGeneration
    local fleetAccess = mode == 'garage' and getFleetManagerAccess(index, location) or nil
    local session = {
        id = ('drs-%s-%s'):format(generation, GetGameTimer()),
        generation = generation,
        expiresAt = GetGameTimer() + 120000,
        revision = 1,
        mode = mode,
        index = index,
        location = location,
        allowSociety = mode == 'impound' or not location.Property,
        canManageFleet = fleetAccess ~= nil,
        fleetJob = fleetAccess and fleetAccess.job or nil,
        scope = 'personal',
        busy = true,
        items = {}
    }

    nuiSession = session
    local vehicles, items = queryNuiVehicles(session, session.scope, session.revision)

    if nuiSession ~= session or session.generation ~= nuiSessionGeneration then
        return true
    end

    session.items = items
    session.busy = false
    SetNuiFocus(true, true)
    SendNUIMessage(buildNuiPayload('open', session, vehicles))

    CreateThread(function()
        while nuiSession == session and GetGameTimer() < session.expiresAt do
            Wait(1000)
        end

        if nuiSession == session then closeGarageNui() end
    end)

    return true
end

local function openGarage(index)
    local garage = getGarage(index)
    if not garage then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    local settings, mode = getInterfaceSettings()
    if mode ~= 'context' and openGarageNui('garage', index, garage) then return end

    if mode == 'context' or mode == 'auto' or settings.ContextFallback ~= false then
        openGarageContext(index)
    else
        ShowNotification(locale('garage_ui_unavailable'), 'error')
    end
end

local function openImpound(index)
    local impound = Config.Impounds[index]
    if not impound then
        ShowNotification(locale('invalid_impound'), 'error')
        return
    end

    local settings, mode = getInterfaceSettings()
    if mode ~= 'context' and openGarageNui('impound', index, impound) then return end

    if mode == 'context' or mode == 'auto' or settings.ContextFallback ~= false then
        openImpoundContext(index)
    else
        ShowNotification(locale('garage_ui_unavailable'), 'error')
    end
end

local radialGarageSuppressed = false

local function getGarageRadialRadius(garage)
    local settings = type(Config.RadialMenu) == 'table' and Config.RadialMenu or {}
    local allowed = garage.Property
        and garageRadius(Config.PropertyGarageDistance, 3.0)
        or garageRadius(Config.MaxDistance, 10.0)
    local configured = garage.Property and settings.PropertyDistance or settings.Distance

    return math.min(allowed, garageRadius(configured, allowed))
end

local function resolveNearbyRadialGarage()
    if radialGarageSuppressed then return end
    if type(Framework.isPlayerLoaded) == 'function' and not Framework.isPlayerLoaded() then return end

    local playerCoords = GetEntityCoords(cache.ped)
    local bestContext, bestDistance, bestKey

    for context in pairs(nearbyGarageRadialContexts) do
        local garage = getGarage(context.index)
        if garage == context.garage and (not garage.Jobs or Utils.hasJobs(garage.Jobs)) then
            local distance = distanceFromCoords(playerCoords, context.coords)
            local key = ('%s:%s'):format(type(context.index), tostring(context.index))

            if distance and distance <= context.radius + 0.25
                and (not bestDistance or distance < bestDistance or distance == bestDistance and key < bestKey)
            then
                bestContext, bestDistance, bestKey = context, distance, key
            end
        end
    end

    return bestContext
end


local function refreshNearbyGarageRadial(force)
    local context = resolveNearbyRadialGarage()

    if nearbyGarageRadialHandle and (force or not context) then
        Utils.removeRadialOption(nearbyGarageRadialHandle)
        nearbyGarageRadialHandle = nil
    end

    if not context or nearbyGarageRadialHandle then return end

    nearbyGarageRadialHandle = Utils.addRadialOption(RADIAL_GARAGE_OPTION_ID, {
        label = locale('open_garage'),
        icon = 'warehouse',
        onSelect = function()
            local current = resolveNearbyRadialGarage()
            if not current then
                ShowNotification(locale('garage_radial_too_far'), 'error')
                return
            end

            openGarage(current.index)
        end
    })
end

local function removeGarageRadialZone(record)
    if not record then return end

    nearbyGarageRadialContexts[record.context] = nil
    if record.zone then record.zone:remove() end
    refreshNearbyGarageRadial()
end

local function createGarageRadialZone(index, garage, trackProperty)
    if not Utils.isRadialEnabled() then return end

    local records, seen = {}, {}
    local function addZone(coords)
        if not coords then return end

        local key = ('%.2f:%.2f:%.2f'):format(coords.x, coords.y, coords.z)
        if seen[key] then return end
        seen[key] = true

        local context = {
            index = index,
            garage = garage,
            coords = vector3(coords.x, coords.y, coords.z),
            radius = getGarageRadialRadius(garage)
        }
        local record = { context = context }

        record.zone = lib.zones.sphere({
            coords = context.coords,
            radius = context.radius,
            onEnter = function()
                nearbyGarageRadialContexts[context] = true
                refreshNearbyGarageRadial()
            end,
            onExit = function()
                nearbyGarageRadialContexts[context] = nil
                refreshNearbyGarageRadial()
            end
        })

        records[#records + 1] = record
        if not trackProperty then staticGarageRadialZones[#staticGarageRadialZones + 1] = record end
    end

    addZone(garage.Position)
    addZone(garage.PedPosition)
    if not garage.Position and not garage.PedPosition then addZone(garage.SpawnPosition) end

    if trackProperty and #records > 0 then
        propertyGarageRadialZones[index] = records
    end
end

local function refreshRadialAfterLifecycle(delay, force)
    CreateThread(function()
        Wait(delay or 0)
        refreshNearbyGarageRadial(force)
    end)
end

AddEventHandler('radialmenu:client:deadradial', function(isDead)
    radialGarageSuppressed = isDead == true
    refreshRadialAfterLifecycle(100, true)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    radialGarageSuppressed = false
    refreshRadialAfterLifecycle(250, true)
end)

RegisterNetEvent('esx:playerLoaded', function()
    radialGarageSuppressed = false
    refreshRadialAfterLifecycle(250, true)
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function()
    refreshRadialAfterLifecycle(0, true)
end)

RegisterNetEvent('QBCore:Client:SetDuty', function()
    refreshRadialAfterLifecycle(0, true)
end)

RegisterNetEvent('esx:setJob', function()
    refreshRadialAfterLifecycle(0, true)
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qbx_radialmenu' or resource == 'qb-radialmenu' or resource == 'ox_lib' then
        refreshRadialAfterLifecycle(250, true)
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'qbx_radialmenu' or resource == 'qb-radialmenu' or resource == 'ox_lib' then
        refreshRadialAfterLifecycle(100, true)
    end
end)

RegisterNUICallback('ready', function(_, cb)
    nuiReady = true
    cb({ ok = true })
end)

RegisterNUICallback('close', function(data, cb)
    local session = nuiSession
    if session and type(data) == 'table' and data.sessionId == session.id then
        closeGarageNui()
    end

    cb({ ok = true })
end)

RegisterNUICallback('scope', function(data, cb)
    local session = nuiSession
    local sessionId = type(data) == 'table' and data.sessionId or nil
    local requestedScope = type(data) == 'table' and data.scope or nil

    if session and GetGameTimer() >= session.expiresAt then
        closeGarageNui()
        session = nil
    end

    if not session or sessionId ~= session.id or session.busy
        or requestedScope ~= 'personal' and requestedScope ~= 'society'
        or requestedScope == 'society' and not session.allowSociety
    then
        cb({ ok = false })
        return
    end

    if requestedScope == session.scope then
        cb({ ok = true })
        return
    end

    session.busy = true
    session.expiresAt = GetGameTimer() + 120000
    session.scope = requestedScope
    session.revision += 1
    local revision = session.revision
    sendNuiBusy(session, true)
    cb({ ok = true })

    CreateThread(function()
        local vehicles, items = queryNuiVehicles(session, requestedScope, revision)

        if nuiSession ~= session or session.generation ~= nuiSessionGeneration or session.revision ~= revision then return end

        session.items = items
        session.busy = false
        SendNUIMessage(buildNuiPayload('update', session, vehicles))
        sendNuiBusy(session, false)
    end)
end)

RegisterNUICallback('fleet', function(data, cb)
    local session = nuiSession
    local sessionId = type(data) == 'table' and data.sessionId or nil

    if session and GetGameTimer() >= session.expiresAt then
        closeGarageNui()
        session = nil
    end

    if not session or sessionId ~= session.id or session.busy or session.mode ~= 'garage'
        or session.scope ~= 'society' or session.canManageFleet ~= true
    then
        cb({ ok = false })
        return
    end

    session.busy = true
    cb({ ok = true })
    closeGarageNui()

    CreateThread(function()
        openFleetManager(session.index, { job = session.fleetJob })
    end)
end)

RegisterNUICallback('select', function(data, cb)
    local session = nuiSession
    local sessionId = type(data) == 'table' and data.sessionId or nil
    local itemId = type(data) == 'table' and data.itemId or nil

    if session and GetGameTimer() >= session.expiresAt then
        closeGarageNui()
        session = nil
    end

    local item = session and session.items[itemId] or nil

    if not session or sessionId ~= session.id or session.busy or not item then
        cb({ ok = false })
        return
    end

    session.busy = true
    cb({ ok = true })

    -- Browser data is only an opaque lookup key. All action arguments below
    -- come from the short-lived Lua session built from a fresh server response.
    closeGarageNui()

    CreateThread(function()
        if session.mode == 'impound' then
            retrieveVehicle({ index = session.index, props = item.props, society = item.society })
        elseif item.state == 'in_garage' then
            SpawnVehicle({ index = session.index, props = item.props, society = item.society })
        elseif item.state == 'out_garage' then
            local coords = lib.callback.await('drs_garages:getVehicleCoords', false, item.plate, item.society)
            if coords then
                SetNewWaypoint(coords.x, coords.y)
                ShowNotification(locale('out_garage_message'))
            else
                ShowNotification(locale('in_impound_message'), 'error')
            end
        else
            ShowNotification(locale('in_impound_message'), 'error')
        end
    end)
end)

local function isNearPropertyParking(data)
    if not data.Property or not data.SpawnPosition then return false end

    local radius = Config.PropertyGarageParkingDistance or Config.PropertyGarageDistance or 3.0

    return #(cache.coords - data.SpawnPosition.xyz) <= radius
end

local function garagePrompt(index, data, mode)
    Binds.first.removeListener('garage')
    Binds.second.removeListener('garage')

    if mode == 'park' then
        if not cache.vehicle then
            HideUI()
            return
        end

        ShowUI(('[%s] - %s'):format(Binds.second.currentKey, locale('save_vehicle')), 'floppy-disk')
        Binds.second.addListener('garage', function()
            saveVehicle(index)
        end)
    elseif cache.vehicle then
        if data.Property then
            if not isNearPropertyParking(data) then
                HideUI()
                return
            end
        end

        ShowUI(('[%s] - %s'):format(Binds.second.currentKey, locale('save_vehicle')), 'floppy-disk')
        Binds.second.addListener('garage', function()
            saveVehicle(index)
        end)
    else
        local prompt

        if data.Interior then
            prompt = ('[%s] - %s  \n  [%s] - %s'):format(Binds.first.currentKey, locale('open_garage'), Binds.second.currentKey, locale('enter_interior'))
        else
            prompt = (('[%s] - %s'):format(Binds.first.currentKey, locale('open_garage')))
        end

        ShowUI(prompt, 'warehouse')
        Binds.first.addListener('garage', function()
            openGarage(index)
        end)
        Binds.second.addListener('garage', function()
            EnterInterior(index)
        end)
    end
end

lib.onCache('vehicle', function(vehicle)
    if not currentGarageIndex then return end

    local garage = getGarage(currentGarageIndex)

    if not garage then return end

    -- Update value manually, because it gets updated after the call of onCache
    cache.vehicle = vehicle
    garagePrompt(currentGarageIndex, garage, currentGarageMode)
end)

local function clearGaragePrompt(index, mode)
    if currentGarageIndex ~= index then return end
    if mode and currentGarageMode ~= mode then return end

    HideUI()
    Binds.first.removeListener('garage')
    Binds.second.removeListener('garage')
    currentGarageIndex = nil
    currentGarageMode = nil
end

local function createGaragePoint(index, data, trackZone)
    createGarageRadialZone(index, data, trackZone == true)

    local targetAvailable = Utils.isTargetEnabled() and data.PedPosition and Utils.isTargetAvailable(true)
    local interactionPosition = data.Position or (data.PedPosition and data.PedPosition.xyz)

    if not targetAvailable and interactionPosition then
        local radius = data.Property and (Config.PropertyGarageDistance or 3.0) or Config.MaxDistance
        local zone = lib.zones.sphere({
            coords = interactionPosition,
            radius = radius,
            onEnter = function()
                if data.Jobs and not Utils.hasJobs(data.Jobs) then return end

                currentGarageIndex = index
                currentGarageMode = data.Property and 'entry' or 'garage'
                garagePrompt(index, data, currentGarageMode)
            end,
            onExit = function()
                clearGaragePrompt(index, data.Property and 'entry' or 'garage')
            end
        })

        if trackZone then
            propertyGarageZones[index] = zone
        else
            staticGarageZones[#staticGarageZones + 1] = zone
        end

        if trackZone and data.Property and data.SpawnPosition then
            local parkZone = lib.zones.sphere({
                coords = data.SpawnPosition.xyz,
                radius = Config.PropertyGarageParkingDistance or Config.PropertyGarageDistance or 3.0,
                onEnter = function()
                    if data.Jobs and not Utils.hasJobs(data.Jobs) then return end

                    currentGarageIndex = index
                    currentGarageMode = 'park'
                    garagePrompt(index, data, currentGarageMode)
                end,
                onExit = function()
                    clearGaragePrompt(index, 'park')
                end
            })

            propertyGarageParkZones[index] = parkZone
        end
    elseif targetAvailable then
        if not data.Model then
            warn(('Skipping garage - missing Model, index: %s'):format(index))
            return
        end

        local pedPoint = Utils.createPed(data.PedPosition, data.Model, {
            {
                label = locale('open_garage'),
                icon = 'warehouse',
                job = data.Jobs,
                args = index,
                onSelect = openGarage
            },
            {
                label = locale('enter_interior'),
                icon = 'right-to-bracket',
                job = data.Jobs,
                args = index,
                canInteract = function()
                    return data.Interior ~= nil
                end,
                onSelect = EnterInterior
            },
            {
                label = locale('save_vehicle'),
                icon = 'floppy-disk',
                job = data.Jobs,
                onSelect = function()
                    local vehicle = GetVehiclePedIsIn(cache.ped, true)

                    if Utils.distanceCheck(cache.ped, vehicle, 20.0) then
                        saveVehicle(index, vehicle)
                    end
                end
            }
        })

        if trackZone then
            propertyGaragePedPoints[index] = pedPoint
        end
    else
        warn(('Skipping garage - missing Position or PedPosition, index: %s'):format(index))
    end
end

local function toVector3(coords)
    if not coords then return end
    return vector3(coords.x, coords.y, coords.z)
end

local function toVector4(coords)
    if not coords then return end
    return vector4(coords.x, coords.y, coords.z, coords.w or coords.heading or 0.0)
end

local function normalizePropertyGarage(data)
    data.Position = toVector3(data.Position or data.entryCoords or data.coords)
    data.SpawnPosition = toVector4(data.SpawnPosition or data.spawnCoords or data.spawnPosition or data.coords)
    data.Interior = data.Interior or data.interior
    data.Type = data.Type or data.type or 'car'
    data.Property = true
    data.Visible = false

    return data
end

local function removePropertyGarage(index)
    local zone = propertyGarageZones[index]
    local parkZone = propertyGarageParkZones[index]
    local pedPoint = propertyGaragePedPoints[index]
    local radialZones = propertyGarageRadialZones[index]

    if zone then
        zone:remove()
        propertyGarageZones[index] = nil
    end

    if parkZone then
        parkZone:remove()
        propertyGarageParkZones[index] = nil
    end

    if pedPoint then
        Utils.removePedPoint(pedPoint)
        propertyGaragePedPoints[index] = nil
    end

    if radialZones then
        for i = 1, #radialZones do
            removeGarageRadialZone(radialZones[i])
        end
        propertyGarageRadialZones[index] = nil
    end

    clearGaragePrompt(index)
    propertyGarages[index] = nil
end

local function registerPropertyGarage(index, data)
    removePropertyGarage(index)

    data = normalizePropertyGarage(data)
    propertyGarages[index] = data
    createGaragePoint(index, data, true)
end

RegisterNetEvent('drs_garages:client:registerPropertyGarage', registerPropertyGarage)
RegisterNetEvent('drs_garages:client:removePropertyGarage', removePropertyGarage)

local function requestPropertyGarages()
    propertyRequestGeneration += 1
    local generation = propertyRequestGeneration
    local garages = lib.callback.await('drs_garages:getPropertyGarages', false) or {}

    if generation ~= propertyRequestGeneration then return end

    local staleIndexes = {}
    for index in pairs(propertyGarages) do
        if garages[index] == nil then staleIndexes[#staleIndexes + 1] = index end
    end

    for i = 1, #staleIndexes do
        removePropertyGarage(staleIndexes[i])
    end

    for index, data in pairs(garages) do
        registerPropertyGarage(index, data)
    end
end

CreateThread(function()
    Wait(1000)
    requestPropertyGarages()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    Wait(1000)
    requestPropertyGarages()
end)

RegisterNetEvent('esx:playerLoaded', function()
    Wait(1000)
    requestPropertyGarages()
end)

local function clearPropertyGaragesOnLogout()
    propertyRequestGeneration += 1
    closeGarageNui()
    radialGarageSuppressed = true
    refreshNearbyGarageRadial(true)

    local indexes = {}
    for index in pairs(propertyGarages) do
        indexes[#indexes + 1] = index
    end

    for i = 1, #indexes do
        removePropertyGarage(indexes[i])
    end
end

RegisterNetEvent('QBCore:Client:OnPlayerUnload', clearPropertyGaragesOnLogout)
RegisterNetEvent('qbx_core:client:playerLoggedOut', clearPropertyGaragesOnLogout)
RegisterNetEvent('esx:onPlayerLogout', clearPropertyGaragesOnLogout)

local function canTargetVehicleForParking(vehicle, targetDistance)
    local settings, _, maximumSpeed, maximumDistance = getParkingSettings()
    if settings.TargetEnabled == false or parkingOperation or parkingInspectionBusy then return false end
    if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false end
    if type(vehicle) ~= 'number' or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return false end
    if not NetworkGetEntityIsNetworked(vehicle) then return false end
    if tonumber(targetDistance) and targetDistance > maximumDistance then return false end
    if #(GetEntityCoords(cache.ped) - GetEntityCoords(vehicle)) > maximumDistance then return false end
    if GetEntitySpeed(vehicle) > maximumSpeed or not vehicleIsEmpty(vehicle) then return false end

    local stateOk, removalPending = pcall(function()
        return Entity(vehicle).state.drsEnforcementImpoundPending == true
    end)
    if stateOk and removalPending then return false end

    return resolveParkingGarage(vehicle) ~= nil
end

local function targetParkVehicle(vehicle)
    if not canTargetVehicleForParking(vehicle) then
        ShowNotification(locale('vehicle_parking_context_changed'), 'error')
        return
    end

    local index = resolveParkingGarage(vehicle)
    if not index then
        ShowNotification(locale('vehicle_not_in_parking_area'), 'error')
        return
    end

    parkingInspectionBusy = true
    local inspected, eligible, reason = xpcall(function()
        return lib.callback.await(
            'drs_garages:inspectParkingVehicle',
            false,
            NetworkGetNetworkIdFromEntity(vehicle),
            index
        )
    end, function(errorMessage)
        return debug.traceback(errorMessage, 2)
    end)
    parkingInspectionBusy = false

    if not inspected then
        warn(('[drs_garages] Parking inspection error: %s'):format(tostring(eligible)))
        ShowNotification(locale('vehicle_save_failed'), 'error')
        return
    end

    if eligible ~= true then
        ShowNotification(locale(PARKING_FAILURE_LOCALES[reason] or 'vehicle_save_failed'), 'error')
        return
    end

    if not canTargetVehicleForParking(vehicle) then
        ShowNotification(locale('vehicle_parking_context_changed'), 'error')
        return
    end

    saveVehicle(index, vehicle)
end

local parkingSettings, parkingDurationUnused, parkingSpeedUnused, parkingTargetDistance = getParkingSettings()
if parkingSettings.TargetEnabled ~= false then
    Utils.addGlobalVehicleTarget('drs_garages_park_vehicle', {
        {
            -- QB target providers remove by visible label, so keep this globally
            -- registered option namespaced away from other garage resources.
            label = ('%s · DRS'):format(locale('park_vehicle_target')),
            icon = 'square-parking',
            distance = parkingTargetDistance,
            canInteract = function(vehicle, targetDistance)
                return canTargetVehicleForParking(vehicle, targetDistance)
            end,
            onSelect = targetParkVehicle
        }
    }, parkingTargetDistance)
end

if type(Config.EnforcementImpound) == 'table' and Config.EnforcementImpound.Enabled == true then
    local distance = math.max(0.5, tonumber(Config.EnforcementImpound.Distance) or 3.0)

    Utils.addGlobalVehicleTarget('drs_garages_enforcement_impound', {
        {
            -- qb-target/qtarget remove global options by their visible label, so
            -- the DRS suffix keeps cleanup scoped away from police/MDT options.
            label = ('%s · DRS'):format(locale('enforcement_impound_target')),
            icon = 'truck-ramp-box',
            distance = distance,
            canInteract = function(vehicle, targetDistance)
                return canTargetVehicleForImpound(vehicle, targetDistance, false)
            end,
            onSelect = startEnforcementImpound
        }
    }, distance)
end

for index, data in ipairs(Config.Garages) do
    createGaragePoint(index, data)
end

for index, data in ipairs(Config.Impounds) do
    local targetAvailable = Utils.isTargetEnabled() and data.PedPosition and Utils.isTargetAvailable(true)
    local interactionPosition = data.Position or (data.PedPosition and data.PedPosition.xyz)

    if not targetAvailable and interactionPosition then
        impoundZones[#impoundZones + 1] = lib.zones.sphere({
            coords = interactionPosition,
            radius = Config.MaxDistance,
            onEnter = function()
                if data.Jobs and not Utils.hasJobs(data.Jobs) then return end

                ShowUI(('[%s] - %s'):format(Binds.first.currentKey, locale('open_impound')), 'warehouse')
                Binds.first.addListener('impound', function()
                    openImpound(index)
                end)
            end,
            onExit = function()
                HideUI()
                Binds.first.removeListener('impound')
            end
        })
    elseif targetAvailable then
        if not data.Model then
            warn(('Skipping impound - missing Model, index: %s'):format(index))
        else
            Utils.createPed(data.PedPosition, data.Model, {
                {
                    label = locale('open_impound'),
                    icon = 'warehouse',
                    job = data.Jobs,
                    args = index,
                    onSelect = openImpound
                }
            })
        end
    else
        warn(('Skipping impound - missing Position or PedPosition, index: %s'):format(index))
    end
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    closeGarageNui()
    if parkingOperation then
        parkingOperation.progressFinished = true
        pcall(lib.cancelProgress)
        parkingOperation = nil
    end
    HideUI()
    Binds.first.removeListener('garage')
    Binds.second.removeListener('garage')
    Binds.first.removeListener('impound')

    for i = 1, #staticGarageZones do
        staticGarageZones[i]:remove()
    end

    for i = 1, #staticGarageRadialZones do
        removeGarageRadialZone(staticGarageRadialZones[i])
    end

    staticGarageRadialZones = {}

    for i = 1, #impoundZones do
        impoundZones[i]:remove()
    end

    local propertyIndexes = {}
    for index in pairs(propertyGarages) do
        propertyIndexes[#propertyIndexes + 1] = index
    end

    for i = 1, #propertyIndexes do
        removePropertyGarage(propertyIndexes[i])
    end

    nearbyGarageRadialContexts = {}
    if nearbyGarageRadialHandle then
        Utils.removeRadialOption(nearbyGarageRadialHandle)
        nearbyGarageRadialHandle = nil
    end
end)
