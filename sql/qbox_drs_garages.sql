-- DRS Garages QB/Qbox database fallback.
-- Compatible with Oracle MySQL 8 and MariaDB.
--
-- Run this with a database-administrator account against the database that
-- already contains the framework's player_vehicles table. It conditionally adds
-- only missing compatibility columns and named indexes. It never drops or
-- recreates the table.

SET @drs_schema_name = DATABASE();

-- Preserve which storage-state column(s) existed before this migration. When
-- exactly one existed, its values remain authoritative for the newly-added side.
SET @drs_had_stored = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND COLUMN_NAME = 'stored'
    )
);
SET @drs_had_state = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND COLUMN_NAME = 'state'
    )
);

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND COLUMN_NAME = 'job'
        ),
        'SELECT 1',
        'ALTER TABLE `player_vehicles` ADD COLUMN `job` VARCHAR(50) NULL DEFAULT NULL'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND COLUMN_NAME = 'type'
        ),
        'SELECT 1',
        'ALTER TABLE `player_vehicles` ADD COLUMN `type` VARCHAR(20) NOT NULL DEFAULT ''car'''
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND COLUMN_NAME = 'stored'
        ),
        'SELECT 1',
        'ALTER TABLE `player_vehicles` ADD COLUMN `stored` TINYINT(1) NOT NULL DEFAULT 1'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND COLUMN_NAME = 'state'
        ),
        'SELECT 1',
        'ALTER TABLE `player_vehicles` ADD COLUMN `state` INT(11) NOT NULL DEFAULT 1'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = IF(
    @drs_had_stored = 0 AND @drs_had_state = 1,
    'UPDATE `player_vehicles` SET `stored` = CASE WHEN `state` = 1 THEN 1 ELSE 0 END',
    IF(
        @drs_had_stored = 1 AND @drs_had_state = 0,
        'UPDATE `player_vehicles` SET `state` = CASE WHEN `stored` = 1 THEN 1 ELSE 0 END',
        'SELECT 1'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND INDEX_NAME = 'idx_player_vehicles_citizenid_type_stored'
        ),
        'SELECT 1',
        'CREATE INDEX `idx_player_vehicles_citizenid_type_stored` ON `player_vehicles` (`citizenid`, `type`, `stored`)'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND INDEX_NAME = 'idx_player_vehicles_job_type_stored'
        ),
        'SELECT 1',
        'CREATE INDEX `idx_player_vehicles_job_type_stored` ON `player_vehicles` (`job`, `type`, `stored`)'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(
        EXISTS (
            SELECT 1
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = @drs_schema_name
              AND TABLE_NAME = 'player_vehicles'
              AND INDEX_NAME = 'idx_player_vehicles_plate'
        ),
        'SELECT 1',
        'CREATE INDEX `idx_player_vehicles_plate` ON `player_vehicles` (`plate`)'
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = NULL;
SET @drs_had_state = NULL;
SET @drs_had_stored = NULL;
SET @drs_schema_name = NULL;
