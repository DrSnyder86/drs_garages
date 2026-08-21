local RESOURCE_NAME = GetCurrentResourceName()
local TABLE_NAME = 'player_vehicles'
local CONNECTION_ATTEMPTS = 20
local CONNECTION_RETRY_DELAY = 250

local BASE_COLUMNS = { 'citizenid', 'plate', 'garage', 'mods' }
local MODEL_COLUMNS = { 'vehicle', 'hash' }
local COMPATIBILITY_COLUMNS = {
    {
        name = 'job',
        definition = "`job` VARCHAR(50) NULL DEFAULT NULL"
    },
    {
        name = 'type',
        definition = "`type` VARCHAR(20) NOT NULL DEFAULT 'car'"
    },
    {
        name = 'stored',
        definition = "`stored` TINYINT(1) NOT NULL DEFAULT 1"
    },
    {
        name = 'state',
        definition = "`state` INT(11) NOT NULL DEFAULT 1"
    }
}

local COMPATIBILITY_INDEXES = {
    {
        name = 'idx_player_vehicles_citizenid_type_stored',
        columns = { 'citizenid', 'type', 'stored' },
        create = 'CREATE INDEX `idx_player_vehicles_citizenid_type_stored` ON `player_vehicles` (`citizenid`, `type`, `stored`)'
    },
    {
        name = 'idx_player_vehicles_job_type_stored',
        columns = { 'job', 'type', 'stored' },
        create = 'CREATE INDEX `idx_player_vehicles_job_type_stored` ON `player_vehicles` (`job`, `type`, `stored`)'
    },
    {
        name = 'idx_player_vehicles_plate',
        columns = { 'plate' },
        create = 'CREATE INDEX `idx_player_vehicles_plate` ON `player_vehicles` (`plate`)'
    }
}

local migrationComplete = false
local migrationSuccessful = false
local migrationDetail = 'database setup is still running'
local readyPromise = promise.new()

---@class DRSGaragesDatabaseApi
---@field isReady fun(): boolean
---@field isUsable fun(): boolean, string?
---@field wasSuccessful fun(): boolean, string?
---@field awaitReady fun(): boolean, string?
DRSGaragesDatabase = {}

---Returns whether the database setup attempt has finished.
---@return boolean
function DRSGaragesDatabase.isReady()
    return migrationComplete
end

---Returns whether setup has finished successfully without blocking the caller.
---@return boolean usable
---@return string? detail
function DRSGaragesDatabase.isUsable()
    return migrationComplete and migrationSuccessful, migrationDetail
end

---Returns the current setup result without waiting.
---@return boolean successful
---@return string? detail
function DRSGaragesDatabase.wasSuccessful()
    return migrationSuccessful, migrationDetail
end

---Waits until database setup has finished, including disabled, skipped, and error paths.
---@return boolean successful
---@return string? detail
function DRSGaragesDatabase.awaitReady()
    if not migrationComplete then
        Citizen.Await(readyPromise)
    end

    return migrationSuccessful, migrationDetail
end

local function log(message)
    print(('[%s][database] %s'):format(RESOURCE_NAME, message))
end

---@param sql string
---@param parameters? table
---@return boolean successful
---@return any result
local function query(sql, parameters)
    local successful, result = pcall(function()
        return MySQL.query.await(sql, parameters or {})
    end)

    if not successful then
        return false, tostring(result)
    end

    return true, result
end

---@param sql string
---@param parameters? table
---@return boolean successful
---@return integer|string affectedRowsOrError
local function update(sql, parameters)
    local successful, result = pcall(function()
        return MySQL.update.await(sql, parameters or {})
    end)

    if not successful then
        return false, tostring(result)
    end

    local affectedRows = tonumber(result)
    if not affectedRows or affectedRows < 0 or affectedRows % 1 ~= 0 then
        return false, ('oxmysql returned an invalid affected-row count: %s'):format(tostring(result))
    end

    return true, affectedRows
end

---@return string? schemaName
---@return string? errorMessage
local function getCurrentSchema()
    local successful, rows = query('SELECT DATABASE() AS `schema_name`')
    if not successful then
        return nil, ('could not determine the active database: %s'):format(rows)
    end

    local schemaName = rows and rows[1] and rows[1].schema_name
    if type(schemaName) ~= 'string' or schemaName == '' then
        return nil, 'oxmysql does not have an active database selected'
    end

    return schemaName
end

---@param schemaName string
---@return boolean? exists
---@return string? errorMessage
local function tableExists(schemaName)
    local successful, rows = query([[
        SELECT 1 AS `present`
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        LIMIT 1
    ]], { schemaName, TABLE_NAME })

    if not successful then
        return nil, ('could not inspect information_schema.TABLES: %s'):format(rows)
    end

    return rows ~= nil and rows[1] ~= nil
end

---@param schemaName string
---@return table<string, boolean>? columns
---@return string? errorMessage
local function getColumns(schemaName)
    local successful, rows = query([[
        SELECT COLUMN_NAME AS `column_name`
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
    ]], { schemaName, TABLE_NAME })

    if not successful then
        return nil, ('could not inspect information_schema.COLUMNS: %s'):format(rows)
    end

    local columns = {}
    for _, row in ipairs(rows or {}) do
        if type(row.column_name) == 'string' then
            columns[row.column_name:lower()] = true
        end
    end

    return columns
end

---@param schemaName string
---@return table<string, table>? indexes
---@return string? errorMessage
local function getIndexes(schemaName)
    local successful, rows = query([[
        SELECT
            INDEX_NAME AS `index_name`,
            NON_UNIQUE AS `non_unique`,
            SEQ_IN_INDEX AS `sequence`,
            COLUMN_NAME AS `column_name`
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
    ]], { schemaName, TABLE_NAME })

    if not successful then
        return nil, ('could not inspect information_schema.STATISTICS: %s'):format(rows)
    end

    local indexes = {}
    for _, row in ipairs(rows or {}) do
        local indexName = row.index_name
        if type(indexName) == 'string' then
            indexName = indexName:lower()
            local index = indexes[indexName]
            if not index then
                index = {
                    nonUnique = row.non_unique == true or tonumber(row.non_unique) == 1,
                    columns = {}
                }
                indexes[indexName] = index
            end

            local sequence = tonumber(row.sequence)
            if sequence and type(row.column_name) == 'string' then
                index.columns[sequence] = row.column_name:lower()
            end
        end
    end

    return indexes
end

---@param actual table?
---@param expected string[]
---@return boolean
local function indexMatches(actual, expected)
    if not actual or not actual.nonUnique or #actual.columns ~= #expected then
        return false
    end

    for index, columnName in ipairs(expected) do
        if actual.columns[index] ~= columnName then
            return false
        end
    end

    return true
end

---@param values string[]
---@return string
local function join(values)
    return table.concat(values, ', ')
end

local SHARED_TYPE_TO_GARAGE_TYPE = {
    automobile = 'car',
    bike = 'car',
    boat = 'boat',
    heli = 'air',
    plane = 'air',
    submarine = 'boat'
}

local SHARED_CATEGORY_TO_GARAGE_TYPE = {
    boats = 'boat',
    cycles = 'car',
    helicopters = 'air',
    motorcycles = 'car',
    planes = 'air',
    submarines = 'boat'
}

local UINT32_RANGE = 4294967296

---@param value any
---@return string?
local function normalizedText(value)
    if type(value) ~= 'string' then return end

    value = value:match('^%s*(.-)%s*$')
    if value == '' then return end

    return value:lower()
end

---@param value any
---@return string?
local function normalizedHash(value)
    if type(value) ~= 'number' and type(value) ~= 'string' then return end

    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then return end

    number = math.floor(number) % UINT32_RANGE
    return ('%.0f'):format(number)
end

---@param metadata table
---@return string?
local function getMetadataGarageType(metadata)
    local sharedType = normalizedText(metadata.type)
    if sharedType and SHARED_TYPE_TO_GARAGE_TYPE[sharedType] then
        return SHARED_TYPE_TO_GARAGE_TYPE[sharedType]
    end

    local category = normalizedText(metadata.category)
    return category and SHARED_CATEGORY_TO_GARAGE_TYPE[category] or nil
end

---@param lookup table<string, string|boolean>
---@param key string?
---@param garageType string
local function addLookupValue(lookup, key, garageType)
    if not key then return end

    local existing = lookup[key]
    if existing and existing ~= garageType then
        -- Conflicting metadata is not safe to use for an automatic data change.
        lookup[key] = false
    elseif existing == nil then
        lookup[key] = garageType
    end
end

---@param nameLookup table<string, string|boolean>
---@param hashLookup table<string, string|boolean>
---@param value any
---@param garageType string
local function addModelLookup(nameLookup, hashLookup, value, garageType)
    local hash = normalizedHash(value)
    if hash then
        addLookupValue(hashLookup, hash, garageType)
        return
    end

    local name = normalizedText(value)
    if not name then return end

    addLookupValue(nameLookup, name, garageType)

    local hashFunction = type(joaat) == 'function' and joaat
        or type(GetHashKey) == 'function' and GetHashKey
        or nil
    if hashFunction then
        local successful, modelHash = pcall(hashFunction, name)
        if successful then
            addLookupValue(hashLookup, normalizedHash(modelHash), garageType)
        end
    end
end

---@param frameworkName string
---@return table[] sources
---@return string? warning
local function getSharedVehicleSources(frameworkName)
    local sources = {}
    local warnings = {}

    if frameworkName == 'qb-core' then
        local vehicles = type(QBCore) == 'table'
            and type(QBCore.Shared) == 'table'
            and QBCore.Shared.Vehicles
            or nil

        if type(vehicles) == 'table' then
            sources[#sources + 1] = vehicles
        else
            warnings[#warnings + 1] = 'QBCore.Shared.Vehicles is unavailable'
        end
    elseif frameworkName == 'qbx_core' then
        local byNameSuccessful, byName = pcall(function()
            return exports.qbx_core:GetVehiclesByName()
        end)
        if byNameSuccessful and type(byName) == 'table' then
            sources[#sources + 1] = byName
        else
            warnings[#warnings + 1] = ('qbx_core GetVehiclesByName failed: %s'):format(tostring(byName))
        end

        local byHashSuccessful, byHash = pcall(function()
            return exports.qbx_core:GetVehiclesByHash()
        end)
        if byHashSuccessful and type(byHash) == 'table' then
            sources[#sources + 1] = byHash
        else
            warnings[#warnings + 1] = ('qbx_core GetVehiclesByHash failed: %s'):format(tostring(byHash))
        end
    end

    return sources, #warnings > 0 and join(warnings) or nil
end

---@param frameworkName string
---@return table<string, string|boolean> nameLookup
---@return table<string, string|boolean> hashLookup
---@return string? warning
local function buildVehicleTypeLookups(frameworkName)
    local sources, warning = getSharedVehicleSources(frameworkName)
    local nameLookup = {}
    local hashLookup = {}

    for _, vehicles in ipairs(sources) do
        for key, metadata in pairs(vehicles) do
            if type(metadata) == 'table' then
                local garageType = getMetadataGarageType(metadata)
                if garageType then
                    addModelLookup(nameLookup, hashLookup, key, garageType)
                    addModelLookup(nameLookup, hashLookup, metadata.model, garageType)
                    addModelLookup(nameLookup, hashLookup, metadata.spawncode, garageType)
                    addModelLookup(nameLookup, hashLookup, metadata.hash, garageType)
                end
            end
        end
    end

    return nameLookup, hashLookup, warning
end

---@param row table
---@param nameLookup table<string, string|boolean>
---@param hashLookup table<string, string|boolean>
---@return string?
---@return 'vehicle'|'hash'?
---@return any
local function getRowGarageType(row, nameLookup, hashLookup)
    for index = 1, 2 do
        local columnName = index == 1 and 'vehicle' or 'hash'
        local value = row[columnName]
        local name = normalizedText(value)
        local nameType = name and nameLookup[name] or nil
        if type(nameType) == 'string' then return nameType, columnName, value end

        local hash = normalizedHash(value)
        local hashType = hash and hashLookup[hash] or nil
        if type(hashType) == 'string' then return hashType, columnName, value end
    end
end

---@param columns table<string, boolean>
---@param frameworkName string
---@return boolean successful
---@return string? errorMessage
local function backfillVehicleTypes(columns, frameworkName)
    local selectColumns = { '`plate`' }
    if columns.vehicle then selectColumns[#selectColumns + 1] = '`vehicle`' end
    if columns.hash then selectColumns[#selectColumns + 1] = '`hash`' end

    local selected, rows = query(("SELECT %s FROM `%s` WHERE `type` = 'car'"):format(join(selectColumns), TABLE_NAME))
    if not selected then
        return false, ('could not read default-car vehicles for type inference: %s'):format(rows)
    end

    rows = rows or {}
    local nameLookup, hashLookup, metadataWarning = buildVehicleTypeLookups(frameworkName)
    if metadataWarning then
        log(('WARNING: Shared vehicle metadata was only partially available: %s.'):format(metadataWarning))
    end

    local knownLand = 0
    local unknown = 0
    local specialCandidates = 0
    local affectedRows = 0
    local failed = 0
    local firstError

    for _, row in ipairs(rows) do
        local garageType, modelColumn, modelValue = getRowGarageType(row, nameLookup, hashLookup)

        if garageType == 'car' then
            knownLand = knownLand + 1
        elseif garageType == 'boat' or garageType == 'air' then
            specialCandidates = specialCandidates + 1

            if type(row.plate) ~= 'string' or row.plate == '' or not modelColumn or modelValue == nil then
                failed = failed + 1
                firstError = firstError or 'a classified row has no usable plate/model identity'
            else
                local updateSql = modelColumn == 'vehicle'
                    and "UPDATE `player_vehicles` SET `type` = ? WHERE `plate` = ? AND `vehicle` = ? AND `type` = 'car'"
                    or "UPDATE `player_vehicles` SET `type` = ? WHERE `plate` = ? AND `hash` = ? AND `type` = 'car'"
                local updated, affectedOrError = update(updateSql, { garageType, row.plate, modelValue })

                if updated then
                    local pendingSql = modelColumn == 'vehicle'
                        and "SELECT COUNT(*) AS `pending_count` FROM `player_vehicles` WHERE `plate` = ? AND `vehicle` = ? AND `type` = 'car'"
                        or "SELECT COUNT(*) AS `pending_count` FROM `player_vehicles` WHERE `plate` = ? AND `hash` = ? AND `type` = 'car'"
                    local checked, pendingRows = query(pendingSql, { row.plate, modelValue })
                    local pendingCount = checked and pendingRows and pendingRows[1]
                        and tonumber(pendingRows[1].pending_count)
                        or nil

                    if not checked then
                        failed = failed + 1
                        firstError = firstError or tostring(pendingRows)
                    elseif not pendingCount or pendingCount < 0 or pendingCount % 1 ~= 0 then
                        failed = failed + 1
                        firstError = firstError or 'could not validate remaining default-car rows after an inference update'
                    elseif pendingCount > 0 then
                        failed = failed + 1
                        firstError = firstError or ('%d matching row(s) remained `car` after an inference update'):format(pendingCount)
                    else
                        affectedRows = affectedRows + affectedOrError
                    end
                else
                    failed = failed + 1
                    firstError = firstError or tostring(affectedOrError)
                end
            end
        else
            unknown = unknown + 1
        end
    end

    log(('Vehicle type inference checked %d default-car row(s): %d known land, %d boat/air candidate(s), %d unmatched; %d row(s) updated.'):format(
        #rows,
        knownLand,
        specialCandidates,
        unknown,
        affectedRows
    ))

    if unknown > 0 then
        log(('WARNING: %d player_vehicles row(s) could not be matched to known shared vehicle metadata and retained the default `car` type. Review custom boats and aircraft manually.'):format(unknown))
    end

    if failed > 0 then
        return false, ('could not safely infer the type of %d classified vehicle row(s): %s. Setup remains gated and will retry on the next resource start.'):format(failed, firstError)
    end

    return true
end

---@return boolean successful
---@return string detail
local function migrate()
    local databaseConfig = type(Config) == 'table' and Config.Database or nil
    if type(databaseConfig) == 'table' and databaseConfig.AutoMigrate == false then
        log('Automatic migration is disabled by Config.Database.AutoMigrate.')
        return true, 'automatic migration disabled'
    end

    local frameworkName = type(Framework) == 'table' and Framework.name or nil
    if frameworkName == 'es_extended' then
        log('ESX detected; QB/Qbox player_vehicles migration is not required.')
        return true, 'ESX does not require the player_vehicles migration'
    end

    if frameworkName ~= 'qb-core' and frameworkName ~= 'qbx_core' then
        return false, ('cannot migrate before a supported framework is detected (got %s)'):format(tostring(frameworkName))
    end

    local schemaName, schemaError
    for attempt = 1, CONNECTION_ATTEMPTS do
        schemaName, schemaError = getCurrentSchema()
        if schemaName then break end

        if attempt < CONNECTION_ATTEMPTS then
            Wait(CONNECTION_RETRY_DELAY)
        end
    end

    if not schemaName then
        return false, ('database connection was not ready after %d attempts: %s'):format(CONNECTION_ATTEMPTS, schemaError)
    end

    local exists, tableError = tableExists(schemaName)
    if exists == nil then
        return false, tableError
    end

    if not exists then
        return false, ("`%s`.`%s` is missing. Import the framework's standard player_vehicles schema manually; DRS Garages will never create or replace that table."):format(schemaName, TABLE_NAME)
    end

    local columns, columnError = getColumns(schemaName)
    if not columns then
        return false, columnError
    end

    local missingBaseColumns = {}
    for _, columnName in ipairs(BASE_COLUMNS) do
        if not columns[columnName] then
            missingBaseColumns[#missingBaseColumns + 1] = columnName
        end
    end

    if #missingBaseColumns > 0 then
        return false, ("`%s` is missing required framework column(s): %s. Restore the standard QB/Qbox table schema manually; automatic migration only adds job, type, stored, and state."):format(TABLE_NAME, join(missingBaseColumns))
    end

    local hasModelColumn = false
    for _, columnName in ipairs(MODEL_COLUMNS) do
        if columns[columnName] then
            hasModelColumn = true
            break
        end
    end

    if not hasModelColumn then
        return false, ("`%s` needs at least one usable vehicle model column (`vehicle` or `hash`). Restore the framework's standard schema manually; automatic migration will not invent model data."):format(TABLE_NAME)
    end

    local newlyAdded = {}
    local failedColumns = {}

    for _, column in ipairs(COMPATIBILITY_COLUMNS) do
        if not columns[column.name] then
            local successful, alterError = query(('ALTER TABLE `%s` ADD COLUMN %s'):format(TABLE_NAME, column.definition))

            if successful then
                columns[column.name] = true
                newlyAdded[column.name] = true
                log(('Added missing `%s`.`%s` column.'):format(TABLE_NAME, column.name))
            else
                -- A second resource may have completed the same idempotent change after our check.
                local refreshedColumns = getColumns(schemaName)
                if refreshedColumns and refreshedColumns[column.name] then
                    columns = refreshedColumns
                    log(('`%s`.`%s` was added concurrently; continuing.'):format(TABLE_NAME, column.name))
                else
                    failedColumns[#failedColumns + 1] = column.name
                    log(('Could not add `%s`.`%s`: %s'):format(TABLE_NAME, column.name, alterError))
                end
            end
        end
    end

    local addedStored = newlyAdded.stored == true
    local addedState = newlyAdded.state == true
    if columns.stored and columns.state and addedStored ~= addedState then
        local synchronizeSql = addedStored
            and 'UPDATE `player_vehicles` SET `stored` = CASE WHEN `state` = 1 THEN 1 ELSE 0 END'
            or 'UPDATE `player_vehicles` SET `state` = CASE WHEN `stored` = 1 THEN 1 ELSE 0 END'
        local synchronized, synchronizeError = query(synchronizeSql)

        if not synchronized then
            return false, ('the new storage-state column was added, but existing rows could not be synchronized: %s. Run the matching UPDATE manually before using the garage.'):format(synchronizeError)
        end

        log(('Synchronized existing `%s` values from `%s`.'):format(
            addedStored and 'stored' or 'state',
            addedStored and 'state' or 'stored'
        ))
    end

    if #failedColumns > 0 then
        return false, ('could not add compatibility column(s): %s. Grant the database user ALTER permission or import sql/qbox_drs_garages.sql manually, then restart the resource.'):format(join(failedColumns))
    end

    local inferred, inferenceError = backfillVehicleTypes(columns, frameworkName)
    if not inferred then
        return false, inferenceError
    end

    local indexes, indexError = getIndexes(schemaName)
    if not indexes then
        return false, indexError
    end

    local invalidIndexes = {}
    local failedIndexes = {}

    for _, expected in ipairs(COMPATIBILITY_INDEXES) do
        local existing = indexes[expected.name]

        if existing and not indexMatches(existing, expected.columns) then
            invalidIndexes[#invalidIndexes + 1] = expected.name
            log(('Index `%s` exists but is not the expected nonunique (%s) index; it was left untouched.'):format(
                expected.name,
                join(expected.columns)
            ))
        elseif not existing then
            local created, createError = query(expected.create)

            if created then
                log(('Added missing `%s` index.'):format(expected.name))
            else
                -- Treat a concurrent, correctly defined index as success, but never replace a bad one.
                local refreshedIndexes = getIndexes(schemaName)
                local refreshed = refreshedIndexes and refreshedIndexes[expected.name]
                if indexMatches(refreshed, expected.columns) then
                    indexes = refreshedIndexes
                    log(('Index `%s` was added concurrently; continuing.'):format(expected.name))
                else
                    failedIndexes[#failedIndexes + 1] = expected.name
                    log(('Could not add index `%s`: %s'):format(expected.name, createError))
                end
            end
        end
    end

    if #invalidIndexes > 0 then
        return false, ('named index(es) have unexpected definitions: %s. Correct them manually; automatic migration will not drop or replace indexes.'):format(join(invalidIndexes))
    end

    if #failedIndexes > 0 then
        return false, ('could not add compatibility index(es): %s. Grant the database user INDEX permission or import sql/qbox_drs_garages.sql manually, then restart the resource.'):format(join(failedIndexes))
    end

    local finalIndexes, finalIndexError = getIndexes(schemaName)
    if not finalIndexes then
        return false, finalIndexError
    end

    local unverifiedIndexes = {}
    for _, expected in ipairs(COMPATIBILITY_INDEXES) do
        if not indexMatches(finalIndexes[expected.name], expected.columns) then
            unverifiedIndexes[#unverifiedIndexes + 1] = expected.name
        end
    end

    if #unverifiedIndexes > 0 then
        return false, ('could not verify compatibility index(es): %s. Inspect information_schema.STATISTICS and apply the SQL manually.'):format(join(unverifiedIndexes))
    end

    return true, 'database schema is ready'
end

local function settle(successful, detail)
    if migrationComplete then return end

    migrationSuccessful = successful == true
    migrationDetail = detail
    migrationComplete = true
    readyPromise:resolve(true)
end

CreateThread(function()
    local function migrationError(errorMessage)
        if debug and debug.traceback then
            return debug.traceback(errorMessage, 2)
        end

        return tostring(errorMessage)
    end

    local callSuccessful, migrationResult, detail = xpcall(migrate, migrationError)

    if not callSuccessful then
        settle(false, ('unexpected migration error: %s'):format(tostring(migrationResult)))
    else
        settle(migrationResult, detail)
    end

    if migrationSuccessful then
        log(migrationDetail)
    else
        log(('ERROR: %s'):format(tostring(migrationDetail)))
    end
end)
