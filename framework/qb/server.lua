-- qbx_core advertises a qb-core compatibility alias. Leave Qbox exclusively to
-- the native Qbox adapter instead of initializing both adapters in sequence.
if GetResourceState('qbx_core') == 'started' or GetResourceState('qb-core') ~= 'started' then return end

Framework = { name = 'qb-core' }
local sharedObject = exports['qb-core']:GetCoreObject()
QBCore = sharedObject
local player = {}

---@diagnostic disable-next-line: duplicate-set-field
function Framework.getPlayerFromId(id)
    local player = setmetatable({}, { __index = player })
    player.QBPlayer = sharedObject.Functions.GetPlayer(id)
    if not player.QBPlayer then return end
    player.source = id

    return player
end

Framework.registerUsableItem = sharedObject.Functions.CreateUseableItem

Framework.getPlayers = sharedObject.Functions.GetQBPlayers

local ox_inventory = GetResourceState('ox_inventory') == 'started'

function Framework.getItemLabel(item)
    if ox_inventory then
        return exports.ox_inventory:Items()[item]?.label
    end
    return sharedObject.Shared.Items[item]?.label
end

function player:hasGroup(name)
    return sharedObject.Functions.HasPermission(self.source, name) == name
end

function player:hasOneOfGroups(groups)
    for k,v in pairs(groups) do
        if sharedObject.Functions.HasPermission(self.source, k) then
            return true
        end
    end

    return false
end

function player:addItem(name, count)
    local before = self:getItemCount(name)
    local result = self.QBPlayer.Functions.AddItem(name, count)

    if result ~= nil then return result == true end
    return self:getItemCount(name) >= before + count
end

function player:removeItem(name, count)
    local before = self:getItemCount(name)
    if before < count then return false end

    local result = self.QBPlayer.Functions.RemoveItem(name, count)
    if result ~= nil then return result == true end

    return self:getItemCount(name) <= before - count
end

function player:canCarryItem(name, count)
    return true
end

function player:getItemCount(name)
    return self.QBPlayer.Functions.GetItemByName(name)?.amount or 0
end

function player:getAccountMoney(account)
    if account == 'money' then
        return self.QBPlayer.Functions.GetMoney('cash')
    else
        return self.QBPlayer.Functions.GetMoney(account)
    end
end

function player:addAccountMoney(account, amount)
    if amount == 0 then return true end

    local normalized = account == 'money' and 'cash' or account
    local before = self.QBPlayer.Functions.GetMoney(normalized) or 0
    local result

    if account == 'money' then
        result = self.QBPlayer.Functions.AddMoney('cash', amount, 'drs_garages')
    else
        result = self.QBPlayer.Functions.AddMoney(account, amount, 'drs_garages')
    end

    if result ~= nil then return result == true end
    return (self.QBPlayer.Functions.GetMoney(normalized) or 0) >= before + amount
end

function player:removeAccountMoney(account, amount)
    if amount == 0 then return true end

    local normalized = account == 'money' and 'cash' or account
    local before = self.QBPlayer.Functions.GetMoney(normalized) or 0
    if before < amount then return false end

    local result

    if account == 'money' then
        result = self.QBPlayer.Functions.RemoveMoney('cash', amount, 'drs_garages')
    else
        result = self.QBPlayer.Functions.RemoveMoney(account, amount, 'drs_garages')
    end

    if result ~= nil then return result == true end
    return (self.QBPlayer.Functions.GetMoney(normalized) or 0) <= before - amount
end

function player:getJob()
    return self.QBPlayer.PlayerData.job.name
end

function player:isJobBoss()
    local job = self.QBPlayer.PlayerData.job
    return job and job.isboss == true or false
end

function player:getIdentifier()       
    return self.QBPlayer.PlayerData.citizenid
end

function player:getLicense()
    if self.QBPlayer.PlayerData.license then
        return self.QBPlayer.PlayerData.license
    end

    for _, identifier in ipairs(GetPlayerIdentifiers(self.source)) do
        if identifier:sub(1, 8) == 'license:' then
            return identifier
        end
    end
end

function player:getFirstName()
    return self.QBPlayer.PlayerData.charinfo.firstname
end

function player:getLastName()
    return self.QBPlayer.PlayerData.charinfo.lastname
end
