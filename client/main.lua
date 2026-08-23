local propertyGarages = {}
local propertyGarageZones = {}
local propertyGarageParkZones = {}
local staticGarageZones = {}
local impoundZones = {}
local currentGarageIndex
local currentGarageMode
local networkTimeout = 10000
local propertyRequestGeneration = 0

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
                lib.setVehicleProperties(vehicle, props)
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

    lib.setVehicleProperties(vehicle, data)
end)

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
    local type = getVehicleSpawnType(props.model)
    local netId = lib.callback.await('drs_garages:takeOutVehicle', false, index, props.plate, type, args.society)
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

    applyVehiclePropertiesWhenOwned(vehicle, props)

    TaskTurnPedToFaceCoord(
        cache.ped,
        garage.SpawnPosition.x,
        garage.SpawnPosition.y,
        garage.SpawnPosition.z,
        1000
    )

    Wait(1000)

    local stateBagValue = Entity(vehicle).state.doorslockstate
    if stateBagValue then
        SetVehicleDoorsLocked(vehicle, stateBagValue)
    end

    SetVehicleLockState(vehicle, 2)

    -- -- 🔊 QBX key fob sound
    -- qbx.playAudio({
    --     audioName = 'Remote_Control_Fob',
    --     audioRef = 'PI_Menu_Sounds',
    --     source = vehicle
    -- })

    -- 💡 Better light flash
    SetVehicleLights(vehicle, 2)
    Wait(250)
    SetVehicleLights(vehicle, 1)
    Wait(200)
    SetVehicleLights(vehicle, 0)

    -- Fuel + ownership
    SetVehicleFuel(vehicle, props.fuelLevel or 100.0)
    SetVehicleOwner(props.plate, vehicle)

    ShowNotification(locale('vehicle_retrieved'), 'success')
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

local function openGarage(index)
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

    lib.registerContext({
        id = 'garage_menu',
        title = garage.Label or locale('garage_menu'),
        options = options
    })

    lib.showContext('garage_menu')
end

---@param vehicle number?
local function saveVehicle(index, vehicle)
    if type(index) ~= 'number' and type(index) ~= 'string' then
        vehicle = index
        index = currentGarageIndex
    end

    if not index or not getGarage(index) then
        ShowNotification(locale('invalid_garage'), 'error')
        return
    end

    if not vehicle and cache.seat ~= -1 then
        ShowNotification(locale('not_driver'), 'error')
        return
    end

    local vehicle = cache.vehicle or vehicle
    local props = lib.getVehicleProperties(vehicle)

    if not props then return end

    props.plate = props.plate:strtrim(' ') -- Trim whitespace
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    local type = getVehicleSpawnType(props.model)
    local result = lib.callback.await('drs_garages:saveVehicle', false, {
        plate = props.plate,
        model = props.model
    }, netId, index, type)
    
    if result then
        if cache.vehicle then
            TaskLeaveAnyVehicle(cache.ped, 0, 0)
            Wait(1000)
        end

        ShowNotification(locale('vehicle_saved'), 'success')
    else
        ShowNotification(locale('not_your_vehicle'), 'error')
    end
end

local function retrieveVehicle(args)
    ---@type integer, VehicleProperties
    local index, props = args and args.index, args and args.props

    if not index or not Config.Impounds[index] or type(props) ~= 'table' or not props.model or not props.plate then
        ShowNotification(locale('invalid_impound'), 'error')
        return
    end

    lib.requestModel(props.model)
    local type = getVehicleSpawnType(props.model)

    local success, netId = lib.callback.await('drs_garages:retrieveVehicle', false, index, props.plate, type, args.society)

    if not success or not netId then
        SetModelAsNoLongerNeeded(props.model)
        ShowNotification(locale('not_enough_money'), 'error')
        return
    end

    local vehicle = waitForNetworkVehicle(netId)
    SetModelAsNoLongerNeeded(props.model)

    if not vehicle then
        ShowNotification(locale('vehicle_network_timeout'), 'error')
        return
    end

    applyVehiclePropertiesWhenOwned(vehicle, props)

    local warpDeadline = GetGameTimer() + 5000
    while GetGameTimer() < warpDeadline do
        TaskWarpPedIntoVehicle(cache.ped, vehicle, -1)
        
        if GetVehiclePedIsIn(cache.ped, false) == vehicle then
            break
        end

        Wait(0)
    end

    SetVehicleFuel(vehicle, props.fuelLevel)
    SetVehicleOwner(props.plate, vehicle)
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

            ---@type ContextMenuArrayItem
            local option = {
                title = locale('vehicle_info', GetVehicleLabel(props.model), props.plate),
                icon = getClassIcon(class),
                progress = class ~= 13 and fuelLevel,
                colorScheme = class ~= 13 and getFuelBarColor(fuelLevel),
                metadata = {
                    ---@diagnostic disable-next-line: assign-type-mismatch
                    { label = locale('fuel'), value = class ~= 13 and fuelLevel .. '%' or locale('no_fueltank') }
                },
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

local function openImpound(index)
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

        Utils.createPed(data.PedPosition, data.Model, {
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

    if zone then
        zone:remove()
        propertyGarageZones[index] = nil
    end

    if parkZone then
        parkZone:remove()
        propertyGarageParkZones[index] = nil
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

local function clearPropertyGaragesOnLogout()
    propertyRequestGeneration += 1

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

    HideUI()
    Binds.first.removeListener('garage')
    Binds.second.removeListener('garage')
    Binds.first.removeListener('impound')

    for i = 1, #staticGarageZones do
        staticGarageZones[i]:remove()
    end

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
end)
