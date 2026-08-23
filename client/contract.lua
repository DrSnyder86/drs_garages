if type(Config.Contract) ~= 'table' or Config.Contract.Enabled ~= true then return end

lib.callback.register('drs_garages:getContractOption', function()
    if cache.vehicle then
        ShowNotification(locale('cant_in_vehicle'), 'error')
        return
    end

    local vehicle = lib.getClosestVehicle(cache.coords, 3.0, false)

    if not vehicle then
        ShowNotification(locale('no_vehicle_near_you'), 'error')
        return 
    end

    local plate = GetVehicleNumberPlateText(vehicle)
    local label = GetVehicleLabel(GetEntityModel(vehicle))
    local option = promise.new()

    local function Resolve(name)
        option:resolve(name)
    end

    lib.registerContext({
        id = 'contract',
        title = locale('contract'),
        onClose = function()
            option:resolve()
        end,
        options = {
            {
                title = locale('transfer_player'),
                icon = 'user',
                args = 'transfer_player',
                onSelect = Resolve
            },
            {
                title = locale('transfer_society'),
                icon = 'users',
                args = 'transfer_society',
                onSelect = Resolve
            },
            {
                title = locale('withdraw_society'),
                icon = 'rotate-left',
                args = 'withdraw_society',
                onSelect = Resolve
            }
        }
    })

    lib.showContext('contract')

    return Citizen.Await(option), plate, label
end)

lib.callback.register('drs_garages:getTargetPlayer', function()
    local input = lib.inputDialog(locale('pick_player'), {
        {
            type = 'number',
            label = locale('player_id'),
            required = true,
            min = 1
        },
        {
            type = 'number',
            label = locale('sell_price'),
            required = true,
            min = 0
        }
    })

    if not input then return end

    return tonumber(input[1]), tonumber(input[2])
end)

lib.callback.register('drs_garages:getAgreement', function(price, label, name)
    local result = lib.alertDialog({
        header = locale('offer'),
        content = locale('offer_content', name, label, price),
        centered = true,
        labels = {
            confirm = locale('offer_confirm'),
            cancel = locale('offer_cancel')
        }
    })

    return result == 'confirm'
end)

---@param type 'transfer' | 'withdraw'
lib.callback.register('drs_garages:societyPrompt', function(type)
    local result = lib.alertDialog({
        header = locale('society_prompt'),
        content = type == 'transfer' and locale('society_transfer') or locale('society_withdraw'),
        centered = true,
        labels = {
            confirm = locale('society_confirm'),
            cancel = locale('society_cancel'),
        }
    })

    return result == 'confirm'
end)

RegisterNetEvent('drs_garages:contractAnim', function(message)
    local duration = tonumber(Config.Contract and Config.Contract.Duration) or 5000

    if duration ~= duration or duration == math.huge or duration == -math.huge then
        duration = 5000
    end

    duration = math.min(math.max(math.floor(duration), 250), 60000)

    lib.progressBar({
        label = message,
        duration = duration,
        canCancel = false,
        disable = {
            move = true,
            car = true,
            combat = true
        },
        anim = {
            scenario = 'WORLD_HUMAN_CLIPBOARD'
        }
    })
end)
