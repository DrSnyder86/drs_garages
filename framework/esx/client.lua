if GetResourceState('es_extended') ~= 'started' then return end

Framework = { name = 'es_extended' }
local sharedObject = exports['es_extended']:getSharedObject()

AddEventHandler('esx:setPlayerData', function(key, val, last)
    if GetInvokingResource() == 'es_extended' then
        sharedObject.PlayerData[key] = val
        if OnPlayerData then
            OnPlayerData(key, val, last)
        end
    end
end)

RegisterNetEvent('esx:playerLoaded', function(xPlayer)
    sharedObject.PlayerData = xPlayer
    sharedObject.PlayerLoaded = true
end)

RegisterNetEvent('esx:onPlayerLogout', function()
    sharedObject.PlayerLoaded = false
    sharedObject.PlayerData = {}
end)

Framework.isPlayerLoaded = sharedObject.IsPlayerLoaded

---@diagnostic disable-next-line: duplicate-set-field
Framework.getJob = function()
    if not Framework.isPlayerLoaded() then
        return false
    end

    local playerData = sharedObject.GetPlayerData()
    return playerData and playerData.job and playerData.job.name or false
end

Framework.getJobData = function()
    if not Framework.isPlayerLoaded() then return end

    local playerData = sharedObject.GetPlayerData()
    local job = playerData and playerData.job or {}
    if not job.name then return end
    local duty = job.onduty
    if duty == nil then duty = job.onDuty end

    return {
        name = job.name,
        type = job.type,
        grade = tonumber(job.grade) or 0,
        -- Stock ESX has no universal duty state, so an absent flag means the
        -- current job is active. Custom ESX duty flags are still enforced.
        onDuty = duty == nil or duty == true or duty == 1 or duty == 'true'
    }
end

Framework.hasItem = function(name)
    local playerData = sharedObject.GetPlayerData()
    for k,v in ipairs(playerData.inventory) do
        if v.name == name then
            return true
        end
    end
    return false
end

Framework.spawnVehicle = sharedObject.Game.SpawnVehicle

Framework.spawnLocalVehicle = sharedObject.Game.SpawnLocalVehicle

Framework.deleteVehicle = sharedObject.Game.DeleteVehicle

Framework.getPlayersInArea = sharedObject.Game.GetPlayersInArea
