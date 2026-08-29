lib.locale()

Utils = {}

---@diagnostic disable-next-line: duplicate-set-field
function Utils.getTableSize(t)
    local count = 0

	for _,_ in pairs(t) do
		count = count + 1
	end

	return count
end

---@generic K, V
---@param t table<K, V>
---@return V, K
---@diagnostic disable-next-line: duplicate-set-field
function Utils.randomFromTable(t)
    local index = math.random(1, #t)
    return t[index], index
end

local scenarios = {
    'WORLD_HUMAN_AA_COFFEE',
    --'WORLD_HUMAN_AA_SMOKE',
    --'WORLD_HUMAN_SMOKING',
    'WORLD_HUMAN_STAND_MOBILE',
    'WORLD_HUMAN_CLIPBOARD',
}

local targetProviders <const> = { 'ox_target', 'qb-target', 'qtarget' }
local supportedTargetProviders <const> = {
    ox_target = true,
    ['qb-target'] = true,
    qtarget = true
}
local managedPedPoints = {}
local managedGlobalVehicleTargets = {}
local managedRadialOptions = {}
local radialCallbacks = {}
local targetWarningShown = false
local radialWarningShown = false
local targetZoneSequence = 0
local globalVehicleTargetSequence = 0
local RADIAL_SELECT_EVENT <const> = 'drs_garages:client:selectRadialOption'

local function targetWarning(message)
    if targetWarningShown then return end

    targetWarningShown = true
    print(('[drs_garages] WARNING: %s'):format(message))
end

local function radialWarning(message)
    if radialWarningShown then return end

    radialWarningShown = true
    print(('[drs_garages] WARNING: %s'):format(message))
end

local function normalizedTargetName(value)
    if type(value) ~= 'string' then return end

    value = value:match('^%s*(.-)%s*$'):lower()
    if value == '' then return end
    return value
end

local function getTargetConfiguration()
    local targetConfig = Config and Config.Target
    local enabled = targetConfig ~= false
    local explicitProvider

    if type(targetConfig) == 'string' then
        local normalized = normalizedTargetName(targetConfig)
        enabled = normalized ~= 'off' and normalized ~= 'none' and normalized ~= 'textui'

        if enabled and normalized ~= 'auto' then
            explicitProvider = normalized
        end
    elseif type(targetConfig) == 'table' then
        enabled = targetConfig.Enabled ~= false
        explicitProvider = targetConfig.Resource or targetConfig.Provider
    end

    if Config then
        explicitProvider = Config.TargetResource or Config.TargetProvider or explicitProvider
    end

    explicitProvider = normalizedTargetName(explicitProvider)
    if explicitProvider == 'auto' then explicitProvider = nil end

    return enabled, explicitProvider
end


local function getTargetProvider(warnIfMissing)
    local enabled, explicitProvider = getTargetConfiguration()
    if not enabled then return end

    if explicitProvider then
        if not supportedTargetProviders[explicitProvider] then
            if warnIfMissing then
                targetWarning(('the configured target provider %s is unsupported. Use ox_target, qb-target, or qtarget. Falling back to TextUI interactions.'):format(explicitProvider))
            end

            return
        end

        if GetResourceState(explicitProvider) == 'started' then
            return explicitProvider
        end

        if warnIfMissing then
            targetWarning(('the configured target provider %s is not started. Falling back to TextUI interactions.'):format(explicitProvider))
        end

        return
    end

    for i = 1, #targetProviders do
        local resource = targetProviders[i]

        if GetResourceState(resource) == 'started' then
            return resource
        end
    end

    if warnIfMissing then
        targetWarning('Config.Target is enabled, but ox_target, qb-target, and qtarget are unavailable. Falling back to TextUI interactions.')
    end
end

function Utils.isTargetEnabled()
    return getTargetConfiguration()
end

---Returns whether a supported target resource is currently available.
---@param warnIfMissing? boolean
---@return boolean available
---@return string? provider
function Utils.isTargetAvailable(warnIfMissing)
    local provider = getTargetProvider(warnIfMissing)

    return provider ~= nil, provider
end

exports('IsTargetAvailable', function()
    return Utils.isTargetAvailable(false)
end)

exports('IsTargetEnabled', function()
    return Utils.isTargetEnabled()
end)

local supportedRadialProviders <const> = {
    qbx_radialmenu = true,
    ['qb-radialmenu'] = true,
    ox_lib = true
}

local function getRadialConfiguration()
    local radialConfig = Config and Config.RadialMenu
    local enabled = radialConfig ~= false
    local explicitProvider

    if type(radialConfig) == 'string' then
        local normalized = normalizedTargetName(radialConfig)
        enabled = normalized ~= 'off' and normalized ~= 'none' and normalized ~= 'false'
        if enabled and normalized ~= 'auto' then explicitProvider = normalized end
    elseif type(radialConfig) == 'table' then
        enabled = radialConfig.Enabled ~= false
        explicitProvider = radialConfig.Resource or radialConfig.Provider
    end

    explicitProvider = normalizedTargetName(explicitProvider)
    if explicitProvider == 'auto' then explicitProvider = nil end

    return enabled, explicitProvider
end

local function getRadialProvider(warnIfMissing)
    local enabled, explicitProvider = getRadialConfiguration()
    if not enabled then return end

    if explicitProvider then
        if not supportedRadialProviders[explicitProvider] then
            if warnIfMissing then
                radialWarning(('the configured radial provider %s is unsupported. Use qbx_radialmenu, qb-radialmenu, or ox_lib.'):format(explicitProvider))
            end
            return
        end

        if GetResourceState(explicitProvider) == 'started' then return explicitProvider end

        if warnIfMissing then
            radialWarning(('the configured radial provider %s is not started; nearby garage radial access is unavailable.'):format(explicitProvider))
        end
        return
    end

    if GetResourceState('qbx_radialmenu') == 'started' then return 'qbx_radialmenu' end
    if GetResourceState('qb-radialmenu') == 'started' then return 'qb-radialmenu' end
    if GetResourceState('ox_lib') == 'started' then return 'ox_lib' end

    if warnIfMissing then
        radialWarning('no supported radial provider is started; nearby garage radial access is unavailable.')
    end
end

function Utils.isRadialEnabled()
    return getRadialConfiguration()
end

function Utils.getRadialProvider(warnIfMissing)
    return getRadialProvider(warnIfMissing)
end

RegisterNetEvent(RADIAL_SELECT_EVENT, function(payload)
    local id = type(payload) == 'table' and payload.id or payload
    if type(id) ~= 'string' and type(payload) == 'table' and type(payload.args) == 'table' then
        id = payload.args.id
    end

    local callback = type(id) == 'string' and radialCallbacks[id] or nil
    if callback then callback() end
end)

local function removeRadialOption(handle)
    if type(handle) ~= 'table' or not handle.id then return end

    if handle.provider == 'qbx_radialmenu' and GetResourceState('qbx_radialmenu') == 'started' then
        exports.qbx_radialmenu:RemoveOption(handle.id)
    elseif handle.provider == 'qb-radialmenu' and GetResourceState('qb-radialmenu') == 'started' then
        exports['qb-radialmenu']:RemoveOption(handle.id)
    elseif handle.provider == 'ox_lib' and GetResourceState('ox_lib') == 'started' then
        lib.removeRadialItem(handle.id)
    end
end

---Adds one dynamic option to the active framework radial menu.
---@param id string
---@param option table
---@return table? handle
function Utils.addRadialOption(id, option)
    if type(id) ~= 'string' or id == '' or type(option) ~= 'table' or type(option.onSelect) ~= 'function' then return end

    local provider = getRadialProvider(true)
    if not provider then return end

    radialCallbacks[id] = option.onSelect
    local ok, result = pcall(function()
        if provider == 'qbx_radialmenu' then
            return exports.qbx_radialmenu:AddOption({
                id = id,
                label = option.label,
                icon = option.icon,
                onSelect = function()
                    local callback = radialCallbacks[id]
                    if callback then callback() end
                end
            }, id)
        elseif provider == 'qb-radialmenu' then
            return exports['qb-radialmenu']:AddOption({
                id = id,
                title = option.label,
                icon = option.icon,
                type = 'client',
                event = RADIAL_SELECT_EVENT,
                args = { id = id },
                shouldClose = true
            }, id)
        end

        lib.addRadialItem({
            id = id,
            label = option.label,
            icon = option.icon,
            onSelect = function()
                local callback = radialCallbacks[id]
                if callback then callback() end
            end
        })
        return id
    end)

    if not ok or result == false then
        radialCallbacks[id] = nil
        radialWarning(('the %s radial adapter failed: %s'):format(provider, tostring(result)))
        return
    end

    local handle = { id = id, provider = provider }
    managedRadialOptions[handle] = true
    return handle
end

function Utils.removeRadialOption(handle)
    if not managedRadialOptions[handle] then return false end

    pcall(removeRadialOption, handle)
    managedRadialOptions[handle] = nil
    radialCallbacks[handle.id] = nil
    return true
end

local function targetIcon(icon)
    if type(icon) ~= 'string' or icon == '' then return icon end
    if icon:find('fa%-', 1, false) then return icon end

    return ('fa-solid fa-%s'):format(icon)
end

local function qbTargetJobs(jobs)
    if type(jobs) ~= 'table' then return jobs end

    local result = {}
    for key, value in pairs(jobs) do
        local job = type(key) == 'number' and value or key
        local grade = type(key) == 'number' and 0 or tonumber(value) or 0

        if type(job) == 'string' and job ~= '' then
            result[job] = grade
        end
    end

    return result
end

local function buildOxTargetOptions(zoneName, options)
    local result = {}

    for index, option in ipairs(options or {}) do
        local selectedOption = option

        result[index] = {
            name = ('%s_%s'):format(zoneName, index),
            label = selectedOption.label,
            icon = targetIcon(selectedOption.icon),
            groups = selectedOption.job,
            distance = selectedOption.distance or 2.0,
            canInteract = selectedOption.canInteract,
            onSelect = function()
                if selectedOption.onSelect then
                    selectedOption.onSelect(selectedOption.args)
                end
            end
        }
    end

    return result
end

local function buildQbTargetOptions(options)
    local result = {}

    for index, option in ipairs(options or {}) do
        local selectedOption = option

        result[index] = {
            label = selectedOption.label,
            icon = targetIcon(selectedOption.icon),
            job = qbTargetJobs(selectedOption.job),
            canInteract = selectedOption.canInteract,
            action = function()
                if selectedOption.onSelect then
                    selectedOption.onSelect(selectedOption.args)
                end
            end
        }
    end

    return result
end

local function addTargetZone(provider, zoneName, coords, options)
    if provider == 'ox_target' then
        return exports.ox_target:addSphereZone({
            name = zoneName,
            coords = coords.xyz,
            radius = 0.75,
            debug = false,
            options = buildOxTargetOptions(zoneName, options)
        })
    end

    exports[provider]:AddCircleZone(zoneName, coords.xyz, 0.75, {
        name = zoneName,
        debugPoly = false
    }, {
        options = buildQbTargetOptions(options),
        distance = 2.0
    })

    return zoneName
end

local function removeTargetZone(provider, zoneId)
    if not provider or not zoneId or GetResourceState(provider) ~= 'started' then return end

    if provider == 'ox_target' then
        exports.ox_target:removeZone(zoneId)
    else
        exports[provider]:RemoveZone(zoneId)
    end
end

local function buildOxGlobalVehicleOptions(namespace, options)
    local result = {}
    local names = {}

    for index, option in ipairs(options or {}) do
        local selectedOption = option
        local optionName = ('%s_%s'):format(namespace, index)
        names[#names + 1] = optionName
        result[index] = {
            name = optionName,
            label = selectedOption.label,
            icon = targetIcon(selectedOption.icon),
            groups = selectedOption.job,
            distance = selectedOption.distance,
            canInteract = function(entity, distance, coords, name, bone)
                if not selectedOption.canInteract then return true end
                return selectedOption.canInteract(entity, distance, coords, name, bone) == true
            end,
            onSelect = function(data)
                if selectedOption.onSelect then
                    selectedOption.onSelect(data and data.entity or nil, selectedOption.args)
                end
            end
        }
    end

    return result, names
end

local function buildQbGlobalVehicleOptions(options)
    local result = {}
    local labels = {}

    for index, option in ipairs(options or {}) do
        local selectedOption = option
        labels[index] = selectedOption.label
        result[index] = {
            label = selectedOption.label,
            icon = targetIcon(selectedOption.icon),
            job = qbTargetJobs(selectedOption.job),
            canInteract = function(entity, distance, data)
                if not selectedOption.canInteract then return true end
                return selectedOption.canInteract(entity, distance, data) == true
            end,
            action = function(entity)
                if selectedOption.onSelect then selectedOption.onSelect(entity, selectedOption.args) end
            end
        }
    end

    return result, labels
end


local function removeGlobalVehicleTarget(handle)
    if type(handle) ~= 'table' or not handle.provider or GetResourceState(handle.provider) ~= 'started' then return end

    if handle.provider == 'ox_target' then
        exports.ox_target:removeGlobalVehicle(handle.keys)
    elseif handle.provider == 'qb-target' then
        exports['qb-target']:RemoveGlobalVehicle(handle.keys)
    elseif handle.provider == 'qtarget' then
        exports.qtarget:RemoveVehicle(handle.keys)
    end
end

---Registers provider-normalized options on every networked vehicle.
---@param namespace string
---@param options table[]
---@param distance? number
---@return table? handle
function Utils.addGlobalVehicleTarget(namespace, options, distance)
    local available, provider = Utils.isTargetAvailable(true)
    if not available then return end
    if type(namespace) ~= 'string' or namespace == '' or type(options) ~= 'table' or #options == 0 then return end

    globalVehicleTargetSequence += 1
    namespace = ('%s_%s'):format(namespace:gsub('[^%w_%-]', '_'), globalVehicleTargetSequence)

    local providerOptions, keys
    if provider == 'ox_target' then
        providerOptions, keys = buildOxGlobalVehicleOptions(namespace, options)
    else
        providerOptions, keys = buildQbGlobalVehicleOptions(options)
    end

    local ok, errorMessage = pcall(function()
        if provider == 'ox_target' then
            exports.ox_target:addGlobalVehicle(providerOptions)
        elseif provider == 'qb-target' then
            exports['qb-target']:AddGlobalVehicle({
                options = providerOptions,
                distance = distance or 2.5
            })
        else
            exports.qtarget:Vehicle({
                options = providerOptions,
                distance = distance or 2.5
            })
        end
    end)

    if not ok then
        targetWarning(('the %s global vehicle target adapter failed: %s'):format(provider, tostring(errorMessage)))
        return
    end

    local handle = { provider = provider, keys = keys }
    managedGlobalVehicleTargets[handle] = true
    return handle
end

function Utils.removeGlobalVehicleTarget(handle)
    if not managedGlobalVehicleTargets[handle] then return false end

    pcall(removeGlobalVehicleTarget, handle)
    managedGlobalVehicleTargets[handle] = nil
    return true
end

local function cleanupPedPoint(record)
    if record.zoneId then
        pcall(removeTargetZone, record.provider, record.zoneId)
        record.zoneId = nil
        record.provider = nil
    end

    if record.ped and DoesEntityExist(record.ped) then
        DeleteEntity(record.ped)
    end

    record.ped = nil
    if record.model then SetModelAsNoLongerNeeded(record.model) end
end

function Utils.createPed(coords, model, options)
    if not IsModelValid(model) then
        error(('Invalid ped model: %s'):format(tostring(model)))
    end

    targetZoneSequence += 1
    local record = {
        zoneName = ('drs_garage_ped_%s'):format(targetZoneSequence),
        model = model,
        removed = false
    }

    record.point = lib.points.new({
        coords = coords.xyz,
        distance = 100.0,
        onEnter = function()
            lib.requestModel(model)

            -- A dynamic property can be removed while requestModel yields.
            -- Never let that suspended handler recreate an untracked ped/zone.
            if record.removed or not managedPedPoints[record] then
                SetModelAsNoLongerNeeded(model)
                return
            end

            record.ped = CreatePed(4, model, coords.x, coords.y, coords.z - 1.0, coords.w, false, true)

            if not record.ped or record.ped == 0 or not DoesEntityExist(record.ped) then
                targetWarning(('could not create the interaction ped for zone %s.'):format(record.zoneName))
                return
            end

            SetEntityInvincible(record.ped, true)
            FreezeEntityPosition(record.ped, true)
            SetBlockingOfNonTemporaryEvents(record.ped, true)
            local scenario = Utils.randomFromTable(scenarios)
            TaskStartScenarioInPlace(record.ped, scenario, -1, true)

            if options then
                local available, provider = Utils.isTargetAvailable(true)
                if not available then return end

                local ok, zoneId = pcall(addTargetZone, provider, record.zoneName, coords, options)
                if not ok or not zoneId then
                    targetWarning(('the %s target adapter failed; restart drs_garages after correcting the target resource.'):format(provider))
                    return
                end

                record.provider = provider
                record.zoneId = zoneId
            end
        end,
        onExit = function()
            cleanupPedPoint(record)
        end
    })

    managedPedPoints[record] = true
    return record
end

function Utils.removePedPoint(record)
    if not managedPedPoints[record] then return false end

    record.removed = true
    cleanupPedPoint(record)

    if record.point then
        record.point:remove()
        record.point = nil
    end

    managedPedPoints[record] = nil
    return true
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for record in pairs(managedPedPoints) do
        record.removed = true
        cleanupPedPoint(record)

        if record.point then
            record.point:remove()
            record.point = nil
        end
    end

    managedPedPoints = {}

    for handle in pairs(managedGlobalVehicleTargets) do
        pcall(removeGlobalVehicleTarget, handle)
    end

    managedGlobalVehicleTargets = {}

    for handle in pairs(managedRadialOptions) do
        pcall(removeRadialOption, handle)
        radialCallbacks[handle.id] = nil
    end

    managedRadialOptions = {}
end)

---@param point1 vector3 | vector4 | number
---@param point2 vector3 | vector4 | number
---@param distance number?
---@diagnostic disable-next-line: duplicate-set-field
function Utils.distanceCheck(point1, point2, distance)
    distance = distance or Config.MaxDistance

    if type(point1) == 'number' then
        point1 = GetEntityCoords(point1)
    end

    if type(point2) == 'number' then
        point2 = GetEntityCoords(point2)
    end

    return #(point1.xyz - point2.xyz) <= distance
end

function Utils.createBlip(coords, text, sprite, scale, color)
    local blip = AddBlipForCoord(coords.x, coords.y)

    SetBlipSprite (blip, sprite)
    SetBlipDisplay(blip, 4)
    SetBlipScale  (blip, scale)
    SetBlipColour (blip, color)
    SetBlipAsShortRange(blip, true)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(blip)
    return blip
end

---@param jobs string | string[]
function Utils.hasJobs(jobs)
    if type(jobs) == 'string' then
        jobs = { jobs } ---@cast jobs string[]
    end

    local playerJob = Framework.getJob()
    if not playerJob then return false end

    for key, value in pairs(jobs) do
        local name = type(key) == 'number' and value or key

        if playerJob == name then
            return true
        end
    end

    return false
end

---@class KeybindData
---@field name string
---@field description string
---@field defaultMapper? string (see: https://docs.fivem.net/docs/game-references/input-mapper-parameter-ids/)
---@field defaultKey? string
---@field disabled? boolean
---@field disable? fun(self: CKeybind, toggle: boolean)

---@class Keybind : CKeybind
---@field addListener fun(name: string, cb: fun(self: CKeybind), args...: any)
---@field removeListener fun(name: string)

-- A wrapper around lib.addKeybind with extra functions.
---@param data KeybindData
---@return Keybind
function Utils.addKeybind(data)
    local bind = lib.addKeybind(data --[[@as KeybindProps]]) 

    local listeners = {}

    function bind.addListener(name, cb, ...)
        local args = ...
        listeners[name] = function()
            CreateThread(function()
                cb(args)
            end)
        end
    end

    function bind.removeListener(name)
        listeners[name] = nil
    end

    function bind.onReleased(self)
        for _, cb in pairs(listeners) do
            cb()
        end
    end

    return bind --[[@as Keybind]]
end
