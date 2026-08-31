-- Secure job-fleet ownership and administration.
--
-- This module deliberately keeps framework-owned vehicle data in the framework
-- table. DRS stores only fleet policy metadata and a durable audit journal. All
-- mutating entry points re-resolve the player, job, boss/ACE authorization,
-- garage, vehicle row, storage state, model and plate on the server.

local RESOURCE_NAME <const> = GetCurrentResourceName()
local FLEET_TABLE <const> = 'drs_job_fleet_vehicles'
local OPERATIONS_TABLE <const> = 'drs_job_fleet_operations'
local SERVER_DISTANCE_TOLERANCE <const> = 2.0
local DEFAULT_MAX_REASON_LENGTH <const> = 500
local DEFAULT_MAX_GRADE <const> = 100

local sourceLocks = {}
local metadataByRow = {}
local metadataByPlate = {}
local operationPlates = {}
local quarantinedPlates = {}
local quarantineTokens = {}
local synchronizeExternalQuarantine
local refreshPlateQuarantine
local safeRequestId
local reconcilePendingOperation
local purchaseSessions = {}
local serviceReady = false
local serviceDetail = 'job-fleet database setup is still running'

local CREATE_FLEET_TABLE = [[
    CREATE TABLE IF NOT EXISTS `drs_job_fleet_vehicles` (
        `vehicle_row_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `job` VARCHAR(50) NOT NULL,
        `model` VARCHAR(64) NOT NULL,
        `vehicle_type` VARCHAR(20) NOT NULL,
        `garage` VARCHAR(50) NOT NULL,
        `min_grade` INT UNSIGNED NOT NULL DEFAULT 0,
        `status` VARCHAR(16) NOT NULL DEFAULT 'active',
        `added_by_identifier` VARCHAR(80) NOT NULL,
        `added_by_name` VARCHAR(100) NOT NULL,
        `added_at` BIGINT UNSIGNED NOT NULL,
        `updated_at` BIGINT UNSIGNED NOT NULL,
        `retired_at` BIGINT UNSIGNED NULL,
        `retire_reason` VARCHAR(500) NULL,
        PRIMARY KEY (`vehicle_row_id`),
        UNIQUE KEY `ux_drs_job_fleet_plate` (`plate`),
        KEY `idx_drs_job_fleet_job_status` (`job`, `status`),
        KEY `idx_drs_job_fleet_job_garage` (`job`, `garage`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
]]

local CREATE_OPERATIONS_TABLE = [[
    CREATE TABLE IF NOT EXISTS `drs_job_fleet_operations` (
        `operation_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `external_request_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
        `action` VARCHAR(32) NOT NULL,
        `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
        `vehicle_row_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
        `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        `job` VARCHAR(50) NOT NULL,
        `model` VARCHAR(64) NULL,
        `garage_from` VARCHAR(50) NULL,
        `garage_to` VARCHAR(50) NULL,
        `min_grade` INT UNSIGNED NULL,
        `actor_source` INT UNSIGNED NOT NULL DEFAULT 0,
        `actor_identifier` VARCHAR(80) NOT NULL,
        `actor_name` VARCHAR(100) NOT NULL,
        `actor_job` VARCHAR(50) NULL,
        `actor_grade` INT NOT NULL DEFAULT 0,
        `source_resource` VARCHAR(64) NOT NULL DEFAULT 'drs_garages',
        `reason` VARCHAR(500) NULL,
        `vehicle_snapshot` LONGTEXT NULL,
        `request_json` LONGTEXT NULL,
        `error_code` VARCHAR(100) NULL,
        `error_detail` VARCHAR(500) NULL,
        `created_at` BIGINT UNSIGNED NOT NULL,
        `updated_at` BIGINT UNSIGNED NOT NULL,
        `completed_at` BIGINT UNSIGNED NULL,
        PRIMARY KEY (`operation_id`),
        UNIQUE KEY `ux_drs_job_fleet_external_request` (`source_resource`, `external_request_id`),
        KEY `idx_drs_job_fleet_operations_plate` (`plate`, `created_at`),
        KEY `idx_drs_job_fleet_operations_job` (`job`, `created_at`),
        KEY `idx_drs_job_fleet_operations_status` (`status`, `created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
]]

local function settings()
    return type(Config.JobFleet) == 'table' and Config.JobFleet or {}
end

local function enabled()
    return settings().Enabled ~= false
end

local function nowMilliseconds()
    return os.time() * 1000
end

local function cleanText(value, maximumLength, allowEmpty)
    if type(value) ~= 'string' and type(value) ~= 'number' then return end

    local text = tostring(value):gsub('[%z\1-\31\127]', ''):match('^%s*(.-)%s*$')
    if not allowEmpty and text == '' then return end
    if maximumLength and #text > maximumLength then text = text:sub(1, maximumLength) end
    return text
end

local function normalizePlate(value)
    local plate = cleanText(value, 8)
    if not plate then return end

    plate = plate:upper()
    if not plate:match('^[A-Z0-9 ]+$') then return end
    return plate
end

local function normalizeJob(value)
    local job = cleanText(value, 50)
    if not job then return end

    job = job:lower()
    if job == 'unemployed' or not job:match('^[%w_.%-]+$') then return end
    return job
end

local function normalizeModel(value)
    local model = cleanText(value, 64)
    if not model then return end

    model = model:lower()
    if model:match('^%d+$') or not model:match('^[%w_%-]+$') then return end
    return model
end

local function normalizeVehicleType(value)
    local vehicleType = cleanText(value or 'car', 20)
    if not vehicleType then return 'car' end

    vehicleType = vehicleType:lower()
    if vehicleType == 'automobile' or vehicleType == 'bike' or vehicleType == 'bicycle'
        or vehicleType == 'quadbike' or vehicleType == 'trailer' or vehicleType == 'train'
    then
        return 'car'
    elseif vehicleType == 'plane' or vehicleType == 'heli' or vehicleType == 'helicopter' then
        return 'air'
    elseif vehicleType == 'jetski' or vehicleType == 'submarine' or vehicleType == 'submersible' then
        return 'boat'
    end

    return vehicleType
end

local function integerFlag(value)
    if value == true then return 1 end
    if value == false then return 0 end
    return tonumber(value)
end

local function boundedGrade(value)
    local grade = tonumber(value)
    local maximum = math.max(0, math.floor(tonumber(settings().MaximumVehicleGrade) or DEFAULT_MAX_GRADE))

    if not grade or grade ~= grade or grade == math.huge or grade == -math.huge or grade % 1 ~= 0 then return end
    grade = math.floor(grade)
    if grade < 0 or grade > maximum then return end
    return grade
end

local function reasonText(value, required)
    local maximum = math.max(16, math.min(DEFAULT_MAX_REASON_LENGTH,
        math.floor(tonumber(settings().MaximumReasonLength) or DEFAULT_MAX_REASON_LENGTH)))
    local reason = cleanText(value, maximum)

    if required and (not reason or #reason < 3) then return end
    return reason
end

local function success(message, extra)
    local response = extra or {}
    response.ok = true
    response.message = message
    return response
end

local function failure(code, message, extra)
    local response = extra or {}
    response.ok = false
    response.code = code
    response.message = message
    return response
end

local function vehicleTable()
    return Framework and Framework.name == 'es_extended' and 'owned_vehicles' or 'player_vehicles'
end

local function ownerColumn()
    return Framework and Framework.name == 'es_extended' and 'owner' or 'citizenid'
end

local function databaseUsable(source)
    if not serviceReady then return false end

    local checker = rawget(_G, 'CanUseDrsGarageDatabase')
    if type(checker) ~= 'function' then return false end

    local ok, usable = pcall(checker, source)
    return ok and usable == true
end

local function safeEncode(value)
    local ok, encoded = pcall(json.encode, value)
    return ok and encoded or nil
end

local function stableHash(value)
    local hash = 2166136261
    for index = 1, #value do hash = ((hash ~ value:byte(index)) * 16777619) & 0xffffffff end
    return ('%08x'):format(hash)
end

local function safeStorageName(value)
    local name = cleanText(value, 50)
    if name and name:match('^[%w_%-]+$') then return name end
end

local function generatedStorageName(garage)
    local coords = garage and (garage.SpawnPosition or garage.Position or garage.PedPosition)
    if not coords then return end

    local signature = ('%s|%.6f|%.6f|%.6f|%.6f'):format(
        normalizeVehicleType(garage.Type),
        tonumber(coords.x) or 0.0,
        tonumber(coords.y) or 0.0,
        tonumber(coords.z) or 0.0,
        tonumber(coords.w or coords.heading) or 0.0
    )

    return ('drs_%s_%s%s'):format(
        normalizeVehicleType(garage.Type),
        stableHash(signature),
        stableHash(signature:reverse())
    ):sub(1, 50)
end

local function storageName(garage)
    return safeStorageName(garage and (garage.Garage or garage.Id or garage.ID or garage.StorageId or garage.Name or garage.Label))
        or generatedStorageName(garage)
end

local function garageJobs(garage)
    local result, seen = {}, {}
    local configured = garage and garage.Jobs

    local function add(value)
        local job = normalizeJob(value)
        if job and not seen[job] then
            seen[job] = true
            result[#result + 1] = job
        end
    end

    if type(configured) == 'string' then
        add(configured)
    elseif type(configured) == 'table' then
        for _, value in pairs(configured) do add(value) end
    end

    table.sort(result)
    return result, seen
end

local function resolveGarage(index)
    index = tonumber(index)
    if not index or index % 1 ~= 0 then return end

    index = math.floor(index)
    local garage = Config.Garages and Config.Garages[index]
    if type(garage) ~= 'table' or garage.Property then return end

    local name = storageName(garage)
    local jobs, jobSet = garageJobs(garage)
    if not name or #jobs == 0 then return end

    return {
        index = index,
        data = garage,
        garage = name,
        type = normalizeVehicleType(garage.Type),
        jobs = jobs,
        jobSet = jobSet,
        label = cleanText(garage.Label or garage.Name or name, 80) or name
    }
end

local function nearGarage(source, resolved)
    local settingsValue = settings()
    if settingsValue.RequireGarageProximity == false then return true end
    if IsPlayerAceAllowed(source, cleanText(settingsValue.AcePermission, 100) or 'drs_garages.fleet.admin')
        and settingsValue.AdminBypassesProximity == true
    then
        return true
    end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end

    local pedCoords = GetEntityCoords(ped)
    local maximum = math.max(1.0, tonumber(settingsValue.Distance) or tonumber(Config.MaxDistance) or 10.0)
        + SERVER_DISTANCE_TOLERANCE
    local garage = resolved.data

    local function isNear(coords)
        return coords and #(pedCoords - vector3(coords.x, coords.y, coords.z)) <= maximum
    end
    if isNear(garage.Position) or isNear(garage.PedPosition) or isNear(garage.SpawnPosition) then return true end

    return false
end

local function safePlayerMethod(player, method, ...)
    if not player or type(player[method]) ~= 'function' then return false end
    return pcall(player[method], player, ...)
end

local function playerIdentity(player)
    local ok, identifier = safePlayerMethod(player, 'getIdentifier')
    identifier = ok and cleanText(identifier, 80) or nil
    return identifier
end

local function playerJobData(player)
    local ok, data = safePlayerMethod(player, 'getJobData')
    if not ok or type(data) ~= 'table' then
        local jobOk, job = safePlayerMethod(player, 'getJob')
        data = { name = jobOk and job or nil, grade = 0, onDuty = false }
    end

    return {
        name = normalizeJob(data.name),
        type = cleanText(data.type, 50),
        grade = math.max(0, math.floor(tonumber(data.grade) or 0)),
        onDuty = data.onDuty == true
    }
end

local function actorName(source, player)
    local firstOk, first = safePlayerMethod(player, 'getFirstName')
    local lastOk, last = safePlayerMethod(player, 'getLastName')
    local name = ('%s %s'):format(firstOk and tostring(first or '') or '', lastOk and tostring(last or '') or '')
        :match('^%s*(.-)%s*$')
    return cleanText(name ~= '' and name or GetPlayerName(source) or 'Unknown', 100) or 'Unknown'
end

local function resolveActor(source, garageIndex, requestedJob, actionMode)
    source = tonumber(source)
    if not source or source < 1 or not GetPlayerName(source) then
        return nil, failure('player_not_found', 'Player data is unavailable.')
    end

    if not enabled() then return nil, failure('fleet_disabled', 'Job fleet management is disabled.') end
    if not databaseUsable(source) then return nil, failure('database_unavailable', 'The garage database is not ready.') end

    local resolvedGarage = resolveGarage(garageIndex)
    if not resolvedGarage then return nil, failure('invalid_garage', 'Select a configured job garage.') end
    local requireProximity = actionMode == nil or actionMode == 'society_purchase_ui'
        or settings().ExternalIssuanceRequiresGarageProximity == true
    if requireProximity and not nearGarage(source, resolvedGarage) then
        return nil, failure('too_far', 'You must be at the selected job garage.')
    end

    local player = Framework and Framework.getPlayerFromId(source)
    local identifier = playerIdentity(player)
    if not player or not identifier then return nil, failure('player_not_found', 'Player data is unavailable.') end

    local config = settings()
    local ace = cleanText(config.AcePermission, 100) or 'drs_garages.fleet.admin'
    local admin = IsPlayerAceAllowed(source, ace) == true
    local jobData = playerJobData(player)
    local targetJob = normalizeJob(requestedJob)

    if actionMode == 'admin_grant' and not admin then
        return nil, failure('not_authorized', 'This action requires the fleet administrator ACE permission.')
    end

    local bossOnly = actionMode == 'society_purchase' or actionMode == 'society_purchase_ui'
    local manageAsAdmin = admin and not bossOnly

    if manageAsAdmin then
        if not targetJob and jobData.name and resolvedGarage.jobSet[jobData.name] then targetJob = jobData.name end
        if not targetJob then
            return nil, failure('job_required', 'Choose the job whose fleet you want to manage.', {
                needsJob = true,
                jobs = resolvedGarage.jobs
            })
        end
    else
        targetJob = jobData.name
        local bossOk, isBoss = safePlayerMethod(player, 'isJobBoss')
        local bossMinimum = math.max(0, math.floor(tonumber(config.BossMinimumGrade) or 0))

        if not targetJob or not bossOk or isBoss ~= true or jobData.grade < bossMinimum then
            return nil, failure('not_authorized', 'Only an authorized job boss can manage this fleet.')
        end
        if config.RequireBossDuty == true and jobData.onDuty ~= true then
            return nil, failure('off_duty', 'You must be on duty to manage the job fleet.')
        end
        if requestedJob and normalizeJob(requestedJob) ~= targetJob then
            return nil, failure('job_changed', 'Your current job no longer matches this fleet.')
        end
    end

    if not targetJob or not resolvedGarage.jobSet[targetJob] then
        return nil, failure('garage_job_mismatch', 'That job is not authorized to use this garage.')
    end

    return {
        source = source,
        player = player,
        identifier = identifier,
        name = actorName(source, player),
        admin = admin,
        job = targetJob,
        jobData = jobData,
        garage = resolvedGarage
    }
end

local function resolveDestination(index, job, expectedType)
    local destination = resolveGarage(index)
    if not destination or not destination.jobSet[job] then return end
    if expectedType and destination.type ~= normalizeVehicleType(expectedType) then return end
    return destination
end

local function revalidateActor(actor, actionMode)
    local refreshed, refreshError = resolveActor(actor.source, actor.garage.index, actor.job, actionMode)
    if not refreshed or refreshed.identifier ~= actor.identifier or refreshed.job ~= actor.job then
        return nil, refreshError or failure('authorization_changed', 'Fleet authorization changed during the operation.')
    end
    return refreshed
end

local function rowKey(vehicle)
    if vehicle and vehicle.id ~= nil then return cleanText(vehicle.id, 48) end
    local plate = vehicle and normalizePlate(vehicle.plate)
    return plate and ('plate:%s'):format(plate) or nil
end

local function rowModel(vehicle)
    local direct = vehicle and normalizeModel(vehicle.vehicle or vehicle.model)
    if direct then return direct end

    local encoded = vehicle and (vehicle.mods or vehicle.vehicle)
    if type(encoded) == 'string' and encoded:sub(1, 1) == '{' then
        local ok, props = pcall(json.decode, encoded)
        if ok and type(props) == 'table' and props.model then
            local catalog = Framework and Framework.name == 'qbx_core'
                and select(2, pcall(function() return exports.qbx_core:GetVehiclesByName() end))
                or nil
            if type(catalog) == 'table' then
                local wanted = math.floor(tonumber(props.model) or -1) & 0xffffffff
                for name in pairs(catalog) do
                    if (joaat(name) & 0xffffffff) == wanted then return normalizeModel(name) end
                end
            end
        end
    end
end

local function rowType(vehicle)
    local direct = vehicle and cleanText(vehicle.type, 20)
    if direct then return normalizeVehicleType(direct) end
    return 'car'
end

local function exactVehicleByPlate(plate)
    local ok, rows = pcall(MySQL.query.await, ('SELECT * FROM `%s` WHERE BINARY UPPER(TRIM(`plate`)) = BINARY ? LIMIT 2')
        :format(vehicleTable()), { plate })
    if not ok or type(rows) ~= 'table' then return nil, 'database' end
    if #rows > 1 then return nil, 'duplicate' end
    return rows[1], rows[1] and nil or 'missing'
end

local function exactVehicleIsAbsent(plate)
    local vehicle, lookupError = exactVehicleByPlate(plate)
    return vehicle == nil and lookupError == 'missing'
end

local function exactPersonalVehicle(identifier, plate)
    local query = ('SELECT * FROM `%s` WHERE `%s` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ? AND `job` IS NULL LIMIT 2')
        :format(vehicleTable(), ownerColumn())
    local ok, rows = pcall(MySQL.query.await, query, { identifier, plate })
    if not ok or type(rows) ~= 'table' then return nil, 'database' end
    if #rows > 1 then return nil, 'duplicate' end
    return rows[1], rows[1] and nil or 'missing'
end

local function exactJobVehicle(job, plate)
    local ok, rows = pcall(MySQL.query.await, ('SELECT * FROM `%s` WHERE `job` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ? LIMIT 2')
        :format(vehicleTable()), { job, plate })
    if not ok or type(rows) ~= 'table' then return nil, 'database' end
    if #rows > 1 then return nil, 'duplicate' end
    return rows[1], rows[1] and nil or 'missing'
end

local function rowIsStored(vehicle)
    if integerFlag(vehicle and vehicle.stored) ~= 1 then return false end
    if Framework.name ~= 'es_extended' and integerFlag(vehicle.state) ~= 1 then return false end
    return true
end

local function rowIsOut(vehicle)
    if integerFlag(vehicle and vehicle.stored) ~= 0 then return false end
    if Framework.name ~= 'es_extended' and integerFlag(vehicle.state) ~= 0 then return false end
    return true
end

local function findLiveVehicle(plate)
    local found
    for _, vehicle in ipairs(GetAllVehicles()) do
        if DoesEntityExist(vehicle) and normalizePlate(GetVehicleNumberPlateText(vehicle)) == plate then
            if found and found ~= vehicle then return nil, 'duplicate' end
            found = vehicle
        end
    end
    return found
end

local function validateLiveVehicle(source, netId, plate, storedVehicle)
    netId = tonumber(netId)
    if not netId or netId <= 0 then return nil, 'vehicle_not_nearby' end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then
        return nil, 'vehicle_not_found'
    end
    if normalizePlate(GetVehicleNumberPlateText(vehicle)) ~= plate then return nil, 'vehicle_changed' end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil, 'player_not_found' end
    if GetEntityRoutingBucket(vehicle) ~= GetPlayerRoutingBucket(source) then return nil, 'vehicle_not_nearby' end

    local distance = math.max(2.0, tonumber(settings().VehicleDistance) or 8.0) + SERVER_DISTANCE_TOLERANCE
    if #(GetEntityCoords(ped) - GetEntityCoords(vehicle)) > distance then return nil, 'vehicle_not_nearby' end

    for seat = -1, math.max(15, tonumber(GetVehicleMaxNumberOfPassengers(vehicle)) or 0) do
        local occupant = GetPedInVehicleSeat(vehicle, seat)
        if occupant ~= 0 and occupant ~= ped then return nil, 'vehicle_occupied' end
    end

    local model = rowModel(storedVehicle)
    if model and (GetEntityModel(vehicle) & 0xffffffff) ~= (joaat(model) & 0xffffffff) then
        return nil, 'vehicle_model_mismatch'
    end

    return vehicle
end

local function beginPlateOperation(source, plate, name)
    local beginOperation = rawget(_G, 'BeginDrsGaragePlateOperation')
    if type(beginOperation) ~= 'function' then return end
    return beginOperation(plate, source, name)
end

local function endPlateOperation(plate, token)
    local finishOperation = rawget(_G, 'EndDrsGaragePlateOperation')
    if type(finishOperation) == 'function' then pcall(finishOperation, plate, token) end
end

synchronizeExternalQuarantine = function(plate)
    if quarantineTokens[plate] or not quarantinedPlates[plate] then return end

    CreateThread(function()
        for _ = 1, 100 do
            if quarantineTokens[plate] or not quarantinedPlates[plate] then return end
            local beginOperation = rawget(_G, 'BeginDrsGaragePlateOperation')
            if type(beginOperation) == 'function' then
                local token = beginOperation(plate, 0, 'unresolved job fleet operation')
                if token then
                    quarantineTokens[plate] = token
                    return
                end
            end
            Wait(100)
        end
        print(('[drs_garages] CRITICAL: Could not attach the shared garage quarantine lock for fleet plate %s.'):format(plate))
    end)
end

local function withPlateOperation(source, plate, name, callback)
    if sourceLocks[source] then return failure('operation_busy', 'Another fleet operation is already in progress.') end
    if quarantinedPlates[plate] then
        return failure('fleet_operation_quarantined', 'That plate has an unresolved fleet operation requiring staff review.')
    end

    local contractBlocked = rawget(_G, 'IsDrsGarageContractPlateBlocked')
    if type(contractBlocked) ~= 'function' then
        -- Contract operations have their own durable plate journal. Missing an
        -- enabled peer module is a service failure, not permission to mutate.
        if type(Config) == 'table' and type(Config.Contract) == 'table'
            and Config.Contract.Enabled == true
        then
            return failure('contract_service_unavailable', 'The enabled vehicle-contract service is unavailable.')
        end
    else
        local checked, blocked = pcall(contractBlocked, plate)
        if not checked or blocked == true then
            return failure('contract_operation_blocked', 'That plate has an active or unresolved contract operation.')
        end
    end

    local token = beginPlateOperation(source, plate, name)
    if not token then return failure('vehicle_busy', 'That vehicle is being used by another garage operation.') end

    sourceLocks[source] = token
    local ok, result = xpcall(callback, function(errorMessage) return debug.traceback(errorMessage, 2) end)
    if sourceLocks[source] == token then sourceLocks[source] = nil end

    if not ok then
        for operationId, operationPlate in pairs(operationPlates) do
            if operationPlate == plate then quarantinedPlates[plate] = operationId end
        end
    end

    if quarantinedPlates[plate] then
        quarantineTokens[plate] = token
    else
        endPlateOperation(plate, token)
    end

    if not ok then
        print(('[drs_garages] Unexpected job-fleet %s error (source=%s, plate=%s): %s'):format(
            tostring(name), tostring(source), tostring(plate), tostring(result)
        ))
        return failure('unexpected_error', 'The fleet operation failed unexpectedly.')
    end

    return result
end


local function newOperationId(source)
    return ('fleet-%d-%s-%06d'):format(nowMilliseconds(), tostring(source or 0), math.random(0, 999999))
end

local function journalActor(actor)
    return {
        source = tonumber(actor.source) or 0,
        identifier = cleanText(actor.identifier, 80) or 'unknown',
        name = cleanText(actor.name, 100) or 'Unknown',
        job = actor.jobData and actor.jobData.name or nil,
        grade = actor.jobData and math.floor(tonumber(actor.jobData.grade) or 0) or 0
    }
end

local function startJournal(actor, data)
    local operationId = newOperationId(actor.source)
    local at = nowMilliseconds()
    local journal = journalActor(actor)
    local ok, inserted = pcall(MySQL.insert.await, [[
        INSERT INTO `drs_job_fleet_operations`
            (`operation_id`, `external_request_id`, `action`, `status`, `vehicle_row_id`, `plate`, `job`,
             `model`, `garage_from`, `garage_to`, `min_grade`, `actor_source`, `actor_identifier`,
             `actor_name`, `actor_job`, `actor_grade`, `source_resource`, `reason`, `vehicle_snapshot`,
             `request_json`, `created_at`, `updated_at`)
        VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        operationId,
        data.externalRequestId,
        data.action,
        data.vehicleRowId,
        data.plate,
        data.job,
        data.model,
        data.garageFrom,
        data.garageTo,
        data.minGrade,
        journal.source,
        journal.identifier,
        journal.name,
        journal.job,
        journal.grade,
        cleanText(data.sourceResource, 64) or RESOURCE_NAME,
        data.reason,
        safeEncode(data.snapshot),
        safeEncode(data.request),
        at,
        at
    })

    if not ok or not inserted then return nil, tostring(inserted) end
    operationPlates[operationId] = data.plate
    return operationId
end

local function finishJournal(operationId, status, errorCode, errorDetail)
    local at = nowMilliseconds()
    local normalizedErrorCode = cleanText(errorCode, 100)
    local normalizedErrorDetail = cleanText(errorDetail, 500)
    local ok, changed = pcall(MySQL.update.await, [[
        UPDATE `drs_job_fleet_operations`
        SET `status` = ?, `error_code` = ?, `error_detail` = ?, `updated_at` = ?,
            `completed_at` = CASE WHEN ? IN ('committed', 'failed') THEN ? ELSE NULL END
        WHERE BINARY `operation_id` = BINARY ? AND `status` IN ('pending', 'attention')
        LIMIT 1
    ]], {
        status,
        normalizedErrorCode,
        normalizedErrorDetail,
        at,
        status,
        at,
        operationId
    })
    local finalized = ok and tonumber(changed) == 1
    if not finalized then
        -- An await can fail after MySQL committed. Exact read-back prevents a
        -- terminal journal from retaining an orphan in-memory quarantine lock.
        local readOk, current = pcall(MySQL.single.await, [[
            SELECT `status`, `error_code`, `error_detail`
            FROM `drs_job_fleet_operations`
            WHERE BINARY `operation_id` = BINARY ?
            LIMIT 1
        ]], { operationId })
        finalized = readOk and current and current.status == status
            and tostring(current.error_code or '') == tostring(normalizedErrorCode or '')
            and tostring(current.error_detail or '') == tostring(normalizedErrorDetail or '')
    end
    local plate = operationPlates[operationId]
    if plate then
        if status == 'attention' or not finalized then
            quarantinedPlates[plate] = operationId
            synchronizeExternalQuarantine(plate)
        elseif quarantinedPlates[plate] == operationId then
            quarantinedPlates[plate] = nil
            local token = quarantineTokens[plate]
            if token then
                quarantineTokens[plate] = nil
                endPlateOperation(plate, token)
            end
        end
        if finalized and (status == 'committed' or status == 'failed') then operationPlates[operationId] = nil end
    end
    return finalized
end

local function revalidateBeforeMutation(actor, actionMode, operationId, external)
    local refreshed, actorError = revalidateActor(actor, actionMode)
    if refreshed then return refreshed end

    local detail = actorError and actorError.message or 'Fleet authorization changed during the operation.'
    local finalized = finishJournal(operationId, 'failed', 'authorization_changed', detail)
    return nil, failure(finalized and 'authorization_changed' or 'journal_finalize_failed', detail, {
        operationId = operationId,
        committed = false,
        safeToRefund = external and finalized or nil,
        retryable = false
    })
end

local function updateJournalVehicle(operationId, vehicleId, plate)
    local ok, changed = pcall(MySQL.update.await, [[
        UPDATE `drs_job_fleet_operations`
        SET `vehicle_row_id` = ?, `plate` = ?, `updated_at` = ?
        WHERE BINARY `operation_id` = BINARY ? AND `status` = 'pending'
        LIMIT 1
    ]], { vehicleId, plate, nowMilliseconds(), operationId })
    return ok and tonumber(changed) == 1
end

local function getExternalJournal(sourceResource, requestId)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT `operation_id`, `status`, `vehicle_row_id`, `plate`, `error_code`, `error_detail`,
               `action`, `job`, `model`, `garage_to`, `min_grade`, `actor_source`, `actor_identifier`, `reason`, `request_json`
        FROM `drs_job_fleet_operations`
        WHERE BINARY `source_resource` = BINARY ? AND BINARY `external_request_id` = BINARY ?
        LIMIT 1
    ]], { sourceResource, requestId })
    return ok and row or nil, ok
end

local function externalRequestMatches(row, expected)
    if not expected then return true end
    if not row or row.action ~= expected.action then return false end
    if normalizeJob(row.job) ~= expected.job or normalizeModel(row.model) ~= expected.model then return false end
    -- Server IDs are ephemeral and may change when an authorized actor reconnects.
    -- The stable framework identifier below is the actor identity invariant; keep
    -- actor_source in the journal for audit history, but do not bind replays to it.
    if tonumber(row.min_grade) ~= expected.minGrade then return false end
    if safeStorageName(row.garage_to) ~= expected.garageId then return false end
    if not expected.actorIdentifier or tostring(row.actor_identifier or '') ~= expected.actorIdentifier then return false end
    if (reasonText(row.reason, false) or '') ~= (expected.reason or '') then return false end

    local decoded
    if type(row.request_json) == 'string' and row.request_json ~= '' then
        local ok, value = pcall(json.decode, row.request_json)
        if ok and type(value) == 'table' then decoded = value end
    end
    return decoded ~= nil
        and tonumber(decoded.garageIndex) == expected.garageIndex
        and safeStorageName(decoded.garageId) == expected.garageId
        and normalizeJob(decoded.job) == expected.job
        and normalizeModel(decoded.model) == expected.model
        and decoded.action == expected.action
        and tonumber(decoded.minGrade) == expected.minGrade
        and tostring(decoded.actorIdentifier or '') == expected.actorIdentifier
        and (reasonText(decoded.reason, false) or '') == (expected.reason or '')
end

local function replayResponse(row, expected)
    if not row then return end
    if not externalRequestMatches(row, expected) then
        return failure('idempotency_mismatch', 'That request ID is already bound to different fleet purchase details.', {
            operationId = row.operation_id,
            plate = row.plate,
            status = row.status,
            replayed = true,
            committed = false,
            safeToRefund = false,
            retryable = false
        })
    end
    -- A prior same-request call may have thrown after its journal insert. Once
    -- withPlateOperation has quarantined that exact operation, no mutation is
    -- still running, so a replay can prove its current final state immediately
    -- instead of remaining retryable until the next resource restart.
    local plate = normalizePlate(row.plate)
    if row.status == 'pending' and plate
        and quarantinedPlates[plate] == row.operation_id
        and type(reconcilePendingOperation) == 'function'
    then
        row = reconcilePendingOperation(row, 'recovered_during_idempotent_retry') or row
    end

    if row.status == 'committed' then
        return success('The fleet vehicle was already issued.', {
            operationId = row.operation_id,
            vehicleId = tonumber(row.vehicle_row_id) or row.vehicle_row_id,
            plate = row.plate,
            replayed = true,
            committed = true,
            safeToRefund = false,
            retryable = false
        })
    end
    return failure(row.error_code or 'operation_unresolved', row.error_detail or 'That request already exists and is not safely repeatable.', {
        operationId = row.operation_id,
        plate = row.plate,
        status = row.status,
        replayed = true,
        committed = false,
        safeToRefund = row.status == 'failed',
        retryable = row.status == 'pending'
    })
end

refreshPlateQuarantine = function(rawPlate)
    local plate = normalizePlate(rawPlate)
    if not plate then return false end

    local ok, unresolved = pcall(MySQL.single.await, [[
        SELECT `operation_id`
        FROM `drs_job_fleet_operations`
        WHERE BINARY `plate` = BINARY ? AND `status` IN ('pending', 'attention')
        ORDER BY `created_at` ASC
        LIMIT 1
    ]], { plate })
    if not ok then return false end

    if unresolved then
        operationPlates[unresolved.operation_id] = plate
        quarantinedPlates[plate] = unresolved.operation_id
        synchronizeExternalQuarantine(plate)
    else
        quarantinedPlates[plate] = nil
        local token = quarantineTokens[plate]
        if token then
            quarantineTokens[plate] = nil
            endPlateOperation(plate, token)
        end
    end
    return true
end

local function cacheMetadata(row)
    if not row then return end
    local key = cleanText(row.vehicle_row_id, 64)
    local plate = normalizePlate(row.plate)
    if not key or not plate then return end

    row.vehicle_row_id = key
    row.plate = plate
    row.job = normalizeJob(row.job)
    row.min_grade = math.max(0, math.floor(tonumber(row.min_grade) or 0))
    metadataByRow[key] = row
    metadataByPlate[plate] = row
end

local function removeCachedMetadata(key, plate)
    local row = key and metadataByRow[key] or plate and metadataByPlate[plate]
    if not row then return end
    metadataByRow[row.vehicle_row_id] = nil
    metadataByPlate[row.plate] = nil
end

local function loadMetadataCache()
    local ok, rows = pcall(MySQL.query.await, ('SELECT * FROM `%s`'):format(FLEET_TABLE))
    if not ok or type(rows) ~= 'table' then return false end

    metadataByRow = {}
    metadataByPlate = {}
    for _, row in ipairs(rows) do cacheMetadata(row) end
    return true
end

local function metadataFor(vehicle)
    if not vehicle then return end
    local key = rowKey(vehicle)
    local plate = normalizePlate(vehicle.plate)
    if not key or not plate then return nil, 'invalid_identity' end

    local byRow = metadataByRow[key]
    local byPlate = metadataByPlate[plate]
    if byRow and (byRow.plate ~= plate or (byPlate and byPlate ~= byRow)) then
        return nil, 'identity_mismatch'
    end
    if byPlate and byPlate.vehicle_row_id ~= key then return nil, 'identity_mismatch' end
    return byRow or byPlate, (byRow or byPlate) and nil or 'missing'
end

reconcilePendingOperation = function(operation, recoveryCode)
    if type(operation) ~= 'table' or operation.status ~= 'pending' then return operation end

    local plate = normalizePlate(operation.plate)
    if plate then operationPlates[operation.operation_id] = plate end
    local vehicle, vehicleLookupError
    if plate then vehicle, vehicleLookupError = exactVehicleByPlate(plate) end
    local metadata, metadataError
    if vehicle then
        metadata, metadataError = metadataFor(vehicle)
    else
        metadata = plate and metadataByPlate[plate] or nil
    end
    local metadataIdentityMatches = metadataError ~= 'identity_mismatch'
        and (not metadata or not operation.vehicle_row_id
            or tostring(metadata.vehicle_row_id) == tostring(operation.vehicle_row_id))
    local committed = false

    if operation.action == 'retire_vehicle' then
        committed = vehicle == nil and vehicleLookupError == 'missing'
            and metadata and metadataIdentityMatches and metadata.status == 'retired'
    elseif vehicle and metadata and metadataIdentityMatches and metadata.status == 'active' then
        committed = normalizeJob(vehicle.job) == normalizeJob(operation.job)
            and normalizeJob(metadata.job) == normalizeJob(operation.job)
        if committed and operation.garage_to then
            committed = safeStorageName(vehicle.garage) == safeStorageName(operation.garage_to)
                and safeStorageName(metadata.garage) == safeStorageName(operation.garage_to)
        end
        if committed and operation.min_grade ~= nil then
            committed = tonumber(metadata.min_grade) == tonumber(operation.min_grade)
        end
    end

    local creationAction = operation.action == 'society_purchase'
        or operation.action == 'admin_grant' or operation.action == 'admin_create'
    local safelyAbsent = creationAction and vehicle == nil and vehicleLookupError == 'missing' and metadata == nil
    local status = committed and 'committed' or safelyAbsent and 'failed' or 'attention'
    local code = committed and (recoveryCode or 'recovered_pending_operation')
        or safelyAbsent and 'recovered_creation_absent' or 'recovery_required'
    local detail = committed and 'The committed final state was verified from the framework row and fleet metadata.'
        or safelyAbsent and 'No matching framework vehicle or fleet metadata exists; creation was proven absent.'
        or 'The pending operation could not be proven complete; inspect its snapshot and current vehicle row.'
    if not finishJournal(operation.operation_id, status, code, detail) then return operation end

    operation.status = status
    operation.error_code = code
    operation.error_detail = detail
    return operation
end

local function insertActiveMetadata(actor, vehicle, job, garage, minimumGrade)
    local key = rowKey(vehicle)
    local plate = normalizePlate(vehicle.plate)
    local model = rowModel(vehicle) or 'unknown'
    local vehicleType = rowType(vehicle)
    local at = nowMilliseconds()
    if not key or not plate then return false, 'invalid_vehicle_identity' end

    local existing = metadataByRow[key] or metadataByPlate[plate]
    if existing and existing.vehicle_row_id ~= key then return false, 'metadata_plate_conflict' end

    local query, values
    if existing then
        query = [[
            UPDATE `drs_job_fleet_vehicles`
            SET `job` = ?, `model` = ?, `vehicle_type` = ?, `garage` = ?, `min_grade` = ?,
                `status` = 'active', `updated_at` = ?, `retired_at` = NULL, `retire_reason` = NULL
            WHERE BINARY `vehicle_row_id` = BINARY ? AND BINARY `plate` = BINARY ?
            LIMIT 1
        ]]
        values = { job, model, vehicleType, garage, minimumGrade, at, key, plate }
    else
        query = [[
            INSERT INTO `drs_job_fleet_vehicles`
                (`vehicle_row_id`, `plate`, `job`, `model`, `vehicle_type`, `garage`, `min_grade`,
                 `status`, `added_by_identifier`, `added_by_name`, `added_at`, `updated_at`)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)
        ]]
        values = { key, plate, job, model, vehicleType, garage, minimumGrade, actor.identifier, actor.name, at, at }
    end

    local ok, changed = pcall(existing and MySQL.update.await or MySQL.insert.await, query, values)
    -- oxmysql returns an insert id for `insert.await`. This table deliberately
    -- has no AUTO_INCREMENT column, so a successful first insert may return 0.
    -- The exact identity/policy read-back below is the authoritative result for
    -- both inserts and idempotent updates.
    if not ok or changed == nil or changed == false then return false, tostring(changed) end

    local rowOk, current = pcall(MySQL.single.await, [[
        SELECT * FROM `drs_job_fleet_vehicles`
        WHERE BINARY `vehicle_row_id` = BINARY ? AND BINARY `plate` = BINARY ?
        LIMIT 1
    ]], { key, plate })
    if not rowOk or not current or current.status ~= 'active' or normalizeJob(current.job) ~= job
        or cleanText(current.garage, 50) ~= garage or tonumber(current.min_grade) ~= minimumGrade
    then
        return false, 'metadata_verification_failed'
    end

    cacheMetadata(current)
    return true
end

local function deleteActiveMetadata(vehicle)
    local key = rowKey(vehicle)
    local plate = normalizePlate(vehicle.plate)
    if not key or not plate then return false end

    local ok, changed = pcall(MySQL.update.await, [[
        DELETE FROM `drs_job_fleet_vehicles`
        WHERE BINARY `vehicle_row_id` = BINARY ? AND BINARY `plate` = BINARY ? AND `status` = 'active'
        LIMIT 1
    ]], { key, plate })
    local verified, current = pcall(MySQL.single.await, [[
        SELECT `vehicle_row_id`, `plate`
        FROM `drs_job_fleet_vehicles`
        WHERE BINARY `vehicle_row_id` = BINARY ? OR BINARY `plate` = BINARY ?
        LIMIT 1
    ]], { key, plate })
    if verified and not current then
        removeCachedMetadata(key, plate)
        return true
    end
    return false, ok and ('metadata_delete_unconfirmed:%s'):format(tostring(changed)) or tostring(changed)
end

local function retireMetadata(actor, vehicle, reason)
    local key = rowKey(vehicle)
    local plate = normalizePlate(vehicle.plate)
    local existing = metadataByRow[key] or metadataByPlate[plate]
    local at = nowMilliseconds()
    if not key or not plate then return false end

    if not existing then
        local ok, inserted = pcall(MySQL.insert.await, [[
            INSERT INTO `drs_job_fleet_vehicles`
                (`vehicle_row_id`, `plate`, `job`, `model`, `vehicle_type`, `garage`, `min_grade`,
                 `status`, `added_by_identifier`, `added_by_name`, `added_at`, `updated_at`,
                 `retired_at`, `retire_reason`)
            VALUES (?, ?, ?, ?, ?, ?, 0, 'retired', ?, ?, ?, ?, ?, ?)
        ]], {
            key, plate, normalizeJob(vehicle.job), rowModel(vehicle) or 'unknown', rowType(vehicle),
            safeStorageName(vehicle.garage) or 'unknown', actor.identifier, actor.name, at, at, at, reason
        })
        if not ok or not inserted then return false end
    else
        local ok, changed = pcall(MySQL.update.await, [[
            UPDATE `drs_job_fleet_vehicles`
            SET `status` = 'retired', `updated_at` = ?, `retired_at` = ?, `retire_reason` = ?
            WHERE BINARY `vehicle_row_id` = BINARY ? AND BINARY `plate` = BINARY ?
            LIMIT 1
        ]], { at, at, reason, key, plate })
        if not ok or tonumber(changed) ~= 1 then return false end
    end

    local ok, current = pcall(MySQL.single.await, [[
        SELECT * FROM `drs_job_fleet_vehicles`
        WHERE BINARY `vehicle_row_id` = BINARY ? AND BINARY `plate` = BINARY ?
        LIMIT 1
    ]], { key, plate })
    if not ok or not current or current.status ~= 'retired' then return false end
    cacheMetadata(current)
    return true
end

local function getFrameworkCatalog()
    if Framework.name == 'qbx_core' then
        local ok, catalog = pcall(function() return exports.qbx_core:GetVehiclesByName() end)
        return ok and type(catalog) == 'table' and catalog or nil
    elseif Framework.name == 'qb-core' then
        local core = rawget(_G, 'QBCore')
        return core and core.Shared and type(core.Shared.Vehicles) == 'table' and core.Shared.Vehicles or nil
    end
end

local function configuredModelEntries(job)
    local allowed = settings().AllowedModels
    local entries = {}

    local function merge(container)
        if type(container) ~= 'table' then return end
        for key, value in pairs(container) do
            local model, spec
            if type(key) == 'number' then
                if type(value) == 'string' then
                    model, spec = normalizeModel(value), {}
                elseif type(value) == 'table' then
                    model, spec = normalizeModel(value.Model or value.model or value.Name or value.name), value
                end
            elseif value ~= false then
                model, spec = normalizeModel(key), type(value) == 'table' and value or {}
            end
            if model then entries[model] = spec end
        end
    end

    if type(allowed) == 'table' then
        merge(allowed['*'])
        merge(allowed[job])
    end
    return entries
end

local function catalogVehicle(model, job)
    model = normalizeModel(model)
    if not model then return end

    local spec = configuredModelEntries(job)[model]
    if not spec then return end

    local catalog = getFrameworkCatalog()
    local record = catalog and catalog[model]
    if type(record) ~= 'table' then
        for key, value in pairs(catalog or {}) do
            local candidate = normalizeModel(type(key) == 'string' and key or type(value) == 'table' and (value.model or value.name))
            if candidate == model then record = value break end
        end
    end
    if type(record) ~= 'table' then return end

    local vehicleType = normalizeVehicleType(spec.Type or spec.type or record.type or record.vehicleType or 'car')
    local minimumBossGrade = math.max(0, math.floor(tonumber(spec.MinimumBossGrade or spec.minimumBossGrade) or 0))
    return {
        model = model,
        label = cleanText(spec.Label or spec.label or record.name or record.brand or model, 80) or model,
        type = vehicleType,
        minimumBossGrade = minimumBossGrade
    }
end

local function catalogForActor(actor)
    local result = {}
    for model in pairs(configuredModelEntries(actor.job)) do
        local item = catalogVehicle(model, actor.job)
        if item and item.type == actor.garage.type and (actor.admin or actor.jobData.grade >= item.minimumBossGrade) then
            result[#result + 1] = item
        end
    end
    table.sort(result, function(a, b) return a.label:lower() < b.label:lower() end)
    return result
end

local function actorCanCreate(actor, externalAction)
    if Framework.name ~= 'qbx_core' or GetResourceState('qbx_vehicles') ~= 'started' then return false end
    if settings().CreationEnabled == false then return false end
    if externalAction == 'admin_grant' then return actor.admin end
    if externalAction == 'society_purchase' then return true end
    return actor.admin or settings().BossCanCreate == true
end

local function actorCanPurchase(actor)
    if settings().BossPurchasesEnabled == false then return false end
    local resource = cleanText(settings().VehicleShopResource, 64) or 'drs_vehicleshop'
    if not resource:match('^[%w_%-]+$') or GetResourceState(resource) ~= 'started' then return false end
    if actor.jobData.name ~= actor.job then return false end
    local bossOk, isBoss = safePlayerMethod(actor.player, 'isJobBoss')
    if not bossOk or isBoss ~= true then return false end
    local minimum = math.max(0, math.floor(tonumber(settings().BossMinimumGrade) or 0))
    if actor.jobData.grade < minimum then return false end
    if settings().RequireBossDuty == true and actor.jobData.onDuty ~= true then return false end
    return true
end

local function plateExists(plate)
    local liveVehicle, liveError = findLiveVehicle(plate)
    if liveVehicle or liveError then return true end

    local ok, found = pcall(MySQL.scalar.await, ('SELECT 1 FROM `%s` WHERE BINARY UPPER(TRIM(`plate`)) = BINARY ? LIMIT 1')
        :format(vehicleTable()), { plate })
    if not ok or found ~= nil then return true end

    local metaOk, metadata = pcall(MySQL.scalar.await, [[
        SELECT 1 FROM `drs_job_fleet_vehicles` WHERE BINARY `plate` = BINARY ? LIMIT 1
    ]], { plate })
    return not metaOk or metadata ~= nil
end

local function generatePlate()
    local alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789'
    for _ = 1, 50 do
        local value = 'DR'
        for _ = 1, 6 do
            local index = math.random(1, #alphabet)
            value = value .. alphabet:sub(index, index)
        end
        if not plateExists(value) then return value end
    end
end

local function setQboxOwner(vehicleId, identifier, expectedJob, plate)
    if Framework.name ~= 'qbx_core' or vehicleId == nil or GetResourceState('qbx_vehicles') ~= 'started' then return false end

    local ok, result = pcall(function()
        return exports.qbx_vehicles:SetPlayerVehicleOwner(tonumber(vehicleId) or vehicleId, identifier)
    end)
    if not ok or result ~= true then return false end

    local row = exactVehicleByPlate(plate)
    if not row or tostring(row.id) ~= tostring(vehicleId) or normalizeJob(row.job) ~= normalizeJob(expectedJob) then return false end
    if tostring(row.citizenid or '') ~= tostring(identifier or '') then return false end
    if identifier == nil and tostring(row.license or '') ~= '' then return false end
    return true
end

local function updateLiveQboxKeys(source, vehicle, newOwner)
    if Framework.name ~= 'qbx_core' or not vehicle or not DoesEntityExist(vehicle) then return true end

    local state = Entity(vehicle).state
    if Config.UseKeySystem and GetResourceState('qbx_vehiclekeys') == 'started' then
        local previous = state.sessionId
        state:set('sessionId', nil, true)
        local ok, created = pcall(function() return exports.qbx_core:CreateSessionId(vehicle) end)
        if not ok or created == false or state.sessionId == nil or state.sessionId == previous then return false end

        local keysOk = pcall(function() exports.qbx_vehiclekeys:GiveKeys(source, vehicle, false) end)
        if not keysOk then return false end
    end

    return pcall(function() state:set('owner', newOwner, true) end)
end

local function updatePersonalRowToJob(vehicle, actor, destination, wasStored)
    local tableName = vehicleTable()
    local owner = ownerColumn()
    local params = { actor.job, destination.garage }
    local where

    if vehicle.id ~= nil then
        where = '`id` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ?'
        params[#params + 1] = vehicle.id
        params[#params + 1] = normalizePlate(vehicle.plate)
    else
        where = ('`%s` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ?'):format(owner)
        params[#params + 1] = actor.identifier
        params[#params + 1] = normalizePlate(vehicle.plate)
    end

    if Framework.name == 'qbx_core' then
        where = where .. ' AND `citizenid` IS NULL AND `license` IS NULL'
    else
        where = where .. (' AND `%s` = ?'):format(owner)
        params[#params + 1] = actor.identifier
    end

    where = where .. ' AND `job` IS NULL AND `stored` = ?'
    params[#params + 1] = wasStored and 1 or 0
    if Framework.name ~= 'es_extended' then
        where = where .. ' AND `state` = ?'
        params[#params + 1] = wasStored and 1 or 0
    end

    local ok, changed = pcall(MySQL.update.await,
        ('UPDATE `%s` SET `job` = ?, `garage` = ? WHERE %s LIMIT 1'):format(tableName, where), params)
    return ok and tonumber(changed) == 1
end

local function rollbackRegistration(vehicle, actor, originalGarage)
    local plate = normalizePlate(vehicle.plate)
    local setClause = originalGarage and '`garage` = ?' or '`garage` = NULL'
    local params = originalGarage and { originalGarage, actor.job, plate } or { actor.job, plate }
    local identity = '`job` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ?'
    if vehicle.id ~= nil then
        identity = '`id` = ? AND ' .. identity
        table.insert(params, originalGarage and 2 or 1, vehicle.id)
    end

    local ok, changed = pcall(MySQL.update.await,
        ('UPDATE `%s` SET `job` = NULL, %s WHERE %s LIMIT 1'):format(vehicleTable(), setClause, identity), params)
    if not ok or tonumber(changed) ~= 1 then return false end

    if Framework.name == 'qbx_core' then
        return setQboxOwner(vehicle.id, actor.identifier, nil, plate)
    end
    return true
end

local function registerPersonalVehicle(source, garageIndex, requestedJob, rawPlate, minimumGrade, netId)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then return actorError end

    local plate = normalizePlate(rawPlate)
    local grade = boundedGrade(minimumGrade)
    if not plate then return failure('invalid_plate', 'Select a valid owned vehicle.') end
    if grade == nil then return failure('invalid_grade', 'Enter a valid minimum grade.') end

    return withPlateOperation(source, plate, 'job fleet registration', function()
        local vehicle, lookupError = exactPersonalVehicle(actor.identifier, plate)
        if not vehicle then
            return failure(lookupError == 'missing' and 'vehicle_not_owned' or 'vehicle_lookup_failed',
                lookupError == 'missing' and 'That personal vehicle is no longer owned by you.' or 'The vehicle record could not be verified.')
        end
        local personalMetadata, personalMetadataError = metadataFor(vehicle)
        if personalMetadata or personalMetadataError == 'identity_mismatch' then
            return failure('metadata_conflict', 'That plate already has fleet metadata requiring staff review.')
        end
        if rowType(vehicle) ~= actor.garage.type then
            return failure('vehicle_type_mismatch', 'That vehicle type cannot be assigned to this garage.')
        end

        local stored = rowIsStored(vehicle)
        local liveVehicle
        if stored then
            local liveError
            liveVehicle, liveError = findLiveVehicle(plate)
            if liveVehicle or liveError then
                return failure(liveError == 'duplicate' and 'duplicate_live_vehicle' or 'vehicle_is_active',
                    'Store every active copy of the vehicle cleanly before assigning it.')
            end
        elseif rowIsOut(vehicle) then
            liveVehicle, lookupError = validateLiveVehicle(source, netId, plate, vehicle)
            if not liveVehicle then return failure(lookupError, 'The out vehicle must be nearby, unchanged, and unoccupied.') end
            local uniqueLive, uniqueError = findLiveVehicle(plate)
            if uniqueError or uniqueLive ~= liveVehicle then
                return failure('duplicate_live_vehicle', 'The plate must identify exactly one live vehicle before fleet assignment.')
            end
            if Framework.name == 'qb-core' and Config.UseKeySystem and GetResourceState('qb-vehiclekeys') == 'started' then
                return failure('unsafe_key_provider', 'Live fleet assignment is unavailable with stock qb-vehiclekeys; park the vehicle first.')
            end
        else
            return failure('vehicle_not_available', 'Impounded or transitional vehicles cannot be assigned to a fleet.')
        end

        local operationId, journalError = startJournal(actor, {
            action = 'register_personal',
            vehicleRowId = rowKey(vehicle),
            plate = plate,
            job = actor.job,
            model = rowModel(vehicle),
            garageFrom = safeStorageName(vehicle.garage),
            garageTo = actor.garage.garage,
            minGrade = grade,
            snapshot = vehicle,
            request = { garageIndex = actor.garage.index, netId = tonumber(netId), wasStored = stored }
        })
        if not operationId then
            return failure('journal_unavailable', 'The fleet audit journal rejected this operation.', { detail = journalError })
        end

        local refreshed, authorizationError = revalidateBeforeMutation(actor, nil, operationId, false)
        if not refreshed then return authorizationError end
        actor = refreshed

        local verified = exactPersonalVehicle(actor.identifier, plate)
        if not verified or tostring(rowKey(verified)) ~= tostring(rowKey(vehicle))
            or rowIsStored(verified) ~= stored or rowIsOut(verified) ~= (not stored)
        then
            finishJournal(operationId, 'failed', 'vehicle_changed', 'The exact personal vehicle changed after authorization was refreshed.')
            return failure('vehicle_changed', 'The vehicle changed before it could be assigned.', { operationId = operationId })
        end
        vehicle = verified
        if liveVehicle then
            local recheckedLive, liveError = validateLiveVehicle(source, netId, plate, vehicle)
            local uniqueLive, uniqueError = findLiveVehicle(plate)
            if not recheckedLive or recheckedLive ~= liveVehicle or uniqueError or uniqueLive ~= liveVehicle then
                finishJournal(operationId, 'failed', 'vehicle_changed', 'The nearby live vehicle changed before ownership mutation.')
                return failure(liveError or 'vehicle_changed', 'The nearby vehicle changed before it could be assigned.', {
                    operationId = operationId
                })
            end
        end

        local qboxOwnerCleared = false
        if Framework.name == 'qbx_core' then
            if vehicle.id == nil or not setQboxOwner(vehicle.id, nil, nil, plate) then
                finishJournal(operationId, 'failed', 'owner_clear_failed', 'Qbox ownership hook or verification failed.')
                return failure('owner_clear_failed', 'Qbox could not safely clear personal ownership.', { operationId = operationId })
            end
            qboxOwnerCleared = true
        end

        if not updatePersonalRowToJob(vehicle, actor, actor.garage, stored) then
            local restored = not qboxOwnerCleared or setQboxOwner(vehicle.id, actor.identifier, nil, plate)
            finishJournal(operationId, restored and 'failed' or 'attention', 'vehicle_update_failed',
                restored and 'The conditional job assignment changed no row.' or 'The Qbox owner rollback failed.')
            return failure(restored and 'vehicle_changed' or 'operation_requires_staff',
                restored and 'The vehicle changed before it could be assigned.' or 'Ownership needs staff reconciliation.',
                { operationId = operationId })
        end

        local current = exactJobVehicle(actor.job, plate)
        local metadataOk, metadataError = current and tostring(rowKey(current)) == tostring(rowKey(vehicle))
            and insertActiveMetadata(actor, current, actor.job, actor.garage.garage, grade)
        if not metadataOk then
            local metadataRestored = deleteActiveMetadata(vehicle)
            local ownershipRestored = rollbackRegistration(vehicle, actor, safeStorageName(vehicle.garage))
            local recovered = metadataRestored and ownershipRestored
            finishJournal(operationId, recovered and 'failed' or 'attention', 'metadata_commit_failed', tostring(metadataError))
            return failure(recovered and 'metadata_commit_failed' or 'operation_requires_staff',
                recovered and 'Fleet metadata could not be saved; the vehicle was restored.'
                    or 'Metadata or ownership rollback is unconfirmed; the vehicle needs staff reconciliation.',
                { operationId = operationId })
        end

        if liveVehicle and Framework.name == 'qbx_core' and not updateLiveQboxKeys(source, liveVehicle, nil) then
            finishJournal(operationId, 'attention', 'key_rotation_failed', 'Ownership committed but the live Qbox key session could not be rotated.')
            return failure('key_rotation_failed', 'The fleet assignment was saved, but vehicle keys need staff attention.', {
                operationId = operationId,
                committed = true
            })
        end

        if not finishJournal(operationId, 'committed') then
            return failure('journal_finalize_failed', 'The assignment succeeded but its journal needs staff attention.', {
                operationId = operationId,
                committed = true
            })
        end

        return success(('%s is now assigned to the %s fleet.'):format(plate, actor.job), {
            operationId = operationId,
            vehicleId = vehicle.id,
            plate = plate
        })
    end)
end

local function createVehicleForActor(actor, rawModel, minimumGrade, journalOptions)
    local grade = boundedGrade(minimumGrade)
    local catalogEntry = catalogVehicle(rawModel, actor.job)
    local externalRequestId = journalOptions and journalOptions.requestId or nil
    local sourceResource = journalOptions and journalOptions.sourceResource or RESOURCE_NAME
    if grade == nil then return failure('invalid_grade', 'Enter a valid minimum grade.', {
        committed = false, safeToRefund = true, retryable = false
    }) end
    if not actorCanCreate(actor, journalOptions and journalOptions.action) then
        return failure('creation_unavailable', 'Fleet vehicle creation is not available for this framework or role.', {
            committed = false, safeToRefund = true, retryable = false
        })
    end
    if not catalogEntry or catalogEntry.type ~= actor.garage.type then
        return failure('model_not_allowed', 'That model is not in the server allowlist for this job and garage.', {
            committed = false, safeToRefund = true, retryable = false
        })
    end
    if not actor.admin and actor.jobData.grade < catalogEntry.minimumBossGrade then
        return failure('model_grade_denied', 'Your job grade cannot issue that model.', {
            committed = false, safeToRefund = true, retryable = false
        })
    end

    local externalFingerprint = externalRequestId and {
        action = journalOptions.action,
        actorSource = actor.source,
        actorIdentifier = actor.identifier,
        job = actor.job,
        model = catalogEntry.model,
        garageIndex = actor.garage.index,
        garageId = actor.garage.garage,
        minGrade = grade,
        reason = journalOptions.reason or ''
    } or nil

    local plate = generatePlate()
    if not plate then return failure('plate_generation_failed', 'A unique fleet plate could not be reserved.', {
        committed = false, safeToRefund = true, retryable = true
    }) end

    local response = withPlateOperation(actor.source, plate, 'job fleet creation', function()
        if externalRequestId then
            local existing, readable = getExternalJournal(sourceResource, externalRequestId)
            if not readable then return failure('journal_unavailable', 'The fleet idempotency journal could not be read.', {
                committed = false, safeToRefund = false, retryable = true
            }) end
            local replay = replayResponse(existing, externalFingerprint)
            if replay then return replay end
        end

        local operationId, journalError = startJournal(actor, {
            externalRequestId = externalRequestId,
            sourceResource = sourceResource,
            action = journalOptions and journalOptions.action or 'admin_create',
            plate = plate,
            job = actor.job,
            model = catalogEntry.model,
            garageTo = actor.garage.garage,
            minGrade = grade,
            reason = journalOptions and journalOptions.reason or nil,
            request = {
                requestId = externalRequestId,
                garageIndex = actor.garage.index,
                garageId = actor.garage.garage,
                job = actor.job,
                model = catalogEntry.model,
                action = journalOptions and journalOptions.action or 'admin_create',
                actorSource = actor.source,
                actorIdentifier = actor.identifier,
                minGrade = grade,
                reason = journalOptions and journalOptions.reason or nil
            }
        })
        if not operationId then
            local existing, readable
            if externalRequestId then existing, readable = getExternalJournal(sourceResource, externalRequestId) end
            local replay = externalRequestId and readable and replayResponse(existing, externalFingerprint) or nil
            return replay or failure('journal_unavailable', 'The fleet audit journal rejected this operation.', {
                detail = journalError,
                committed = false,
                safeToRefund = false,
                retryable = true
            })
        end

        local actionMode = journalOptions and journalOptions.action or nil
        local refreshed, authorizationError = revalidateBeforeMutation(
            actor,
            actionMode,
            operationId,
            externalRequestId ~= nil
        )
        if not refreshed then return authorizationError end
        actor = refreshed

        local refreshedCatalog = catalogVehicle(catalogEntry.model, actor.job)
        if not actorCanCreate(actor, actionMode) or not refreshedCatalog
            or refreshedCatalog.type ~= actor.garage.type
            or (not actor.admin and actor.jobData.grade < refreshedCatalog.minimumBossGrade)
        then
            local finalized = finishJournal(operationId, 'failed', 'creation_policy_changed',
                'The creation allowlist, framework availability, or actor grade changed before vehicle creation.')
            return failure(finalized and 'creation_policy_changed' or 'journal_finalize_failed',
                'Fleet creation policy changed before the vehicle could be issued.', {
                    operationId = operationId,
                    committed = false,
                    safeToRefund = externalRequestId ~= nil and finalized or nil,
                    retryable = false
                })
        end
        catalogEntry = refreshedCatalog

        local createOk, vehicleId, createError = pcall(function()
            return exports.qbx_vehicles:CreatePlayerVehicle({
                model = catalogEntry.model,
                citizenid = nil,
                garage = actor.garage.garage,
                props = {
                    plate = plate,
                    model = joaat(catalogEntry.model),
                    fuelLevel = 100,
                    engineHealth = 1000,
                    bodyHealth = 1000
                }
            })
        end)

        if not createOk or not vehicleId then
            local reason = type(createError) == 'table' and (createError.code or createError.message) or tostring(createError or vehicleId)
            local recovered, recoveryError = exactVehicleByPlate(plate)
            if recovered or not createOk or recoveryError ~= 'missing' then
                updateJournalVehicle(operationId, recovered and rowKey(recovered) or nil, plate)
                finishJournal(operationId, 'attention', 'creation_result_unknown', tostring(reason))
                return failure('operation_requires_staff', 'Vehicle creation returned an uncertain result; staff review is required.', {
                    operationId = operationId,
                    plate = plate,
                    committed = false,
                    safeToRefund = false,
                    retryable = false
                })
            end
            local finalized = finishJournal(operationId, 'failed', 'creation_failed', tostring(reason))
            return failure(finalized and 'creation_failed' or 'journal_finalize_failed',
                finalized and 'Qbox could not create the fleet vehicle.' or 'No vehicle row was found, but the failure journal could not be finalized.', {
                operationId = operationId,
                committed = false,
                safeToRefund = finalized,
                retryable = false
            })
        end

        vehicleId = tonumber(vehicleId) or vehicleId
        updateJournalVehicle(operationId, tostring(vehicleId), plate)
        local created = exactVehicleByPlate(plate)
        if not created or tostring(created.id) ~= tostring(vehicleId)
            or tostring(created.citizenid or '') ~= '' or normalizeJob(created.job) ~= nil
        then
            finishJournal(operationId, 'attention', 'creation_verification_failed', 'The new Qbox row could not be matched exactly.')
            return failure('operation_requires_staff', 'The created vehicle needs staff reconciliation.', {
                operationId = operationId,
                plate = plate,
                committed = false,
                safeToRefund = false,
                retryable = false
            })
        end

        local postCreateActor, postCreateError = revalidateActor(actor, actionMode)
        if not postCreateActor then
            local deleteOk = pcall(function() return exports.qbx_vehicles:DeletePlayerVehicles('vehicleId', vehicleId) end)
            local recovered = deleteOk and exactVehicleIsAbsent(plate)
            local finalized = finishJournal(operationId, recovered and 'failed' or 'attention', 'authorization_changed',
                postCreateError and postCreateError.message or 'Fleet authorization changed after vehicle creation.')
            return failure(recovered and finalized and 'authorization_changed' or 'operation_requires_staff',
                recovered and 'Fleet authorization changed; the incomplete vehicle was removed.'
                    or 'Authorization changed and the incomplete vehicle needs staff reconciliation.', {
                    operationId = operationId,
                    plate = plate,
                    committed = false,
                    safeToRefund = externalRequestId ~= nil and recovered and finalized or false,
                    retryable = false
                })
        end
        actor = postCreateActor

        local updateOk, changed = pcall(MySQL.update.await, [[
            UPDATE `player_vehicles`
            SET `job` = ?, `garage` = ?, `type` = ?, `stored` = 1, `state` = 1
            WHERE `id` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ?
              AND `citizenid` IS NULL AND `license` IS NULL AND `job` IS NULL
            LIMIT 1
        ]], { actor.job, actor.garage.garage, catalogEntry.type, vehicleId, plate })

        if not updateOk or tonumber(changed) ~= 1 then
            local deleted = pcall(function() return exports.qbx_vehicles:DeletePlayerVehicles('vehicleId', vehicleId) end)
            local recovered = deleted and exactVehicleIsAbsent(plate)
            local finalized = finishJournal(operationId, recovered and 'failed' or 'attention', 'compatibility_update_failed',
                recovered and 'The incomplete vehicle row was removed.' or 'The incomplete vehicle row could not be removed.')
            return failure(recovered and finalized and 'creation_failed' or 'operation_requires_staff',
                recovered and 'Fleet compatibility setup failed; no vehicle was issued.' or 'The incomplete vehicle needs staff reconciliation.',
                {
                    operationId = operationId,
                    plate = plate,
                    committed = false,
                    safeToRefund = recovered and finalized,
                    retryable = false
                })
        end

        created = exactJobVehicle(actor.job, plate)
        local metadataOk, metadataError = created and tostring(created.id) == tostring(vehicleId)
            and insertActiveMetadata(actor, created, actor.job, actor.garage.garage, grade)
        if not metadataOk then
            local deleted = pcall(function() return exports.qbx_vehicles:DeletePlayerVehicles('vehicleId', vehicleId) end)
            local metadataRestored = deleteActiveMetadata(created or { id = vehicleId, plate = plate })
            local recovered = deleted and exactVehicleIsAbsent(plate)
            local fullyRecovered = recovered and metadataRestored
            local finalized = finishJournal(operationId, fullyRecovered and 'failed' or 'attention', 'metadata_commit_failed', tostring(metadataError))
            return failure(fullyRecovered and finalized and 'creation_failed' or 'operation_requires_staff',
                fullyRecovered and 'Fleet metadata failed; the incomplete vehicle and metadata were removed.'
                    or 'The incomplete vehicle or metadata needs staff reconciliation.',
                {
                    operationId = operationId,
                    plate = plate,
                    committed = false,
                    safeToRefund = fullyRecovered and finalized,
                    retryable = false
                })
        end

        if not finishJournal(operationId, 'committed') then
            return failure('journal_finalize_failed', 'The vehicle was issued but its journal needs staff attention.', {
                operationId = operationId,
                vehicleId = vehicleId,
                plate = plate,
                committed = true,
                safeToRefund = false,
                retryable = false
            })
        end

        return success(('%s was created and stored in the %s fleet.'):format(plate, actor.job), {
            operationId = operationId,
            vehicleId = vehicleId,
            plate = plate,
            committed = true,
            safeToRefund = false,
            retryable = false
        })
    end)

    if journalOptions and type(response) == 'table' and response.committed == nil then
        response.committed = false
        if response.code == 'operation_busy' or response.code == 'vehicle_busy' then
            local existing, readable = getExternalJournal(sourceResource, externalRequestId)
            local replay = readable and replayResponse(existing, externalFingerprint) or nil
            if replay then return replay end
            -- Contention can mean another copy of this request is between
            -- validation and its durable journal insert. It is retryable, but a
            -- refund is not safe until the journal proves a terminal failure.
            response.safeToRefund = false
            response.retryable = true
        else
            response.safeToRefund = false
            response.retryable = response.code == 'unexpected_error'
        end
    end
    return response
end

local function createFleetVehicle(source, garageIndex, requestedJob, model, minimumGrade)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then return actorError end
    return createVehicleForActor(actor, model, minimumGrade)
end

local function moveFleetVehicle(source, contextGarageIndex, requestedJob, rawPlate, destinationGarageIndex)
    local actor, actorError = resolveActor(source, contextGarageIndex, requestedJob)
    if not actor then return actorError end

    local plate = normalizePlate(rawPlate)
    if not plate then return failure('invalid_plate', 'Select a valid fleet vehicle.') end

    return withPlateOperation(source, plate, 'job fleet move', function()
        local vehicle, lookupError = exactJobVehicle(actor.job, plate)
        if not vehicle then return failure(lookupError == 'missing' and 'vehicle_not_found' or 'vehicle_lookup_failed', 'The fleet vehicle could not be verified.') end
        local liveVehicle, liveError = findLiveVehicle(plate)
        if not rowIsStored(vehicle) or liveVehicle or liveError then
            return failure('vehicle_not_stored', 'Only a cleanly stored vehicle can be moved between garages.')
        end

        local destination = resolveDestination(destinationGarageIndex, actor.job, rowType(vehicle))
        if not destination then return failure('invalid_destination', 'That garage is not authorized for this job and vehicle type.') end
        local originalGarage = safeStorageName(vehicle.garage)
        if not originalGarage then return failure('invalid_current_garage', 'The vehicle has no storage-safe current garage assignment.') end
        if originalGarage == destination.garage then return success('The vehicle is already assigned to that garage.', { plate = plate }) end

        local existingMetadata, metadataError = metadataFor(vehicle)
        if metadataError == 'identity_mismatch'
            or existingMetadata and (existingMetadata.status ~= 'active' or normalizeJob(existingMetadata.job) ~= actor.job)
        then
            return failure('metadata_conflict', 'That vehicle has inconsistent fleet metadata.')
        end
        local minimumGrade = existingMetadata and boundedGrade(existingMetadata.min_grade) or 0
        local operationId = startJournal(actor, {
            action = 'move_garage',
            vehicleRowId = rowKey(vehicle),
            plate = plate,
            job = actor.job,
            model = rowModel(vehicle),
            garageFrom = originalGarage,
            garageTo = destination.garage,
            minGrade = minimumGrade,
            snapshot = vehicle,
            request = { contextGarageIndex = actor.garage.index, destinationGarageIndex = destination.index }
        })
        if not operationId then return failure('journal_unavailable', 'The fleet audit journal rejected this operation.') end

        local refreshed, authorizationError = revalidateBeforeMutation(actor, nil, operationId, false)
        if not refreshed then return authorizationError end
        actor = refreshed
        local refreshedDestination = resolveDestination(destination.index, actor.job, rowType(vehicle))
        if not refreshedDestination or refreshedDestination.garage ~= destination.garage then
            finishJournal(operationId, 'failed', 'destination_changed', 'The authorized destination changed before the garage move.')
            return failure('destination_changed', 'The destination garage authorization changed.', { operationId = operationId })
        end
        destination = refreshedDestination

        local identityClause = vehicle.id ~= nil and '`id` = ? AND ' or ''
        local params = { destination.garage }
        if vehicle.id ~= nil then params[#params + 1] = vehicle.id end
        params[#params + 1] = actor.job
        params[#params + 1] = plate
        params[#params + 1] = originalGarage
        local stateClause = Framework.name ~= 'es_extended' and ' AND `state` = 1' or ''
        local ok, changed = pcall(MySQL.update.await,
            ('UPDATE `%s` SET `garage` = ? WHERE %s`job` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ? AND `garage` = ? AND `stored` = 1%s LIMIT 1')
                :format(vehicleTable(), identityClause, stateClause), params)
        if not ok or tonumber(changed) ~= 1 then
            finishJournal(operationId, 'failed', 'vehicle_changed', 'The conditional garage move changed no row.')
            return failure('vehicle_changed', 'The vehicle changed before it could be moved.', { operationId = operationId })
        end

        local current = exactJobVehicle(actor.job, plate)
        local metadataOk, metadataError = current and safeStorageName(current.garage) == destination.garage
            and insertActiveMetadata(actor, current, actor.job, destination.garage, minimumGrade)
        if not metadataOk then
            local rollbackParams = { originalGarage }
            if vehicle.id ~= nil then rollbackParams[#rollbackParams + 1] = vehicle.id end
            rollbackParams[#rollbackParams + 1] = actor.job
            rollbackParams[#rollbackParams + 1] = plate
            rollbackParams[#rollbackParams + 1] = destination.garage
            local rollbackOk, rolledBack = pcall(MySQL.update.await,
                ('UPDATE `%s` SET `garage` = ? WHERE %s`job` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ? AND `garage` = ? AND `stored` = 1%s LIMIT 1')
                    :format(vehicleTable(), identityClause, stateClause), rollbackParams)
            local frameworkRestored = rollbackOk and tonumber(rolledBack) == 1
            finishJournal(operationId, 'attention', 'metadata_commit_ambiguous',
                ('%s; framework garage rollback=%s'):format(tostring(metadataError), tostring(frameworkRestored)))
            return failure('operation_requires_staff',
                frameworkRestored and 'The garage row was restored, but fleet metadata still needs staff verification.'
                    or 'The garage move and fleet metadata need staff reconciliation.',
                { operationId = operationId, committed = false })
        end

        if not finishJournal(operationId, 'committed') then
            return failure('journal_finalize_failed', 'The garage move succeeded, but its journal needs staff attention.', {
                operationId = operationId,
                plate = plate,
                committed = true
            })
        end
        return success(('%s was moved to %s.'):format(plate, destination.label), {
            operationId = operationId,
            plate = plate
        })
    end)
end

local function updateFleetGrade(source, garageIndex, requestedJob, rawPlate, rawGrade)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then return actorError end

    local plate = normalizePlate(rawPlate)
    local grade = boundedGrade(rawGrade)
    if not plate then return failure('invalid_plate', 'Select a valid fleet vehicle.') end
    if grade == nil then return failure('invalid_grade', 'Enter a valid minimum grade.') end

    return withPlateOperation(source, plate, 'job fleet grade', function()
        local vehicle, lookupError = exactJobVehicle(actor.job, plate)
        if not vehicle then return failure(lookupError == 'missing' and 'vehicle_not_found' or 'vehicle_lookup_failed', 'The fleet vehicle could not be verified.') end

        local existing, metadataError = metadataFor(vehicle)
        if metadataError == 'identity_mismatch'
            or existing and (existing.status ~= 'active' or normalizeJob(existing.job) ~= actor.job)
        then
            return failure('metadata_conflict', 'That vehicle has inconsistent fleet metadata.')
        end
        local operationId = startJournal(actor, {
            action = 'set_min_grade',
            vehicleRowId = rowKey(vehicle),
            plate = plate,
            job = actor.job,
            model = rowModel(vehicle),
            garageFrom = safeStorageName(vehicle.garage),
            garageTo = safeStorageName(vehicle.garage),
            minGrade = grade,
            snapshot = vehicle,
            request = { previousGrade = existing and tonumber(existing.min_grade) or nil }
        })
        if not operationId then return failure('journal_unavailable', 'The fleet audit journal rejected this operation.') end

        local refreshed, authorizationError = revalidateBeforeMutation(actor, nil, operationId, false)
        if not refreshed then return authorizationError end
        actor = refreshed

        local metadataOk, metadataError = insertActiveMetadata(
            actor, vehicle, actor.job, safeStorageName(vehicle.garage) or actor.garage.garage, grade
        )
        if not metadataOk then
            finishJournal(operationId, 'attention', 'metadata_commit_ambiguous', tostring(metadataError))
            return failure('operation_requires_staff', 'The minimum-grade update needs staff verification.', {
                operationId = operationId,
                committed = false
            })
        end

        if not finishJournal(operationId, 'committed') then
            return failure('journal_finalize_failed', 'The minimum grade was saved, but its journal needs staff attention.', {
                operationId = operationId,
                plate = plate,
                committed = true
            })
        end
        return success(('%s now requires job grade %d.'):format(plate, grade), {
            operationId = operationId,
            plate = plate
        })
    end)
end

local function retireFleetVehicle(source, garageIndex, requestedJob, rawPlate, confirmation, rawReason)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then return actorError end

    local plate = normalizePlate(rawPlate)
    local confirmedPlate = normalizePlate(confirmation)
    local reason = reasonText(rawReason, true)
    if not plate or confirmedPlate ~= plate then
        return failure('confirmation_failed', 'Type the exact plate to confirm permanent retirement.')
    end
    if not reason then return failure('invalid_reason', 'Enter a retirement reason of at least three characters.') end

    return withPlateOperation(source, plate, 'job fleet retirement', function()
        local vehicle, lookupError = exactJobVehicle(actor.job, plate)
        if not vehicle then return failure(lookupError == 'missing' and 'vehicle_not_found' or 'vehicle_lookup_failed', 'The fleet vehicle could not be verified.') end
        local liveVehicle, liveError = findLiveVehicle(plate)
        if not rowIsStored(vehicle) or liveVehicle or liveError then
            return failure('vehicle_not_stored', 'Only a cleanly stored vehicle can be retired.')
        end
        if Framework.name == 'qbx_core' and vehicle.id == nil then
            return failure('missing_vehicle_id', 'Qbox retirement requires an exact vehicle row ID.')
        end

        local metadata, metadataError = metadataFor(vehicle)
        if metadataError == 'identity_mismatch'
            or metadata and (metadata.status ~= 'active' or normalizeJob(metadata.job) ~= actor.job)
        then
            return failure('metadata_conflict', 'That vehicle has inconsistent fleet metadata.')
        end
        local operationId = startJournal(actor, {
            action = 'retire_vehicle',
            vehicleRowId = rowKey(vehicle),
            plate = plate,
            job = actor.job,
            model = rowModel(vehicle),
            garageFrom = safeStorageName(vehicle.garage),
            minGrade = metadata and tonumber(metadata.min_grade) or 0,
            reason = reason,
            snapshot = vehicle,
            request = { confirmedPlate = confirmedPlate }
        })
        if not operationId then return failure('journal_unavailable', 'The fleet audit journal rejected this operation.') end

        local refreshed, authorizationError = revalidateBeforeMutation(actor, nil, operationId, false)
        if not refreshed then return authorizationError end
        actor = refreshed

        local current = exactJobVehicle(actor.job, plate)
        local currentLive, currentLiveError = findLiveVehicle(plate)
        if not current or tostring(rowKey(current)) ~= tostring(rowKey(vehicle))
            or not rowIsStored(current) or currentLive or currentLiveError
        then
            finishJournal(operationId, 'failed', 'vehicle_changed', 'The exact stored vehicle changed before permanent retirement.')
            return failure('vehicle_changed', 'The vehicle changed before it could be retired.', { operationId = operationId })
        end
        vehicle = current

        local deleted = false
        local deletionUncertain = false
        local deletionDetail = 'The exact stored vehicle row was not deleted.'
        if Framework.name == 'qbx_core' then
            local ok, result = pcall(function()
                return exports.qbx_vehicles:DeletePlayerVehicles('vehicleId', tonumber(vehicle.id) or vehicle.id)
            end)
            local remains, remainsError = exactVehicleByPlate(plate)
            deleted = remains == nil and remainsError == 'missing'
            if not deleted then
                local originalIntact = remains and tostring(rowKey(remains)) == tostring(rowKey(vehicle))
                deletionUncertain = not originalIntact or (ok and result == true)
                deletionDetail = tostring(ok and result or result)
            end
        else
            local identityClause = vehicle.id ~= nil and '`id` = ? AND ' or ''
            local params = {}
            if vehicle.id ~= nil then params[#params + 1] = vehicle.id end
            params[#params + 1] = actor.job
            params[#params + 1] = plate
            local stateClause = Framework.name ~= 'es_extended' and ' AND `state` = 1' or ''
            local ok, changed = pcall(MySQL.update.await,
                ('DELETE FROM `%s` WHERE %s`job` = ? AND BINARY UPPER(TRIM(`plate`)) = BINARY ? AND `stored` = 1%s LIMIT 1')
                    :format(vehicleTable(), identityClause, stateClause), params)
            local remains, remainsError = exactVehicleByPlate(plate)
            deleted = ok and tonumber(changed) == 1 and remains == nil and remainsError == 'missing'
            if not deleted then
                local originalIntact = remains and tostring(rowKey(remains)) == tostring(rowKey(vehicle))
                deletionUncertain = not originalIntact or (ok and tonumber(changed) == 1)
                deletionDetail = ok and ('delete changed %s row(s) but absence was not proven'):format(tostring(changed))
                    or tostring(changed)
            end
        end

        if not deleted then
            finishJournal(operationId, deletionUncertain and 'attention' or 'failed', 'vehicle_delete_failed', deletionDetail)
            return failure(deletionUncertain and 'operation_requires_staff' or 'vehicle_delete_failed',
                deletionUncertain and 'The delete result is uncertain; staff review is required.' or 'The vehicle could not be retired.',
                { operationId = operationId })
        end

        if not retireMetadata(actor, vehicle, reason) then
            finishJournal(operationId, 'attention', 'retirement_metadata_failed', 'Vehicle deleted; retirement metadata could not be finalized.')
            return failure('operation_requires_staff', 'The vehicle was removed, but its audit metadata needs staff attention.', {
                operationId = operationId,
                committed = true
            })
        end

        if not finishJournal(operationId, 'committed') then
            return failure('journal_finalize_failed', 'The vehicle was retired but its journal needs staff attention.', {
                operationId = operationId,
                committed = true
            })
        end

        return success(('%s was permanently retired from the %s fleet.'):format(plate, actor.job), {
            operationId = operationId,
            plate = plate
        })
    end)
end

local function listAuthorizedGarages(job)
    local result = {}
    for index in ipairs(Config.Garages or {}) do
        local garage = resolveGarage(index)
        if garage and garage.jobSet[job] then
            result[#result + 1] = {
                index = garage.index,
                id = garage.garage,
                label = garage.label,
                type = garage.type
            }
        end
    end
    table.sort(result, function(a, b) return a.label:lower() < b.label:lower() end)
    return result
end

local function canManageFleet(source, garageIndex, requestedJob)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then
        local ace = cleanText(settings().AcePermission, 100) or 'drs_garages.fleet.admin'
        if actorError and actorError.needsJob and IsPlayerAceAllowed(tonumber(source), ace) then
            return success('Fleet administration is authorized; choose a job.', {
                admin = true,
                needsJob = true,
                jobs = actorError.jobs
            })
        end
        return actorError or { ok = false }
    end
    return success('Fleet management is authorized.', {
        job = actor.job,
        admin = actor.admin,
        garageIndex = actor.garage.index
    })
end

local function listFleetContext(source, garageIndex, requestedJob)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob)
    if not actor then return actorError end

    local tableName = vehicleTable()
    local owner = ownerColumn()
    local fleetOk, fleetRows = pcall(MySQL.query.await,
        ('SELECT * FROM `%s` WHERE `job` = ? ORDER BY `plate` ASC LIMIT 250'):format(tableName), { actor.job })
    local personalOk, personalRows = pcall(MySQL.query.await,
        ('SELECT * FROM `%s` WHERE `%s` = ? AND `job` IS NULL ORDER BY `plate` ASC LIMIT 100'):format(tableName, owner),
        { actor.identifier })
    if not fleetOk or not personalOk then return failure('vehicle_lookup_failed', 'Fleet vehicles could not be loaded.') end

    local fleet = {}
    for _, vehicle in ipairs(fleetRows or {}) do
        local plate = normalizePlate(vehicle.plate)
        local metadata, metadataError = metadataFor(vehicle)
        if plate and metadataError ~= 'identity_mismatch' and (not metadata or metadata.status == 'active') then
            fleet[#fleet + 1] = {
                id = rowKey(vehicle),
                plate = plate,
                model = rowModel(vehicle) or 'unknown',
                type = rowType(vehicle),
                garage = safeStorageName(vehicle.garage),
                stored = rowIsStored(vehicle),
                minGrade = metadata and tonumber(metadata.min_grade) or 0,
                managed = metadata ~= nil
            }
        end
    end

    local personal = {}
    for _, vehicle in ipairs(personalRows or {}) do
        local plate = normalizePlate(vehicle.plate)
        local vehicleType = rowType(vehicle)
        local personalMetadata, personalMetadataError = metadataFor(vehicle)
        if plate and vehicleType == actor.garage.type and not personalMetadata
            and personalMetadataError ~= 'identity_mismatch'
        then
            personal[#personal + 1] = {
                id = rowKey(vehicle),
                plate = plate,
                model = rowModel(vehicle) or 'unknown',
                type = vehicleType,
                garage = safeStorageName(vehicle.garage),
                stored = rowIsStored(vehicle),
                out = rowIsOut(vehicle)
            }
        end
    end

    return success('Fleet context loaded.', {
        job = actor.job,
        actorGrade = actor.jobData.grade,
        admin = actor.admin,
        garage = {
            index = actor.garage.index,
            id = actor.garage.garage,
            label = actor.garage.label,
            type = actor.garage.type
        },
        garages = listAuthorizedGarages(actor.job),
        vehicles = fleet,
        personalVehicles = personal,
        canCreate = actorCanCreate(actor),
        canPurchase = actorCanPurchase(actor),
        catalog = actorCanCreate(actor) and catalogForActor(actor) or {}
    })
end

local function vehicleShopResource()
    local resource = cleanText(settings().VehicleShopResource, 64) or 'drs_vehicleshop'
    if resource:match('^[%w_%-]+$') then return resource end
end

local function newPurchaseToken(source)
    return ('fleetbuy-%d-%d-%06d'):format(nowMilliseconds(), tonumber(source) or 0, math.random(0, 999999))
end

local function activePurchaseSession(source)
    local session = purchaseSessions[source]
    if not session then return end
    if session.busy then return session end
    if nowMilliseconds() - session.createdAt > math.max(60000, tonumber(settings().PurchaseSessionDuration) or 300000) then
        purchaseSessions[source] = nil
        return
    end
    return session
end

local function getSocietyPurchaseCatalog(source, garageIndex, requestedJob)
    local actor, actorError = resolveActor(source, garageIndex, requestedJob, 'society_purchase_ui')
    if not actor then return actorError end
    if not actorCanPurchase(actor) then
        return failure('purchase_not_authorized', 'Only the exact current-job boss can purchase society vehicles.')
    end

    local existing = activePurchaseSession(source)
    if existing and existing.identifier ~= actor.identifier then
        purchaseSessions[source] = nil
        existing = nil
    end
    if existing and existing.busy then return failure('purchase_processing', 'A society purchase is already processing.', {
        retryable = true
    }) end
    if existing and existing.requestId and existing.result and existing.result.retryable == true
        and existing.job == actor.job and existing.garageIndex == actor.garage.index
    then
        return success('The prior purchase can be retried safely with the same request ID.', {
            token = existing.token,
            job = existing.job,
            account = existing.account,
            bankProvider = existing.bankProvider,
            balance = existing.balance,
            balanceUnavailable = existing.balanceUnavailable == true,
            vehicles = existing.vehicles,
            retrying = true
        })
    end
    if existing and existing.result and existing.result.review == true then
        return failure('purchase_review', existing.result.message or 'The previous society purchase requires staff review.', {
            review = true,
            orderId = existing.result.orderId,
            requestId = existing.requestId
        })
    end

    local resource = vehicleShopResource()
    if not resource or GetResourceState(resource) ~= 'started' then
        return failure('vehicle_shop_unavailable', 'DRS Vehicle Shop is not started.')
    end

    local called, catalog = pcall(function()
        return exports[resource]:GetFleetCatalog({ actorSource = source, job = actor.job })
    end)
    if not called or type(catalog) ~= 'table' or catalog.ok ~= true then
        return failure(type(catalog) == 'table' and catalog.code or 'vehicle_shop_unavailable',
            type(catalog) == 'table' and catalog.message or 'The society vehicle catalog is unavailable.')
    end

    local refreshed, refreshError = revalidateActor(actor, 'society_purchase_ui')
    if not refreshed or not actorCanPurchase(refreshed) then
        return refreshError or failure('authorization_changed', 'Purchase authorization changed while loading the catalog.')
    end
    actor = refreshed

    local vehicles, allowed = {}, {}
    for _, shopVehicle in pairs(type(catalog.vehicles) == 'table' and catalog.vehicles or {}) do
        if type(shopVehicle) == 'table' then
            local model = normalizeModel(shopVehicle.model)
            local fleetEntry = model and catalogVehicle(model, actor.job) or nil
            local shopType = normalizeVehicleType(shopVehicle.vehicleType or shopVehicle.type or 'car')
            local price = tonumber(shopVehicle.price)
            if fleetEntry and fleetEntry.type == actor.garage.type and shopType == fleetEntry.type
                and price and price >= 0 and price % 1 == 0
            then
                price = math.floor(price)
                allowed[model] = true
                vehicles[#vehicles + 1] = {
                    model = model,
                    name = cleanText(shopVehicle.name or fleetEntry.label, 80) or model,
                    brand = cleanText(shopVehicle.brand, 50),
                    category = cleanText(shopVehicle.category, 50),
                    type = fleetEntry.type,
                    price = price
                }
            end
        end
    end
    table.sort(vehicles, function(a, b)
        if a.price == b.price then return a.name:lower() < b.name:lower() end
        return a.price < b.price
    end)
    if #vehicles == 0 then
        return failure('no_purchase_models', 'No vehicle-shop models also match this job fleet allowlist and garage type.')
    end

    local recoveryRequestId, recoveryModel, recoveryStatus
    if type(catalog.recovery) == 'table' then
        recoveryRequestId = safeRequestId(catalog.recovery.requestId)
        recoveryModel = normalizeModel(catalog.recovery.model)
        recoveryStatus = cleanText(catalog.recovery.status, 32)
        local recoveryGarage = tonumber(catalog.recovery.garageIndex)
        local recoveredVehicle
        for _, vehicle in ipairs(vehicles) do
            if vehicle.model == recoveryModel then recoveredVehicle = vehicle break end
        end
        if catalog.recovery.retryable ~= true or not recoveryRequestId or not recoveryModel
            or not recoveryGarage or recoveryGarage % 1 ~= 0
            or math.floor(recoveryGarage) ~= actor.garage.index or not recoveredVehicle
        then
            return failure('purchase_recovery_invalid',
                'A prior society purchase needs staff review because its recovery details no longer match this fleet.', {
                    review = true
                })
        end
        vehicles = { recoveredVehicle }
        allowed = { [recoveryModel] = true }
    end

    local token = newPurchaseToken(source)
    purchaseSessions[source] = {
        token = token,
        createdAt = nowMilliseconds(),
        source = source,
        identifier = actor.identifier,
        job = actor.job,
        garageIndex = actor.garage.index,
        vehicles = vehicles,
        allowed = allowed,
        requestId = recoveryRequestId,
        requestModel = recoveryModel,
        recoveryStatus = recoveryStatus,
        account = cleanText(catalog.account, 32),
        bankProvider = cleanText(catalog.bankProvider, 64),
        balance = math.max(0, math.floor(tonumber(catalog.balance) or 0)),
        balanceUnavailable = catalog.balanceUnavailable == true
    }

    return success('Society purchase catalog loaded.', {
        token = token,
        job = actor.job,
        account = purchaseSessions[source].account,
        bankProvider = purchaseSessions[source].bankProvider,
        balance = purchaseSessions[source].balance,
        balanceUnavailable = purchaseSessions[source].balanceUnavailable,
        vehicles = vehicles,
        retrying = recoveryRequestId ~= nil,
        recoveryStatus = recoveryStatus
    })
end

local function purchaseSocietyVehicle(source, token, rawModel, rawReason)
    token = safeRequestId(token)
    local model = normalizeModel(rawModel)
    local session = token and activePurchaseSession(source) or nil
    if not session or session.token ~= token or not model or session.allowed[model] ~= true then
        return failure('purchase_session_invalid', 'The society purchase session expired or changed.')
    end
    if session.busy then return failure('purchase_processing', 'This society purchase is already processing.', {
        retryable = true
    }) end
    if session.requestModel and session.requestModel ~= model then
        return failure('idempotency_mismatch', 'This purchase session is already bound to a different model.', {
            review = true
        })
    end

    local actor, actorError = resolveActor(source, session.garageIndex, session.job, 'society_purchase_ui')
    if not actor then return actorError end
    if actor.identifier ~= session.identifier or not actorCanPurchase(actor) then
        return failure('authorization_changed', 'Society purchase authorization changed.')
    end

    local resource = vehicleShopResource()
    if not resource or GetResourceState(resource) ~= 'started' then
        return failure('vehicle_shop_unavailable', 'DRS Vehicle Shop is not started.', { retryable = true })
    end

    session.requestModel = model
    session.requestId = session.requestId or ('fleetbuy:%s'):format(session.token)
    session.busy = true
    local called, result = pcall(function()
        return exports[resource]:PurchaseFleetVehicle({
            requestId = session.requestId,
            actorSource = source,
            action = 'society_purchase',
            job = session.job,
            model = model,
            garageIndex = session.garageIndex,
            reason = reasonText(rawReason, false)
        })
    end)
    session.busy = false

    if not called or type(result) ~= 'table' then
        result = failure('purchase_result_unknown', 'The vehicle shop call returned an uncertain result. Retry the same session; do not purchase again.', {
            retryable = true,
            review = true,
            requestId = session.requestId
        })
    end
    session.result = result

    return {
        ok = result.ok == true,
        code = cleanText(result.code, 100),
        message = cleanText(result.message, 500) or 'Society purchase completed.',
        committed = result.committed == true,
        retryable = result.retryable == true,
        review = result.review == true,
        orderId = cleanText(result.orderId, 64),
        requestId = cleanText(result.requestId or session.requestId, 64),
        operationId = cleanText(result.operationId, 64),
        vehicleId = tonumber(result.vehicleId) or cleanText(result.vehicleId, 64),
        plate = normalizePlate(result.plate),
        status = cleanText(result.status, 32),
        amount = tonumber(result.amount) and math.max(0, math.floor(tonumber(result.amount))) or nil,
        model = normalizeModel(result.model or model),
        job = normalizeJob(result.job or session.job)
    }
end

local function trustedResource(name)
    local configured = settings().TrustedResources
    if type(configured) ~= 'table' then return name == (vehicleShopResource() or 'drs_vehicleshop') end
    if configured[name] == true then return true end
    for _, value in pairs(configured) do if value == name then return true end end
    return false
end

safeRequestId = function(value)
    local requestId = cleanText(value, 64)
    if requestId and requestId:match('^[%w_.:%-]+$') then return requestId end
end

local function createFromTrustedResource(request)
    local invokingResource = cleanText(GetInvokingResource(), 64)
    if not invokingResource or not trustedResource(invokingResource) then
        return failure('untrusted_resource', 'The invoking resource is not authorized to issue fleet vehicles.', {
            committed = false, safeToRefund = true, retryable = false
        })
    end
    if type(request) ~= 'table' then return failure('invalid_request', 'A fleet issuance request is required.', {
        committed = false, safeToRefund = true, retryable = false
    }) end

    local requestId = safeRequestId(request.requestId)
    local actorSource = tonumber(request.actorSource)
    local action = request.action == 'society_purchase' and 'society_purchase'
        or request.action == 'admin_grant' and 'admin_grant'
        or nil
    local requestJob = normalizeJob(request.job)
    local requestModel = normalizeModel(request.model)
    local requestGarageIndex = tonumber(request.garageIndex)
    local requestMinimumGrade = boundedGrade(request.minGrade or 0)
    local requestReason = reasonText(request.reason, false)
    local requestPlayer = actorSource and Framework and Framework.getPlayerFromId(actorSource) or nil
    local requestActorIdentifier = playerIdentity(requestPlayer)
    if not requestId or not actorSource or actorSource < 1 or actorSource % 1 ~= 0
        or not action or not requestJob or not requestModel
        or not requestGarageIndex or requestGarageIndex % 1 ~= 0 or requestMinimumGrade == nil
    then
        return failure('invalid_request', 'requestId, actorSource, and a supported action are required.', {
            committed = false, safeToRefund = true, retryable = false
        })
    end
    actorSource = math.floor(actorSource)
    requestGarageIndex = math.floor(requestGarageIndex)
    local fingerprintGarage = resolveGarage(requestGarageIndex)
    local fingerprint = {
        action = action,
        actorSource = actorSource,
        actorIdentifier = requestActorIdentifier,
        job = requestJob,
        model = requestModel,
        garageIndex = requestGarageIndex,
        garageId = fingerprintGarage and fingerprintGarage.garage or nil,
        minGrade = requestMinimumGrade,
        reason = requestReason or ''
    }

    if not serviceReady then
        return failure('fleet_service_not_ready', serviceDetail, {
            committed = false, safeToRefund = false, retryable = true
        })
    end

    local existing, journalReadable = getExternalJournal(invokingResource, requestId)
    if not journalReadable then
        return failure('journal_unavailable', 'The fleet idempotency journal could not be read.', {
            committed = false, safeToRefund = false, retryable = true
        })
    end
    local replay = replayResponse(existing, fingerprint)
    if replay then return replay end

    local actor, actorError = resolveActor(actorSource, requestGarageIndex, requestJob, action)
    if not actor then
        actorError.committed = false
        actorError.safeToRefund = true
        actorError.retryable = actorError.code == 'database_unavailable'
        return actorError
    end
    if requestJob ~= actor.job then return failure('job_changed', 'The actor no longer controls the requested job.', {
        committed = false, safeToRefund = true, retryable = false
    }) end

    return createVehicleForActor(actor, requestModel, requestMinimumGrade, {
        requestId = requestId,
        sourceResource = invokingResource,
        action = action,
        reason = requestReason
    })
end

local function recoverPendingOperations()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT * FROM `drs_job_fleet_operations`
        WHERE `status` = 'pending'
        ORDER BY `created_at` ASC
        LIMIT 500
    ]])
    if not ok or type(rows) ~= 'table' then return false end

    for _, operation in ipairs(rows) do
        reconcilePendingOperation(operation, 'recovered_after_restart')
    end
    return true
end

local function loadFleetQuarantine()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT `operation_id`, `plate`
        FROM `drs_job_fleet_operations`
        WHERE `status` IN ('pending', 'attention')
    ]])
    if not ok or type(rows) ~= 'table' then return false end

    quarantinedPlates = {}
    for _, operation in ipairs(rows) do
        local plate = normalizePlate(operation.plate)
        if plate then
            operationPlates[operation.operation_id] = plate
            quarantinedPlates[plate] = operation.operation_id
            synchronizeExternalQuarantine(plate)
        end
    end
    return true
end

function CanAccessDrsFleetVehicle(source, vehicle)
    if type(vehicle) ~= 'table' or not vehicle.job or vehicle.job == '' then return true end
    if enabled() and not serviceReady then return false end
    local metadata, metadataError = metadataFor(vehicle)
    if metadataError == 'identity_mismatch' then return false end
    if metadata and metadata.status ~= 'active' then return false end

    source = tonumber(source)
    local player = source and Framework and Framework.getPlayerFromId(source)
    if not player then return false end
    if settings().AdminCanUseVehicles == true then
        local ace = cleanText(settings().AcePermission, 100) or 'drs_garages.fleet.admin'
        if IsPlayerAceAllowed(source, ace) then return true end
    end

    local jobData = playerJobData(player)
    local requiredJob = normalizeJob(metadata and metadata.job or vehicle.job)
    local requiredGrade = metadata and (tonumber(metadata.min_grade) or 0) or 0
    return requiredJob ~= nil and jobData.name == requiredJob and jobData.grade >= requiredGrade
end

function GetDrsFleetVehicleMetadata(vehicle)
    local metadata = type(vehicle) == 'table' and metadataFor(vehicle)
        or metadataByPlate[normalizePlate(vehicle)]
    if not metadata then return end

    return {
        vehicleRowId = metadata.vehicle_row_id,
        plate = metadata.plate,
        job = metadata.job,
        model = metadata.model,
        type = metadata.vehicle_type,
        garage = metadata.garage,
        minGrade = tonumber(metadata.min_grade) or 0,
        status = metadata.status
    }
end

function GetDrsFleetDiagnosticSnapshot()
    local active, retired, unresolved = 0, 0, 0
    local statusQueryOk = false
    local statusQueryDetail = serviceReady and 'job-fleet operation status has not been queried'
        or 'job-fleet service is not ready'
    for _, row in pairs(metadataByRow) do
        if row.status == 'active' then active = active + 1 else retired = retired + 1 end
    end
    if serviceReady then
        local ok, count = pcall(MySQL.scalar.await, [[
            SELECT COUNT(*) FROM `drs_job_fleet_operations` WHERE `status` IN ('pending', 'attention')
        ]])
        if ok and tonumber(count) ~= nil then
            unresolved = math.max(0, math.floor(tonumber(count)))
            statusQueryOk = true
            statusQueryDetail = 'job-fleet operation status query completed'
        else
            statusQueryDetail = ('job-fleet operation status query failed: %s'):format(tostring(count))
        end
    end
    return {
        enabled = enabled(),
        ready = serviceReady,
        detail = serviceDetail,
        activeVehicles = active,
        retiredVehicles = retired,
        unresolvedOperations = unresolved,
        statusQueryOk = statusQueryOk,
        statusQueryDetail = statusQueryDetail
    }
end

function GetDrsFleetServiceStatus()
    local isEnabled = enabled()
    local mainDatabaseReady = false
    local snapshot = GetDrsFleetDiagnosticSnapshot()
    if serviceReady then
        local checker = rawget(_G, 'CanUseDrsGarageDatabase')
        if type(checker) == 'function' then
            local checked, usable = pcall(checker, 0)
            mainDatabaseReady = checked and usable == true
        end
    end
    local journalStatusReady = snapshot.statusQueryOk == true
    local ready = isEnabled and serviceReady and mainDatabaseReady and journalStatusReady
    local detail = serviceDetail
    if isEnabled and serviceReady and not mainDatabaseReady then
        detail = 'the main garage database setup or startup reconciliation is not ready'
    elseif isEnabled and serviceReady and mainDatabaseReady and not journalStatusReady then
        detail = snapshot.statusQueryDetail or 'the job-fleet operation journal could not be inspected'
    end
    return {
        ok = ready,
        ready = ready,
        enabled = isEnabled,
        code = ready and 'fleet_ready' or (isEnabled and 'fleet_not_ready' or 'fleet_disabled'),
        message = detail,
        detail = detail
    }
end

function IsDrsGarageFleetPlateBlocked(rawPlate)
    local plate = normalizePlate(rawPlate)
    if not plate then return true end
    if not enabled() then return false end
    return not serviceReady or quarantinedPlates[plate] ~= nil
end

local function fleetAdminAllowed(source)
    if tonumber(source) == 0 then return true end
    local ace = cleanText(settings().AcePermission, 100) or 'drs_garages.fleet.admin'
    return IsPlayerAceAllowed(tonumber(source), ace) == true
end

local function commandOutput(source, message)
    message = cleanText(message, 500, true) or ''
    if tonumber(source) == 0 then
        print(('[drs_garages][fleet] %s'):format(message))
    else
        TriggerClientEvent('chat:addMessage', source, {
            color = { 52, 211, 153 },
            args = { 'DRS Fleet', message }
        })
    end
end

RegisterCommand('drsgarages:fleetops', function(source, args)
    if not fleetAdminAllowed(source) then
        commandOutput(source, 'You do not have the configured fleet administrator ACE permission.')
        return
    end
    if not serviceReady then
        commandOutput(source, ('Fleet service unavailable: %s'):format(serviceDetail))
        return
    end

    local plateFilter = args and args[1] and normalizePlate(args[1]) or nil
    if args and args[1] and not plateFilter then
        commandOutput(source, 'Usage: drsgarages:fleetops [plate]')
        return
    end

    local query = [[
        SELECT `operation_id`, `action`, `status`, `plate`, `job`, `model`, `garage_to`,
               `actor_identifier`, `source_resource`, `error_code`, `error_detail`, `created_at`
        FROM `drs_job_fleet_operations`
        WHERE `status` = 'attention'
    ]]
    local values = {}
    if plateFilter then
        query = query .. ' AND BINARY `plate` = BINARY ?'
        values[1] = plateFilter
    end
    query = query .. ' ORDER BY `created_at` ASC LIMIT 50'

    local ok, rows = pcall(MySQL.query.await, query, values)
    if not ok or type(rows) ~= 'table' then
        commandOutput(source, 'The unresolved fleet journal could not be read.')
        return
    end
    if #rows == 0 then
        commandOutput(source, plateFilter and ('No unresolved operation exists for %s.'):format(plateFilter)
            or 'No unresolved fleet operations exist.')
        return
    end

    commandOutput(source, ('%d fleet operation(s) requiring attention:'):format(#rows))
    for _, row in ipairs(rows) do
        commandOutput(source, ('%s | %s | %s | %s/%s | %s'):format(
            tostring(row.operation_id),
            tostring(row.status),
            tostring(row.action),
            tostring(row.job),
            tostring(row.plate),
            tostring(row.error_code or row.error_detail or 'no error detail')
        ))
    end
end, false)

RegisterCommand('drsgarages:fleetresolve', function(source, args)
    if not fleetAdminAllowed(source) then
        commandOutput(source, 'You do not have the configured fleet administrator ACE permission.')
        return
    end
    if not serviceReady then
        commandOutput(source, ('Fleet service unavailable: %s'):format(serviceDetail))
        return
    end

    local operationId = args and cleanText(args[1], 64) or nil
    local resolution = args and cleanText(args[2], 16) or nil
    resolution = resolution and resolution:lower() or nil
    local reason = args and reasonText(table.concat(args, ' ', 3), true) or nil
    if not operationId or not operationId:match('^[%w_.:%-]+$')
        or (resolution ~= 'committed' and resolution ~= 'failed') or not reason
    then
        commandOutput(source, 'Usage: drsgarages:fleetresolve <operationId> <committed|failed> <reason>')
        return
    end

    local ok, operation = pcall(MySQL.single.await, [[
        SELECT `operation_id`, `plate`, `status`
        FROM `drs_job_fleet_operations`
        WHERE BINARY `operation_id` = BINARY ?
        LIMIT 1
    ]], { operationId })
    if not ok or not operation then
        commandOutput(source, 'That fleet operation was not found.')
        return
    end
    if operation.status ~= 'attention' then
        commandOutput(source, ('Manual resolution refused: %s is %s, not attention.'):format(operationId, tostring(operation.status)))
        return
    end

    local plate = normalizePlate(operation.plate)
    if not plate then
        commandOutput(source, 'Manual resolution refused because the journal plate is invalid.')
        return
    end
    if not fleetAdminAllowed(source) then
        commandOutput(source, 'Authorization changed before the resolution could be committed.')
        return
    end
    operationPlates[operationId] = plate
    local at = nowMilliseconds()
    local detail = cleanText(('%s: %s'):format(
        tonumber(source) == 0 and 'console' or (GetPlayerName(source) or tostring(source)),
        reason
    ), 500)
    local resolvedOk, changed = pcall(MySQL.update.await, [[
        UPDATE `drs_job_fleet_operations`
        SET `status` = ?, `error_code` = 'manually_resolved', `error_detail` = ?,
            `updated_at` = ?, `completed_at` = ?
        WHERE BINARY `operation_id` = BINARY ? AND `status` = 'attention'
        LIMIT 1
    ]], { resolution, detail, at, at, operationId })
    local finalized = resolvedOk and tonumber(changed) == 1
    if not finalized then
        local readOk, current = pcall(MySQL.single.await, [[
            SELECT `status`, `error_code`, `error_detail`, `completed_at`
            FROM `drs_job_fleet_operations`
            WHERE BINARY `operation_id` = BINARY ?
            LIMIT 1
        ]], { operationId })
        finalized = readOk and current and current.status == resolution
            and current.error_code == 'manually_resolved'
            and tostring(current.error_detail or '') == tostring(detail or '')
            and current.completed_at ~= nil
    end
    if not finalized then
        commandOutput(source, 'The attention row changed or the resolution could not be committed.')
        return
    end
    operationPlates[operationId] = nil

    if not refreshPlateQuarantine(plate) then
        quarantinedPlates[plate] = operationId
        synchronizeExternalQuarantine(plate)
        commandOutput(source, 'Resolution saved, but the plate quarantine could not be revalidated; it remains locked.')
        return
    end
    commandOutput(source, ('Resolved %s as %s. Plate %s quarantine state was refreshed.'):format(
        operationId,
        resolution,
        plate
    ))
end, false)

exports('CanAccessJobFleetVehicle', CanAccessDrsFleetVehicle)
exports('GetJobFleetVehicleMetadata', GetDrsFleetVehicleMetadata)
exports('GetJobFleetDiagnosticSnapshot', GetDrsFleetDiagnosticSnapshot)
exports('GetJobFleetServiceStatus', GetDrsFleetServiceStatus)
exports('GetFleetServiceStatus', GetDrsFleetServiceStatus)
exports('CreateJobFleetVehicle', createFromTrustedResource)
exports('IsJobFleetPlateBlocked', IsDrsGarageFleetPlateBlocked)

lib.callback.register('drs_garages:fleet:getContext', listFleetContext)
lib.callback.register('drs_garages:fleet:canManage', canManageFleet)
lib.callback.register('drs_garages:fleet:getPurchaseCatalog', getSocietyPurchaseCatalog)
lib.callback.register('drs_garages:fleet:purchaseSocietyVehicle', purchaseSocietyVehicle)
lib.callback.register('drs_garages:fleet:registerPersonal', registerPersonalVehicle)
lib.callback.register('drs_garages:fleet:createVehicle', createFleetVehicle)
lib.callback.register('drs_garages:fleet:moveVehicle', moveFleetVehicle)
lib.callback.register('drs_garages:fleet:setMinimumGrade', updateFleetGrade)
lib.callback.register('drs_garages:fleet:retireVehicle', retireFleetVehicle)

AddEventHandler('playerDropped', function()
    sourceLocks[source] = nil
    purchaseSessions[source] = nil
end)

local function validateFleetTableDefinitions()
    local schemaOk, schemaName = pcall(MySQL.scalar.await, 'SELECT DATABASE()')
    if not schemaOk or type(schemaName) ~= 'string' or schemaName == '' then
        return false, 'the active database schema could not be identified'
    end

    local tableOk, tableRows = pcall(MySQL.query.await, [[
        SELECT `TABLE_NAME`, `ENGINE`, `TABLE_COLLATION`
        FROM information_schema.TABLES
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` IN ('drs_job_fleet_vehicles', 'drs_job_fleet_operations')
    ]], { schemaName })
    if not tableOk or type(tableRows) ~= 'table' then return false, 'job-fleet table definitions could not be inspected' end

    local function value(row, key)
        return row and (row[key] ~= nil and row[key] or row[key:lower()])
    end
    local tables = {}
    for _, row in ipairs(tableRows) do tables[tostring(value(row, 'TABLE_NAME'))] = row end
    for _, tableName in ipairs({ FLEET_TABLE, OPERATIONS_TABLE }) do
        local row = tables[tableName]
        if not row then return false, ('%s is missing'):format(tableName) end
        if tostring(value(row, 'ENGINE') or ''):lower() ~= 'innodb' then
            return false, ('%s must use InnoDB'):format(tableName)
        end
        if tostring(value(row, 'TABLE_COLLATION') or ''):lower() ~= 'utf8mb4_unicode_ci' then
            return false, ('%s must use utf8mb4_unicode_ci'):format(tableName)
        end
    end

    local columnOk, columnRows = pcall(MySQL.query.await, [[
        SELECT `TABLE_NAME`, `COLUMN_NAME`, `DATA_TYPE`, `COLUMN_TYPE`, `IS_NULLABLE`,
               `CHARACTER_MAXIMUM_LENGTH`, `COLUMN_DEFAULT`, `CHARACTER_SET_NAME`, `COLLATION_NAME`
        FROM information_schema.COLUMNS
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` IN ('drs_job_fleet_vehicles', 'drs_job_fleet_operations')
    ]], { schemaName })
    if not columnOk or type(columnRows) ~= 'table' then return false, 'job-fleet columns could not be inspected' end

    local columns = { [FLEET_TABLE] = {}, [OPERATIONS_TABLE] = {} }
    for _, row in ipairs(columnRows) do
        local tableName = tostring(value(row, 'TABLE_NAME'))
        local columnName = tostring(value(row, 'COLUMN_NAME'))
        if columns[tableName] then columns[tableName][columnName] = row end
    end

    local function checkColumn(tableName, columnName, expected)
        local row = columns[tableName] and columns[tableName][columnName]
        if not row then return false, ('%s.%s is missing'):format(tableName, columnName) end
        local dataType = tostring(value(row, 'DATA_TYPE') or ''):lower()
        if dataType ~= expected.type then
            return false, ('%s.%s must be %s'):format(tableName, columnName, expected.type)
        end
        local nullable = tostring(value(row, 'IS_NULLABLE') or ''):upper() == 'YES'
        if nullable ~= expected.nullable then
            return false, ('%s.%s has incompatible nullability'):format(tableName, columnName)
        end
        if expected.length and (tonumber(value(row, 'CHARACTER_MAXIMUM_LENGTH')) or 0) < expected.length then
            return false, ('%s.%s must allow at least %d characters'):format(tableName, columnName, expected.length)
        end
        if expected.unsigned and not tostring(value(row, 'COLUMN_TYPE') or ''):lower():find('unsigned', 1, true) then
            return false, ('%s.%s must be unsigned'):format(tableName, columnName)
        end
        if expected.charset and tostring(value(row, 'CHARACTER_SET_NAME') or ''):lower() ~= expected.charset then
            return false, ('%s.%s must use %s'):format(tableName, columnName, expected.charset)
        end
        if expected.collation and tostring(value(row, 'COLLATION_NAME') or ''):lower() ~= expected.collation then
            return false, ('%s.%s must use %s'):format(tableName, columnName, expected.collation)
        end
        if expected.default ~= nil then
            local actual = tostring(value(row, 'COLUMN_DEFAULT') or ''):gsub("^'(.*)'$", '%1')
            if actual ~= tostring(expected.default) then
                return false, ('%s.%s must default to %s'):format(tableName, columnName, tostring(expected.default))
            end
        end
        return true
    end

    local required = {
        [FLEET_TABLE] = {
            vehicle_row_id = { type = 'varchar', length = 64, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
            plate = { type = 'varchar', length = 8, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
            job = { type = 'varchar', length = 50, nullable = false },
            model = { type = 'varchar', length = 64, nullable = false },
            vehicle_type = { type = 'varchar', length = 20, nullable = false },
            garage = { type = 'varchar', length = 50, nullable = false },
            min_grade = { type = 'int', nullable = false, unsigned = true, default = 0 },
            status = { type = 'varchar', length = 16, nullable = false, default = 'active' },
            added_by_identifier = { type = 'varchar', length = 80, nullable = false },
            added_by_name = { type = 'varchar', length = 100, nullable = false },
            added_at = { type = 'bigint', nullable = false, unsigned = true },
            updated_at = { type = 'bigint', nullable = false, unsigned = true },
            retired_at = { type = 'bigint', nullable = true, unsigned = true },
            retire_reason = { type = 'varchar', length = 500, nullable = true }
        },
        [OPERATIONS_TABLE] = {
            operation_id = { type = 'varchar', length = 64, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
            external_request_id = { type = 'varchar', length = 64, nullable = true, charset = 'ascii', collation = 'ascii_bin' },
            action = { type = 'varchar', length = 32, nullable = false },
            status = { type = 'varchar', length = 16, nullable = false, default = 'pending' },
            vehicle_row_id = { type = 'varchar', length = 64, nullable = true, charset = 'ascii', collation = 'ascii_bin' },
            plate = { type = 'varchar', length = 8, nullable = false, charset = 'ascii', collation = 'ascii_bin' },
            job = { type = 'varchar', length = 50, nullable = false },
            model = { type = 'varchar', length = 64, nullable = true },
            garage_from = { type = 'varchar', length = 50, nullable = true },
            garage_to = { type = 'varchar', length = 50, nullable = true },
            min_grade = { type = 'int', nullable = true, unsigned = true },
            actor_source = { type = 'int', nullable = false, unsigned = true, default = 0 },
            actor_identifier = { type = 'varchar', length = 80, nullable = false },
            actor_name = { type = 'varchar', length = 100, nullable = false },
            actor_job = { type = 'varchar', length = 50, nullable = true },
            actor_grade = { type = 'int', nullable = false, default = 0 },
            source_resource = { type = 'varchar', length = 64, nullable = false, default = 'drs_garages' },
            reason = { type = 'varchar', length = 500, nullable = true },
            vehicle_snapshot = { type = 'longtext', nullable = true },
            request_json = { type = 'longtext', nullable = true },
            error_code = { type = 'varchar', length = 100, nullable = true },
            error_detail = { type = 'varchar', length = 500, nullable = true },
            created_at = { type = 'bigint', nullable = false, unsigned = true },
            updated_at = { type = 'bigint', nullable = false, unsigned = true },
            completed_at = { type = 'bigint', nullable = true, unsigned = true }
        }
    }
    for tableName, definitions in pairs(required) do
        for columnName, expected in pairs(definitions) do
            local compatible, detail = checkColumn(tableName, columnName, expected)
            if not compatible then return false, detail end
        end
    end
    return true, schemaName
end

local function validateTables()
    local ok = pcall(MySQL.query.await, [[
        SELECT `vehicle_row_id`, `plate`, `job`, `model`, `vehicle_type`, `garage`, `min_grade`, `status`,
               `added_by_identifier`, `added_by_name`, `added_at`, `updated_at`, `retired_at`, `retire_reason`
        FROM `drs_job_fleet_vehicles` LIMIT 0
    ]])
    if not ok then return false, 'drs_job_fleet_vehicles is missing or incompatible' end

    ok = pcall(MySQL.query.await, [[
        SELECT `operation_id`, `external_request_id`, `action`, `status`, `vehicle_row_id`, `plate`, `job`,
               `model`, `garage_from`, `garage_to`, `min_grade`, `actor_source`, `actor_identifier`,
               `actor_name`, `actor_job`, `actor_grade`, `source_resource`, `reason`, `vehicle_snapshot`,
               `request_json`, `error_code`, `error_detail`, `created_at`, `updated_at`, `completed_at`
        FROM `drs_job_fleet_operations` LIMIT 0
    ]])
    if not ok then return false, 'drs_job_fleet_operations is missing or incompatible' end

    local definitionsOk, schemaName = validateFleetTableDefinitions()
    if not definitionsOk then return false, schemaName end

    local indexOk, rows = pcall(MySQL.query.await, [[
        SELECT `TABLE_NAME`, `INDEX_NAME`, `NON_UNIQUE`, `SEQ_IN_INDEX`, `COLUMN_NAME`, `SUB_PART`
        FROM information_schema.STATISTICS
        WHERE `TABLE_SCHEMA` = ? AND `TABLE_NAME` IN ('drs_job_fleet_vehicles', 'drs_job_fleet_operations')
        ORDER BY `TABLE_NAME`, `INDEX_NAME`, `SEQ_IN_INDEX`
    ]], { schemaName })
    if not indexOk or type(rows) ~= 'table' then return false, 'job-fleet indexes could not be inspected' end

    local indexes = {}
    for _, row in ipairs(rows) do
        local key = ('%s:%s'):format(tostring(row.TABLE_NAME or row.table_name), tostring(row.INDEX_NAME or row.index_name))
        indexes[key] = indexes[key] or {
            nonUnique = tonumber(row.NON_UNIQUE or row.non_unique),
            columns = {},
            full = true
        }
        local sequence = tonumber(row.SEQ_IN_INDEX or row.seq_in_index)
        if sequence then indexes[key].columns[sequence] = tostring(row.COLUMN_NAME or row.column_name):lower() end
        if row.SUB_PART ~= nil or row.sub_part ~= nil then indexes[key].full = false end
    end

    local function exactIndex(tableName, indexName, unique, expected)
        local definition = indexes[('%s:%s'):format(tableName, indexName)]
        if not definition or definition.full ~= true then return false end
        if unique and definition.nonUnique ~= 0 then return false end
        if not unique and definition.nonUnique ~= 1 then return false end
        if #definition.columns ~= #expected then return false end
        for index, column in ipairs(expected) do
            if definition.columns[index] ~= column then return false end
        end
        return true
    end

    if not exactIndex(FLEET_TABLE, 'PRIMARY', true, { 'vehicle_row_id' })
        or not exactIndex(FLEET_TABLE, 'ux_drs_job_fleet_plate', true, { 'plate' })
    then
        return false, 'drs_job_fleet_vehicles is missing its exact primary or unique plate invariant'
    end
    if not exactIndex(OPERATIONS_TABLE, 'PRIMARY', true, { 'operation_id' })
        or not exactIndex(OPERATIONS_TABLE, 'ux_drs_job_fleet_external_request', true, { 'source_resource', 'external_request_id' })
    then
        return false, 'drs_job_fleet_operations is missing its exact primary or idempotency invariant'
    end
    return true
end

MySQL.ready(function()
    if not enabled() then
        serviceDetail = 'job fleet management is disabled'
        return
    end

    local autoMigrate = not (type(Config.Database) == 'table' and Config.Database.AutoMigrate == false)
    if autoMigrate then
        local fleetOk, fleetError = pcall(MySQL.query.await, CREATE_FLEET_TABLE)
        local journalOk, journalError = pcall(MySQL.query.await, CREATE_OPERATIONS_TABLE)
        if not fleetOk or not journalOk then
            serviceDetail = ('automatic job-fleet migration failed: %s'):format(tostring(fleetOk and journalError or fleetError))
            print(('[drs_garages] ERROR: %s'):format(serviceDetail))
            return
        end
    end

    local valid, validationError = validateTables()
    if not valid then
        serviceDetail = ('%s; back up these DRS tables, restore the definitions from sql/drs_job_fleet.sql, and restart DRS Garages')
            :format(validationError)
        print(('[drs_garages] ERROR: %s'):format(serviceDetail))
        return
    end
    if not loadMetadataCache() then
        serviceDetail = 'job-fleet metadata cache could not be loaded'
        print(('[drs_garages] ERROR: %s'):format(serviceDetail))
        return
    end
    if not recoverPendingOperations() then
        serviceDetail = 'job-fleet startup recovery could not inspect pending operations'
        print(('[drs_garages] ERROR: %s'):format(serviceDetail))
        return
    end
    if not loadFleetQuarantine() then
        serviceDetail = 'job-fleet unresolved-operation quarantine could not be loaded'
        print(('[drs_garages] ERROR: %s'):format(serviceDetail))
        return
    end

    serviceReady = true
    serviceDetail = autoMigrate and 'job-fleet schema, cache, and recovery are ready'
        or 'job-fleet schema validated with automatic migration disabled'
    print(('[drs_garages] %s.'):format(serviceDetail))
end)
