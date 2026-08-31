if type(Config.Contract) ~= 'table' or Config.Contract.Enabled ~= true then return end

local function finiteNumber(value, fallback)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return value
end

local function resolveOnce(pending)
    local settled = false

    return function(...)
        if settled then return end
        settled = true
        pending:resolve(...)
    end
end

lib.callback.register('drs_garages:getContractVehicle', function()
    local ped = cache.ped or PlayerPedId()
    if cache.vehicle or IsPedInAnyVehicle(ped, false) then
        ShowNotification(locale('cant_in_vehicle'), 'error')
        return
    end

    local distance = math.min(math.max(finiteNumber(Config.Contract.VehicleDistance, 5.0), 1.0), 25.0)
    local vehicle = lib.getClosestVehicle(GetEntityCoords(ped), distance, false)

    if not vehicle then
        ShowNotification(locale('no_vehicle_near_you'), 'error')
        return
    end

    return GetVehicleNumberPlateText(vehicle), GetVehicleLabel(GetEntityModel(vehicle))
end)

lib.callback.register('drs_garages:chooseContractOption', function(eligibility)
    if type(eligibility) ~= 'table' then return end

    local options = {}
    if eligibility.playerSale == true then
        options[#options + 1] = {
            title = locale('transfer_player'),
            icon = 'user',
            args = 'transfer_player'
        }
    end
    if eligibility.societyDonation == true then
        options[#options + 1] = {
            title = locale('transfer_society'),
            icon = 'users',
            args = 'transfer_society'
        }
    end
    if eligibility.societyWithdrawal == true then
        options[#options + 1] = {
            title = locale('withdraw_society'),
            icon = 'rotate-left',
            args = 'withdraw_society'
        }
    end

    if #options == 0 then
        ShowNotification(locale('contract_failed'), 'error')
        return
    end

    local pending = promise.new()
    local resolve = resolveOnce(pending)
    for i = 1, #options do options[i].onSelect = resolve end

    lib.registerContext({
        id = 'drs_garages_contract',
        title = locale('contract'),
        onClose = resolve,
        options = options
    })
    lib.showContext('drs_garages_contract')

    return Citizen.Await(pending)
end)

local function chooseNearbyPlayer()
    local maximumDistance = math.min(math.max(finiteNumber(Config.Contract.PlayerDistance, 10.0), 1.0), 25.0)
    local ped = cache.ped or PlayerPedId()
    local nearbyPlayers = lib.getNearbyPlayers(GetEntityCoords(ped), maximumDistance, false)
    local options = {}

    for i = 1, #nearbyPlayers do
        local playerId = nearbyPlayers[i].id
        local serverId = GetPlayerServerId(playerId)

        if serverId and serverId > 0 then
            options[#options + 1] = {
                title = ('%s [%s]'):format(GetPlayerName(playerId) or 'Player', serverId),
                icon = 'user',
                args = serverId
            }
        end
    end

    table.sort(options, function(left, right)
        return tonumber(left.args) < tonumber(right.args)
    end)

    if #options == 0 then
        ShowNotification('No nearby players were found.', 'error')
        return
    end

    local pending = promise.new()
    local resolve = resolveOnce(pending)
    for i = 1, #options do options[i].onSelect = resolve end

    lib.registerContext({
        id = 'drs_garages_contract_player',
        title = locale('pick_player'),
        onClose = resolve,
        options = options
    })
    lib.showContext('drs_garages_contract_player')

    return Citizen.Await(pending)
end

lib.callback.register('drs_garages:getTargetPlayer', function()
    local targetId = chooseNearbyPlayer()
    if not targetId then return end

    local minimum = math.max(0, math.floor(finiteNumber(Config.Contract.MinimumPrice or Config.Contract.MinPrice, 0)))
    local maximum = math.max(minimum, math.floor(finiteNumber(
        Config.Contract.MaximumPrice or Config.Contract.MaxPrice,
        100000000
    )))
    local input = lib.inputDialog(locale('pick_player'), {
        {
            type = 'number',
            label = locale('sell_price'),
            required = true,
            min = minimum,
            max = maximum
        }
    })

    if not input then return end
    return tonumber(targetId), tonumber(input[1])
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
            cancel = locale('society_cancel')
        }
    })

    return result == 'confirm'
end)

local function signingDuration()
    return math.min(math.max(math.floor(finiteNumber(Config.Contract.Duration, 5000)), 250), 60000)
end

lib.callback.register('drs_garages:signContract', function(message)
    return lib.progressBar({
        label = tostring(message or locale('contract')),
        duration = signingDuration(),
        canCancel = true,
        disable = {
            move = true,
            car = true,
            combat = true
        },
        anim = {
            scenario = 'WORLD_HUMAN_CLIPBOARD'
        }
    }) == true
end)

-- Kept for compatibility with companion resources that used the V1 cosmetic
-- animation event. Contract V2 itself signs through the callback above before
-- any item, money, or ownership mutation occurs.
RegisterNetEvent('drs_garages:contractAnim', function(message)
    lib.progressBar({
        label = message,
        duration = signingDuration(),
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
