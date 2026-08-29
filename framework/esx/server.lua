if GetResourceState('es_extended') ~= 'started' then return end

Framework = { name = 'es_extended' }
local sharedObject = exports['es_extended']:getSharedObject()
local player = {}

---@diagnostic disable-next-line: duplicate-set-field
Framework.getPlayerFromId = function(id)
    local player = setmetatable({}, { __index = player })
    player.xPlayer = sharedObject.GetPlayerFromId(id)
    if not player.xPlayer then return end
    player.source = id

    return player
end

Framework.registerUsableItem = sharedObject.RegisterUsableItem

Framework.getPlayers = sharedObject.GetExtendedPlayers

Framework.getItemLabel = sharedObject.GetItemLabel

function player:hasGroup(name)
    return self.xPlayer.getGroup() == name
end

function player:hasOneOfGroups(groups)
    return groups[self.xPlayer.getGroup()] or false
end

function player:addItem(name, count)
    if not self:canCarryItem(name, count) then return false end

    local before = self:getItemCount(name)
    self.xPlayer.addInventoryItem(name, count)
    return self:getItemCount(name) >= before + count
end

function player:removeItem(name, count)
    local before = self:getItemCount(name)
    if before < count then return false end

    self.xPlayer.removeInventoryItem(name, count)
    return self:getItemCount(name) <= before - count
end

function player:canCarryItem(name, count)
    return self.xPlayer.canCarryItem(name, count)
end

function player:getItemCount(name)
    return self.xPlayer.getInventoryItem(name).count
end

function player:getAccountMoney(account)
    return self.xPlayer.getAccount(account).money
end

function player:addAccountMoney(account, amount)
    if amount == 0 then return true end

    local before = self:getAccountMoney(account)
    self.xPlayer.addAccountMoney(account, amount)
    return self:getAccountMoney(account) >= before + amount
end

function player:removeAccountMoney(account, amount)
    if amount == 0 then return true end

    local before = self:getAccountMoney(account)
    if before < amount then return false end

    self.xPlayer.removeAccountMoney(account, amount)
    return self:getAccountMoney(account) <= before - amount
end

function player:getJob()
    return self.xPlayer.getJob().name
end

function player:getJobData()
    local job = self.xPlayer.getJob() or {}
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

function player:isJobBoss()
    local job = self.xPlayer.getJob()
    return job and (job.isboss == true or job.grade_name == 'boss') or false
end

function player:getIdentifier()
    return self.xPlayer.getIdentifier()
end

function player:getLicense()
    return self:getIdentifier()
end

function player:getFirstName()
    return self.xPlayer.get('firstName')
end

function player:getLastName()
    return self.xPlayer.get('lastName')
end
