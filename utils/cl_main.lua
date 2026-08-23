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
local targetWarningShown = false
local targetZoneSequence = 0

local function targetWarning(message)
    if targetWarningShown then return end

    targetWarningShown = true
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
end

function Utils.createPed(coords, model, options)
    if not IsModelValid(model) then
        error(('Invalid ped model: %s'):format(tostring(model)))
    end

    targetZoneSequence += 1
    local record = {
        zoneName = ('drs_garage_ped_%s'):format(targetZoneSequence)
    }

    record.point = lib.points.new({
        coords = coords.xyz,
        distance = 100.0,
        onEnter = function()
            lib.requestModel(model)
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
            SetModelAsNoLongerNeeded(model)
        end
    })

    managedPedPoints[record] = true
    return record.point
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for record in pairs(managedPedPoints) do
        cleanupPedPoint(record)

        if record.point then
            record.point:remove()
            record.point = nil
        end
    end

    managedPedPoints = {}
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
