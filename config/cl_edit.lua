function ShowNotification(message, notifyType)
    if Framework and Framework.name == 'qbx_core' and GetResourceState('qbx_core') == 'started' then
        exports.qbx_core:Notify(message, notifyType or 'inform', 5000, nil, 'bottom')
        return
    end

    lib.notify({
        description = message,
        type = notifyType or 'inform',
        position = 'bottom'
    })
end

RegisterNetEvent('drs_garages:showNotification')
AddEventHandler('drs_garages:showNotification', ShowNotification)

function ShowUI(text, icon)
    if icon == 0 or not icon then
        lib.showTextUI(text)
    else
        lib.showTextUI(text, {
            icon = icon
        })
    end
end

function HideUI()
    lib.hideTextUI()
end

local function getConfiguredFuelResource()
    local configured = Config.FuelScript or Config.Fuel or 'auto'

    if configured ~= 'auto' then
        return configured
    end

    local resources = {
        'ox_fuel',
        'LegacyFuel',
        'ps-fuel',
        'cdn-fuel',
        'BigDaddy-Fuel'
    }

    for i = 1, #resources do
        if GetResourceState(resources[i]) == 'started' then
            return resources[i]
        end
    end
end

function GetVehicleFuel(vehicle)
    local fuel = getConfiguredFuelResource()

    if fuel == 'ox_fuel' then
        return Entity(vehicle).state.fuel or GetVehicleFuelLevel(vehicle)
    elseif fuel == 'LegacyFuel' then
        return exports['LegacyFuel']:GetFuel(vehicle)
    elseif fuel == 'ps-fuel' then
        return exports['ps-fuel']:GetFuel(vehicle)
    elseif fuel == 'cdn-fuel' then
        return exports['cdn-fuel']:GetFuel(vehicle)
    elseif fuel == 'BigDaddy-Fuel' then
        return exports['BigDaddy-Fuel']:GetFuel(vehicle)
    end

    return GetVehicleFuelLevel(vehicle)
end

function SetVehicleFuel(vehicle, fuelLevel)
    fuelLevel = fuelLevel or 100.0
    local fuel = getConfiguredFuelResource()

    if fuel == 'ox_fuel' then
        Entity(vehicle).state:set('fuel', fuelLevel, true)
        SetVehicleFuelLevel(vehicle, fuelLevel + 0.0)
    elseif fuel == 'LegacyFuel' then
        exports['LegacyFuel']:SetFuel(vehicle, fuelLevel)
    elseif fuel == 'ps-fuel' then
        exports['ps-fuel']:SetFuel(vehicle, fuelLevel)
    elseif fuel == 'cdn-fuel' then
        exports['cdn-fuel']:SetFuel(vehicle, fuelLevel)
    elseif fuel == 'BigDaddy-Fuel' then
        exports['BigDaddy-Fuel']:SetFuel(vehicle, fuelLevel)
    else
        SetVehicleFuelLevel(vehicle, fuelLevel + 0.0)
    end
end

function SetVehicleLockState(vehicle, lockState)
    if not vehicle or vehicle == 0 then return end

    SetVehicleDoorsLocked(vehicle, lockState or 2)

    if GetResourceState('qb-vehiclekeys') == 'started' then
        TriggerServerEvent('qb-vehiclekeys:server:setVehLockState', NetworkGetNetworkIdFromEntity(vehicle), lockState or 2)
    end
end

function SetVehicleOwner(plate, vehicle)
    if not Config.UseKeySystem then return end

    if Framework.name == 'qbx_core' then
        -- Qbox keys are granted by the validated server spawn/retrieval flows.
        -- Do not expose a client-callable netId-to-key handoff.
        return
    elseif Framework.name == 'qb-core' then
        -- Current qb-vehiclekeys keys are granted by the validated server flow.
        return
    elseif Framework.name == 'es_extended' then
        -- Not implemented by default.
    end
end
