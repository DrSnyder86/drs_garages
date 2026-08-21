local contractConfig

local function getContractConfig()
    contractConfig = contractConfig or Config and Config.Contract
    return contractConfig
end

local function databaseIsUsable(source)
    return not CanUseDrsGarageDatabase or CanUseDrsGarageDatabase(source)
end

local function transferToPlayer(source, plate, label)
    if not databaseIsUsable(source) then return end

    local player = Framework.getPlayerFromId(source)
    local contract = getContractConfig()

    if not player or not contract then return end

    local vehicle = MySQL.single.await(Queries.getVehicleStrict, { player:getIdentifier(), plate })

    if not vehicle then
        TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_not_yours'), 'error')
        return
    end

    local targetId, price = lib.callback.await('drs_garages:getTargetPlayer', source)

    if not targetId or source == targetId or not price or price < 0 then
        TriggerClientEvent('drs_garages:showNotification', source, locale('invalid_data'), 'error')
        return
    end

    if #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(GetPlayerPed(targetId))) > 10.0 then
        TriggerClientEvent('drs_garages:showNotification', source, locale('player_too_far'), 'error')
        return
    end

    local target = Framework.getPlayerFromId(targetId)

    if not target then return end

    local name = ('%s %s'):format(player:getFirstName(), player:getLastName())
    local success = lib.callback.await('drs_garages:getAgreement', targetId, price, label, name)

    if not success then
        TriggerClientEvent('drs_garages:showNotification', source, locale('offer_declined'), 'error')
        return
    end

    if target:getAccountMoney('money') < price then
        return
    end

    MySQL.update.await(Queries.transferVehiclePlayer, { target:getIdentifier(), plate })
    player:removeItem(contract.Item, 1)
    target:removeAccountMoney('money', price)
    player:addAccountMoney('money', price)

    TriggerClientEvent('drs_garages:contractAnim', source, locale('progress_selling'))
    Wait(contract.Duration or 5000)
    TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_sold'))
    Wait(500)
    TriggerClientEvent('drs_garages:contractAnim', targetId, locale('progress_buying'))
    Wait(contract.Duration or 5000)
    TriggerClientEvent('drs_garages:showNotification', targetId, locale('vehicle_bought'))
end

local function transferToSociety(source, plate)
    if not databaseIsUsable(source) then return end

    local player = Framework.getPlayerFromId(source)
    local contract = getContractConfig()

    if not player or not contract then return end

    local vehicle = MySQL.single.await(Queries.getVehicleStrict, { player:getIdentifier(), plate })

    if not vehicle then
        TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_not_yours'), 'error')
        return
    end

    local result = lib.callback.await('drs_garages:societyPrompt', source, 'transfer')

    if not result then return end

    MySQL.update.await(Queries.transferVehicleSociety, { player:getJob(), plate })
    player:removeItem(contract.Item, 1)

    TriggerClientEvent('drs_garages:contractAnim', source, locale('progress_transfering'))
    Wait(contract.Duration or 5000)
    TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_transfered'))
end

local function withdrawFromSociety(source, plate)
    if not databaseIsUsable(source) then return end

    local player = Framework.getPlayerFromId(source)
    local contract = getContractConfig()

    if not player or not contract then return end

    local vehicle = MySQL.single.await(Queries.getVehicle, { player:getIdentifier(), plate })

    if not vehicle then
        TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_not_yours'), 'error')
        return
    end

    local result = lib.callback.await('drs_garages:societyPrompt', source, 'withdraw')

    if not result then return end

    MySQL.update.await(Queries.withdrawVehicleSociety, { plate })
    player:removeItem(contract.Item, 1)

    TriggerClientEvent('drs_garages:contractAnim', source, locale('progress_withdrawing'))
    Wait(contract.Duration or 5000)
    TriggerClientEvent('drs_garages:showNotification', source, locale('vehicle_withdrawn'))
end

CreateThread(function()
    local waited = 0

    while not Framework or not Framework.registerUsableItem or not getContractConfig() or not contractConfig.Item do
        if waited >= 5000 then
            print('[drs_garages] Contract item registration skipped because Config.Contract or Framework was not loaded.')
            return
        end

        Wait(100)
        waited = waited + 100
    end

    Framework.registerUsableItem(contractConfig.Item, function(source)
        if not databaseIsUsable(source) then return end

        local option, plate, label = lib.callback.await('drs_garages:getContractOption', source)

        if not option or not plate then return end

        if option == 'transfer_player' then
            transferToPlayer(source, plate, label)
        elseif option == 'transfer_society' then
            transferToSociety(source, plate)
        elseif option == 'withdraw_society' then
            withdrawFromSociety(source, plate)
        end
    end)
end)
