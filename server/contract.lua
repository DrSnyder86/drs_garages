local contractConfig
local playerLocks = {}
local plateLocks = {}
local journalReady = false
local journalDetail = 'contract journal has not initialized'
local journalSnapshot = {
    ready = false,
    required = false,
    attempted = false,
    tablePresent = false,
    unresolved = 0,
    inProgress = 0,
    reviewRequired = 0,
    recovered = 0,
    lastReconciledAt = nil,
    statusQueryOk = false,
    statusQueryDetail = 'contract journal status has not been queried',
    registrationAttempted = false,
    registrationReady = false,
    registrationDetail = 'contract item registration has not been evaluated'
}
local operationSequence = 0
local operationNonce = math.random(0, 2147483647)
local journalOwnershipMatches
local journalOperationPlates = {}
local journalQuarantinePending = {}
local journalQuarantineTokens = {}

local CONTRACT_JOURNAL_TABLE_SQL = [[
    CREATE TABLE IF NOT EXISTS `drs_vehicle_contract_operations` (
        `operation_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `operation_type` VARCHAR(32) NOT NULL,
        `status` VARCHAR(32) NOT NULL,
        `step` VARCHAR(48) NOT NULL,
        `active_plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NULL,
        `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `vehicle_row_id` VARCHAR(64) NULL,
        `actor_identifier` VARCHAR(80) NOT NULL,
        `counterparty_identifier` VARCHAR(80) NULL,
        `job` VARCHAR(50) NULL,
        `price` INT UNSIGNED NOT NULL DEFAULT 0,
        `payment_account` VARCHAR(32) NOT NULL DEFAULT 'money',
        `item_name` VARCHAR(64) NOT NULL,
        `item_removed` TINYINT(1) NOT NULL DEFAULT 0,
        `money_debited` TINYINT(1) NOT NULL DEFAULT 0,
        `ownership_changed` TINYINT(1) NOT NULL DEFAULT 0,
        `money_credited` TINYINT(1) NOT NULL DEFAULT 0,
        `keys_updated` TINYINT(1) NOT NULL DEFAULT 0,
        `compensated` TINYINT(1) NOT NULL DEFAULT 0,
        `failure_text` VARCHAR(1000) NULL,
        `created_at` BIGINT UNSIGNED NOT NULL,
        `updated_at` BIGINT UNSIGNED NOT NULL,
        `completed_at` BIGINT UNSIGNED NULL,
        PRIMARY KEY (`operation_id`),
        UNIQUE KEY `ux_drs_vehicle_contract_active_plate` (`active_plate`),
        KEY `idx_drs_vehicle_contract_status_updated` (`status`, `updated_at`),
        KEY `idx_drs_vehicle_contract_plate_created` (`plate`, `created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
]]

local function getContractConfig()
    contractConfig = contractConfig or Config and Config.Contract
    return contractConfig
end

local function actionEnabled(contract, action)
    if type(contract) ~= 'table' or contract.Enabled ~= true then return false end

    local actions = contract.Actions
    if type(actions) ~= 'table' then return true end -- Backward-compatible V1 configuration.
    return actions[action] == true
end

local function getContractActionState(contract)
    local actions = {
        PlayerSales = actionEnabled(contract, 'PlayerSales'),
        SocietyDonations = actionEnabled(contract, 'SocietyDonations'),
        SocietyWithdrawals = actionEnabled(contract, 'SocietyWithdrawals')
    }

    return actions, actions.PlayerSales or actions.SocietyDonations or actions.SocietyWithdrawals
end

local function getPaymentAccount(contract)
    local account = type(contract.PaymentAccount) == 'string' and contract.PaymentAccount:lower() or 'money'
    if account ~= 'money' and account ~= 'bank' then return 'money' end
    return account
end

local function fleetPlateIsBlocked(plate)
    local checker = rawget(_G, 'IsDrsGarageFleetPlateBlocked')
    if type(checker) ~= 'function' then
        -- An enabled fleet subsystem owns durable plate locks. If its module did
        -- not load, contract mutations must stop instead of bypassing its journal.
        return type(Config) == 'table' and type(Config.JobFleet) == 'table'
            and Config.JobFleet.Enabled == true
    end

    local ok, blocked = pcall(checker, plate)
    return not ok or blocked == true
end

local function fleetVehicleIsManaged(plate)
    local checker = rawget(_G, 'GetDrsFleetVehicleMetadata')
    if type(checker) ~= 'function' then
        return type(Config) == 'table' and type(Config.JobFleet) == 'table'
            and Config.JobFleet.Enabled == true
    end

    local ok, metadata = pcall(checker, plate)
    if not ok then return true end
    return type(metadata) == 'table' and metadata.status == 'active'
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

local function hasContractAdminAce(source, contract)
    local ace = type(contract.AdminAce) == 'string' and contract.AdminAce or 'drs_garages.contract.admin'
    return ace ~= '' and IsPlayerAceAllowed(tostring(source), ace) == true
end

local function societyPermissionAllows(source, player, job, policy, contract)
    if not isValidSocietyJob(job) then return false end

    policy = type(policy) == 'string' and policy:match('^%s*(.-)%s*$'):lower() or nil
    if policy ~= 'member' and policy ~= 'boss' and policy ~= 'admin' and policy ~= 'boss_or_admin' then
        return false
    end
    if policy == 'member' then return true end

    local ok, isBoss = safePlayerCall(player, 'isJobBoss')
    isBoss = ok and isBoss == true
    local isAdmin = hasContractAdminAce(source, contract)

    if policy == 'admin' then return isAdmin end
    if policy == 'boss_or_admin' then return isBoss or isAdmin end
    return isBoss
end

local function canDonateSocietyVehicle(source, player, job, contract)
    return societyPermissionAllows(
        source, player, job, contract.SocietyDonationPermission or 'boss', contract
    )
end

local function canWithdrawSocietyVehicle(source, player, job, contract)
    local policy = contract.SocietyWithdrawalPermission
    if type(policy) ~= 'string' then return false end

    return societyPermissionAllows(source, player, job, policy, contract)
end

local function getItemCount(player, item)
    local ok, count = safePlayerCall(player, 'getItemCount', item)
    count = tonumber(count)
    if not ok or not isFiniteNumber(count) then return 0 end
    return count
end

local function getMoney(player, account)
    local ok, amount = safePlayerCall(player, 'getAccountMoney', account)
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

local function executeDatabase(query, params, operation, source, plate)
    local ok, result = pcall(function()
        MySQL.query.await(query, params or {})
    end)

    if not ok then
        critical(operation, source, plate, result)
        return false
    end

    return true
end

local function unixTime()
    return math.max(0, math.floor(tonumber(os.time()) or 0))
end

local function newOperationId(source)
    operationSequence = (operationSequence + 1) % 1000000
    return ('contract:%s:%s:%s:%s:%s'):format(
        unixTime(),
        math.max(0, math.floor(tonumber(GetGameTimer()) or 0)),
        math.max(0, math.floor(tonumber(source) or 0)),
        operationNonce,
        operationSequence
    )
end

local function compactJournalValue(value, maximumLength)
    if value == nil then return nil end
    return tostring(value):sub(1, maximumLength)
end

local function integerFlag(value)
    if value == true then return 1 end
    if value == false then return 0 end
    return tonumber(value)
end

local function queueJournalQuarantine(operationId, plate)
    plate = normalizePlate(plate or journalOperationPlates[operationId])
    if not plate then return end

    journalOperationPlates[operationId] = plate
    if not journalQuarantineTokens[plate] then journalQuarantinePending[plate] = true end
end

local function releaseJournalQuarantine(operationId, plate)
    plate = normalizePlate(plate or journalOperationPlates[operationId])
    if not plate then return end

    journalQuarantinePending[plate] = nil
    local token = journalQuarantineTokens[plate]
    if token then
        local release = rawget(_G, 'EndDrsGaragePlateOperation')
        if type(release) == 'function' then pcall(release, plate, token) end
        journalQuarantineTokens[plate] = nil
    end
    journalOperationPlates[operationId] = nil
end

local function journalStep(operationId, step)
    if not journalReady or type(operationId) ~= 'string' then return false end

    local affected = updateDatabase([[
        UPDATE `drs_vehicle_contract_operations`
        SET `step` = ?, `updated_at` = ?
        WHERE `operation_id` = ? AND `active_plate` IS NOT NULL
        LIMIT 1
    ]], { compactJournalValue(step, 48), unixTime(), operationId }, 'contract journal step', nil, nil)

    if affected ~= 1 then
        queueJournalQuarantine(operationId)
        return false
    end

    return true
end

local JOURNAL_FLAG_COLUMNS = {
    item_removed = true,
    money_debited = true,
    ownership_changed = true,
    money_credited = true,
    keys_updated = true
}

local function journalFlag(operationId, step, flag)
    if not journalReady or not JOURNAL_FLAG_COLUMNS[flag] then return false end

    local affected = updateDatabase(([[
        UPDATE `drs_vehicle_contract_operations`
        SET `%s` = 1, `step` = ?, `updated_at` = ?
        WHERE `operation_id` = ? AND `active_plate` IS NOT NULL
        LIMIT 1
    ]]):format(flag), {
        compactJournalValue(step, 48), unixTime(), operationId
    }, 'contract journal progress', nil, nil)

    if affected ~= 1 then
        queueJournalQuarantine(operationId)
        return false
    end

    return true
end


local function terminalJournalMatches(operationId, status, step, failureText, compensated)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT `status`, `step`, `active_plate`, `compensated`, `failure_text`, `completed_at`
        FROM `drs_vehicle_contract_operations`
        WHERE `operation_id` = ?
        LIMIT 1
    ]], { operationId })
    return ok and row and row.status == status and row.step == step
        and row.active_plate == nil and integerFlag(row.compensated) == (compensated and 1 or 0)
        and tostring(row.failure_text or '') == tostring(failureText or '')
        and row.completed_at ~= nil
end

local function finishJournal(operationId, status, step, failureText, compensated)
    if not journalReady or type(operationId) ~= 'string' then return false end

    local timestamp = unixTime()
    local normalizedStatus = compactJournalValue(status, 32)
    local normalizedStep = compactJournalValue(step, 48)
    local normalizedFailureText = compactJournalValue(failureText or '', 1000)
    local affected = updateDatabase([[
        UPDATE `drs_vehicle_contract_operations`
        SET `status` = ?, `step` = ?, `active_plate` = NULL,
            `compensated` = ?, `failure_text` = ?, `updated_at` = ?, `completed_at` = ?
        WHERE `operation_id` = ? AND `active_plate` IS NOT NULL
        LIMIT 1
    ]], {
        normalizedStatus,
        normalizedStep,
        compensated and 1 or 0,
        normalizedFailureText,
        timestamp,
        timestamp,
        operationId
    }, 'contract journal completion', nil, nil)

    if affected ~= 1 and not terminalJournalMatches(
        operationId, normalizedStatus, normalizedStep, normalizedFailureText, compensated
    ) then
        queueJournalQuarantine(operationId)
        return false
    end

    releaseJournalQuarantine(operationId)
    return true
end

local function reviewJournal(operationId, step, failureText)
    if not journalReady or type(operationId) ~= 'string' then return false end

    local affected = updateDatabase([[
        UPDATE `drs_vehicle_contract_operations`
        SET `status` = 'review_required', `step` = ?, `failure_text` = ?, `updated_at` = ?
        WHERE `operation_id` = ? AND `active_plate` IS NOT NULL
        LIMIT 1
    ]], {
        compactJournalValue(step, 48),
        compactJournalValue(failureText or '', 1000),
        unixTime(),
        operationId
    }, 'contract journal review', nil, nil)

    queueJournalQuarantine(operationId)
    return affected == 1
end

local function createJournal(record)
    if not journalReady then return nil, journalDetail end
    if fleetPlateIsBlocked(record.plate) then
        return nil, 'the fleet journal has quarantined this plate'
    end

    local operationId = newOperationId(record.source)
    local timestamp = unixTime()
    local affected = updateDatabase([[
        INSERT INTO `drs_vehicle_contract_operations`
            (`operation_id`, `operation_type`, `status`, `step`, `active_plate`, `plate`,
             `vehicle_row_id`, `actor_identifier`, `counterparty_identifier`, `job`,
             `price`, `payment_account`, `item_name`, `created_at`, `updated_at`)
        VALUES (?, ?, 'in_progress', 'validated', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        operationId,
        compactJournalValue(record.operationType, 32),
        record.plate,
        record.plate,
        compactJournalValue(record.vehicleRowId or record.plate, 64),
        compactJournalValue(record.actorIdentifier, 80),
        compactJournalValue(record.counterpartyIdentifier or '', 80),
        compactJournalValue(record.job or '', 50),
        math.max(0, math.floor(tonumber(record.price) or 0)),
        compactJournalValue(record.paymentAccount or 'money', 32),
        compactJournalValue(record.itemName, 64),
        timestamp,
        timestamp
    }, 'contract journal begin', record.source, record.plate)

    if affected ~= 1 then
        return nil, 'another unresolved operation already owns this plate or the journal insert failed'
    end

    journalOperationPlates[operationId] = record.plate
    return operationId
end

local JOURNAL_COLUMN_REQUIREMENTS = {
    operation_id = { type = 'varchar', length = 64, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
    operation_type = { type = 'varchar', length = 32, nullable = false, charset = 'utf8mb4' },
    status = { type = 'varchar', length = 32, nullable = false, charset = 'utf8mb4' },
    step = { type = 'varchar', length = 48, nullable = false, charset = 'utf8mb4' },
    active_plate = { type = 'varchar', length = 8, nullable = true, charset = 'ascii', collation = 'ascii_bin' },
    plate = { type = 'varchar', length = 8, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
    vehicle_row_id = { type = 'varchar', length = 64, nullable = true, charset = 'utf8mb4' },
    actor_identifier = { type = 'varchar', length = 80, nullable = false, charset = 'utf8mb4' },
    counterparty_identifier = { type = 'varchar', length = 80, nullable = true, charset = 'utf8mb4' },
    job = { type = 'varchar', length = 50, nullable = true, charset = 'utf8mb4' },
    price = { type = 'int', nullable = false, unsigned = true, default = '0' },
    payment_account = { type = 'varchar', length = 32, nullable = false, charset = 'utf8mb4', default = 'money' },
    item_name = { type = 'varchar', length = 64, nullable = false, charset = 'utf8mb4' },
    item_removed = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    money_debited = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    ownership_changed = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    money_credited = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    keys_updated = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    compensated = { type = 'tinyint', nullable = false, unsigned = false, default = '0' },
    failure_text = { type = 'varchar', length = 1000, nullable = true, charset = 'utf8mb4' },
    created_at = { type = 'bigint', nullable = false, unsigned = true },
    updated_at = { type = 'bigint', nullable = false, unsigned = true },
    completed_at = { type = 'bigint', nullable = true, unsigned = true }
}

local JOURNAL_INDEX_REQUIREMENTS = {
    PRIMARY = { unique = true, columns = { 'operation_id' } },
    ux_drs_vehicle_contract_active_plate = { unique = true, columns = { 'active_plate' } },
    idx_drs_vehicle_contract_status_updated = { unique = false, columns = { 'status', 'updated_at' } },
    idx_drs_vehicle_contract_plate_created = { unique = false, columns = { 'plate', 'created_at' } }
}

local function normalizedColumnDefault(value)
    if value == nil then return nil end
    value = tostring(value):match('^%s*(.-)%s*$')
    if value:sub(1, 1) == "'" and value:sub(-1) == "'" then value = value:sub(2, -2) end
    return value
end

local function journalTableExists()
    local schemaRows = queryDatabase('SELECT DATABASE() AS `schema_name`', {}, 'contract journal discovery', nil, nil)
    local schemaName = schemaRows and schemaRows[1] and schemaRows[1].schema_name
    if type(schemaName) ~= 'string' or schemaName == '' then
        return nil, 'could not determine the active database schema'
    end

    local tableRows = queryDatabase([[
        SELECT 1 AS `present`
        FROM information_schema.TABLES
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` = 'drs_vehicle_contract_operations'
        LIMIT 1
    ]], { schemaName }, 'contract journal discovery', nil, nil)
    if not tableRows then return nil, 'could not inspect the active database schema' end

    return tableRows[1] ~= nil
end

local function validateJournalSchema()
    local schemaRows = queryDatabase('SELECT DATABASE() AS `schema_name`', {}, 'contract journal schema validation', nil, nil)
    local schemaName = schemaRows and schemaRows[1] and schemaRows[1].schema_name
    if type(schemaName) ~= 'string' or schemaName == '' then
        return false, 'could not determine the active database schema'
    end

    local tableRows = queryDatabase([[
        SELECT `ENGINE` AS `engine`, `TABLE_COLLATION` AS `table_collation`
        FROM information_schema.TABLES
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` = 'drs_vehicle_contract_operations'
        LIMIT 1
    ]], { schemaName }, 'contract journal table validation', nil, nil)
    local tableInfo = tableRows and tableRows[1]
    if not tableInfo then return false, 'table `drs_vehicle_contract_operations` is missing' end
    if tostring(tableInfo.engine or ''):upper() ~= 'INNODB' then
        return false, ('table engine must be InnoDB (found %s)'):format(tostring(tableInfo.engine))
    end
    if tostring(tableInfo.table_collation or ''):lower() ~= 'utf8mb4_unicode_ci' then
        return false, ('table collation must be utf8mb4_unicode_ci (found %s)'):format(tostring(tableInfo.table_collation))
    end

    local columnRows = queryDatabase([[
        SELECT `COLUMN_NAME` AS `column_name`, `DATA_TYPE` AS `data_type`,
               `COLUMN_TYPE` AS `column_type`, `IS_NULLABLE` AS `is_nullable`,
               `CHARACTER_MAXIMUM_LENGTH` AS `character_maximum_length`,
               `CHARACTER_SET_NAME` AS `character_set_name`, `COLLATION_NAME` AS `collation_name`,
               `COLUMN_DEFAULT` AS `column_default`
        FROM information_schema.COLUMNS
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` = 'drs_vehicle_contract_operations'
    ]], { schemaName }, 'contract journal column validation', nil, nil)
    if not columnRows then return false, 'could not read journal column definitions' end

    local columns = {}
    for _, column in ipairs(columnRows) do
        columns[tostring(column.column_name):lower()] = column
    end

    for name, requirement in pairs(JOURNAL_COLUMN_REQUIREMENTS) do
        local column = columns[name]
        if not column then return false, ('required column `%s` is missing'):format(name) end

        local dataType = tostring(column.data_type or ''):lower()
        local nullable = tostring(column.is_nullable or ''):upper() == 'YES'
        if dataType ~= requirement.type then
            return false, ('column `%s` must be %s (found %s)'):format(name, requirement.type, dataType)
        end
        if nullable ~= requirement.nullable then
            return false, ('column `%s` nullable=%s (expected %s)'):format(
                name, tostring(nullable), tostring(requirement.nullable)
            )
        end
        if requirement.length and tonumber(column.character_maximum_length) ~= requirement.length then
            return false, ('column `%s` length must be %s (found %s)'):format(
                name, requirement.length, tostring(column.character_maximum_length)
            )
        end
        if requirement.charset
            and tostring(column.character_set_name or ''):lower() ~= requirement.charset
        then
            return false, ('column `%s` character set must be %s (found %s)'):format(
                name, requirement.charset, tostring(column.character_set_name)
            )
        end
        local expectedCollation = requirement.collation
            or (requirement.charset == 'utf8mb4' and 'utf8mb4_unicode_ci' or nil)
        if expectedCollation
            and tostring(column.collation_name or ''):lower() ~= expectedCollation
        then
            return false, ('column `%s` collation must be %s (found %s)'):format(
                name, expectedCollation, tostring(column.collation_name)
            )
        end
        if requirement.unsigned ~= nil then
            local unsigned = tostring(column.column_type or ''):lower():find('unsigned', 1, true) ~= nil
            if unsigned ~= requirement.unsigned then
                return false, ('column `%s` unsigned=%s (expected %s)'):format(
                    name, tostring(unsigned), tostring(requirement.unsigned)
                )
            end
        end
        if requirement.default ~= nil
            and normalizedColumnDefault(column.column_default) ~= requirement.default
        then
            return false, ('column `%s` default must be %s (found %s)'):format(
                name, requirement.default, tostring(column.column_default)
            )
        end
    end

    local indexRows = queryDatabase([[
        SELECT `INDEX_NAME` AS `index_name`, `NON_UNIQUE` AS `non_unique`,
               `SEQ_IN_INDEX` AS `seq_in_index`, `COLUMN_NAME` AS `column_name`,
               `INDEX_TYPE` AS `index_type`
        FROM information_schema.STATISTICS
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` = 'drs_vehicle_contract_operations'
        ORDER BY `INDEX_NAME`, `SEQ_IN_INDEX`
    ]], { schemaName }, 'contract journal index validation', nil, nil)
    if not indexRows then return false, 'could not read journal index definitions' end

    local indexes = {}
    for _, index in ipairs(indexRows) do
        local name = tostring(index.index_name)
        local definition = indexes[name] or {
            unique = tonumber(index.non_unique) == 0,
            type = tostring(index.index_type or ''):lower(),
            columns = {}
        }
        definition.columns[tonumber(index.seq_in_index) or (#definition.columns + 1)] = tostring(index.column_name):lower()
        indexes[name] = definition
    end

    for name, requirement in pairs(JOURNAL_INDEX_REQUIREMENTS) do
        local index = indexes[name]
        if not index then return false, ('required index `%s` is missing'):format(name) end
        if index.type ~= 'btree' then
            return false, ('index `%s` must use BTREE (found %s)'):format(name, tostring(index.type))
        end
        if index.unique ~= requirement.unique or #index.columns ~= #requirement.columns then
            return false, ('index `%s` uniqueness or column count is incompatible'):format(name)
        end
        for position, column in ipairs(requirement.columns) do
            if index.columns[position] ~= column then
                return false, ('index `%s` column %s must be `%s` (found `%s`)'):format(
                    name, position, column, tostring(index.columns[position])
                )
            end
        end
    end

    return true
end

local function initializeJournal(required)
    required = required == true
    journalSnapshot.required = required
    journalSnapshot.attempted = true
    journalSnapshot.ready = false
    journalSnapshot.statusQueryOk = false
    journalSnapshot.statusQueryDetail = 'contract journal startup has not completed'

    local databaseApi = rawget(_G, 'DRSGaragesDatabase')
    if type(databaseApi) == 'table' and type(databaseApi.awaitReady) == 'function' then
        local databaseReady, detail = databaseApi.awaitReady()
        if not databaseReady then
            journalDetail = ('garage database unavailable: %s'):format(tostring(detail))
            journalSnapshot.statusQueryDetail = journalDetail
            return false
        end
    end

    local tablePresent, discoveryDetail = journalTableExists()
    if tablePresent == nil then
        journalDetail = ('contract journal discovery failed: %s'):format(tostring(discoveryDetail))
        journalSnapshot.statusQueryDetail = journalDetail
        return false
    end

    journalSnapshot.tablePresent = tablePresent
    local autoMigrate = not (type(Config.Database) == 'table' and Config.Database.AutoMigrate == false)
    if not tablePresent and not required then
        journalDetail = 'contracts are inactive and no existing contract journal requires reconciliation'
        journalSnapshot.statusQueryOk = true
        journalSnapshot.statusQueryDetail = 'not applicable; journal table is absent'
        return true
    end

    if not tablePresent and required and not autoMigrate then
        journalDetail = 'contract journal table is missing; import sql/drs_vehicle_contract_operations.sql'
        journalSnapshot.statusQueryDetail = journalDetail
        return false
    end

    if not tablePresent and autoMigrate then
        if not executeDatabase(CONTRACT_JOURNAL_TABLE_SQL, {}, 'contract journal migration', nil, nil) then
            journalDetail = 'automatic contract journal migration failed'
            journalSnapshot.statusQueryDetail = journalDetail
            return false
        end
        tablePresent = true
        journalSnapshot.tablePresent = true
    end

    local schemaValid, schemaDetail = validateJournalSchema()
    if not schemaValid then
        journalDetail = ('contract journal schema is incompatible: %s; back it up and run sql/repair_drs_vehicle_contract_operations.sql'):format(
            tostring(schemaDetail)
        )
        journalSnapshot.statusQueryDetail = journalDetail
        return false
    end

    journalReady = true
    journalDetail = 'ready'

    local activeRows = queryDatabase([[
        SELECT `operation_id`, `operation_type`, `plate`, `step`, `actor_identifier`,
               `counterparty_identifier`, `job`, `item_removed`, `money_debited`,
               `ownership_changed`, `money_credited`, `keys_updated`, `compensated`
        FROM `drs_vehicle_contract_operations`
        WHERE `active_plate` IS NOT NULL
        ORDER BY `created_at` ASC
    ]], {}, 'contract journal startup reconciliation', nil, nil)

    if not activeRows then
        journalReady = false
        journalDetail = 'contract journal startup reconciliation query failed'
        journalSnapshot.statusQueryDetail = journalDetail
        return false
    end

    local recovered = 0
    local unresolved = 0
    for _, row in ipairs(activeRows) do
        journalOperationPlates[row.operation_id] = normalizePlate(row.plate)
        local committed
        if row.operation_type == 'player_sale' then
            committed = integerFlag(row.item_removed) == 1
                and integerFlag(row.money_debited) == 1
                and integerFlag(row.ownership_changed) == 1
                and integerFlag(row.money_credited) == 1
                and integerFlag(row.keys_updated) == 1
        else
            committed = integerFlag(row.item_removed) == 1
                and integerFlag(row.ownership_changed) == 1
                and integerFlag(row.keys_updated) == 1
        end

        if committed and type(journalOwnershipMatches) == 'function' then
            committed = journalOwnershipMatches(row) == true
        end

        if committed then
            if finishJournal(
                row.operation_id,
                'completed',
                'startup_reconciled',
                'Item, payment, ownership, and key side effects were fully journaled before restart.',
                false
            ) then
                recovered = recovered + 1
            else
                unresolved = unresolved + 1
            end
        elseif integerFlag(row.compensated) == 1 then
            if finishJournal(row.operation_id, 'compensated', 'startup_reconciled', nil, true) then
                recovered = recovered + 1
            else
                unresolved = unresolved + 1
            end
        else
            reviewJournal(
                row.operation_id,
                'startup_review',
                ('Server restarted during step `%s`; cash/item APIs cannot be inferred safely.'):format(tostring(row.step))
            )
            unresolved = unresolved + 1
            print(('[drs_garages][contract][journal] REVIEW REQUIRED: operation=%s type=%s plate=%s lastStep=%s'):format(
                tostring(row.operation_id), tostring(row.operation_type), tostring(row.plate), tostring(row.step)
            ))
        end
    end

    local retentionDays = tonumber(getContractConfig() and getContractConfig().JournalRetentionDays) or 90
    if isFiniteNumber(retentionDays) and retentionDays > 0 then
        local cutoff = unixTime() - math.floor(math.min(retentionDays, 3650) * 86400)
        updateDatabase([[
            DELETE FROM `drs_vehicle_contract_operations`
            WHERE `active_plate` IS NULL AND `completed_at` IS NOT NULL AND `completed_at` < ?
        ]], { cutoff }, 'contract journal retention', nil, nil)
    end

    journalSnapshot.ready = true
    journalSnapshot.unresolved = unresolved
    journalSnapshot.inProgress = 0
    journalSnapshot.reviewRequired = unresolved
    journalSnapshot.recovered = recovered
    journalSnapshot.lastReconciledAt = unixTime()
    journalSnapshot.statusQueryOk = true
    journalSnapshot.statusQueryDetail = 'startup reconciliation query completed'
    print(('[drs_garages][contract][journal] Ready: %s recovered, %s requiring review.'):format(recovered, unresolved))
    return true
end

local function countJournalEntries(entries)
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    return count
end

DRSGaragesContractJournal = {
    getStatus = function()
        if journalReady then
            local rows = queryDatabase([[
                SELECT `status`, COUNT(*) AS `count`
                FROM `drs_vehicle_contract_operations`
                WHERE `active_plate` IS NOT NULL
                GROUP BY `status`
            ]], {}, 'contract journal status', nil, nil)

            if rows then
                local unresolved = 0
                local inProgress = 0
                local reviewRequired = 0
                for _, row in ipairs(rows) do
                    local count = math.max(0, math.floor(tonumber(row.count) or 0))
                    unresolved = unresolved + count
                    if row.status == 'in_progress' then inProgress = inProgress + count end
                    if row.status == 'review_required' then reviewRequired = reviewRequired + count end
                end

                journalSnapshot.unresolved = unresolved
                journalSnapshot.inProgress = inProgress
                journalSnapshot.reviewRequired = reviewRequired
                journalSnapshot.statusQueryOk = true
                journalSnapshot.statusQueryDetail = 'status query completed'
            else
                journalSnapshot.statusQueryOk = false
                journalSnapshot.statusQueryDetail = 'contract journal status query failed; counts may be stale'
            end
        end

        local contract = getContractConfig()
        local activeActions, required = getContractActionState(contract)
        journalSnapshot.required = required
        journalSnapshot.ready = journalReady

        return {
            enabled = type(contract) == 'table' and contract.Enabled == true,
            activeActions = activeActions,
            required = required,
            attempted = journalSnapshot.attempted,
            ready = journalReady,
            detail = journalDetail,
            tablePresent = journalSnapshot.tablePresent,
            unresolved = journalSnapshot.unresolved,
            inProgress = journalSnapshot.inProgress,
            reviewRequired = journalSnapshot.reviewRequired,
            quarantined = countJournalEntries(journalQuarantineTokens),
            pendingQuarantine = countJournalEntries(journalQuarantinePending),
            recovered = journalSnapshot.recovered,
            lastReconciledAt = journalSnapshot.lastReconciledAt,
            statusQueryOk = journalSnapshot.statusQueryOk,
            statusQueryDetail = journalSnapshot.statusQueryDetail,
            registrationAttempted = journalSnapshot.registrationAttempted,
            registrationReady = journalSnapshot.registrationReady,
            registrationDetail = journalSnapshot.registrationDetail
        }
    end,
    listUnresolved = function(limit)
        if not journalReady then return {} end
        limit = tonumber(limit) or 25
        if not isFiniteNumber(limit) then limit = 25 end
        limit = math.min(math.max(math.floor(limit), 1), 100)

        return queryDatabase(([==[
            SELECT `operation_id`, `operation_type`, `status`, `step`, `plate`,
                   `actor_identifier`, `counterparty_identifier`, `job`, `price`,
                   `payment_account`, `failure_text`, `created_at`, `updated_at`
            FROM `drs_vehicle_contract_operations`
            WHERE `active_plate` IS NOT NULL
            ORDER BY `created_at` ASC
            LIMIT %s
        ]==]):format(limit), {}, 'contract journal unresolved list', nil, nil) or {}
    end,
    resolve = function(operationId, status, note)
        if not journalReady or type(operationId) ~= 'string' or operationId == '' then return false end
        if status ~= 'completed' and status ~= 'compensated' and status ~= 'cancelled' then return false end

        local timestamp = unixTime()
        local failureText = compactJournalValue(note or ('Manually resolved as %s.'):format(status), 1000)
        local compensated = status == 'compensated'
        local affected = updateDatabase([[
            UPDATE `drs_vehicle_contract_operations`
            SET `status` = ?, `step` = 'manual_resolution', `active_plate` = NULL,
                `compensated` = ?, `failure_text` = ?, `updated_at` = ?, `completed_at` = ?
            WHERE `operation_id` = ? AND `active_plate` IS NOT NULL
              AND `status` = 'review_required'
            LIMIT 1
        ]], {
            status,
            compensated and 1 or 0,
            failureText,
            timestamp,
            timestamp,
            operationId
        }, 'contract journal manual resolution', nil, nil)

        if affected == 1 or terminalJournalMatches(
            operationId, status, 'manual_resolution', failureText, compensated
        ) then
            releaseJournalQuarantine(operationId)
            return true
        end

        queueJournalQuarantine(operationId)
        return false
    end
}

local isQb = Framework and (Framework.name == 'qb-core' or Framework.name == 'qbx_core')
local vehicleTable = isQb and 'player_vehicles' or 'owned_vehicles'
local ownerColumn = isQb and 'citizenid' or 'owner'

journalOwnershipMatches = function(operation)
    local rows = queryDatabase(
        ('SELECT `%s` AS `owner_key`, `job`, `plate` FROM `%s` WHERE `plate` = ? LIMIT 2')
            :format(ownerColumn, vehicleTable),
        { operation.plate }, 'contract journal ownership reconciliation', nil, operation.plate
    )
    if not rows or #rows ~= 1 or normalizePlate(rows[1].plate) ~= normalizePlate(operation.plate) then
        return false
    end

    local vehicle = rows[1]
    if operation.operation_type == 'player_sale' then
        return vehicle.job == nil
            and tostring(vehicle.owner_key or '') == tostring(operation.counterparty_identifier or '')
    end
    if operation.operation_type == 'society_donation' then
        return tostring(vehicle.job or '') == tostring(operation.job or '')
    end
    if operation.operation_type == 'society_withdrawal' then
        return vehicle.job == nil
            and tostring(vehicle.owner_key or '') == tostring(operation.actor_identifier or '')
    end

    return false
end

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

    local contract = getContractConfig() or {}
    local maximumDistance = tonumber(contract.PlayerDistance) or 10.0
    if not isFiniteNumber(maximumDistance) then maximumDistance = 10.0 end
    maximumDistance = math.min(math.max(maximumDistance, 1.0), 25.0)

    return ok and distance <= maximumDistance + 2.0
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

local function journalPlateIsBlocked(plate, source)
    if not journalReady then
        -- Inactive contracts with no historical table are the only safe
        -- not-ready state. Before discovery completes, or when an existing
        -- journal cannot be reconciled, its affected plates are unknowable and
        -- ordinary garage operations must fail closed.
        return journalSnapshot.statusQueryOk ~= true
    end
    if journalSnapshot.statusQueryOk ~= true then return true end
    if journalQuarantinePending[plate] or journalQuarantineTokens[plate] then return true end
    for _, activePlate in pairs(journalOperationPlates) do
        if activePlate == plate then return true end
    end
    return false
end

function IsDrsGarageContractPlateBlocked(rawPlate)
    local plate = normalizePlate(rawPlate)
    return not plate or journalPlateIsBlocked(plate, nil)
end

local function getContractEligibility(source, plate)
    local contract = getContractConfig()
    local result = {
        playerSale = false,
        societyDonation = false,
        societyWithdrawal = false
    }

    if not contract or contract.Enabled ~= true or not databaseIsUsable(source) or not journalReady then
        return result
    end
    if fleetPlateIsBlocked(plate) then return result end
    if fleetVehicleIsManaged(plate) then return result end
    if journalPlateIsBlocked(plate, source) then return result end
    if not getContractVehicle(source, plate) then return result end

    local player = Framework.getPlayerFromId(source)
    local identifier = getIdentifier(player)
    if not player or not identifier or getItemCount(player, contract.Item) < 1 then return result end

    local job = getJob(player)
    local personalVehicle
    if actionEnabled(contract, 'PlayerSales') or actionEnabled(contract, 'SocietyDonations') then
        personalVehicle = getPersonalVehicle(identifier, plate, 'contract eligibility', source)
    end

    result.playerSale = actionEnabled(contract, 'PlayerSales') and personalVehicle ~= nil
    result.societyDonation = actionEnabled(contract, 'SocietyDonations')
        and personalVehicle ~= nil
        and canDonateSocietyVehicle(source, player, job, contract)

    if actionEnabled(contract, 'SocietyWithdrawals')
        and canWithdrawSocietyVehicle(source, player, job, contract)
    then
        result.societyWithdrawal = getSocietyVehicle(job, plate, 'contract eligibility', source) ~= nil
    end

    return result
end

lib.callback.register('drs_garages:getContractEligibility', function(source, rawPlate)
    source = tonumber(source)
    local plate = normalizePlate(rawPlate)
    if not source or not plate then
        return { playerSale = false, societyDonation = false, societyWithdrawal = false }
    end

    return getContractEligibility(source, plate)
end)

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

local function refundMoney(player, account, amount, operation, source, plate)
    if mutatePlayer(player, 'addAccountMoney', account, amount) then return true end

    critical(operation, source, plate, ('failed to refund $%s'):format(amount))
    return false
end

local function requestSignature(source, progressKey)
    if not GetPlayerName(source) then return false end
    return lib.callback.await('drs_garages:signContract', source, locale(progressKey)) == true
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

local function restorePersonalAfterDonation(vehicle, identifier, license, job, plate, operation, source)
    if Framework.name == 'qbx_core' then
        return restoreQboxPersonalAfterDonation(vehicle, identifier, license, job, plate, operation, source)
    end

    local params = { identifier, plate, job }
    local identityClause = ''
    if vehicle.id ~= nil then
        identityClause = ' AND `id` = ?'
        params[#params + 1] = vehicle.id
    end

    local query = ('UPDATE `%s` SET `job` = NULL WHERE `%s` = ? AND `plate` = ? AND `job` = ?%s LIMIT 1')
        :format(vehicleTable, ownerColumn, identityClause)
    if updateDatabase(query, params, operation, source, plate) ~= 1 then return false end

    local restored = getPersonalVehicle(identifier, plate, operation .. ' verification', source)
    return restored ~= nil
end

local function restoreSocietyAfterWithdrawal(
    vehicle, currentIdentifier, currentLicense, originalIdentifier, originalLicense,
    job, plate, operation, source
)
    if Framework.name == 'qbx_core' then
        local current = getVehicleById(vehicle.id, operation .. ' precheck', source, plate)
        if current and current.job == nil then
            local restoredJob = updateDatabase([[
                UPDATE `player_vehicles`
                SET `job` = ?
                WHERE `id` = ? AND `plate` = ? AND `job` IS NULL
                  AND `citizenid` = ? AND `license` = ?
                LIMIT 1
            ]], { job, vehicle.id, plate, currentIdentifier, currentLicense }, operation, source, plate)
            if restoredJob ~= 1 then return false end
        end

        return restoreQboxSocietyOwner(
            vehicle, currentIdentifier, originalIdentifier, originalLicense,
            job, plate, operation, source
        )
    end

    local assignments = '`job` = ?'
    local params = { job }
    if originalIdentifier == nil then
        assignments = assignments .. (', `%s` = NULL'):format(ownerColumn)
    else
        assignments = assignments .. (', `%s` = ?'):format(ownerColumn)
        params[#params + 1] = originalIdentifier
    end
    if isQb then
        if originalLicense == nil then
            assignments = assignments .. ', `license` = NULL'
        else
            assignments = assignments .. ', `license` = ?'
            params[#params + 1] = originalLicense
        end
    end
    params[#params + 1] = currentIdentifier
    params[#params + 1] = plate

    local identityClause = ''
    if vehicle.id ~= nil then
        identityClause = ' AND `id` = ?'
        params[#params + 1] = vehicle.id
    end

    local query = ('UPDATE `%s` SET %s WHERE `%s` = ? AND `plate` = ? AND `job` IS NULL%s LIMIT 1')
        :format(vehicleTable, assignments, ownerColumn, identityClause)
    if updateDatabase(query, params, operation, source, plate) ~= 1 then return false end

    local restored = getSocietyVehicle(job, plate, operation .. ' verification', source)
    return restored ~= nil and tostring(restored[ownerColumn] or '') == tostring(originalIdentifier or '')
end

local function transferToPlayer(source, plate, _label, token)
    local operation = 'player sale'
    local contract = getContractConfig()
    if not actionEnabled(contract, 'PlayerSales') then
        notify(source, 'contract_failed')
        return
    end

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

    if not requestSignature(source, 'progress_selling')
        or not requestSignature(targetId, 'progress_buying')
    then
        notify(source, 'offer_declined')
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

    local paymentAccount = getPaymentAccount(contract)
    local buyerBalance = getMoney(target, paymentAccount)
    local sellerBalance = getMoney(player, paymentAccount)
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

    local journalId, journalError = createJournal({
        operationType = 'player_sale',
        source = source,
        plate = plate,
        vehicleRowId = vehicle.id,
        actorIdentifier = sellerIdentifier,
        counterpartyIdentifier = targetIdentifier,
        price = price,
        paymentAccount = paymentAccount,
        itemName = contract.Item
    })
    if not journalId then
        critical(operation, source, plate, ('journal refused the operation: %s'):format(tostring(journalError)))
        notify(source, 'contract_busy')
        return
    end

    if not journalStep(journalId, 'item_remove_pending') then
        reviewJournal(journalId, 'journal_write_failed', 'Could not persist the pre-item step.')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        finishJournal(journalId, 'cancelled', 'item_not_removed', 'The required item was not removed.', false)
        notify(source, 'contract_item_missing')
        return
    end
    if not journalFlag(journalId, 'item_removed', 'item_removed') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_item_rollback', 'Item journal write failed.', true)
        else
            reviewJournal(journalId, 'journal_item_ambiguous', 'Item was removed but its journal update and restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
        return
    end

    if not journalStep(journalId, 'buyer_debit_pending') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_debit_rollback', 'Buyer debit did not begin.', true)
        else
            reviewJournal(journalId, 'journal_debit_ambiguous', 'Buyer debit did not begin, but item restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
        return
    end

    if not mutatePlayer(target, 'removeAccountMoney', paymentAccount, price) then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'buyer_debit_failed', 'Buyer payment was declined.', true)
        else
            reviewJournal(journalId, 'buyer_debit_failed', 'Buyer payment was declined and item restoration failed.')
        end
        notify(source, 'buyer_not_enough_money')
        return
    end
    if not journalFlag(journalId, 'buyer_debited', 'money_debited') then
        local refunded = refundMoney(target, paymentAccount, price, operation, source, plate)
        local restored = restoreItem(player, contract, operation, source, plate)
        if refunded and restored then
            finishJournal(journalId, 'compensated', 'journal_debit_rollback', 'Buyer debit journal write failed.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_debit_ambiguous', 'Buyer debit was applied but compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end
        return
    end

    if not journalStep(journalId, 'ownership_change_pending') then
        local refunded = refundMoney(target, paymentAccount, price, operation, source, plate)
        local restored = restoreItem(player, contract, operation, source, plate)
        if refunded and restored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership change did not begin.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Ownership change did not begin, but compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end
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
            reviewJournal(journalId, 'ownership_ambiguous', 'Ownership transition could not be verified or rolled back.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
            return
        end

        local refunded = refundMoney(target, paymentAccount, price, operation, source, plate)
        local restored = restoreItem(player, contract, operation, source, plate)

        if refunded and restored then
            finishJournal(journalId, 'compensated', 'ownership_failed', 'Ownership transition failed and was compensated.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'ownership_compensation_failed', 'Ownership failed and payment/item compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end

        return
    end

    if not journalFlag(journalId, 'ownership_changed', 'ownership_changed') then
        local reverted = revertPersonalOwner(
            vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate,
            operation .. ' journal rollback', source
        )
        local refunded = reverted == 1
            and refundMoney(target, paymentAccount, price, operation, source, plate)
            or false
        local restored = refunded and restoreItem(player, contract, operation, source, plate) or false

        if reverted == 1 and refunded and restored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership journal write failed.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Ownership changed but its journal update or compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end
        return
    end

    if not journalStep(journalId, 'seller_credit_pending') then
        local reverted = revertPersonalOwner(
            vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate,
            operation .. ' journal-credit rollback', source
        )
        local refunded = reverted == 1
            and refundMoney(target, paymentAccount, price, operation, source, plate)
            or false
        local restored = refunded and restoreItem(player, contract, operation, source, plate) or false

        if reverted == 1 and refunded and restored then
            finishJournal(journalId, 'compensated', 'journal_credit_rollback', 'Seller credit did not begin.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_credit_ambiguous', 'Seller credit did not begin, but compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end
        return
    end

    if not mutatePlayer(player, 'addAccountMoney', paymentAccount, price) then
        local reverted = revertPersonalOwner(
            vehicle, targetIdentifier, sellerIdentifier, sellerLicense, plate, operation .. ' rollback', source
        )

        if reverted == 1 then
            local refunded = refundMoney(target, paymentAccount, price, operation, source, plate)
            local restored = restoreItem(player, contract, operation, source, plate)

            if not refunded or not restored then
                reviewJournal(journalId, 'seller_credit_compensation_failed', 'Seller credit failed and compensation was incomplete.')
                notify(source, 'contract_compensation_failed')
            else
                finishJournal(journalId, 'compensated', 'seller_credit_failed', 'Seller credit failed and was compensated.', true)
                notify(source, 'contract_failed')
            end
        else
            critical(operation, source, plate, 'seller credit failed and vehicle ownership rollback did not affect exactly one row')
            reviewJournal(journalId, 'seller_credit_ownership_ambiguous', 'Seller credit failed and ownership rollback was not exact.')
            notify(source, 'contract_compensation_failed')
            notify(targetId, 'contract_compensation_failed')
        end

        return
    end

    if not journalFlag(journalId, 'seller_credited', 'money_credited') then
        reviewJournal(journalId, 'journal_credit_ambiguous', 'Seller was credited but the journal update failed.')
        notify(source, 'contract_compensation_failed')
        notify(targetId, 'contract_compensation_failed')
        return
    end

    if not journalStep(journalId, 'key_handoff_pending') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Ownership and funds committed but the key pre-step could not be persisted.')
        notify(source, 'contract_key_handoff_failed')
        notify(targetId, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        notify(targetId, 'contract_compensation_failed')
        return
    end

    local keyHandoff = transferVehicleKeys(source, targetId, targetIdentifier, plate, contractEntity)
    if not keyHandoff then
        reviewJournal(journalId, 'key_handoff_failed', 'Ownership and payment committed, but the key handoff failed.')
        notify(source, 'contract_key_handoff_failed')
        notify(targetId, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        notify(targetId, 'contract_compensation_failed')
        return
    end

    if not journalFlag(journalId, 'keys_updated', 'keys_updated') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Keys were updated but the journal flag could not be persisted.')
        notify(source, 'contract_compensation_failed')
        notify(targetId, 'contract_compensation_failed')
        return
    end

    if not finishJournal(
        journalId,
        'completed',
        'completed',
        nil,
        false
    ) then
        critical(operation, source, plate, 'ownership and funds committed but the journal could not be finalized')
        notify(source, 'contract_compensation_failed')
        notify(targetId, 'contract_compensation_failed')
        return
    end

    notify(source, 'vehicle_sold', 'success')
    notify(targetId, 'vehicle_bought', 'success')
end

local function transferToSociety(source, plate, token)
    local operation = 'society transfer'
    local contract = getContractConfig()
    if not actionEnabled(contract, 'SocietyDonations') then
        notify(source, 'society_invalid')
        return
    end

    local player = Framework.getPlayerFromId(source)
    local identifier = getIdentifier(player)
    local job = getJob(player)
    local originalLicense = Framework.name == 'qbx_core' and getLicense(player) or nil
    if not player or not identifier or not canDonateSocietyVehicle(source, player, job, contract) then
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

    if not requestSignature(source, 'progress_transfering') then return end

    player = refreshPlayer(source, identifier)
    if not player or getJob(player) ~= job or not canDonateSocietyVehicle(source, player, job, contract) then
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
        and (vehicle.id == nil
            or getLicense(player) ~= originalLicense
            or tostring(vehicle.license or '') ~= tostring(originalLicense))
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

    local journalId, journalError = createJournal({
        operationType = 'society_donation',
        source = source,
        plate = plate,
        vehicleRowId = vehicle.id,
        actorIdentifier = identifier,
        job = job,
        itemName = contract.Item
    })
    if not journalId then
        critical(operation, source, plate, ('journal refused the operation: %s'):format(tostring(journalError)))
        notify(source, 'contract_busy')
        return
    end

    if not journalStep(journalId, 'item_remove_pending') then
        reviewJournal(journalId, 'journal_write_failed', 'Could not persist the pre-item step.')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        finishJournal(journalId, 'cancelled', 'item_not_removed', 'The required item was not removed.', false)
        notify(source, 'contract_item_missing')
        return
    end
    if not journalFlag(journalId, 'item_removed', 'item_removed') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_item_rollback', 'Item journal write failed.', true)
        else
            reviewJournal(journalId, 'journal_item_ambiguous', 'Item was removed but its journal update and restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
        return
    end

    if not journalStep(journalId, 'ownership_change_pending') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership change did not begin.', true)
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Ownership change did not begin, but item restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
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
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'ownership_failed', 'Society assignment failed and the item was restored.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'ownership_compensation_failed', 'Society assignment failed and item restoration failed.')
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
                finishJournal(journalId, 'compensated', 'owner_clear_failed', 'Qbox owner clear failed and was compensated.', true)
                notify(source, 'contract_failed')
            else
                critical(operation, source, plate, 'society donation owner clear failed and exact rollback was not completed')
                reviewJournal(journalId, 'owner_clear_ambiguous', 'Qbox owner clear failed and exact compensation was incomplete.')
                notify(source, 'contract_compensation_failed')
            end
            return
        end
    end

    if not journalFlag(journalId, 'ownership_changed', 'ownership_changed') then
        local ownershipRestored = restorePersonalAfterDonation(
            vehicle, identifier, originalLicense, job, plate, operation .. ' journal rollback', source
        )
        local itemRestored = ownershipRestored and restoreItem(player, contract, operation, source, plate) or false

        if ownershipRestored and itemRestored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership journal write failed.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Society assignment committed but its journal update or compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
        end
        return
    end

    if not journalStep(journalId, 'key_handoff_pending') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Society assignment committed but the key pre-step could not be persisted.')
        notify(source, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        return
    end

    local keysUpdated = updateSocietyVehicleKeys(source, plate, getContractVehicle(source, plate, token), nil)
    if not keysUpdated then
        reviewJournal(journalId, 'key_handoff_failed', 'Society assignment committed, but the key update failed.')
        notify(source, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not journalFlag(journalId, 'keys_updated', 'keys_updated') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Society keys were updated but the journal flag could not be persisted.')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not finishJournal(
        journalId,
        'completed',
        'completed',
        nil,
        false
    ) then
        critical(operation, source, plate, 'society assignment committed but the journal could not be finalized')
        notify(source, 'contract_compensation_failed')
        return
    end

    notify(source, 'vehicle_transfered', 'success')
end

local function withdrawFromSociety(source, plate, token)
    local operation = 'society withdrawal'
    local contract = getContractConfig()
    if not actionEnabled(contract, 'SocietyWithdrawals') then
        notify(source, 'society_withdrawal_denied')
        return
    end

    local player = Framework.getPlayerFromId(source)
    local identifier = getIdentifier(player)
    local job = getJob(player)
    if not player or not identifier or not canWithdrawSocietyVehicle(source, player, job, contract) then
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
    if fleetVehicleIsManaged(plate) then
        notify(source, 'society_withdrawal_denied')
        return
    end

    if lib.callback.await('drs_garages:societyPrompt', source, 'withdraw') ~= true then return end

    if not lockSharedPlate(token, plate) then
        notify(source, 'contract_busy')
        return
    end

    if not requestSignature(source, 'progress_withdrawing') then return end

    player = refreshPlayer(source, identifier)
    if not player or getJob(player) ~= job
        or not canWithdrawSocietyVehicle(source, player, job, contract)
    then
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
    if fleetVehicleIsManaged(plate) then
        notify(source, 'society_withdrawal_denied')
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

    local originalIdentifier = vehicle[ownerColumn]
    local originalLicense = isQb and vehicle.license or nil
    if Framework.name == 'qbx_core' and (vehicle.id == nil or originalIdentifier ~= nil and not originalLicense) then
        notify(source, 'contract_failed')
        return
    end

    if not getContractVehicle(source, plate, token) then
        notify(source, 'no_vehicle_near_you')
        return
    end

    local journalId, journalError = createJournal({
        operationType = 'society_withdrawal',
        source = source,
        plate = plate,
        vehicleRowId = vehicle.id,
        actorIdentifier = identifier,
        job = job,
        itemName = contract.Item
    })
    if not journalId then
        critical(operation, source, plate, ('journal refused the operation: %s'):format(tostring(journalError)))
        notify(source, 'contract_busy')
        return
    end

    if not journalStep(journalId, 'item_remove_pending') then
        reviewJournal(journalId, 'journal_write_failed', 'Could not persist the pre-item step.')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not mutatePlayer(player, 'removeItem', contract.Item, 1) then
        finishJournal(journalId, 'cancelled', 'item_not_removed', 'The required item was not removed.', false)
        notify(source, 'contract_item_missing')
        return
    end
    if not journalFlag(journalId, 'item_removed', 'item_removed') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_item_rollback', 'Item journal write failed.', true)
        else
            reviewJournal(journalId, 'journal_item_ambiguous', 'Item was removed but its journal update and restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
        return
    end

    if not journalStep(journalId, 'ownership_change_pending') then
        local restored = restoreItem(player, contract, operation, source, plate)
        if restored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership change did not begin.', true)
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Ownership change did not begin, but item restoration failed.')
        end
        notify(source, restored and 'contract_failed' or 'contract_compensation_failed')
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
                finishJournal(journalId, 'compensated', 'owner_change_failed', 'Qbox owner change failed and was compensated.', true)
                notify(source, 'contract_failed')
            else
                critical(operation, source, plate, 'Qbox owner change failed and exact society-owner rollback was not completed')
                reviewJournal(journalId, 'owner_change_ambiguous', 'Qbox owner change failed and exact compensation was incomplete.')
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
            finishJournal(journalId, 'compensated', 'ownership_failed', 'Society withdrawal failed and was compensated.', true)
            notify(source, 'contract_failed')
        else
            critical(operation, source, plate, 'society withdrawal database transition failed and exact rollback was not completed')
            reviewJournal(journalId, 'ownership_compensation_failed', 'Society withdrawal failed and exact compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
        end
        return
    end

    if Framework.name == 'qbx_core' then
        local verified = getVehicleById(vehicle.id, operation .. ' verification', source, plate)
        if not rowMatchesPersonalOwner(verified, vehicle.id, identifier, playerLicense, plate) then
            critical(operation, source, plate, 'society withdrawal committed but exact personal-owner verification failed')
            reviewJournal(journalId, 'ownership_verification_failed', 'The personal ownership transition could not be verified.')
            notify(source, 'contract_compensation_failed')
            return
        end
    end

    if not journalFlag(journalId, 'ownership_changed', 'ownership_changed') then
        local ownershipRestored = restoreSocietyAfterWithdrawal(
            vehicle, identifier, playerLicense, originalIdentifier, originalLicense,
            job, plate, operation .. ' journal rollback', source
        )
        local itemRestored = ownershipRestored and restoreItem(player, contract, operation, source, plate) or false

        if ownershipRestored and itemRestored then
            finishJournal(journalId, 'compensated', 'journal_ownership_rollback', 'Ownership journal write failed.', true)
            notify(source, 'contract_failed')
        else
            reviewJournal(journalId, 'journal_ownership_ambiguous', 'Society withdrawal committed but its journal update or compensation was incomplete.')
            notify(source, 'contract_compensation_failed')
        end
        return
    end

    if not journalStep(journalId, 'key_handoff_pending') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Society withdrawal committed but the key pre-step could not be persisted.')
        notify(source, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        return
    end

    local keysUpdated = updateSocietyVehicleKeys(
        source, plate, getContractVehicle(source, plate, token), identifier
    )
    if not keysUpdated then
        reviewJournal(journalId, 'key_handoff_failed', 'Society withdrawal committed, but the key handoff failed.')
        notify(source, 'contract_key_handoff_failed')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not journalFlag(journalId, 'keys_updated', 'keys_updated') then
        reviewJournal(journalId, 'journal_key_ambiguous', 'Withdrawal keys were updated but the journal flag could not be persisted.')
        notify(source, 'contract_compensation_failed')
        return
    end

    if not finishJournal(
        journalId,
        'completed',
        'completed',
        nil,
        false
    ) then
        critical(operation, source, plate, 'society withdrawal committed but the journal could not be finalized')
        notify(source, 'contract_compensation_failed')
        return
    end

    notify(source, 'vehicle_withdrawn', 'success')
end

-- A review-required journal row keeps the shared garage plate domain locked,
-- including across resource restarts. The worker also handles runtime failures:
-- it waits until the live contract releases its temporary token, then replaces
-- it with a retained quarantine token.
CreateThread(function()
    while true do
        local retryDelay = 1000
        for plate in pairs(journalQuarantinePending) do
            retryDelay = 250
            if not journalQuarantineTokens[plate] then
                local beginOperation = rawget(_G, 'BeginDrsGaragePlateOperation')
                if type(beginOperation) == 'function' then
                    local ok, token = pcall(beginOperation, plate, 0, 'unresolved vehicle contract operation')
                    if ok and token then
                        journalQuarantineTokens[plate] = token
                        journalQuarantinePending[plate] = nil
                        print(('[drs_garages][contract][journal] Quarantined plate %s pending staff resolution.'):format(plate))
                    end
                end
            end
        end

        Wait(retryDelay)
    end
end)

CreateThread(function()
    local waited = 0

    while (not Framework or not getContractConfig()) and waited < 5000 do
        Wait(100)
        waited = waited + 100
    end

    local contract = getContractConfig()
    if not contract then
        journalDetail = 'Config.Contract was not loaded'
        journalSnapshot.registrationDetail = 'contract item registration skipped because Config.Contract was not loaded'
        print('[drs_garages] Contract journal and item registration skipped because Config.Contract was not loaded.')
        return
    end

    local _, required = getContractActionState(contract)
    journalSnapshot.required = required

    if not Framework then
        journalSnapshot.statusQueryOk = false
        journalSnapshot.statusQueryDetail = 'framework was unavailable; existing contract operations could not be reconciled'
        journalDetail = journalSnapshot.statusQueryDetail
        journalSnapshot.registrationDetail = 'contract item registration skipped because Framework was not loaded'
        print('[drs_garages] Contract journal and item registration skipped because Framework was not loaded.')
        return
    end

    local initialized = initializeJournal(required)
    if not required then
        journalSnapshot.registrationDetail = 'not required; vehicle contract actions are disabled'
        if not initialized then
            print(('[drs_garages] Existing contract journal reconciliation was unavailable while contracts are disabled: %s'):format(
                tostring(journalDetail)
            ))
        end
        return
    end

    journalSnapshot.registrationAttempted = true
    if not initialized then
        journalSnapshot.registrationDetail = ('operation journal unavailable: %s'):format(tostring(journalDetail))
        print(('[drs_garages] Contract item registration skipped because the operation journal is unavailable: %s'):format(
            tostring(journalDetail)
        ))
        return
    end

    if type(Framework.registerUsableItem) ~= 'function' then
        journalSnapshot.registrationDetail = 'Framework.registerUsableItem is unavailable'
        print('[drs_garages] Contract item registration skipped because the framework usable-item API is unavailable.')
        return
    end

    if Framework.name == 'qb-core' and Config.UseKeySystem
        and GetResourceState('qb-vehiclekeys') ~= 'missing'
    then
        journalSnapshot.registrationDetail = 'blocked: stock qb-vehiclekeys has no safe global/offline plate-key reset'
        print('[drs_garages] Contract item registration blocked on QB-Core: stock qb-vehiclekeys has no safe global/offline plate-key reset. Disable Config.UseKeySystem or leave Config.Contract.Enabled = false.')
        return
    end

    if type(contract.Item) ~= 'string' or contract.Item:match('^%s*$') then
        journalSnapshot.registrationDetail = 'Config.Contract.Item is invalid'
        print('[drs_garages] Contract item registration skipped because Config.Contract.Item is invalid.')
        return
    end

    local registered, registrationError = pcall(Framework.registerUsableItem, contract.Item, function(source)
        if not databaseIsUsable(source) then return end
        if not journalReady then
            notify(source, 'contract_failed')
            return
        end

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

            local rawPlate, label = lib.callback.await('drs_garages:getContractVehicle', source)
            if not rawPlate then return end

            local plate = normalizePlate(rawPlate)
            if not plate then
                notify(source, 'invalid_data')
                return
            end

            if not lockPlate(token, plate) then
                notify(source, 'contract_busy')
                return
            end

            local eligibility = getContractEligibility(source, plate)
            if not eligibility.playerSale
                and not eligibility.societyDonation
                and not eligibility.societyWithdrawal
            then
                notify(source, 'contract_failed')
                return
            end

            local option = lib.callback.await('drs_garages:chooseContractOption', source, eligibility)
            if not option then return end

            if option == 'transfer_player' then
                if not eligibility.playerSale then
                    notify(source, 'invalid_data')
                    return
                end
                transferToPlayer(source, plate, label, token)
            elseif option == 'transfer_society' then
                if not eligibility.societyDonation then
                    notify(source, 'invalid_data')
                    return
                end
                transferToSociety(source, plate, token)
            elseif option == 'withdraw_society' then
                if not eligibility.societyWithdrawal then
                    notify(source, 'invalid_data')
                    return
                end
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

    if not registered then
        journalSnapshot.registrationReady = false
        journalSnapshot.registrationDetail = ('registration failed: %s'):format(tostring(registrationError))
        print(('[drs_garages] Contract item registration failed for `%s`: %s. The item may be absent from the inventory catalog; see install/ContractItem.md.'):format(
            tostring(contract.Item), tostring(registrationError)
        ))
    else
        journalSnapshot.registrationReady = true
        journalSnapshot.registrationDetail = ('usable item `%s` registered; inventory catalog presence must be verified separately'):format(
            tostring(contract.Item)
        )
    end
end)

local function canAdministerContractJournal(source)
    if tonumber(source) == 0 then return true end
    return hasContractAdminAce(source, getContractConfig() or {})
end

RegisterCommand('drsgarages:contracts', function(source)
    source = tonumber(source) or 0
    if not canAdministerContractJournal(source) then return end

    local status = DRSGaragesContractJournal.getStatus()
    print(('[drs_garages][contract][journal] required=%s attempted=%s ready=%s detail=%s unresolved=%s inProgress=%s reviewRequired=%s quarantined=%s pendingQuarantine=%s recovered=%s statusQueryOk=%s registrationReady=%s registrationDetail=%s'):format(
        tostring(status.required), tostring(status.attempted), tostring(status.ready), tostring(status.detail),
        tostring(status.unresolved), tostring(status.inProgress), tostring(status.reviewRequired),
        tostring(status.quarantined), tostring(status.pendingQuarantine), tostring(status.recovered),
        tostring(status.statusQueryOk), tostring(status.registrationReady), tostring(status.registrationDetail)
    ))

    for _, row in ipairs(DRSGaragesContractJournal.listUnresolved(25)) do
        print(('[drs_garages][contract][journal] operation=%s type=%s plate=%s status=%s step=%s actor=%s target=%s job=%s error=%s'):format(
            tostring(row.operation_id), tostring(row.operation_type), tostring(row.plate),
            tostring(row.status), tostring(row.step), tostring(row.actor_identifier),
            tostring(row.counterparty_identifier), tostring(row.job), tostring(row.failure_text)
        ))
    end

    if source > 0 then
        TriggerClientEvent(
            'drs_garages:showNotification', source,
            ('Contract journal: %s unresolved. Details printed to the server console.'):format(status.unresolved or 0),
            (status.unresolved or 0) > 0 and 'warning' or 'success'
        )
    end
end, false)

RegisterCommand('drsgarages:contractresolve', function(source, args)
    source = tonumber(source) or 0
    if not canAdministerContractJournal(source) then return end

    local operationId = args and args[1]
    local status = args and args[2] and tostring(args[2]):lower() or nil
    if type(operationId) ~= 'string'
        or (status ~= 'completed' and status ~= 'compensated' and status ~= 'cancelled')
    then
        print('[drs_garages][contract][journal] Usage: drsgarages:contractresolve <operation_id> <completed|compensated|cancelled>')
        return
    end

    local actor = source == 0 and 'server console' or ('source %s'):format(source)
    local resolved = DRSGaragesContractJournal.resolve(
        operationId,
        status,
        ('Manually resolved as %s by %s. Verify inventory, money, ownership, and keys before resolving.'):format(status, actor)
    )

    print(('[drs_garages][contract][journal] manual resolution operation=%s status=%s actor=%s result=%s'):format(
        operationId, status, actor, tostring(resolved)
    ))

    if source > 0 then
        TriggerClientEvent(
            'drs_garages:showNotification', source,
            resolved and 'Contract journal operation resolved.' or 'Contract journal operation could not be resolved.',
            resolved and 'success' or 'error'
        )
    end
end, false)
