if GetResourceState('qbx_core') ~= 'started' then return end

Framework = { name = 'qbx_core' }

local PlayerData = {}

local function RefreshPlayerData()
    local ok, data = pcall(function()
        if exports.qbx_core.GetPlayerData then
            return exports.qbx_core:GetPlayerData()
        end
    end)

    if ok and data then
        PlayerData = data
    end

    return PlayerData
end

CreateThread(function()
    Wait(500)
    RefreshPlayerData()
end)

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    RefreshPlayerData()
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    PlayerData = {}
end)

RegisterNetEvent('qbx_core:client:playerLoggedOut', function()
    PlayerData = {}
end)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    PlayerData.job = job

    if OnPlayerData then
        OnPlayerData('job', job)
    end
end)

function Framework.isPlayerLoaded()
    return LocalPlayer.state.isLoggedIn == true or next(PlayerData) ~= nil
end

---@diagnostic disable-next-line: duplicate-set-field
function Framework.getJob()
    local data = RefreshPlayerData()

    if data and data.job and data.job.name then
        return data.job.name
    end

    -- Fallback: qbx_core exposes group checks but not always primary job info client-side.
    return false
end

function Framework.hasGroup(filter)
    if GetResourceState('qbx_core') ~= 'started' then return false end

    local ok, result = pcall(function()
        return exports.qbx_core:HasGroup(filter)
    end)

    return ok and result == true
end

function Framework.hasItem(name)
    if GetResourceState('ox_inventory') == 'started' then
        return (exports.ox_inventory:Search('count', name) or 0) > 0
    end

    return false
end

local function spawnVehicle(model, coords, heading, networked, cb)
    lib.requestModel(model)

    local vehicle = CreateVehicle(model, coords.x, coords.y, coords.z, heading, networked, true)

    if not DoesEntityExist(vehicle) then return end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetModelAsNoLongerNeeded(model)

    if cb then
        cb(vehicle)
    end
end

function Framework.spawnVehicle(model, coords, heading, cb)
    spawnVehicle(model, coords, heading, true, cb)
end

function Framework.spawnLocalVehicle(model, coords, heading, cb)
    spawnVehicle(model, coords, heading, false, cb)
end

function Framework.deleteVehicle(vehicle)
    if DoesEntityExist(vehicle) then
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteVehicle(vehicle)
    end
end

function Framework.getPlayersInArea(coords, radius)
    local players = {}
    local activePlayers = GetActivePlayers()

    for i = 1, #activePlayers do
        local playerId = activePlayers[i]
        local ped = GetPlayerPed(playerId)

        if DoesEntityExist(ped) and #(GetEntityCoords(ped) - coords) <= radius then
            players[#players + 1] = playerId
        end
    end

    return players
end
