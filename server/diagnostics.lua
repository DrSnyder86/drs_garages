local RESOURCE_NAME = GetCurrentResourceName()
local EXPECTED_RESOURCE_NAME = 'drs_garages'
local EXPECTED_VERSION = '2.2.0-drs.3'
local COMMAND_NAME = 'drsgarages:doctor'

local CORE_RESOURCES = {
    { resource = 'qbx_core', framework = 'qbx_core' },
    { resource = 'qb-core', framework = 'qb-core' },
    { resource = 'es_extended', framework = 'es_extended' }
}

local TARGET_RESOURCES = { 'ox_target', 'qb-target', 'qtarget' }
local SUPPORTED_TARGET_RESOURCES = {
    ox_target = true,
    ['qb-target'] = true,
    qtarget = true
}
local GARAGE_CONFLICTS = { 'lunar_garage', 'qb-garages', 'qbx_garages' }
local VEHICLESHOP_CONFLICTS = { 'qr-vehicleshop', 'qbx_vehicleshop' }

local function isStarted(resource)
    return GetResourceState(resource) == 'started'
end

-- `provide` aliases resolve through GetResourceState just like their provider.
-- The resolved path identifies that both names belong to the same running
-- resource while still distinguishing genuinely separate started resources.
local function getStartedResourceIdentity(resource)
    if not isStarted(resource) then return end

    local path = GetResourcePath(resource)
    if type(path) == 'string' and path ~= '' then
        return ('path:%s'):format(path)
    end

    return ('name:%s'):format(resource)
end

local function join(values)
    return #values > 0 and table.concat(values, ', ') or 'none'
end

local function countEntries(value)
    if type(value) ~= 'table' then return 0 end

    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function normalizedText(value)
    if type(value) ~= 'string' then return end

    value = value:match('^%s*(.-)%s*$')
    if value == '' then return end

    return value:lower()
end

local function createReport()
    return {
        entries = {},
        summary = { PASS = 0, WARN = 0, FAIL = 0 }
    }
end

local function add(report, level, check, detail)
    if level ~= 'PASS' and level ~= 'WARN' and level ~= 'FAIL' then level = 'WARN' end

    local entry = {
        level = level,
        check = tostring(check),
        detail = tostring(detail or '')
    }

    report.entries[#report.entries + 1] = entry
    report.summary[level] = report.summary[level] + 1
end

local function getDiagnosticSnapshot(report)
    local provider = rawget(_G, 'GetDrsGaragesDiagnosticSnapshot')
    if type(provider) ~= 'function' then
        add(report, 'FAIL', 'Runtime snapshot', 'Provider is unavailable; runtime and startup reconciliation state could not be inspected.')
        return
    end

    local successful, snapshot = pcall(provider)
    if not successful or type(snapshot) ~= 'table' then
        add(report, 'FAIL', 'Runtime snapshot', ('Provider failed; runtime health could not be verified: %s'):format(tostring(snapshot)))
        return
    end

    local details = {}
    local fields = {
        { 'activeVehicleCount', 'active vehicles' },
        { 'propertyGarageCount', 'property garages' },
        { 'storageOperationCount', 'storage operations' },
        { 'quarantinedVehicleCount', 'quarantined vehicles' }
    }

    for _, field in ipairs(fields) do
        local value = tonumber(snapshot[field[1]])
        if value then details[#details + 1] = ('%d %s'):format(value, field[2]) end
    end

    add(report, 'PASS', 'Runtime snapshot', #details > 0 and join(details) or 'Provider responded successfully.')

    if snapshot.reconciliationComplete == false then
        add(report, 'WARN', 'Startup reconciliation', snapshot.reconciliationDetail or 'Vehicle reconciliation is still running.')
    elseif snapshot.reconciliationSuccessful == false then
        add(report, 'FAIL', 'Startup reconciliation', snapshot.reconciliationDetail or 'Vehicle reconciliation failed.')
    elseif snapshot.reconciliationComplete == true and snapshot.reconciliationSuccessful == true
        and (tonumber(snapshot.quarantinedVehicleCount) or 0) > 0
    then
        add(report, 'WARN', 'Startup reconciliation', snapshot.reconciliationDetail or 'Suspicious vehicle identities were quarantined.')
    elseif snapshot.reconciliationComplete == true and snapshot.reconciliationSuccessful == true then
        add(report, 'PASS', 'Startup reconciliation', snapshot.reconciliationDetail or 'Vehicle reconciliation completed.')
    else
        add(report, 'WARN', 'Startup reconciliation', 'Runtime did not expose reconciliation status.')
    end

    return snapshot
end

local function checkIdentity(report)
    if RESOURCE_NAME == EXPECTED_RESOURCE_NAME then
        add(report, 'PASS', 'Resource name', RESOURCE_NAME)
    else
        add(report, 'FAIL', 'Resource name', ('Expected %s, running as %s. Rename the folder/resource.'):format(
            EXPECTED_RESOURCE_NAME,
            RESOURCE_NAME
        ))
    end

    local version = GetResourceMetadata(RESOURCE_NAME, 'version', 0)
    if version == EXPECTED_VERSION then
        add(report, 'PASS', 'Version', version)
    else
        add(report, 'WARN', 'Version', ('Expected %s, manifest reports %s.'):format(EXPECTED_VERSION, tostring(version)))
    end
end

local function checkDependencies(report)
    for _, dependency in ipairs({ 'ox_lib', 'oxmysql' }) do
        local state = GetResourceState(dependency)
        add(
            report,
            state == 'started' and 'PASS' or 'FAIL',
            ('Dependency: %s'):format(dependency),
            state
        )
    end

    local oneSync = normalizedText(GetConvar('onesync', 'off')) or 'off'
    local enabled = oneSync ~= 'off' and oneSync ~= 'false' and oneSync ~= '0'
    add(report, enabled and 'PASS' or 'FAIL', 'OneSync', enabled and oneSync or 'OneSync is disabled.')
end

local function checkFramework(report)
    local started = {}
    local startedIdentities = {}
    local expectedFramework

    for _, candidate in ipairs(CORE_RESOURCES) do
        local identity = getStartedResourceIdentity(candidate.resource)

        if identity and not startedIdentities[identity] then
            startedIdentities[identity] = true
            started[#started + 1] = candidate.resource
            expectedFramework = candidate.framework
        end
    end

    if #started == 1 then
        add(report, 'PASS', 'Framework resources', started[1])
    elseif #started == 0 then
        add(report, 'FAIL', 'Framework resources', 'No supported core is started (qbx_core, qb-core, or es_extended).')
    else
        add(report, 'FAIL', 'Framework resources', ('Multiple supported cores are started: %s.'):format(join(started)))
        expectedFramework = nil
    end

    local resolvedFramework = type(Framework) == 'table' and Framework.name or nil
    if expectedFramework and resolvedFramework == expectedFramework then
        add(report, 'PASS', 'Framework adapter', resolvedFramework)
    elseif not resolvedFramework then
        add(report, 'FAIL', 'Framework adapter', 'No DRS framework adapter resolved.')
    else
        add(report, expectedFramework and 'FAIL' or 'WARN', 'Framework adapter', ('Resolved to %s.'):format(tostring(resolvedFramework)))
    end

    if resolvedFramework == 'qbx_core' then
        local persistenceEnabled = normalizedText(GetConvar('qbx:enableVehiclePersistence', 'false')) or 'false'
        local persistenceType = normalizedText(GetConvar('qbx:vehiclePersistenceType', 'semi')) or 'semi'
        local enabled = persistenceEnabled == 'true' or persistenceEnabled == '1' or persistenceEnabled == 'yes'
        local full = enabled and persistenceType == 'full'

        add(
            report,
            full and 'FAIL' or 'PASS',
            'Qbox vehicle persistence',
            full and 'Full persistence conflicts with DRS vehicle reconciliation; use semi mode or disable Qbox persistence.'
                or (enabled and ('compatible %s mode'):format(persistenceType) or 'disabled')
        )
    end

    return resolvedFramework
end

local function checkDatabase(report)
    local databaseApi = rawget(_G, 'DRSGaragesDatabase')
    if type(databaseApi) ~= 'table' then
        add(report, 'FAIL', 'Database readiness API', 'DRSGaragesDatabase is unavailable.')
        return
    end

    if type(databaseApi.isReady) ~= 'function' or type(databaseApi.isUsable) ~= 'function' then
        add(report, 'FAIL', 'Database readiness API', 'The readiness API is incomplete.')
        return
    end

    local readyCallOk, ready = pcall(databaseApi.isReady)
    if not readyCallOk then
        add(report, 'FAIL', 'Database readiness API', ('isReady failed: %s'):format(tostring(ready)))
        return
    end

    local usableCallOk, usable, detail = pcall(databaseApi.isUsable)
    if not usableCallOk then
        add(report, 'FAIL', 'Database schema', ('isUsable failed: %s'):format(tostring(usable)))
    elseif not ready then
        add(report, 'WARN', 'Database schema', ('Setup is still running: %s'):format(tostring(detail)))
    elseif usable then
        add(report, 'PASS', 'Database schema', detail or 'Schema validation passed.')
    else
        add(report, 'FAIL', 'Database schema', detail or 'Schema validation failed.')
    end

    if type(databaseApi.getStatus) == 'function' then
        local statusOk, status = pcall(databaseApi.getStatus)
        if statusOk and type(status) == 'table' then
            add(
                report,
                'PASS',
                'Database migration mode',
                status.autoMigrate == false and 'read-only validation (automatic migration disabled)' or 'automatic migration enabled'
            )
        end
    end
end

local function getTargetConfiguration()
    local targetConfig = type(Config) == 'table' and Config.Target or nil
    local enabled = targetConfig ~= false
    local explicitProvider

    if type(targetConfig) == 'string' then
        local normalized = normalizedText(targetConfig)
        enabled = normalized ~= 'off' and normalized ~= 'none' and normalized ~= 'textui'
        if enabled and normalized ~= 'auto' then explicitProvider = targetConfig end
    elseif type(targetConfig) == 'table' then
        enabled = targetConfig.Enabled ~= false
        explicitProvider = targetConfig.Resource or targetConfig.Provider
    end

    if type(Config) == 'table' then
        explicitProvider = Config.TargetResource or Config.TargetProvider or explicitProvider
    end

    explicitProvider = normalizedText(explicitProvider)
    if explicitProvider == 'auto' then explicitProvider = nil end

    return enabled, explicitProvider
end

local function checkTarget(report)
    local enabled, explicitProvider = getTargetConfiguration()
    local started = {}
    local startedIdentities = {}

    for _, provider in ipairs(TARGET_RESOURCES) do
        local identity = getStartedResourceIdentity(provider)

        if identity and not startedIdentities[identity] then
            startedIdentities[identity] = true
            started[#started + 1] = provider
        end
    end

    if not enabled then
        add(report, 'PASS', 'Target provider', 'Target interaction is disabled; ox_lib TextUI fallback is active.')
        return
    end

    if explicitProvider and not SUPPORTED_TARGET_RESOURCES[explicitProvider] then
        add(report, 'WARN', 'Target provider', ('Configured provider %s is unsupported; ox_lib TextUI fallback is active.'):format(explicitProvider))
        return
    end

    if explicitProvider and not isStarted(explicitProvider) then
        add(report, 'WARN', 'Target provider', ('Configured provider %s is not started; ox_lib TextUI fallback is active.'):format(explicitProvider))
        return
    end

    if explicitProvider then
        add(report, 'PASS', 'Target provider', explicitProvider)
    elseif #started == 0 then
        add(report, 'WARN', 'Target provider', 'No supported target provider is started; ox_lib TextUI fallback is active.')
    elseif #started > 1 and not explicitProvider then
        add(report, 'WARN', 'Target provider', ('Multiple providers are started (%s); automatic preference is ox_target, qb-target, then qtarget.'):format(join(started)))
    else
        add(report, 'PASS', 'Target provider', started[1])
    end
end

local function checkVehicleKeys(report, frameworkName)
    if type(Config) ~= 'table' or Config.UseKeySystem == false then
        add(report, 'PASS', 'Vehicle keys', 'DRS key handoff is disabled.')
        return
    end

    local resource = frameworkName == 'qbx_core' and 'qbx_vehiclekeys'
        or frameworkName == 'qb-core' and 'qb-vehiclekeys'
        or nil

    if not resource then
        add(report, 'WARN', 'Vehicle keys', 'No default ESX vehicle-key handoff is implemented.')
    elseif isStarted(resource) then
        add(report, 'PASS', 'Vehicle keys', resource)
    else
        add(report, 'WARN', 'Vehicle keys', ('%s is not started; spawned vehicles may not receive keys.'):format(resource))
    end
end

local function checkConflictsAndCompanions(report, frameworkName)
    local conflicts = {}
    for _, resource in ipairs(GARAGE_CONFLICTS) do
        if isStarted(resource) then conflicts[#conflicts + 1] = resource end
    end

    if #conflicts == 0 then
        add(report, 'PASS', 'Garage conflicts', 'No known overlapping garage resource is started.')
    else
        add(report, 'FAIL', 'Garage conflicts', ('Stop overlapping resource(s): %s.'):format(join(conflicts)))
    end

    local drsVehicleShopStarted = isStarted('drs_vehicleshop')
    local legacyShops = {}
    for _, resource in ipairs(VEHICLESHOP_CONFLICTS) do
        if isStarted(resource) then legacyShops[#legacyShops + 1] = resource end
    end

    if #legacyShops > 0 then
        add(
            report,
            drsVehicleShopStarted and 'FAIL' or 'WARN',
            'Vehicle-shop conflicts',
            ('Legacy/overlapping shop resource(s) started: %s.'):format(join(legacyShops))
        )
    else
        add(report, 'PASS', 'Vehicle-shop conflicts', 'No known legacy companion shop is started.')
    end

    add(
        report,
        'PASS',
        'Companion: drs_vehicleshop',
        drsVehicleShopStarted and 'started' or 'not started (optional)'
    )

    local propertiesStarted = isStarted('qbx_properties')
    add(
        report,
        propertiesStarted and frameworkName ~= 'qbx_core' and 'WARN' or 'PASS',
        'Companion: qbx_properties',
        propertiesStarted and 'started' or 'not started (optional)'
    )
end

local function getRequestedStorageMode(snapshot)
    local mode = type(snapshot) == 'table'
        and (snapshot.requestedStorageMode or snapshot.RequestedStorageMode)
        or nil

    if mode == nil and type(Config) == 'table' then
        if type(Config.Storage) == 'table' then mode = Config.Storage.Mode or Config.Storage.mode end
        mode = mode or Config.StorageMode
    end

    return normalizedText(mode) or 'global'
end

local function getEffectiveStorageMode(snapshot, requestedMode)
    local mode = type(snapshot) == 'table' and (snapshot.storageMode or snapshot.StorageMode) or nil
    return normalizedText(mode) or requestedMode or 'global'
end

local function checkConfiguration(report, snapshot)
    if type(Config) ~= 'table' then
        add(report, 'FAIL', 'Configuration', 'Config was not loaded.')
        return
    end

    local garageCount = countEntries(Config.Garages)
    local impoundCount = countEntries(Config.Impounds)
    local interiorCount = countEntries(Config.GarageInteriors)

    add(report, garageCount > 0 and 'PASS' or 'WARN', 'Configured garages', garageCount)
    add(report, impoundCount > 0 and 'PASS' or 'WARN', 'Configured impounds', impoundCount)
    add(report, interiorCount > 0 and 'PASS' or 'WARN', 'Configured interiors', interiorCount)

    local contractEnabled = type(Config.Contract) == 'table' and Config.Contract.Enabled == true
    add(
        report,
        contractEnabled and 'WARN' or 'PASS',
        'Vehicle contracts',
        contractEnabled and 'enabled (framework effects are not one crash-durable transaction)' or 'disabled (safe default)'
    )

    local impoundPrice = math.max(0, tonumber(Config.ImpoundPrice) or 0)
    add(
        report,
        impoundPrice > 0 and 'WARN' or 'PASS',
        'Paid impound redemption',
        impoundPrice > 0 and ('enabled at %s; crash-time refunds can require staff review'):format(impoundPrice)
            or 'disabled (safe default)'
    )

    local requestedStorageMode = getRequestedStorageMode(snapshot)
    local storageMode = getEffectiveStorageMode(snapshot, requestedStorageMode)
    local validModes = { global = true, garage = true, property = true }
    if not validModes[requestedStorageMode] then
        add(report, 'FAIL', 'Storage mode', ('Unsupported configured value: %s (effective: %s)'):format(
            requestedStorageMode,
            storageMode
        ))
    elseif requestedStorageMode ~= storageMode then
        add(report, 'WARN', 'Storage mode', ('Configured: %s; effective fallback: %s. Check the server warning for the reason.'):format(
            requestedStorageMode,
            storageMode
        ))
    else
        add(report, 'PASS', 'Storage mode', storageMode)
    end

    local runtimeCatalogCount = type(snapshot) == 'table' and tonumber(snapshot.staticGarageCatalogCount) or nil
    local runtimeCatalogValid = type(snapshot) == 'table' and snapshot.staticGarageCatalogValid or nil

    if runtimeCatalogCount ~= nil and runtimeCatalogValid ~= nil then
        local catalogComplete = runtimeCatalogCount == garageCount and runtimeCatalogValid == true
        local detail = catalogComplete
            and ('%d effective storage-safe garage IDs.'):format(runtimeCatalogCount)
            or ('%d configured, %d cataloged, catalog valid=%s'):format(
                garageCount,
                runtimeCatalogCount,
                tostring(runtimeCatalogValid)
            )

        add(report, catalogComplete and 'PASS' or (storageMode == 'garage' and 'FAIL' or 'WARN'), 'Static garage IDs', detail)
        return
    end

    local missingIds = 0
    local invalidIds = 0
    local duplicateIds = {}
    local seen = {}

    for index, garage in pairs(type(Config.Garages) == 'table' and Config.Garages or {}) do
        if type(garage) == 'table' then
            local id = garage.Garage or garage.Id or garage.ID or garage.StorageId or garage.Name or garage.Label
            local normalized = normalizedText(id)

            if not normalized then
                missingIds = missingIds + 1
            elseif #normalized > 50 or not normalized:match('^[%w_%-]+$') then
                invalidIds = invalidIds + 1
            elseif seen[normalized] then
                duplicateIds[#duplicateIds + 1] = normalized
            else
                seen[normalized] = index
            end
        end
    end

    if missingIds == 0 and invalidIds == 0 and #duplicateIds == 0 then
        add(report, 'PASS', 'Static garage IDs', 'Every configured garage has a unique storage-safe ID.')
    else
        local details = ('%d missing, %d invalid, %d duplicate'):format(missingIds, invalidIds, #duplicateIds)
        add(report, storageMode == 'garage' and 'FAIL' or 'WARN', 'Static garage IDs', details)
    end
end

local function runDoctor()
    local report = createReport()

    checkIdentity(report)
    checkDependencies(report)
    local frameworkName = checkFramework(report)
    checkDatabase(report)
    checkTarget(report)
    checkVehicleKeys(report, frameworkName)
    checkConflictsAndCompanions(report, frameworkName)
    local snapshot = getDiagnosticSnapshot(report)
    checkConfiguration(report, snapshot)

    return report
end

local function printReport(report)
    print(('[%s][doctor] DRS Garages diagnostic report'):format(RESOURCE_NAME))

    for _, entry in ipairs(report.entries) do
        print(('[%s][doctor][%s] %s: %s'):format(RESOURCE_NAME, entry.level, entry.check, entry.detail))
    end

    print(('[%s][doctor] Summary: %d PASS, %d WARN, %d FAIL'):format(
        RESOURCE_NAME,
        report.summary.PASS,
        report.summary.WARN,
        report.summary.FAIL
    ))
end

RegisterCommand(COMMAND_NAME, function(source)
    local report = runDoctor()
    printReport(report)

    if source and source > 0 then
        TriggerClientEvent('drs_garages:client:doctorReport', source, report)
    end
end, true)
