local RESOURCE_NAME = GetCurrentResourceName()
local TABLE_NAME = 'player_vehicles'
local ESX_TABLE_NAME = 'owned_vehicles'
local CONNECTION_ATTEMPTS = 20
local CONNECTION_RETRY_DELAY = 250
local SUPPORTED_CORE_RESOURCES = { 'qbx_core', 'qb-core', 'es_extended' }

local BASE_COLUMNS = { 'citizenid', 'license', 'plate', 'garage', 'mods' }
local MODEL_COLUMNS = { 'vehicle', 'hash' }
local ESX_REQUIRED_COLUMNS = { 'owner', 'plate', 'vehicle', 'stored', 'job' }
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
    }
}

local UNIQUE_PLATE_INDEX_NAMES = {
    [TABLE_NAME] = 'ux_player_vehicles_plate',
    [ESX_TABLE_NAME] = 'ux_owned_vehicles_plate'
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
---@field getStatus fun(): table
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

---Returns a serializable snapshot for diagnostics and companion resources.
---@return table status
function DRSGaragesDatabase.getStatus()
    local databaseConfig = type(Config) == 'table' and Config.Database or nil

    return {
        ready = migrationComplete,
        usable = migrationComplete and migrationSuccessful,
        successful = migrationSuccessful,
        detail = migrationDetail,
        autoMigrate = not (type(databaseConfig) == 'table' and databaseConfig.AutoMigrate == false),
        framework = type(Framework) == 'table' and Framework.name or nil
    }
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

---@param values string[]
---@return string
local function join(values)
    return table.concat(values, ', ')
end

-- GetResourceState also resolves fxmanifest `provide` aliases. The resolved
-- path identifies aliases of one running resource without hiding genuinely
-- separate started framework resources.
local function getStartedResourceIdentity(resource)
    if GetResourceState(resource) ~= 'started' then return end

    local path = GetResourcePath(resource)
    if type(path) == 'string' and path ~= '' then
        return ('path:%s'):format(path)
    end

    return ('name:%s'):format(resource)
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
---@param tableName? string
---@return boolean? exists
---@return string? errorMessage
local function tableExists(schemaName, tableName)
    tableName = tableName or TABLE_NAME

    local successful, rows = query([[
        SELECT 1 AS `present`
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        LIMIT 1
    ]], { schemaName, tableName })

    if not successful then
        return nil, ('could not inspect information_schema.TABLES: %s'):format(rows)
    end

    return rows ~= nil and rows[1] ~= nil
end

---@param schemaName string
---@param tableName? string
---@return table<string, table>? columns
---@return string? errorMessage
local function getColumns(schemaName, tableName)
    tableName = tableName or TABLE_NAME

    local successful, rows = query([[
        SELECT
            COLUMN_NAME AS `column_name`,
            DATA_TYPE AS `data_type`,
            COLUMN_TYPE AS `column_type`,
            IS_NULLABLE AS `is_nullable`,
            CHARACTER_MAXIMUM_LENGTH AS `character_maximum_length`,
            NUMERIC_PRECISION AS `numeric_precision`,
            COLUMN_DEFAULT AS `column_default`
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
    ]], { schemaName, tableName })

    if not successful then
        return nil, ('could not inspect information_schema.COLUMNS: %s'):format(rows)
    end

    local columns = {}
    for _, row in ipairs(rows or {}) do
        if type(row.column_name) == 'string' then
            columns[row.column_name:lower()] = {
                dataType = type(row.data_type) == 'string' and row.data_type:lower() or nil,
                columnType = type(row.column_type) == 'string' and row.column_type:lower() or nil,
                nullable = tostring(row.is_nullable or ''):upper() == 'YES',
                characterMaximumLength = tonumber(row.character_maximum_length),
                numericPrecision = tonumber(row.numeric_precision),
                default = row.column_default
            }
        end
    end

    return columns
end

local TEXT_DATA_TYPES = {
    char = true,
    varchar = true,
    tinytext = true,
    text = true,
    mediumtext = true,
    longtext = true,
    json = true
}
local INTEGER_DATA_TYPES = {
    tinyint = true,
    smallint = true,
    mediumint = true,
    int = true,
    integer = true,
    bigint = true
}
local QB_COLUMN_REQUIREMENTS = {
    citizenid = { kind = 'text', minimumLength = 50 },
    license = { kind = 'text', minimumLength = 50 },
    plate = { kind = 'text', minimumLength = 8 },
    garage = { kind = 'text', minimumLength = 50 },
    mods = { kind = 'text', minimumLength = 65535 },
    job = { kind = 'text', minimumLength = 20, nullable = true, nullDefault = true },
    type = { kind = 'text', minimumLength = 10, nullable = false },
    stored = { kind = 'integer', nullable = false },
    -- Stock qbx_vehicles leaves `state` nullable. Actual NULL rows are checked
    -- and normalized below, so the official definition remains compatible.
    state = { kind = 'integer' }
}
local QB_BASE_COLUMN_REQUIREMENTS = {
    citizenid = QB_COLUMN_REQUIREMENTS.citizenid,
    license = QB_COLUMN_REQUIREMENTS.license,
    plate = QB_COLUMN_REQUIREMENTS.plate,
    garage = QB_COLUMN_REQUIREMENTS.garage,
    mods = QB_COLUMN_REQUIREMENTS.mods
}
local ESX_COLUMN_REQUIREMENTS = {
    owner = { kind = 'text', minimumLength = 50 },
    plate = { kind = 'text', minimumLength = 8 },
    vehicle = { kind = 'text', minimumLength = 65535 },
    stored = { kind = 'integer', nullable = false },
    job = { kind = 'text', minimumLength = 20, nullable = true, nullDefault = true }
}

local function textColumnHasCapacity(column, minimumLength)
    if not column or not TEXT_DATA_TYPES[column.dataType] then return false end
    if column.dataType == 'json' then return true end

    return tonumber(column.characterMaximumLength) ~= nil
        and tonumber(column.characterMaximumLength) >= minimumLength
end

local function describeColumn(column)
    if not column then return 'missing' end

    return ('type=%s, nullable=%s, maxLength=%s, default=%s'):format(
        tostring(column.columnType or column.dataType),
        tostring(column.nullable),
        tostring(column.characterMaximumLength),
        tostring(column.default)
    )
end

-- MariaDB exposes an explicit DEFAULT NULL as the unquoted string `NULL` in
-- information_schema.COLUMNS, while a literal four-character string default
-- is quoted as `'NULL'`. MySQL returns SQL NULL as Lua nil through oxmysql.
local function isNullColumnDefault(value)
    if value == nil then return true end
    if type(value) ~= 'string' then return false end

    return value:match('^%s*(.-)%s*$'):upper() == 'NULL'
end

local function validateColumnDefinitions(columns, requirements)
    local invalid = {}

    for name, requirement in pairs(requirements) do
        local column = columns[name]
        local valid = column ~= nil

        if valid and requirement.kind == 'text' then
            valid = textColumnHasCapacity(column, requirement.minimumLength or 1)
        elseif valid and requirement.kind == 'integer' then
            valid = INTEGER_DATA_TYPES[column.dataType] == true
        end

        if valid and requirement.nullable ~= nil then
            valid = column.nullable == requirement.nullable
        end

        if valid and requirement.nullDefault then
            valid = isNullColumnDefault(column.default)
        end

        if not valid then
            invalid[#invalid + 1] = ('`%s` (%s)'):format(name, describeColumn(column))
        end
    end

    table.sort(invalid)
    return #invalid == 0, invalid
end

local function validatePresentColumnDefinitions(columns, requirements)
    local presentRequirements = {}

    for name, requirement in pairs(requirements) do
        if columns[name] then presentRequirements[name] = requirement end
    end

    return validateColumnDefinitions(columns, presentRequirements)
end

local function hasUsableModelColumn(columns)
    local vehicle = columns.vehicle
    if vehicle and textColumnHasCapacity(vehicle, 1) then return true end

    local hash = columns.hash
    return hash ~= nil and (
        INTEGER_DATA_TYPES[hash.dataType] == true
        or textColumnHasCapacity(hash, 1)
    )
end

local function invalidColumnDefinitionsMessage(tableName, invalid)
    return ('`%s` has incompatible column definition(s): %s. Restore compatible framework definitions manually; automatic and supplied migrations do not rewrite existing columns. Then restart DRS Garages.'):format(
        tableName,
        join(invalid)
    )
end

local function validatePlateValues(tableName)
    local predicate = [[
        `plate` IS NULL
        OR TRIM(`plate`) = ''
        OR CHAR_LENGTH(TRIM(`plate`)) > 8
        OR UPPER(TRIM(`plate`)) NOT REGEXP '^[A-Z0-9 ]+$'
    ]]
    local counted, countRows = query(([[
        SELECT COUNT(*) AS `invalid_count`
        FROM `%s`
        WHERE %s
    ]]):format(tableName, predicate))
    local invalidCount = counted and countRows and countRows[1]
        and tonumber(countRows[1].invalid_count)
        or nil

    if not counted or not invalidCount or invalidCount < 0 or invalidCount % 1 ~= 0 then
        return false, ('could not validate plate values in `%s`: %s'):format(
            tableName,
            counted and tostring(invalidCount) or tostring(countRows)
        )
    end

    if invalidCount == 0 then return true end

    local selected, examples = query(([[
        SELECT `plate`
        FROM `%s`
        WHERE %s
        LIMIT 10
    ]]):format(tableName, predicate))
    local labels = {}
    if selected then
        for _, row in ipairs(examples or {}) do
            labels[#labels + 1] = row.plate == nil and '<NULL>' or ('%q'):format(tostring(row.plate))
        end
    end

    return false, ('`%s` contains %d invalid plate value(s)%s. Plates must trim to 1-8 characters using only A-Z, 0-9, and spaces; repair them manually after a backup.'):format(
        tableName,
        invalidCount,
        #labels > 0 and (': ' .. join(labels)) or ''
    )
end

---@param autoMigrate boolean
---@return boolean successful
---@return string? errorMessage
local function ensureUsableQbRuntimeValues(autoMigrate)
    local checked, invalidRows = query([[
        SELECT COUNT(*) AS `invalid_count`
        FROM `player_vehicles`
        WHERE (`stored` IS NOT NULL AND `stored` NOT IN (0, 1))
           OR (`state` IS NOT NULL AND `state` NOT IN (0, 1, 2))
    ]])
    local invalidCount = checked and invalidRows and invalidRows[1]
        and tonumber(invalidRows[1].invalid_count)
        or nil

    if not checked then
        return false, ('could not validate storage-state values: %s'):format(tostring(invalidRows))
    end

    if not invalidCount or invalidCount < 0 or invalidCount % 1 ~= 0 then
        return false, 'could not validate storage-state values because the database returned an invalid count'
    end

    if invalidCount > 0 then
        return false, ('`player_vehicles` contains %d row(s) with unsupported `stored`/`state` values. Use stored 0/1 and state 0/1/2 before starting DRS Garages.'):format(invalidCount)
    end

    local counted, repairableRows = query([[
        SELECT COUNT(*) AS `repairable_count`
        FROM `player_vehicles`
        WHERE `type` IS NULL OR TRIM(`type`) = '' OR `stored` IS NULL OR `state` IS NULL
    ]])
    local repairableCount = counted and repairableRows and repairableRows[1]
        and tonumber(repairableRows[1].repairable_count)
        or nil

    if not counted then
        return false, ('could not inspect null runtime values: %s'):format(tostring(repairableRows))
    end

    if not repairableCount or repairableCount < 0 or repairableCount % 1 ~= 0 then
        return false, 'could not inspect null runtime values because the database returned an invalid count'
    end

    if repairableCount > 0 then
        if not autoMigrate then
            return false, ('automatic migration is disabled and `player_vehicles` contains %d row(s) with an empty type or NULL storage state'):format(
                repairableCount
            )
        end

        local normalizedType, typeError = update([[
            UPDATE `player_vehicles`
            SET `type` = 'car'
            WHERE `type` IS NULL OR TRIM(`type`) = ''
        ]])
        if not normalizedType then
            return false, ('could not normalize empty vehicle types: %s'):format(tostring(typeError))
        end

        -- Resolve `state` first. If both values are NULL, fail safe to an out
        -- state instead of silently returning an unknown vehicle to storage.
        local normalizedState, stateError = update([[
            UPDATE `player_vehicles`
            SET `state` = CASE WHEN `stored` = 1 THEN 1 ELSE 0 END
            WHERE `state` IS NULL
        ]])
        if not normalizedState then
            return false, ('could not normalize NULL vehicle states: %s'):format(tostring(stateError))
        end

        local normalizedStored, storedError = update([[
            UPDATE `player_vehicles`
            SET `stored` = CASE WHEN `state` = 1 THEN 1 ELSE 0 END
            WHERE `stored` IS NULL
        ]])
        if not normalizedStored then
            return false, ('could not normalize NULL stored values: %s'):format(tostring(storedError))
        end

        local verified, remainingRows = query([[
            SELECT COUNT(*) AS `remaining_count`
            FROM `player_vehicles`
            WHERE `type` IS NULL OR TRIM(`type`) = '' OR `stored` IS NULL OR `state` IS NULL
        ]])
        local remainingCount = verified and remainingRows and remainingRows[1]
            and tonumber(remainingRows[1].remaining_count)
            or nil

        if not verified or remainingCount ~= 0 then
            return false, ('could not verify normalized runtime values (remaining=%s, error=%s)'):format(
                tostring(remainingCount),
                verified and 'none' or tostring(remainingRows)
            )
        end

        log(('Normalized %d player_vehicles row(s) with empty type or NULL storage state.'):format(repairableCount))
    end

    local pairsChecked, inconsistentRows = query([[
        SELECT COUNT(*) AS `inconsistent_count`
        FROM `player_vehicles`
        WHERE NOT ((`stored` = 1 AND `state` = 1)
                OR (`stored` = 0 AND `state` IN (0, 2)))
    ]])
    local inconsistentCount = pairsChecked and inconsistentRows and inconsistentRows[1]
        and tonumber(inconsistentRows[1].inconsistent_count)
        or nil

    if not pairsChecked or not inconsistentCount or inconsistentCount < 0 or inconsistentCount % 1 ~= 0 then
        return false, ('could not validate paired storage state: %s'):format(
            pairsChecked and tostring(inconsistentCount) or tostring(inconsistentRows)
        )
    end

    if inconsistentCount > 0 then
        if not autoMigrate then
            return false, ('automatic migration is disabled and `player_vehicles` contains %d inconsistent stored/state pair(s); valid pairs are (1,1), (0,0), and (0,2)'):format(
                inconsistentCount
            )
        end

        local synchronized, synchronizeError = update([[
            UPDATE `player_vehicles`
            SET `stored` = CASE WHEN `state` = 1 THEN 1 ELSE 0 END
            WHERE NOT ((`stored` = 1 AND `state` = 1)
                    OR (`stored` = 0 AND `state` IN (0, 2)))
        ]])
        if not synchronized then
            return false, ('could not synchronize inconsistent stored/state pairs: %s'):format(tostring(synchronizeError))
        end

        local verified, remainingRows = query([[
            SELECT COUNT(*) AS `remaining_count`
            FROM `player_vehicles`
            WHERE NOT ((`stored` = 1 AND `state` = 1)
                    OR (`stored` = 0 AND `state` IN (0, 2)))
        ]])
        local remainingCount = verified and remainingRows and remainingRows[1]
            and tonumber(remainingRows[1].remaining_count)
            or nil

        if not verified or remainingCount ~= 0 then
            return false, ('could not verify synchronized stored/state pairs (remaining=%s, error=%s)'):format(
                tostring(remainingCount),
                verified and 'none' or tostring(remainingRows)
            )
        end

        log(('Synchronized %d inconsistent player_vehicles stored/state pair(s) using state as authoritative.'):format(inconsistentCount))
    end

    return true
end

---@param schemaName string
---@param tableName? string
---@return table<string, table>? indexes
---@return string? errorMessage
local function getIndexes(schemaName, tableName)
    tableName = tableName or TABLE_NAME

    local successful, rows = query([[
        SELECT
            INDEX_NAME AS `index_name`,
            NON_UNIQUE AS `non_unique`,
            SEQ_IN_INDEX AS `sequence`,
            COLUMN_NAME AS `column_name`,
            SUB_PART AS `sub_part`
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
    ]], { schemaName, tableName })

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
                    columns = {},
                    subParts = {}
                }
                indexes[indexName] = index
            end

            local sequence = tonumber(row.sequence)
            if sequence and type(row.column_name) == 'string' then
                index.columns[sequence] = row.column_name:lower()
                index.subParts[sequence] = tonumber(row.sub_part)
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
        if actual.columns[index] ~= columnName or actual.subParts[index] ~= nil then
            return false
        end
    end

    return true
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

-- Some official QB/Qbox metadata classifies these by service category rather
-- than their native vehicle class. These values are authoritative for the
-- one-time garage-type backfill.
local GARAGE_TYPE_EXCEPTIONS = {
    polmav = 'air',
    thruster = 'air',
    predator = 'boat',
    seashark2 = 'boat'
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
local function addModelLookup(nameLookup, hashLookup, value, garageType, authoritative)
    local hash = normalizedHash(value)
    if hash then
        if authoritative then hashLookup[hash] = garageType else addLookupValue(hashLookup, hash, garageType) end
        return
    end

    local name = normalizedText(value)
    if not name then return end

    if authoritative then nameLookup[name] = garageType else addLookupValue(nameLookup, name, garageType) end

    local hashFunction = type(joaat) == 'function' and joaat
        or type(GetHashKey) == 'function' and GetHashKey
        or nil
    if hashFunction then
        local successful, modelHash = pcall(hashFunction, name)
        if successful then
            local normalizedModelHash = normalizedHash(modelHash)
            if authoritative then
                if normalizedModelHash then hashLookup[normalizedModelHash] = garageType end
            else
                addLookupValue(hashLookup, normalizedModelHash, garageType)
            end
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

    for modelName, garageType in pairs(GARAGE_TYPE_EXCEPTIONS) do
        addModelLookup(nameLookup, hashLookup, modelName, garageType, true)
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

---@param columns table<string, boolean>
---@param required string[]
---@return string[] missing
local function findMissingColumns(columns, required)
    local missing = {}

    for _, columnName in ipairs(required) do
        if not columns[columnName] then
            missing[#missing + 1] = columnName
        end
    end

    return missing
end

---@param schemaName string
---@return boolean valid
---@return string detail
local function validateCompatibilityIndexes(schemaName)
    local indexes, indexError = getIndexes(schemaName)
    if not indexes then return false, indexError end

    local missing = {}
    local invalid = {}

    for _, expected in ipairs(COMPATIBILITY_INDEXES) do
        local existing = indexes[expected.name]

        if not existing then
            missing[#missing + 1] = expected.name
        elseif not indexMatches(existing, expected.columns) then
            invalid[#invalid + 1] = expected.name
        end
    end

    if #missing > 0 then
        return false, ('missing required compatibility index(es): %s'):format(join(missing))
    end

    if #invalid > 0 then
        return false, ('named index(es) have unexpected definitions: %s'):format(join(invalid))
    end

    return true, 'compatibility indexes are ready'
end

---@param indexes table<string, table>
---@return string? indexName
local function findUniquePlateIndex(indexes)
    for indexName, index in pairs(indexes) do
        if index.nonUnique == false
            and #index.columns == 1
            and index.columns[1] == 'plate'
            and index.subParts[1] == nil
        then
            return indexName
        end
    end
end

---@param tableName string
---@return table[]? duplicates
---@return string? errorMessage
local function getDuplicateNormalizedPlates(tableName)
    local successful, rows = query(([=[
        SELECT
            UPPER(TRIM(`plate`)) AS `normalized_plate`,
            COUNT(*) AS `duplicate_count`
        FROM `%s`
        WHERE `plate` IS NOT NULL
        GROUP BY UPPER(TRIM(`plate`))
        HAVING COUNT(*) > 1
        ORDER BY `duplicate_count` DESC, `normalized_plate` ASC
        LIMIT 10
    ]=]):format(tableName))

    if not successful then
        return nil, ('could not check normalized plate uniqueness in `%s`: %s'):format(tableName, rows)
    end

    return rows or {}
end


---@param schemaName string
---@param tableName string
---@param allowCreate boolean
---@return boolean valid
---@return string detail
local function ensureUniquePlateIndex(schemaName, tableName, allowCreate)
    local indexes, indexError = getIndexes(schemaName, tableName)
    if not indexes then return false, indexError end

    local duplicates, duplicateError = getDuplicateNormalizedPlates(tableName)
    if not duplicates then return false, duplicateError end

    if #duplicates > 0 then
        local examples = {}

        for _, duplicate in ipairs(duplicates) do
            local plate = duplicate.normalized_plate
            if plate == nil or plate == '' then plate = '<blank>' end

            examples[#examples + 1] = ('%s (%s rows)'):format(
                tostring(plate),
                tostring(duplicate.duplicate_count or '?')
            )
        end

        return false, ('`%s` contains duplicate normalized plates: %s. Back up the database and resolve each duplicate manually; DRS Garages will never delete or merge owned vehicles automatically.'):format(
            tableName,
            join(examples)
        )
    end

    -- DRS keys active vehicles by an upper-cased, trimmed plate. Check that
    -- normalized invariant even when the database already has a UNIQUE index;
    -- a case-sensitive/binary collation can otherwise permit colliding keys.
    local existingName = findUniquePlateIndex(indexes)
    if existingName then
        return true, ('unique full-column plate index `%s` is ready'):format(existingName)
    end

    local expectedName = UNIQUE_PLATE_INDEX_NAMES[tableName] or ('ux_%s_plate'):format(tableName)
    if not allowCreate then
        return false, ('`%s` has no unique full-column plate index. No duplicates were found, but automatic migration is disabled; create a UNIQUE index on the complete `plate` column manually.'):format(
            tableName
        )
    end

    if indexes[expectedName] then
        return false, ('index `%s` already exists but is not a unique full-column plate index. Correct it manually; automatic migration will not drop or replace indexes.'):format(
            expectedName
        )
    end

    local createSql = ('CREATE UNIQUE INDEX `%s` ON `%s` (`plate`)'):format(expectedName, tableName)
    local created, createError = query(createSql)
    local refreshedIndexes, refreshError = getIndexes(schemaName, tableName)
    local refreshedName = refreshedIndexes and findUniquePlateIndex(refreshedIndexes) or nil

    if refreshedName then
        if created then
            log(('Added unique plate index `%s` to `%s`.'):format(refreshedName, tableName))
        else
            log(('A unique plate index `%s` was added concurrently; continuing.'):format(refreshedName))
        end

        return true, ('unique full-column plate index `%s` is ready'):format(refreshedName)
    end

    if not refreshedIndexes then
        return false, ('could not verify the unique plate index after creation: %s'):format(tostring(refreshError))
    end

    return false, ('could not add unique plate index `%s`: %s. Grant the database user INDEX permission or create a UNIQUE full-column plate index manually.'):format(
        expectedName,
        tostring(createError)
    )
end

---@param schemaName string
---@param autoMigrate boolean
---@return boolean valid
---@return string detail
local function validateEsxSchema(schemaName, autoMigrate)
    local exists, tableError = tableExists(schemaName, ESX_TABLE_NAME)
    if exists == nil then return false, tableError end

    if not exists then
        return false, ("`%s`.`%s` is missing. Import the ESX owned-vehicle schema before starting DRS Garages."):format(
            schemaName,
            ESX_TABLE_NAME
        )
    end

    local columns, columnError = getColumns(schemaName, ESX_TABLE_NAME)
    if not columns then return false, columnError end

    local missing = findMissingColumns(columns, ESX_REQUIRED_COLUMNS)
    if #missing > 0 then
        return false, ("`%s` is missing required runtime column(s): %s. DRS Garages does not add missing ESX columns automatically."):format(
            ESX_TABLE_NAME,
            join(missing)
        )
    end

    local definitionsValid, invalidDefinitions = validateColumnDefinitions(columns, ESX_COLUMN_REQUIREMENTS)
    if not definitionsValid then
        return false, invalidColumnDefinitionsMessage(ESX_TABLE_NAME, invalidDefinitions)
    end

    local platesValid, plateError = validatePlateValues(ESX_TABLE_NAME)
    if not platesValid then return false, plateError end

    local uniquePlateReady, uniquePlateDetail = ensureUniquePlateIndex(schemaName, ESX_TABLE_NAME, autoMigrate)
    if not uniquePlateReady then return false, uniquePlateDetail end

    return true, ('ESX owned_vehicles schema is ready; %s'):format(uniquePlateDetail)
end

---@return boolean successful
---@return string detail
local function migrate()
    local databaseConfig = type(Config) == 'table' and Config.Database or nil
    local autoMigrate = not (type(databaseConfig) == 'table' and databaseConfig.AutoMigrate == false)

    if not autoMigrate then
        log('Automatic migration is disabled; validating the existing schema without changing it.')
    end

    local frameworkName = type(Framework) == 'table' and Framework.name or nil

    local startedCoreResources = {}
    local startedCoreIdentities = {}
    for _, resource in ipairs(SUPPORTED_CORE_RESOURCES) do
        local identity = getStartedResourceIdentity(resource)

        if identity and not startedCoreIdentities[identity] then
            startedCoreIdentities[identity] = true
            startedCoreResources[#startedCoreResources + 1] = resource
        end
    end

    if #startedCoreResources == 0 then
        return false, 'no supported framework core is started (qbx_core, qb-core, or es_extended); database setup refuses to choose an adapter implicitly.'
    end

    if #startedCoreResources > 1 then
        return false, ('multiple supported framework cores are started (%s). Stop the extra core resource(s); database setup refuses to choose an adapter implicitly.'):format(
            join(startedCoreResources)
        )
    end

    local startedFrameworkName = startedCoreResources[1]
    if frameworkName ~= startedFrameworkName then
        return false, ('the loaded framework adapter (%s) does not match the single started core (%s); database setup is blocked until resource startup is consistent.'):format(
            tostring(frameworkName),
            startedFrameworkName
        )
    end

    if frameworkName ~= 'es_extended' and frameworkName ~= 'qb-core' and frameworkName ~= 'qbx_core' then
        return false, ('cannot migrate before a supported framework is detected (got %s)'):format(tostring(frameworkName))
    end

    if frameworkName == 'qbx_core' then
        local persistenceEnabled = tostring(GetConvar('qbx:enableVehiclePersistence', 'false')):lower()
        local persistenceType = tostring(GetConvar('qbx:vehiclePersistenceType', 'semi')):lower()
        local enabled = persistenceEnabled == 'true' or persistenceEnabled == '1' or persistenceEnabled == 'yes'

        if enabled and persistenceType == 'full' then
            return false, 'Qbox full vehicle persistence conflicts with DRS restart/storage ownership. Set qbx:enableVehiclePersistence false or use qbx:vehiclePersistenceType semi, then restart qbx_core, qbx_vehicles, and drs_garages.'
        end
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

    if frameworkName == 'es_extended' then
        log('ESX detected; validating owned_vehicles without applying QB/Qbox migrations.')
        return validateEsxSchema(schemaName, autoMigrate)
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

    local baseDefinitionsValid, invalidBaseDefinitions = validateColumnDefinitions(columns, QB_BASE_COLUMN_REQUIREMENTS)
    if not baseDefinitionsValid then
        return false, invalidColumnDefinitionsMessage(TABLE_NAME, invalidBaseDefinitions)
    end

    if not hasUsableModelColumn(columns) then
        return false, ("`%s` needs at least one usable vehicle model column (`vehicle` or `hash`). Restore the framework's standard schema manually; automatic migration will not invent model data."):format(TABLE_NAME)
    end

    local presentDefinitionsValid, invalidPresentDefinitions = validatePresentColumnDefinitions(columns, QB_COLUMN_REQUIREMENTS)
    if not presentDefinitionsValid then
        return false, invalidColumnDefinitionsMessage(TABLE_NAME, invalidPresentDefinitions)
    end

    local platesValid, plateError = validatePlateValues(TABLE_NAME)
    if not platesValid then return false, plateError end

    if not columns.stored and not columns.state then
        return false, ("`%s` is missing both `stored` and `state`. No authoritative vehicle-location state exists, so DRS Garages will not guess or mark every existing vehicle stored. Add one authoritative column and reconcile its values manually before restarting."):format(
            TABLE_NAME
        )
    end

    if not autoMigrate then
        local compatibilityColumnNames = {}

        for _, column in ipairs(COMPATIBILITY_COLUMNS) do
            compatibilityColumnNames[#compatibilityColumnNames + 1] = column.name
        end

        local missingCompatibilityColumns = findMissingColumns(columns, compatibilityColumnNames)
        if #missingCompatibilityColumns > 0 then
            return false, ('automatic migration is disabled and `%s` is missing compatibility column(s): %s'):format(
                TABLE_NAME,
                join(missingCompatibilityColumns)
            )
        end

        local definitionsValid, invalidDefinitions = validateColumnDefinitions(columns, QB_COLUMN_REQUIREMENTS)
        if not definitionsValid then
            return false, invalidColumnDefinitionsMessage(TABLE_NAME, invalidDefinitions)
        end

        local valuesUsable, valuesError = ensureUsableQbRuntimeValues(false)
        if not valuesUsable then return false, valuesError end

        local indexesValid, indexDetail = validateCompatibilityIndexes(schemaName)
        if not indexesValid then
            return false, ('automatic migration is disabled and the existing schema is incomplete: %s'):format(indexDetail)
        end

        local uniquePlateReady, uniquePlateDetail = ensureUniquePlateIndex(schemaName, TABLE_NAME, false)
        if not uniquePlateReady then
            return false, ('automatic migration is disabled and the plate invariant is not ready: %s'):format(uniquePlateDetail)
        end

        return true, ('database schema is ready (automatic migration disabled; read-only validation passed; %s)'):format(
            uniquePlateDetail
        )
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

    local refreshedColumns, refreshColumnError = getColumns(schemaName)
    if not refreshedColumns then
        return false, ('could not verify compatibility columns after migration: %s'):format(tostring(refreshColumnError))
    end
    columns = refreshedColumns

    local definitionsValid, invalidDefinitions = validateColumnDefinitions(columns, QB_COLUMN_REQUIREMENTS)
    if not definitionsValid then
        return false, invalidColumnDefinitionsMessage(TABLE_NAME, invalidDefinitions)
    end

    local valuesUsable, valuesError = ensureUsableQbRuntimeValues(true)
    if not valuesUsable then return false, valuesError end

    local uniquePlateReady, uniquePlateDetail = ensureUniquePlateIndex(schemaName, TABLE_NAME, true)
    if not uniquePlateReady then return false, uniquePlateDetail end

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
