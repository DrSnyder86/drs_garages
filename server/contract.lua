local contractConfig
local playerLocks = {}
local plateLocks = {}

local function getContractConfig()
    contractConfig = contractConfig or Config and Config.Contract
    return contractConfig
end

local function databaseIsUsable(source)
    return type(CanUseDrsGarageDatabase) == 'function' and CanUseDrsGarageDatabase(source) == true
end

local function notify(source, key, notifyType, ...)
    TriggerClientEvent('drs_garages:showNotification', source, locale(key, ...), notifyType or 'error')
end

local function critical(operation, source, plate, message)
    print(('[drs_garages] CRITICAL contract %s (source=%s, plate=%s): %s'):format(
        operation, tostring(source), tostring(plate), tostring(message)
    ))
end

local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizePlate(value)
    if type(value) ~= 'string' and type(value) ~= 'number' then return end

    local plate = tostring(value):match('^%s*(.-)%s*$')
    if not plate or plate == '' then return end

    plate = plate:upper()
    if #plate > 8 or not plate:match('^[A-Z0-9 ]+$') then return end

    return plate
end

local function normalizePrice(value, contract)
    local price = tonumber(value)
    if not isFiniteNumber(price) or price % 1 ~= 0 then return end

    local minimum = tonumber(contract.MinimumPrice or contract.MinPrice) or 0
    local maximum = tonumber(contract.MaximumPrice or contract.MaxPrice) or 100000000
    if not isFiniteNumber(minimum) then minimum = 0 end
    if not isFiniteNumber(maximum) then maximum = 100000000 end

    minimum = math.max(0, math.floor(minimum))
    maximum = math.max(minimum, math.floor(maximum))
    if price < minimum or price > maximum then return end

    return math.floor(price)
end

local function normalizeTargetId(value)
    local targetId = tonumber(value)
    if not isFiniteNumber(targetId) or targetId % 1 ~= 0 or targetId <= 0 then return end
    return math.floor(targetId)
end

local function contractDuration(contract)
    local duration = tonumber(contract.Duration) or 5000
    if not isFiniteNumber(duration) then duration = 5000 end
    return math.min(math.max(math.floor(duration), 250), 60000)
end

local function safePlayerCall(player, method, ...)
    if not player or type(player[method]) ~= 'function' then return false end

    local args = { ... }
    return pcall(function()
        return player[method](player, table.unpack(args))
    end)
end

local function getIdentifier(player)
    local ok, identifier = safePlayerCall(player, 'getIdentifier')
    if not ok or type(identifier) ~= 'string' or identifier == '' then return end
    return identifier
end

local function getLicense(player)
    local ok, license = safePlayerCall(player, 'getLicense')
    if ok and type(license) == 'string' and license ~= '' then return license end
end

local function getJob(player)
    local ok, job = safePlayerCall(player, 'getJob')
    if not ok or type(job) ~= 'string' or job == '' then return end
    return job
end

local function isValidSocietyJob(job)
    return type(job) == 'string' and job ~= '' and job ~= 'unemployed'
end

local function canWithdrawSocietyVehicle(player, job, contract)
    if not isValidSocietyJob(job) then return false end
    if contract.SocietyWithdrawalRequiresBoss == false then return true end

    local ok, isBoss = safePlayerCall(player, 'isJobBoss')
    return ok and isBoss == true
end

local function getItemCount(player, item)
    local ok, count = safePlayerCall(player, 'getItemCount', item)
    count = tonumber(count)
    if not ok or not isFiniteNumber(count) then return 0 end
    return count
end

local function getMoney(player)
    local ok, amount = safePlayerCall(player, 'getAccountMoney', 'money')
    amount = tonumber(amount)
    if not ok or not isFiniteNumber(amount) then return end
    return amount
end

local function mutatePlayer(player, method, ...)
    local ok, result = safePlayerCall(player, method, ...)
    return ok and result == true
end

local function queryDatabase(query, params, operation, source, plate)
    local ok, result = pcall(function()
        return MySQL.query.await(query, params)
    end)

    if not ok then
        critical(operation, source, plate, result)
        return
    end

    return result
end

local function updateDatabase(query, params, operation, source, plate)
    local ok, result = pcall(function()
        return MySQL.update.await(query, params)
    end)

    if not ok then
        critical(operation, source, plate, result)
        return
    end

    return tonumber(result)
end

local isQb = Framework and (Framework.name == 'qb-core' or Framework.name == 'qbx_core')
local vehicleTable = isQb and 'player_vehicles' or 'owned_vehicles'
local ownerColumn = isQb and 'citizenid' or 'owner'

local function getUniqueVehicle(whereClause, params, operation, source, plate)
    local query = ('SELECT * FROM `%s` WHERE %s LIMIT 2'):format(vehicleTable, whereClause)
    local rows = queryDatabase(query, params, operation, source, plate)
    if not rows then return nil, 'database' end

    if #rows > 1 then
        critical(operation, source, plate, 'multiple database rows matched a supposedly unique ownership scope')
        return nil, 'duplicate'
    end

    if #rows == 0 then return nil, 'missing' end
    return rows[1]
end

local function getPersonalVehicle(identifier, plate, operation, source)
    return getUniqueVehicle(
        ('`%s` = ? AND `plate` = ? AND `job` IS NULL'):format(ownerColumn),
        { identifier, plate }, operation, source, plate
    )
end

local function getSocietyVehicle(job, plate, operation, source)
    return getUniqueVehicle(
        '`job` = ? AND `plate` = ?',
        { job, plate }, operation, source, plate
    )
end

local function notifyLookupFailure(source, reason)
    notify(source, reason == 'missing' and 'vehicle_not_yours' or 'contract_failed')
end

local function beginOperation(source)
    if playerLocks[source] then return end

    local token = { source = source, players = {}, plates = {}, externalPlates = {} }
    token.players[source] = true
    playerLocks[source] = token
    return token
end

local function lockPlayer(token, source)
    local owner = playerLocks[source]
    if owner and owner ~= token then return false end

    playerLocks[source] = token
    token.players[source] = true
    return true
end

local function lockPlate(token, plate)
    local owner = plateLocks[plate]
    if owner and owner ~= token then return false end

    plateLocks[plate] = token
    token.plates[plate] = true
    return true
end

local function lockSharedPlate(token, plate)
    if token.externalPlates[plate] then return true end

    local beginSharedOperation = rawget(_G, 'BeginDrsGaragePlateOperation')
    if type(beginSharedOperation) ~= 'function' then return false end

    local externalToken = beginSharedOperation(plate, token.source, 'vehicle contract')
    if not externalToken then return false end

    token.externalPlates[plate] = externalToken
    return true
end

local function releaseOperation(token)
    for source in pairs(token.players) do
        if playerLocks[source] == token then playerLocks[source] = nil end
    end

    for plate in pairs(token.plates) do
        if plateLocks[plate] == token then plateLocks[plate] = nil end

        local endSharedOperation = rawget(_G, 'EndDrsGaragePlateOperation')
        if type(endSharedOperation) == 'function' then
            endSharedOperation(plate, token.externalPlates[plate])
        end
    end
end

local function refreshPlayer(source, identifier)
    if not GetPlayerName(source) then return end

    local player = Framework.getPlayerFromId(source)
    if not player or getIdentifier(player) ~= identifier then return end
    return player
end

local function playersAreNear(source, targetId)
    if not GetPlayerName(source) or not GetPlayerName(targetId) then return false end
    if GetPlayerRoutingBucket(source) ~= GetPlayerRoutingBucket(targetId) then return false end

    local sourcePed = GetPlayerPed(source)
    local targetPed = GetPlayerPed(targetId)
    if sourcePed <= 0 or targetPed <= 0 then return false end

    local ok, distance = pcall(function()
        return #(GetEntityCoords(sourcePed) - GetEntityCoords(targetPed))
    end)

    return ok and distance <= 10.0
end

local function getContractVehicle(source, plate, token)
    local externalToken = token and token.externalPlates and token.externalPlates[plate]
    local validator = externalToken
        and rawget(_G, 'ValidateDrsGarageContractVehicle')
        or rawget(_G, 'InspectDrsGarageContractVehicle')

    if type(validator) ~= 'function' then return end

    local ok, entity = pcall(validator, source, plate, externalToken)
    if not ok or not entity or entity == 0 or not DoesEntityExist(entity) then return end

    return entity
end

local function rotateQboxVehicleSession(entity)
    if not entity or not DoesEntityExist(entity) then return false end

    local state = Entity(entity).state
    local previousSessionId = state.sessionId
    state:set('sessionId', nil, true)

    local created, result = pcall(function()
        return exports.qbx_core:CreateSessionId(entity)
    end)
    if not created or result == false then return false end

    local currentSessionId = state.sessionId
    return currentSessionId ~= nil and currentSessionId ~= previousSessionId
end

local function clearOnlineQbPlateKeys(plate)
    local cleared = true

    for _, playerId in ipairs(GetPlayers()) do
        local numericId = tonumber(playerId)
        if numericId then
            local ok = pcall(function()
                exports['qb-vehiclekeys']:RemoveKeys(numericId, plate)
            end)
            if not ok then cleared = false end
        end
    end

    return cleared
end

local function transferVehicleKeys(source, targetId, targetIdentifier, plate, entity)
    if not entity or not DoesEntityExist(entity) then return false end

    local removedOk = true
    local grantedOk = true
    local ownerOk = true

    if Config.UseKeySystem and GetResourceState('qbx_vehiclekeys') == 'started' then
        -- qbx_vehiclekeys persists explicit keys by entity session id, including
        -- logged-out holders. Rotating that id invalidates every old key before
        -- the new owner receives one.
        removedOk = rotateQboxVehicleSession(entity)
        if removedOk then
            grantedOk = pcall(function()
                exports.qbx_vehiclekeys:GiveKeys(targetId, entity, false)
            end)
        else
            grantedOk = false
        end
    elseif Config.UseKeySystem and GetResourceState('qb-vehiclekeys') == 'started' then
        removedOk = clearOnlineQbPlateKeys(plate)
        grantedOk = pcall(function()
            exports['qb-vehiclekeys']:GiveKeys(targetId, plate)
        end)
    end

    if Framework.name == 'qbx_core' then
        ownerOk = pcall(function()
            Entity(entity).state:set('owner', targetIdentifier, true)
        end)
    end

    if not removedOk or not grantedOk or not ownerOk then
        critical('player sale key handoff', source, plate, ('remove=%s, give=%s, owner=%s'):format(
            tostring(removedOk),
            tostring(grantedOk),
            tostring(ownerOk)
        ))
    end

    return removedOk and grantedOk and ownerOk
end

local function updateSocietyVehicleKeys(source, plate, entity, newOwnerIdentifier)
    if not entity or not DoesEntityExist(entity) then return false end

    local operationOk, operationResult = pcall(function()
        if Framework.name == 'qbx_core' then
            if Config.UseKeySystem and GetResourceState('qbx_vehiclekeys') == 'started' then
                if not rotateQboxVehicleSession(entity) then return false end
                -- The donating/withdrawing member keeps the operational key so
                -- the live vehicle can still be driven to its new garage domain.
                exports.qbx_vehiclekeys:GiveKeys(source, entity, false)
            end

            Entity(entity).state:set('owner', newOwnerIdentifier, true)
        elseif Framework.name == 'qb-core' and Config.UseKeySystem
            and GetResourceState('qb-vehiclekeys') == 'started'
        then
            if not clearOnlineQbPlateKeys(plate) then return false end
            exports['qb-vehiclekeys']:GiveKeys(source, plate)
        end

        return true
    end)

    if not operationOk or operationResult == false then
        critical('society key handoff', source, plate, operationOk and 'key adapter returned false' or operationResult)
        return false
    end

    return true
end

local function restoreItem(player, contract, operation, source, plate)
    if mutatePlayer(player, 'addItem', contract.Item, 1) then return true end

    critical(operation, source, plate, 'failed to restore the consumed contract item')
    notify(source, 'contract_compensation_failed')
    return false
end

local function refundMoney(player, amount, operation, source, plate)
    if mutatePlayer(player, 'addAccountMoney', 'money', amount) then return true end

    critical(operation, source, plate, ('failed to refund $%s'):format(amount))
    return false
end

local function scheduleAnimation(source, progressKey, successKey, contract, targetId, targetProgressKey, targetSuccessKey)
    local duration = contractDuration(contract)

    CreateThread(function()
        TriggerClientEvent('drs_garages:contractAnim', source, locale(progressKey))
        Wait(duration)
        notify(source, successKey, 'success')

        if targetId then
            Wait(500)
            TriggerClientEvent('drs_garages:contractAnim', targetId, locale(targetProgressKey))
            Wait(duration)
            notify(targetId, targetSuccessKey, 'success')
        end
    end)
end

local function getVehicleById(vehicleId, operation, source, plate)
    if vehicleId == nil then return nil, 'missing_id' end
    return getUniqueVehicle('`id` = ?', { vehicleId }, operation, source, plate)
end

local function rowMatchesQboxOwner(row, vehicleId, identifier, license, plate, expectedJob)
    if not row or tostring(row.id) ~= tostring(vehicleId) then return false end
    if normalizePlate(row.plate) ~= plate or row.job ~= expectedJob then return false end
    if tostring(row[ownerColumn] or '') ~= tostring(identifier or '') then return false end
    if tostring(row.license or '') ~= tostring(license or '') then return false end
    return true
end

local function rowMatchesPersonalOwner(row, vehicleId, identifier, license, plate)
    return rowMatchesQboxOwner(row, vehicleId, identifier, license, plate, nil)
end

local function setQboxVehicleOwner(vehicle, identifier, license, plate, expectedJob, operation, source)
    if Framework.name ~= 'qbx_core' or vehicle.id == nil then return end
    if identifier ~= nil and not license then return end
    if GetResourceState('qbx_vehicles') ~= 'started' then
        critical(operation, source, plate, 'qbx_vehicles is not started; official ownership hook cannot run')
        return 0
    end

    local called, result, exportError = pcall(function()
        return exports.qbx_vehicles:SetPlayerVehicleOwner(vehicle.id, identifier)
    end)
    local current, lookupError = getVehicleById(vehicle.id, operation .. ' verification', source, plate)
    local verified = rowMatchesQboxOwner(current, vehicle.id, identifier, license, plate, expectedJob)

    if not called or result ~= true or not verified then
        critical(operation, source, plate, ('Qbox ownership hook/verification failed (called=%s, result=%s, error=%s, lookup=%s, verified=%s)'):format(
            tostring(called),
            tostring(result),
            tostring(exportError),
            tostring(lookupError),
            tostring(verified)
        ))
        return 0
    end

    return 1
end

local function setQboxPersonalOwner(vehicle, identifier, license, plate, operation, source)
    if not identifier or not license then return end
    return setQboxVehicleOwner(vehicle, identifier, license, plate, nil, operation, source)
end

local function transferPersonalOwner(vehicle, sellerIdentifier, targetIdentifier, targetLicense, plate, operation, source)
    if isQb and not targetLicense then return end

    if Framework.name == 'qbx_core' then
        return setQboxPersonalOwner(vehicle, targetIdentifier, targetLicense, plate, operation, source)
    end

    local assignments = ('`%s` = ?'):format(ownerColumn)
    local params = { targetIdentifier }

    if isQb then
        assignments = assignments .. ', `license` = ?'
        params[#params + 1] = targetLicense
    end

    params[#params + 1] = sellerIdentifier
    params[#params + 1] = plate

    local identityClause = ''
    if vehicle.id ~= nil then
        identityClause = ' AND `id` = ?'
        params[#params + 1] = vehicle.id
    end

    local query = ('UPDATE `%s` SET %s WHERE `%s` = ? AND `plate` = ? AND `job` IS NULL%s LIMIT 1')
        :format(vehicleTable, assignments, ownerColumn, identityClause)

    return updateDatabase(query, params, operation, source, plate)
end

local function revertPersonalOwner(vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate, operation, source)
    if isQb and not sellerLicense then return end

    if Framework.name == 'qbx_core' then
        local current, lookupError = getVehicleById(vehicle.id, operation .. ' precheck', source, plate)
        if rowMatchesPersonalOwner(current, vehicle.id, sellerIdentifier, sellerLicense, plate) then return 1 end

        local targetLicense = current and current.license or nil
        if not rowMatchesPersonalOwner(current, vehicle.id, targetIdentifier, targetLicense, plate) then
            critical(operation, source, plate, ('ownership rollback refused because the row is no longer owned by the expected buyer (lookup=%s, owner=%s)'):format(
                tostring(lookupError),
                tostring(current and current[ownerColumn])
            ))
            return 0
        end

        return setQboxPersonalOwner(vehicle, sellerIdentifier, sellerLicense, plate, operation, source)
    end

    local assignments = ('`%s` = ?'):format(ownerColumn)
    local params = { sellerIdentifier }

    if isQb then
        assignments = assignments .. ', `license` = ?'
        params[#params + 1] = sellerLicense
    end

    params[#params + 1] = targetIdentifier
    params[#params + 1] = plate

    local identityClause = ''
    if vehicle.id ~= nil then
        identityClause = ' AND `id` = ?'
        params[#params + 1] = vehicle.id
    end

    local query = ('UPDATE `%s` SET %s WHERE `%s` = ? AND `plate` = ? AND `job` IS NULL%s LIMIT 1')
        :format(vehicleTable, assignments, ownerColumn, identityClause)

    return updateDatabase(query, params, operation, source, plate)
end

local function restoreQboxSocietyOwner(vehicle, expectedCurrentIdentifier, originalIdentifier, originalLicense, job, plate, operation, source)
    local current, lookupError = getVehicleById(vehicle.id, operation .. ' precheck', source, plate)
    if rowMatchesQboxOwner(current, vehicle.id, originalIdentifier, originalLicense, plate, job) then return true end

    local currentLicense = current and current.license or nil
    if not rowMatchesQboxOwner(current, vehicle.id, expectedCurrentIdentifier, currentLicense, plate, job) then
        critical(operation, source, plate, ('society-owner rollback refused because the row changed unexpectedly (lookup=%s, owner=%s, job=%s)'):format(
            tostring(lookupError),
            tostring(current and current[ownerColumn]),
            tostring(current and current.job)
        ))
        return false
    end

    return setQboxVehicleOwner(
        vehicle, originalIdentifier, originalLicense, plate, job, operation, source
    ) == 1
end

local function restoreQboxPersonalAfterDonation(vehicle, identifier, license, job, plate, operation, source)
    if not restoreQboxSocietyOwner(vehicle, nil, identifier, license, job, plate, operation, source) then
        return false
    end

    local affected = updateDatabase([[
        UPDATE `player_vehicles`
        SET `job` = NULL
        WHERE `id` = ? AND `plate` = ? AND `job` = ?
          AND `citizenid` = ? AND `license` = ?
        LIMIT 1
    ]], { vehicle.id, plate, job, identifier, license }, operation, source, plate)
    if affected ~= 1 then return false end

    local restored = getVehicleById(vehicle.id, operation .. ' verification', source, plate)
    return rowMatchesPersonalOwner(restored, vehicle.id, identifier, license, plate)
end

local function transferToPlayer(source, plate, _label, token)
    local operation = 'player sale'
    local contract = getContractConfig()
    local player = Framework.getPlayerFromId(source)
    local sellerIdentifier = getIdentifier(player)
    if not player or not sellerIdentifier then return end

    local contractEntity = getContractVehicle(source, plate, token)
    if not contractEntity then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local vehicle, lookupError = getPersonalVehicle(sellerIdentifier, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end

    local targetId, rawPrice = lib.callback.await('drs_garages:getTargetPlayer', source)
    targetId = normalizeTargetId(targetId)
    local price = normalizePrice(rawPrice, contract)

    if not targetId or targetId == source or not price then
        notify(source, 'invalid_data')
        return
    end

    if not lockPlayer(token, targetId) then
        notify(source, 'contract_busy')
        return
    end

    local target = Framework.getPlayerFromId(targetId)
    local targetIdentifier = getIdentifier(target)
    if not target or not targetIdentifier then
        notify(source, 'invalid_data')
        return
    end

    if not playersAreNear(source, targetId) then
        notify(source, 'player_too_far')
        return
    end

    contractEntity = getContractVehicle(source, plate, token)
    if not contractEntity then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local firstNameOk, firstName = safePlayerCall(player, 'getFirstName')
    local lastNameOk, lastName = safePlayerCall(player, 'getLastName')
    local sellerName = firstNameOk and tostring(firstName or '') or GetPlayerName(source) or 'Unknown'
    if lastNameOk and lastName and lastName ~= '' then sellerName = sellerName .. ' ' .. tostring(lastName) end

    local agreement = lib.callback.await(
        'drs_garages:getAgreement', targetId, price, locale('contract_vehicle_label', plate), sellerName
    )

    if agreement ~= true then
        notify(source, 'offer_declined')
        return
    end

    if not lockSharedPlate(token, plate) then
        notify(source, 'contract_busy')
        return
    end

    player = refreshPlayer(source, sellerIdentifier)
    target = refreshPlayer(targetId, targetIdentifier)
    if not player or not target then
        notify(source, 'contract_failed')
        return
    end

    if not playersAreNear(source, targetId) then
        notify(source, 'player_too_far')
        return
    end

    vehicle, lookupError = getPersonalVehicle(sellerIdentifier, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end

    if getItemCount(player, contract.Item) < 1 then
        notify(source, 'contract_item_missing')
        return
    end

    contractEntity = getContractVehicle(source, plate, token)
    if not contractEntity then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local buyerBalance = getMoney(target)
    local sellerBalance = getMoney(player)
    if not buyerBalance or not sellerBalance then
        notify(source, 'contract_failed')
        return
    end

    if buyerBalance < price then
        notify(source, 'buyer_not_enough_money')
        notify(targetId, 'not_enough_money')
        return
    end

    local targetLicense = isQb and getLicense(target) or nil
    local sellerLicense = isQb and getLicense(player) or nil
    if isQb and (not targetLicense or not sellerLicense) then
        notify(source, 'contract_failed')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        notify(source, 'contract_item_missing')
        return
    end

    if not mutatePlayer(target, 'removeAccountMoney', 'money', price) then
        restoreItem(player, contract, operation, source, plate)
        notify(source, 'buyer_not_enough_money')
        return
    end

    local affected = transferPersonalOwner(
        vehicle, sellerIdentifier, targetIdentifier, targetLicense, plate, operation, source
    )

    if affected ~= 1 then
        local ownershipSafe = true
        if Framework.name == 'qbx_core' then
            ownershipSafe = revertPersonalOwner(
                vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate,
                operation .. ' failed-transfer rollback', source
            ) == 1
        end

        if not ownershipSafe then
            critical(operation, source, plate, 'ownership outcome is not safe to compensate automatically; funds and item were left unchanged for staff reconciliation')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
            return
        end

        local refunded = refundMoney(target, price, operation, source, plate)
        local restored = restoreItem(player, contract, operation, source, plate)

        if refunded and restored then
            notify(source, 'contract_failed')
        else
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end

        return
    end

    if not mutatePlayer(player, 'addAccountMoney', 'money', price) then
        local reverted = revertPersonalOwner(
            vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate, operation .. ' rollback', source
        )

        if reverted == 1 then
            local refunded = refundMoney(target, price, operation, source, plate)
            local restored = restoreItem(player, contract, operation, source, plate)

            if not refunded or not restored then
                notify(source, 'contract_compensation_failed')
            else
                notify(source, 'contract_failed')
            end
        else
            critical(operation, source, plate, 'seller credit failed and vehicle ownership rollback did not affect exactly one row')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end

        return
    end

    if not transferVehicleKeys(source, targetId, targetIdentifier, plate, contractEntity) then
        notify(source, 'contract_key_handoff_failed')
        notify(targetId, 'contract_key_handoff_failed')
    end
    scheduleAnimation(source, 'progress_selling', 'vehicle_sold', contract, targetId, 'progress_buying', 'vehicle_bought')
end

local function transferToSociety(source, plate, token)
    local operation = 'society transfer'
    local contract = getContractConfig()
    local player = Framework.getPlayerFromId(source)
    local identifier = getIdentifier(player)
    local job = getJob(player)
    local originalLicense = Framework.name == 'qbx_core' and getLicense(player) or nil
    if not player or not identifier or not isValidSocietyJob(job) then
        notify(source, 'society_invalid')
        return
    end
    if Framework.name == 'qbx_core' and not originalLicense then
        notify(source, 'contract_failed')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local vehicle, lookupError = getPersonalVehicle(identifier, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end

    if lib.callback.await('drs_garages:societyPrompt', source, 'transfer') ~= true then return end

    if not lockSharedPlate(token, plate) then
        notify(source, 'contract_busy')
        return
    end

    player = refreshPlayer(source, identifier)
    if not player or getJob(player) ~= job then
        notify(source, 'society_invalid')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    vehicle, lookupError = getPersonalVehicle(identifier, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end
    if Framework.name == 'qbx_core'
        and (vehicle.id == nil or tostring(vehicle.license or '') ~= tostring(originalLicense))
    then
        notify(source, 'contract_failed')
        return
    end

    if getItemCount(player, contract.Item) < 1 then
        notify(source, 'contract_item_missing')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        notify(source, 'contract_item_missing')
        return
    end

    local params = { job, identifier, plate }
    local identityClause = ''
    if vehicle.id ~= nil then
        identityClause = ' AND `id` = ?'
        params[#params + 1] = vehicle.id
    end

    local query = ('UPDATE `%s` SET `job` = ? WHERE `%s` = ? AND `plate` = ? AND `job` IS NULL%s LIMIT 1')
        :format(vehicleTable, ownerColumn, identityClause)
    local affected = updateDatabase(query, params, operation, source, plate)

    if affected ~= 1 then
        if restoreItem(player, contract, operation, source, plate) then
            notify(source, 'contract_failed')
        end
        return
    end

    if Framework.name == 'qbx_core' then
        local ownerCleared = setQboxVehicleOwner(
            vehicle, nil, nil, plate, job, operation .. ' owner clear', source
        ) == 1

        if not ownerCleared then
            local restored = restoreQboxPersonalAfterDonation(
                vehicle, identifier, originalLicense, job, plate, operation .. ' rollback', source
            )

            if restored and restoreItem(player, contract, operation, source, plate) then
                notify(source, 'contract_failed')
            else
                critical(operation, source, plate, 'society donation owner clear failed and exact rollback was not completed')
                notify(source, 'contract_compensation_failed')
            end
            return
        end
    end

    if not updateSocietyVehicleKeys(source, plate, getContractVehicle(source, plate, token), nil) then
        notify(source, 'contract_key_handoff_failed')
    end

    scheduleAnimation(source, 'progress_transfering', 'vehicle_transfered', contract)
end

local function withdrawFromSociety(source, plate, token)
    local operation = 'society withdrawal'
    local contract = getContractConfig()
    local player = Framework.getPlayerFromId(source)
    local identifier = getIdentifier(player)
    local job = getJob(player)
    if not player or not identifier or not canWithdrawSocietyVehicle(player, job, contract) then
        notify(source, 'society_withdrawal_denied')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local vehicle, lookupError = getSocietyVehicle(job, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end

    if lib.callback.await('drs_garages:societyPrompt', source, 'withdraw') ~= true then return end

    if not lockSharedPlate(token, plate) then
        notify(source, 'contract_busy')
        return
    end

    player = refreshPlayer(source, identifier)
    if not player or getJob(player) ~= job or not canWithdrawSocietyVehicle(player, job, contract) then
        notify(source, 'society_withdrawal_denied')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    vehicle, lookupError = getSocietyVehicle(job, plate, operation, source)
    if not vehicle then
        notifyLookupFailure(source, lookupError)
        return
    end

    if getItemCount(player, contract.Item) < 1 then
        notify(source, 'contract_item_missing')
        return
    end

    local playerLicense = isQb and getLicense(player) or nil
    if isQb and not playerLicense then
        notify(source, 'contract_failed')
        return
    end

    local originalIdentifier = Framework.name == 'qbx_core' and vehicle.citizenid or nil
    local originalLicense = Framework.name == 'qbx_core' and vehicle.license or nil
    if Framework.name == 'qbx_core' and (vehicle.id == nil or originalIdentifier ~= nil and not originalLicense) then
        notify(source, 'contract_failed')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        notify(source, 'contract_item_missing')
        return
    end

    local affected
    if Framework.name == 'qbx_core' then
        local ownerChanged = setQboxVehicleOwner(
            vehicle, identifier, playerLicense, plate, job, operation .. ' owner change', source
        ) == 1

        if not ownerChanged then
            local restored = restoreQboxSocietyOwner(
                vehicle, identifier, originalIdentifier, originalLicense, job, plate,
                operation .. ' owner rollback', source
            )

            if restored and restoreItem(player, contract, operation, source, plate) then
                notify(source, 'contract_failed')
            else
                critical(operation, source, plate, 'Qbox owner change failed and exact society-owner rollback was not completed')
                notify(source, 'contract_compensation_failed')
            end
            return
        end

        affected = updateDatabase([[
            UPDATE `player_vehicles`
            SET `job` = NULL
            WHERE `id` = ? AND `plate` = ? AND `job` = ?
              AND `citizenid` = ? AND `license` = ?
            LIMIT 1
        ]], { vehicle.id, plate, job, identifier, playerLicense }, operation, source, plate)
    else
        local assignments = ('`job` = NULL, `%s` = ?'):format(ownerColumn)
        local params = { identifier }

        if isQb then
            assignments = assignments .. ', `license` = ?'
            params[#params + 1] = playerLicense
        end

        params[#params + 1] = job
        params[#params + 1] = plate

        local identityClause = ''
        if vehicle.id ~= nil then
            identityClause = ' AND `id` = ?'
            params[#params + 1] = vehicle.id
        end

        local query = ('UPDATE `%s` SET %s WHERE `job` = ? AND `plate` = ?%s LIMIT 1')
            :format(vehicleTable, assignments, identityClause)
        affected = updateDatabase(query, params, operation, source, plate)
    end

    if affected ~= 1 then
        local ownershipSafe = true
        if Framework.name == 'qbx_core' then
            ownershipSafe = restoreQboxSocietyOwner(
                vehicle, identifier, originalIdentifier, originalLicense, job, plate,
                operation .. ' database rollback', source
            )
        end

        if ownershipSafe and restoreItem(player, contract, operation, source, plate) then
            notify(source, 'contract_failed')
        else
            critical(operation, source, plate, 'society withdrawal database transition failed and exact rollback was not completed')
            notify(source, 'contract_compensation_failed')
        end
        return
    end

    if Framework.name == 'qbx_core' then
        local verified = getVehicleById(vehicle.id, operation .. ' verification', source, plate)
        if not rowMatchesPersonalOwner(verified, vehicle.id, identifier, playerLicense, plate) then
            critical(operation, source, plate, 'society withdrawal committed but exact personal-owner verification failed')
            notify(source, 'contract_compensation_failed')
            return
        end
    end

    if not updateSocietyVehicleKeys(source, plate, getContractVehicle(source, plate, token), identifier) then
        notify(source, 'contract_key_handoff_failed')
    end

    scheduleAnimation(source, 'progress_withdrawing', 'vehicle_withdrawn', contract)
end

CreateThread(function()
    local waited = 0

    while (not Framework or not Framework.registerUsableItem or not getContractConfig()) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    local contract = getContractConfig()
    if not Framework or not Framework.registerUsableItem or not contract then
        print('[drs_garages] Contract item registration skipped because Config.Contract or Framework was not loaded.')
        return
    end

if contract.Enabled ~= true then return end

    if Framework.name == 'qb-core' and Config.UseKeySystem
        and GetResourceState('qb-vehiclekeys') ~= 'missing'
    then
        print('[drs_garages] Contract item registration blocked on QB-Core: stock qb-vehiclekeys has no safe global/offline plate-key reset. Disable Config.UseKeySystem or leave Config.Contract.Enabled = false.')
        return
    end

    if type(contract.Item) ~= 'string' or contract.Item == '' then
        print('[drs_garages] Contract item registration skipped because Config.Contract.Item is invalid.')
        return
    end

    Framework.registerUsableItem(contract.Item, function(source)
        if not databaseIsUsable(source) then return end

        source = tonumber(source)
        if not source then return end

        local token = beginOperation(source)
        if not token then
            notify(source, 'contract_busy')
            return
        end

        local ok, err = xpcall(function()
            local player = Framework.getPlayerFromId(source)
            if not player or getItemCount(player, contract.Item) < 1 then
                notify(source, 'contract_item_missing')
                return
            end

            local option, rawPlate, label = lib.callback.await('drs_garages:getContractOption', source)
            if not option or not rawPlate then return end

            local plate = normalizePlate(rawPlate)
            if not plate then
                notify(source, 'invalid_data')
                return
            end

            if not lockPlate(token, plate) then
                notify(source, 'contract_busy')
                return
            end

            if option == 'transfer_player' then
                transferToPlayer(source, plate, label, token)
            elseif option == 'transfer_society' then
                transferToSociety(source, plate, token)
            elseif option == 'withdraw_society' then
                withdrawFromSociety(source, plate, token)
            else
                notify(source, 'invalid_data')
            end
        end, function(errorMessage)
            return debug.traceback(errorMessage, 2)
        end)

        releaseOperation(token)

        if not ok then
            critical('unexpected error', source, nil, err)
            notify(source, 'contract_failed')
        end
    end)
end)
