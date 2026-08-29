Queries = {
    getGarage = 'SELECT * FROM %s WHERE owner = ? and job is NULL',
    getGarageSociety = 'SELECT * FROM %s WHERE job = ?',
    getImpound = 'SELECT * FROM %s WHERE owner = ? and `stored` = 0 and job is NULL',
    getImpoundSociety = 'SELECT * FROM %s WHERE job = ? and `stored` = 0',
    getStoredVehicle = 'SELECT * FROM %s WHERE (owner = ? or job = ?) and plate = ? and `stored` = ?',
    getStoredVehiclePersonal = 'SELECT * FROM %s WHERE owner = ? and plate = ? and job is NULL and `stored` = 1 LIMIT 1',
    getStoredVehicleSociety = 'SELECT * FROM %s WHERE job = ? and plate = ? and `stored` = 1 LIMIT 1',
    getOutVehiclePersonal = 'SELECT * FROM %s WHERE owner = ? and plate = ? and job is NULL and `stored` = 0 LIMIT 1',
    getOutVehicleSociety = 'SELECT * FROM %s WHERE job = ? and plate = ? and `stored` = 0 LIMIT 1',
    setStoredVehicle = 'UPDATE %s SET `stored` = ? WHERE plate = ?',
    getOwnedVehicle = 'SELECT * FROM %s WHERE (owner = ? or job = ?) and plate = ?',
    getVehicle = 'SELECT * FROM %s WHERE owner = ? and plate = ?',
    getVehicleStrict = 'SELECT * FROM %s WHERE owner = ? and plate = ? and job is NULL',
    getVehicleJobStrict = 'SELECT * FROM %s WHERE job = ? and plate = ?',
    transferVehiclePlayer = 'UPDATE %s SET owner = ? WHERE plate = ?',
    transferVehicleSociety = 'UPDATE %s SET job = ? WHERE plate = ?',
    withdrawVehicleSociety = 'UPDATE %s SET job = NULL WHERE plate = ?',
    getStoredGarage = 'SELECT * FROM %s WHERE owner = ? and job is NULL and `stored` = 1'
}

local table
if Framework.name == 'es_extended' then
    table = 'owned_vehicles'
    Queries.setVehicleProps = 'UPDATE %s SET vehicle = ? WHERE plate = ?'
elseif Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
    table = 'player_vehicles'
    Queries.setVehicleProps = 'UPDATE %s SET mods = ? WHERE plate = ?'
else
    error(('%s framework isn\'t supported by default, you have to implement it yourself.'))
end

for key, query in pairs(Queries) do
    Queries[key] = query:format(table)
    if Framework.name == 'qb-core' or Framework.name == 'qbx_core' then
        Queries[key] = Queries[key]:gsub('owner', 'citizenid')
    end
end

-- DRS-owned impound metadata is deliberately kept outside the framework query
-- formatter above. In particular, the QB owner->citizenid replacement must
-- never rewrite identifiers or columns in this table.
ImpoundQueries = {
    getByPlate = [[
        SELECT `impound_id`, `plate`, `vehicle_row_id`, `ownership_type`, `owner_key`,
               `reason`, `fee`, `release_mode`, `impounded_by_identifier`, `impounded_by_name`,
               `impounded_by_job`, `impounded_by_grade`, `source_resource`, `impounded_at`
        FROM `drs_vehicle_impounds`
        WHERE `plate` = ?
        LIMIT 1
    ]],
    getAll = [[
        SELECT `impound_id`, `plate`, `vehicle_row_id`, `ownership_type`, `owner_key`,
               `reason`, `fee`, `release_mode`, `impounded_by_identifier`, `impounded_by_name`,
               `impounded_by_job`, `impounded_by_grade`, `source_resource`, `impounded_at`
        FROM `drs_vehicle_impounds`
    ]],
    insert = [[
        INSERT INTO `drs_vehicle_impounds`
            (`impound_id`, `plate`, `vehicle_row_id`, `ownership_type`, `owner_key`,
             `reason`, `fee`, `release_mode`, `impounded_by_identifier`,
             `impounded_by_name`, `impounded_by_job`, `impounded_by_grade`,
             `source_resource`, `impounded_at`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]],
    insertAfterChangedRow = [[
        INSERT INTO `drs_vehicle_impounds`
            (`impound_id`, `plate`, `vehicle_row_id`, `ownership_type`, `owner_key`,
             `reason`, `fee`, `release_mode`, `impounded_by_identifier`,
             `impounded_by_name`, `impounded_by_job`, `impounded_by_grade`,
             `source_resource`, `impounded_at`)
        SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        WHERE ROW_COUNT() = 1
    ]],
    deleteExact = [[
        DELETE FROM `drs_vehicle_impounds`
        WHERE `impound_id` = ? AND `plate` = ?
        LIMIT 1
    ]],
    deleteExactAfterChangedRow = [[
        DELETE FROM `drs_vehicle_impounds`
        WHERE `impound_id` = ? AND `plate` = ? AND ROW_COUNT() = 1
        LIMIT 1
    ]]
}
