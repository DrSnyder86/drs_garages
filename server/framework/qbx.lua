if GetResourceState('qbx_core') ~= 'started' then return end

Framework = { name = 'qbx_core' }
local player = {}
local ox_inventory = GetResourceState('ox_inventory') == 'started'

---@diagnostic disable-next-line: duplicate-set-field
function Framework.getPlayerFromId(id)
    local qbxPlayer = exports.qbx_core:GetPlayer(id)
    if not qbxPlayer then return end

    local wrapper = setmetatable({}, { __index = player })
    wrapper.QBXPlayer = qbxPlayer
    wrapper.PlayerData = qbxPlayer.PlayerData or {}
    wrapper.source = id

    return wrapper
end

Framework.registerUsableItem = function(item, cb)
    exports.qbx_core:CreateUseableItem(item, function(source, itemData)
        cb(source, itemData)
    end)
end

Framework.getPlayers = function()
    local players = {}

    for _, id in ipairs(GetPlayers()) do
        local source = tonumber(id)
        local qbxPlayer = exports.qbx_core:GetPlayer(source)

        if qbxPlayer then
            players[source] = qbxPlayer
        end
    end

    return players
end

function Framework.getItemLabel(item)
    if ox_inventory then
        local items = exports.ox_inventory:Items()
        return items[item] and items[item].label or item
    end

    return item
end

function player:hasGroup(name)
    return exports.qbx_core:HasGroup(self.source, name) == true
end

function player:hasOneOfGroups(groups)
    for group in pairs(groups) do
        if exports.qbx_core:HasGroup(self.source, group) then
            return true
        end
    end

    return false
end

function player:addItem(name, count)
    if ox_inventory then
        return exports.ox_inventory:AddItem(self.source, name, count)
    end

    if self.QBXPlayer.Functions and self.QBXPlayer.Functions.AddItem then
        return self.QBXPlayer.Functions.AddItem(name, count)
    end
end

function player:removeItem(name, count)
    if ox_inventory then
        return exports.ox_inventory:RemoveItem(self.source, name, count)
    end

    if self.QBXPlayer.Functions and self.QBXPlayer.Functions.RemoveItem then
        return self.QBXPlayer.Functions.RemoveItem(name, count)
    end
end

function player:canCarryItem(name, count)
    if ox_inventory then
        return exports.ox_inventory:CanCarryItem(self.source, name, count)
    end

    return true
end

function player:getItemCount(name)
    if ox_inventory then
        return exports.ox_inventory:GetItemCount(self.source, name)
    end

    if self.QBXPlayer.Functions and self.QBXPlayer.Functions.GetItemByName then
        local item = self.QBXPlayer.Functions.GetItemByName(name)
        return item and item.amount or 0
    end

    return 0
end

local function normalizeAccount(account)
    return account == 'money' and 'cash' or account
end

function player:getAccountMoney(account)
    return exports.qbx_core:GetMoney(self.source, normalizeAccount(account)) or 0
end

function player:addAccountMoney(account, amount)
    return exports.qbx_core:AddMoney(self.source, normalizeAccount(account), amount, 'drs_garages')
end

function player:removeAccountMoney(account, amount)
    return exports.qbx_core:RemoveMoney(self.source, normalizeAccount(account), amount, 'drs_garages')
end

function player:getJob()
    return self.PlayerData.job and self.PlayerData.job.name or 'unemployed'
end

function player:getIdentifier()
    return self.PlayerData.citizenid
end

function player:getFirstName()
    local charinfo = self.PlayerData.charinfo or {}
    return charinfo.firstname or self.PlayerData.name or GetPlayerName(self.source) or 'Unknown'
end

function player:getLastName()
    local charinfo = self.PlayerData.charinfo or {}
    return charinfo.lastname or ''
end
