-- Ox Lib fallback interface for the secure server-side job-fleet manager.
-- Existing NUI/garage entry points can call the exported OpenJobFleetManager;
-- every permission and vehicle decision is repeated by server/fleet.lua.

local opening = false
local purchasing = false

local function fleetSettings()
    return type(Config.JobFleet) == 'table' and Config.JobFleet or {}
end

local function notify(message, notifyType)
    if type(ShowNotification) == 'function' then
        ShowNotification(message, notifyType)
    else
        lib.notify({ description = message, type = notifyType or 'inform' })
    end
end

local function showResult(result)
    if type(result) ~= 'table' then
        notify('The fleet service did not return a result.', 'error')
        return false
    end

    local committed = result.committed == true
    local completed = result.ok == true or committed
    local notifyType = completed and 'success' or 'error'
    if result.review == true then notifyType = 'inform' end
    notify(result.message or (completed and 'Fleet operation completed.' or 'Fleet operation failed.'), notifyType)
    return completed
end

local function formattedMoney(value)
    local amount = math.max(0, math.floor(tonumber(value) or 0))
    local formatted = tostring(amount):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return '$' .. formatted
end

local function safeContextSuffix(index, job)
    return ('%s_%s'):format(tostring(index or 'none'):gsub('[^%w_]', '_'), tostring(job or 'none'):gsub('[^%w_]', '_'))
end

local function nearbyVehicleNetId(plate)
    local distance = math.max(2.0, tonumber(fleetSettings().VehicleDistance) or 8.0)
    local vehicle = cache.vehicle or lib.getClosestVehicle(cache.coords, distance, false)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    local currentPlate = GetVehicleNumberPlateText(vehicle):upper():match('^%s*(.-)%s*$')
    if currentPlate ~= plate then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    return netId and netId > 0 and netId or nil
end

local openFleetManager

local function runAndRefresh(callbackName, context, ...)
    local result = lib.callback.await(callbackName, false, ...)
    if showResult(result) then
        Wait(100)
        openFleetManager(context.garage.index, context.job)
    end
end

local function openPersonalVehicles(context)
    local suffix = safeContextSuffix(context.garage.index, context.job)
    local menuId = 'drs_job_fleet_personal_' .. suffix
    local options = {}

    for _, vehicle in ipairs(context.personalVehicles or {}) do
        local stored = vehicle.stored == true
        local available = stored or vehicle.out == true
        options[#options + 1] = {
            title = ('%s · %s'):format(vehicle.model or 'Vehicle', vehicle.plate),
            description = stored and 'Stored personal vehicle'
                or vehicle.out and 'Out vehicle — it must be nearby and unoccupied'
                or 'This vehicle is unavailable while impounded or transitioning',
            icon = stored and 'warehouse' or 'car-side',
            disabled = not available,
            onSelect = function()
                local input = lib.inputDialog('Assign personal vehicle', {
                    {
                        type = 'number',
                        label = 'Minimum job grade',
                        description = 'Members below this grade cannot take the vehicle out.',
                        default = 0,
                        min = 0,
                        max = math.max(0, math.floor(tonumber(fleetSettings().MaximumVehicleGrade) or 100)),
                        precision = 0,
                        required = true
                    }
                })
                if not input then return end

                local confirmed = lib.alertDialog({
                    header = 'Assign vehicle to job fleet?',
                    content = ('**%s** will stop being a personal vehicle and become part of the **%s** fleet.'):format(
                        vehicle.plate,
                        context.job
                    ),
                    centered = true,
                    cancel = true,
                    labels = { confirm = 'Assign vehicle', cancel = 'Cancel' }
                })
                if confirmed ~= 'confirm' then return end

                runAndRefresh(
                    'drs_garages:fleet:registerPersonal',
                    context,
                    context.garage.index,
                    context.job,
                    vehicle.plate,
                    tonumber(input[1]),
                    nearbyVehicleNetId(vehicle.plate)
                )
            end
        }
    end

    if #options == 0 then
        options[1] = {
            title = 'No compatible personal vehicles',
            description = 'A personally owned vehicle matching this garage type will appear here.',
            icon = 'circle-info',
            disabled = true
        }
    end

    lib.registerContext({
        id = menuId,
        menu = 'drs_job_fleet_main_' .. suffix,
        title = 'Assign personal vehicle',
        options = options
    })
    lib.showContext(menuId)
end

local function createFleetVehicle(context)
    local models = {}
    for _, entry in ipairs(context.catalog or {}) do
        models[#models + 1] = {
            value = entry.model,
            label = ('%s (%s)'):format(entry.label or entry.model, entry.model)
        }
    end
    if #models == 0 then
        notify('No server-allowlisted models are configured for this job and garage type.', 'error')
        return
    end

    local input = lib.inputDialog('Create stored fleet vehicle', {
        {
            type = 'select',
            label = 'Vehicle model',
            options = models,
            searchable = true,
            required = true
        },
        {
            type = 'number',
            label = 'Minimum job grade',
            default = 0,
            min = 0,
            max = math.max(0, math.floor(tonumber(fleetSettings().MaximumVehicleGrade) or 100)),
            precision = 0,
            required = true
        }
    })
    if not input then return end

    local confirmed = lib.alertDialog({
        header = 'Issue fleet vehicle?',
        content = ('Create **%s** as a stored **%s** job vehicle?'):format(input[1], context.job),
        centered = true,
        cancel = true,
        labels = { confirm = 'Create vehicle', cancel = 'Cancel' }
    })
    if confirmed ~= 'confirm' then return end

    runAndRefresh(
        'drs_garages:fleet:createVehicle',
        context,
        context.garage.index,
        context.job,
        input[1],
        tonumber(input[2])
    )
end

local function purchaseSocietyVehicle(context)
    if purchasing then return end
    purchasing = true
    local catalog = lib.callback.await(
        'drs_garages:fleet:getPurchaseCatalog',
        false,
        context.garage.index,
        context.job
    )
    purchasing = false

    if type(catalog) ~= 'table' or catalog.ok ~= true then
        showResult(catalog)
        return
    end

    local models, byModel = {}, {}
    for _, vehicle in ipairs(catalog.vehicles or {}) do
        if type(vehicle) == 'table' and vehicle.model then
            byModel[vehicle.model] = vehicle
            models[#models + 1] = {
                value = vehicle.model,
                label = ('%s · %s'):format(vehicle.name or vehicle.model, formattedMoney(vehicle.price)),
                description = vehicle.brand and vehicle.brand ~= '' and vehicle.brand or vehicle.category
            }
        end
    end
    if #models == 0 then
        notify('No vehicle-shop models match this job fleet and garage type.', 'error')
        return
    end
    local balanceLabel = catalog.balanceUnavailable and 'Unavailable during recovery' or formattedMoney(catalog.balance)

    local input = lib.inputDialog(
        (catalog.retrying and 'Resume society purchase' or ('Purchase for %s · Balance %s'):format(
            context.job,
            balanceLabel
        )),
        {
            {
                type = 'select',
                label = 'Society vehicle',
                description = catalog.retrying
                    and 'Resuming the same durable order; payment can complete once, never twice.'
                    or 'Prices and payment are verified by DRS Vehicle Shop on the server.',
                options = models,
                searchable = true,
                required = true
            },
            {
                type = 'textarea',
                label = 'Purchase note (optional)',
                min = 0,
                max = math.max(16, math.min(500, math.floor(tonumber(fleetSettings().MaximumReasonLength) or 500)))
            }
        }
    )
    if not input then return end

    local selected = byModel[input[1]]
    if not selected then
        notify('The selected society vehicle is no longer available.', 'error')
        return
    end
    local confirmed = lib.alertDialog({
        header = catalog.retrying and 'Resume society order' or 'Confirm society purchase',
        content = ((catalog.retrying
            and 'Resume **%s** for **%s**?\n\nOriginal price: **%s**\nCurrent society balance: **%s**\n\nThis reuses the original durable order. If payment was already confirmed, it will not be charged again. Delivery remains **%s**.'
            or 'Purchase **%s** for **%s**?\n\nPrice: **%s**\nSociety balance: **%s**\n\nThe vehicle will be delivered stored at **%s**.')):format(
            selected.name or selected.model,
            context.job,
            formattedMoney(selected.price),
            balanceLabel,
            context.garage.label
        ),
        centered = true,
        cancel = true,
        labels = { confirm = catalog.retrying and 'Resume order' or 'Purchase vehicle', cancel = 'Cancel' }
    })
    if confirmed ~= 'confirm' then return end

    purchasing = true
    local result = lib.callback.await(
        'drs_garages:fleet:purchaseSocietyVehicle',
        false,
        catalog.token,
        selected.model,
        input[2]
    )
    purchasing = false
    showResult(result)

    if type(result) == 'table' and (result.committed == true or result.retryable == true) then
        Wait(100)
        openFleetManager(context.garage.index, context.job)
    end
end

local function moveVehicle(context, vehicle)
    if not vehicle.stored then
        notify('Park the vehicle before moving its garage assignment.', 'error')
        return
    end

    local destinations = {}
    for _, garage in ipairs(context.garages or {}) do
        if garage.type == vehicle.type and garage.id ~= vehicle.garage then
            destinations[#destinations + 1] = { value = garage.index, label = garage.label }
        end
    end
    if #destinations == 0 then
        notify('No other authorized garage matches this vehicle type.', 'error')
        return
    end

    local input = lib.inputDialog(('Move %s'):format(vehicle.plate), {
        {
            type = 'select',
            label = 'Destination garage',
            options = destinations,
            searchable = true,
            required = true
        }
    })
    if not input then return end

    runAndRefresh(
        'drs_garages:fleet:moveVehicle',
        context,
        context.garage.index,
        context.job,
        vehicle.plate,
        tonumber(input[1])
    )
end

local function changeMinimumGrade(context, vehicle)
    local input = lib.inputDialog(('Minimum grade · %s'):format(vehicle.plate), {
        {
            type = 'number',
            label = 'Minimum job grade',
            default = tonumber(vehicle.minGrade) or 0,
            min = 0,
            max = math.max(0, math.floor(tonumber(fleetSettings().MaximumVehicleGrade) or 100)),
            precision = 0,
            required = true
        }
    })
    if not input then return end

    runAndRefresh(
        'drs_garages:fleet:setMinimumGrade',
        context,
        context.garage.index,
        context.job,
        vehicle.plate,
        tonumber(input[1])
    )
end

local function retireVehicle(context, vehicle)
    if not vehicle.stored then
        notify('Park the vehicle before permanently retiring it.', 'error')
        return
    end

    local warning = lib.alertDialog({
        header = 'Permanently retire fleet vehicle?',
        content = ('This permanently deletes **%s** from the framework vehicle table. The audit journal keeps a recovery snapshot, but the vehicle will no longer appear in any garage.'):format(vehicle.plate),
        centered = true,
        cancel = true,
        labels = { confirm = 'Continue', cancel = 'Cancel' }
    })
    if warning ~= 'confirm' then return end

    local input = lib.inputDialog(('Retire %s'):format(vehicle.plate), {
        {
            type = 'input',
            label = 'Type the exact plate',
            placeholder = vehicle.plate,
            required = true,
            min = 1,
            max = 8
        },
        {
            type = 'textarea',
            label = 'Retirement reason',
            required = true,
            min = 3,
            max = math.max(16, math.min(500, math.floor(tonumber(fleetSettings().MaximumReasonLength) or 500)))
        }
    })
    if not input then return end

    runAndRefresh(
        'drs_garages:fleet:retireVehicle',
        context,
        context.garage.index,
        context.job,
        vehicle.plate,
        input[1],
        input[2]
    )
end

local function openVehicleManagement(context, vehicle)
    local suffix = safeContextSuffix(context.garage.index, context.job)
    local menuId = ('drs_job_fleet_vehicle_%s_%s'):format(suffix, vehicle.plate:gsub('[^%w_]', '_'))
    local options = {
        {
            title = 'Move to another garage',
            description = vehicle.stored and ('Currently assigned to %s'):format(vehicle.garage or 'an unknown garage')
                or 'Park the vehicle before changing its garage.',
            icon = 'right-left',
            disabled = not vehicle.stored,
            onSelect = function() moveVehicle(context, vehicle) end
        },
        {
            title = 'Change minimum grade',
            description = ('Current minimum grade: %d'):format(tonumber(vehicle.minGrade) or 0),
            icon = 'ranking-star',
            onSelect = function() changeMinimumGrade(context, vehicle) end
        },
        {
            title = 'Permanently retire vehicle',
            description = 'Deletes the stored framework vehicle row and records the reason.',
            icon = 'trash-can',
            iconColor = '#ef4444',
            disabled = not vehicle.stored,
            onSelect = function() retireVehicle(context, vehicle) end
        }
    }

    lib.registerContext({
        id = menuId,
        menu = 'drs_job_fleet_main_' .. suffix,
        title = ('%s · %s'):format(vehicle.model or 'Vehicle', vehicle.plate),
        options = options
    })
    lib.showContext(menuId)
end

local function chooseAdminJob(index, response)
    local options = {}
    for _, job in ipairs(response.jobs or {}) do options[#options + 1] = { value = job, label = job } end
    if #options == 0 then return end

    local input = lib.inputDialog('Choose job fleet', {
        { type = 'select', label = 'Job', options = options, searchable = true, required = true }
    })
    if input then openFleetManager(index, input[1]) end
end

openFleetManager = function(index, requestedJob)
    if opening then return end
    if fleetSettings().Enabled == false then
        notify('Job fleet management is disabled.', 'error')
        return
    end

    opening = true
    local context = lib.callback.await('drs_garages:fleet:getContext', false, index, requestedJob)
    opening = false

    if type(context) ~= 'table' or context.ok ~= true then
        if type(context) == 'table' and context.needsJob then
            chooseAdminJob(index, context)
        else
            notify(type(context) == 'table' and context.message or 'The fleet service is unavailable.', 'error')
        end
        return
    end

    local suffix = safeContextSuffix(context.garage.index, context.job)
    local menuId = 'drs_job_fleet_main_' .. suffix
    local options = {
        {
            title = 'Assign a personal vehicle',
            description = 'Convert one of your owned vehicles into a job fleet vehicle.',
            icon = 'car-on',
            arrow = true,
            disabled = #(context.personalVehicles or {}) == 0,
            onSelect = function() openPersonalVehicles(context) end
        }
    }

    if context.canPurchase then
        options[#options + 1] = {
            title = 'Purchase for society',
            description = 'Buy an allowlisted fleet vehicle through DRS Vehicle Shop using society funds.',
            icon = 'building-columns',
            onSelect = function() purchaseSocietyVehicle(context) end
        }
    end

    if context.canCreate then
        options[#options + 1] = {
            title = 'Create a stored fleet vehicle',
            description = #(context.catalog or {}) > 0 and 'Issue a model from the server allowlist.'
                or 'No allowlisted models match this job garage.',
            icon = 'circle-plus',
            disabled = #(context.catalog or {}) == 0,
            onSelect = function() createFleetVehicle(context) end
        }
    end

    options[#options + 1] = {
        title = ('Fleet vehicles · %d'):format(#(context.vehicles or {})),
        description = 'Select a vehicle to move it, change its minimum grade, or retire it.',
        icon = 'cars',
        disabled = true
    }

    for _, vehicle in ipairs(context.vehicles or {}) do
        options[#options + 1] = {
            title = ('%s · %s'):format(vehicle.model or 'Vehicle', vehicle.plate),
            description = ('%s · Minimum grade %d%s'):format(
                vehicle.stored and (vehicle.garage or 'Stored') or 'Out of garage',
                tonumber(vehicle.minGrade) or 0,
                vehicle.managed and '' or ' · Legacy fleet row'
            ),
            icon = vehicle.stored and 'warehouse' or 'car-side',
            arrow = true,
            onSelect = function() openVehicleManagement(context, vehicle) end
        }
    end

    options[#options + 1] = {
        title = 'Refresh',
        description = 'Reload permissions and vehicle state from the server.',
        icon = 'rotate',
        onSelect = function() openFleetManager(context.garage.index, context.job) end
    }

    lib.registerContext({
        id = menuId,
        title = ('%s Fleet · %s'):format(context.job, context.garage.label),
        options = options
    })
    lib.showContext(menuId)
end

RegisterNetEvent('drs_garages:fleet:open', function(index, requestedJob)
    openFleetManager(index, requestedJob)
end)

exports('OpenJobFleetManager', function(index, requestedJob)
    openFleetManager(index, requestedJob)
end)

local function nearestConfiguredJobGarage()
    local closestIndex, closestDistance
    local playerCoords = GetEntityCoords(cache.ped)
    local maximum = math.max(1.0, tonumber(fleetSettings().Distance) or tonumber(Config.MaxDistance) or 10.0)

    for index, garage in ipairs(Config.Garages or {}) do
        if garage.Jobs and not garage.Property then
            local positions = { garage.Position, garage.PedPosition, garage.SpawnPosition }
            for positionIndex = 1, 3 do
                local coords = positions[positionIndex]
                if coords then
                    local distance = #(playerCoords - vector3(coords.x, coords.y, coords.z))
                    if distance <= maximum and (not closestDistance or distance < closestDistance) then
                        closestIndex, closestDistance = index, distance
                    end
                end
            end
        end
    end
    return closestIndex
end

if fleetSettings().CommandEnabled ~= false then
    RegisterCommand(fleetSettings().Command or 'jobfleet', function()
        local index = nearestConfiguredJobGarage()
        if not index then
            notify('You are not near a configured job garage.', 'error')
            return
        end
        openFleetManager(index)
    end, false)
end
