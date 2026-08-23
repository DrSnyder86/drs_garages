-- DRS Garages QB/Qbox database fallback.
-- Compatible with Oracle MySQL 8 and MariaDB.
--
-- Run this with a database-administrator account against the database that
-- already contains the framework's player_vehicles table. It conditionally adds
-- only missing compatibility columns and indexes. It never drops or recreates
-- the table, and it never resolves, deletes, or merges duplicate vehicle rows.

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
SET @drs_has_storage_state_source = IF(@drs_had_stored = 1 OR @drs_had_state = 1, 1, 0);

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
    SELECT IF(@drs_has_storage_state_source = 0,
        'SELECT ''[DRS][FAIL] Both stored and state are missing. Reconcile an authoritative vehicle-location column manually; this script will not guess.'' AS `drs_garages_status`',
        IF(
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
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = (
    SELECT IF(@drs_has_storage_state_source = 0,
        'SELECT ''[DRS][FAIL] Both stored and state are missing. Reconcile an authoritative vehicle-location column manually; this script will not guess.'' AS `drs_garages_status`',
        IF(
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
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_migration_sql = IF(
    @drs_has_storage_state_source = 0,
    'SELECT ''[DRS][FAIL] Storage-state synchronization was skipped because both source columns were missing.'' AS `drs_garages_status`',
    IF(@drs_had_stored = 0 AND @drs_had_state = 1,
    'UPDATE `player_vehicles` SET `stored` = CASE WHEN `state` = 1 THEN 1 ELSE 0 END',
    IF(
        @drs_had_stored = 1 AND @drs_had_state = 0,
        'UPDATE `player_vehicles` SET `state` = CASE WHEN `stored` = 1 THEN 1 ELSE 0 END',
        'SELECT 1'
    )
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

-- A lookup index is ready only when its canonical name has the exact ordered,
-- non-UNIQUE, full-column signature expected by the runtime. A same-name index
-- with a different definition is reported and left untouched for manual review.
SET @drs_has_citizen_lookup_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_citizenid_type_stored'
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 3
           AND MIN(NON_UNIQUE) = 1
           AND MAX(NON_UNIQUE) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 1 AND LOWER(COLUMN_NAME) = 'citizenid' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 2 AND LOWER(COLUMN_NAME) = 'type' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 3 AND LOWER(COLUMN_NAME) = 'stored' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
    )
);

SET @drs_named_citizen_lookup_exists = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_citizenid_type_stored'
    )
);

SET @drs_migration_sql = IF(
    @drs_has_storage_state_source = 0,
    'SELECT ''[DRS][FAIL] Lookup indexes were skipped because no authoritative stored/state source exists.'' AS `drs_garages_status`',
    IF(
        @drs_has_citizen_lookup_index = 1,
        'SELECT 1',
        IF(
            @drs_named_citizen_lookup_exists = 1,
            'SELECT ''[DRS][FAIL] Index idx_player_vehicles_citizenid_type_stored exists with the wrong definition. Expected a non-UNIQUE full-column (citizenid, type, stored) index in that order; DRS will not drop or replace it.'' AS `drs_garages_status`',
            'CREATE INDEX `idx_player_vehicles_citizenid_type_stored` ON `player_vehicles` (`citizenid`, `type`, `stored`)'
        )
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

SET @drs_has_job_lookup_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_job_type_stored'
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 3
           AND MIN(NON_UNIQUE) = 1
           AND MAX(NON_UNIQUE) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 1 AND LOWER(COLUMN_NAME) = 'job' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 2 AND LOWER(COLUMN_NAME) = 'type' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 3 AND LOWER(COLUMN_NAME) = 'stored' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
    )
);

SET @drs_named_job_lookup_exists = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_job_type_stored'
    )
);

SET @drs_migration_sql = IF(
    @drs_has_storage_state_source = 0,
    'SELECT ''[DRS][FAIL] Lookup indexes were skipped because no authoritative stored/state source exists.'' AS `drs_garages_status`',
    IF(
        @drs_has_job_lookup_index = 1,
        'SELECT 1',
        IF(
            @drs_named_job_lookup_exists = 1,
            'SELECT ''[DRS][FAIL] Index idx_player_vehicles_job_type_stored exists with the wrong definition. Expected a non-UNIQUE full-column (job, type, stored) index in that order; DRS will not drop or replace it.'' AS `drs_garages_status`',
            'CREATE INDEX `idx_player_vehicles_job_type_stored` ON `player_vehicles` (`job`, `type`, `stored`)'
        )
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

-- A plate identifies exactly one owned vehicle throughout DRS. Report
-- normalized duplicates before attempting to enforce the invariant. This is a
-- read-only check: duplicate rows must be reviewed and resolved by an
-- administrator after a backup.
SET @drs_duplicate_plate_groups = (
    SELECT COUNT(*)
    FROM (
        SELECT UPPER(TRIM(`plate`)) AS `normalized_plate`
        FROM `player_vehicles`
        WHERE `plate` IS NOT NULL
        GROUP BY UPPER(TRIM(`plate`))
        HAVING COUNT(*) > 1
    ) AS `drs_duplicate_groups`
);

SELECT
    UPPER(TRIM(`plate`)) AS `duplicate_normalized_plate`,
    COUNT(*) AS `row_count`
FROM `player_vehicles`
WHERE `plate` IS NOT NULL
GROUP BY UPPER(TRIM(`plate`))
HAVING COUNT(*) > 1
ORDER BY `row_count` DESC, `duplicate_normalized_plate` ASC
LIMIT 25;

-- Accept an existing UNIQUE index under any name only when it covers the full
-- plate column and no other columns. Prefix indexes are intentionally rejected.
SET @drs_has_unique_plate_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND NON_UNIQUE = 0
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 1
           AND MAX(
                CASE
                    WHEN SEQ_IN_INDEX = 1
                     AND LOWER(COLUMN_NAME) = 'plate'
                     AND SUB_PART IS NULL
                    THEN 1 ELSE 0
                END
           ) = 1
    )
);

SET @drs_named_plate_index_exists = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'ux_player_vehicles_plate'
    )
);

SET @drs_migration_sql = IF(
    @drs_has_storage_state_source = 0,
    'SELECT ''[DRS][FAIL] UNIQUE plate migration was skipped because no authoritative stored/state source exists.'' AS `drs_garages_status`',
    IF(
        @drs_duplicate_plate_groups > 0,
        CONCAT(
            'SELECT ''[DRS][FAIL] UNIQUE plate index was not created: ',
            @drs_duplicate_plate_groups,
            ' duplicate normalized plate group(s) exist. Back up the database, inspect the result set above, and resolve every duplicate manually.'' AS `drs_garages_status`'
        ),
        IF(
            @drs_has_unique_plate_index = 1,
            'SELECT ''[DRS][PASS] A UNIQUE full-column plate index already exists.'' AS `drs_garages_status`',
            IF(
                @drs_named_plate_index_exists = 1,
                'SELECT ''[DRS][FAIL] Index ux_player_vehicles_plate already exists with the wrong definition. DRS will not drop or replace it; correct it manually.'' AS `drs_garages_status`',
                'CREATE UNIQUE INDEX `ux_player_vehicles_plate` ON `player_vehicles` (`plate`)'
            )
        )
    )
);
PREPARE drs_migration_statement FROM @drs_migration_sql;
EXECUTE drs_migration_statement;
DEALLOCATE PREPARE drs_migration_statement;

-- Re-check every index invariant and print one final result. A FAIL result means
-- DRS will keep its database-backed garage features unavailable until the
-- schema is fixed.
SET @drs_has_unique_plate_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND NON_UNIQUE = 0
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 1
           AND MAX(
                CASE
                    WHEN SEQ_IN_INDEX = 1
                     AND LOWER(COLUMN_NAME) = 'plate'
                     AND SUB_PART IS NULL
                    THEN 1 ELSE 0
                END
           ) = 1
    )
);

SET @drs_has_citizen_lookup_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_citizenid_type_stored'
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 3
           AND MIN(NON_UNIQUE) = 1
           AND MAX(NON_UNIQUE) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 1 AND LOWER(COLUMN_NAME) = 'citizenid' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 2 AND LOWER(COLUMN_NAME) = 'type' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 3 AND LOWER(COLUMN_NAME) = 'stored' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
    )
);

SET @drs_has_job_lookup_index = (
    SELECT EXISTS (
        SELECT 1
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_schema_name
          AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'idx_player_vehicles_job_type_stored'
        GROUP BY INDEX_NAME
        HAVING COUNT(*) = 3
           AND MIN(NON_UNIQUE) = 1
           AND MAX(NON_UNIQUE) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 1 AND LOWER(COLUMN_NAME) = 'job' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 2 AND LOWER(COLUMN_NAME) = 'type' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
           AND MAX(CASE WHEN SEQ_IN_INDEX = 3 AND LOWER(COLUMN_NAME) = 'stored' AND SUB_PART IS NULL THEN 1 ELSE 0 END) = 1
    )
);

SELECT CASE
    WHEN @drs_has_storage_state_source = 0 THEN
        '[DRS][FAIL] Both stored and state were missing. Reconcile one authoritative vehicle-location source manually; no storage-state columns or indexes were created.'
    WHEN @drs_duplicate_plate_groups > 0 THEN CONCAT(
        '[DRS][FAIL] Schema is incomplete: ',
        @drs_duplicate_plate_groups,
        ' duplicate normalized plate group(s) require manual review.'
    )
    WHEN COALESCE(@drs_has_unique_plate_index, 0) <> 1 THEN
        '[DRS][FAIL] Schema is incomplete: no UNIQUE full-column player_vehicles.plate index exists.'
    WHEN COALESCE(@drs_has_citizen_lookup_index, 0) <> 1 THEN
        '[DRS][FAIL] Schema is incomplete: idx_player_vehicles_citizenid_type_stored is missing or does not have the exact non-UNIQUE full-column (citizenid, type, stored) signature.'
    WHEN COALESCE(@drs_has_job_lookup_index, 0) <> 1 THEN
        '[DRS][FAIL] Schema is incomplete: idx_player_vehicles_job_type_stored is missing or does not have the exact non-UNIQUE full-column (job, type, stored) signature.'
    ELSE
        '[DRS][PASS] The UNIQUE full-column plate invariant and both required lookup-index signatures are ready. Restart drs_garages to validate the complete schema.'
END AS `drs_garages_status`;

SET @drs_migration_sql = NULL;
SET @drs_named_job_lookup_exists = NULL;
SET @drs_has_job_lookup_index = NULL;
SET @drs_named_citizen_lookup_exists = NULL;
SET @drs_has_citizen_lookup_index = NULL;
SET @drs_named_plate_index_exists = NULL;
SET @drs_has_unique_plate_index = NULL;
SET @drs_duplicate_plate_groups = NULL;
SET @drs_had_state = NULL;
SET @drs_had_stored = NULL;
SET @drs_has_storage_state_source = NULL;
SET @drs_schema_name = NULL;
