-- DRS Garages Contract V2 journal schema repair
--
-- Stop drs_garages before running this file. This migration never drops the
-- source table or deletes journal rows. It first copies the complete current
-- table into `drs_vehicle_contract_operations_repair_backup`.
--
-- If a required column is missing, or existing data cannot fit the exact V2
-- definitions, the ALTER statement fails in strict mode and the original rows
-- remain available. Do not mark unresolved operations complete merely to make
-- this migration pass; inspect them with staff first.

CREATE TABLE IF NOT EXISTS `drs_vehicle_contract_operations_repair_backup`
LIKE `drs_vehicle_contract_operations`;

INSERT IGNORE INTO `drs_vehicle_contract_operations_repair_backup`
SELECT * FROM `drs_vehicle_contract_operations`;

SET @drs_contract_previous_sql_mode = @@SESSION.sql_mode;
SET SESSION sql_mode = CONCAT_WS(',', @@SESSION.sql_mode, 'STRICT_ALL_TABLES');

ALTER TABLE `drs_vehicle_contract_operations`
    ENGINE = InnoDB,
    DEFAULT CHARACTER SET = utf8mb4,
    COLLATE = utf8mb4_unicode_ci,
    MODIFY COLUMN `operation_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    MODIFY COLUMN `operation_type` VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    MODIFY COLUMN `status` VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    MODIFY COLUMN `step` VARCHAR(48) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    MODIFY COLUMN `active_plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NULL,
    MODIFY COLUMN `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    MODIFY COLUMN `vehicle_row_id` VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL,
    MODIFY COLUMN `actor_identifier` VARCHAR(80) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    MODIFY COLUMN `counterparty_identifier` VARCHAR(80) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL,
    MODIFY COLUMN `job` VARCHAR(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL,
    MODIFY COLUMN `price` INT UNSIGNED NOT NULL DEFAULT 0,
    MODIFY COLUMN `payment_account` VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'money',
    MODIFY COLUMN `item_name` VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL,
    MODIFY COLUMN `item_removed` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `money_debited` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `ownership_changed` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `money_credited` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `keys_updated` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `compensated` TINYINT NOT NULL DEFAULT 0,
    MODIFY COLUMN `failure_text` VARCHAR(1000) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NULL,
    MODIFY COLUMN `created_at` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `updated_at` BIGINT UNSIGNED NOT NULL,
    MODIFY COLUMN `completed_at` BIGINT UNSIGNED NULL;

-- Remove only DRS-owned index names and recreate them in one ALTER statement.
-- Keeping this as one statement prevents a failed uniqueness check from
-- leaving the live table without its previous indexes.
SET @drs_contract_schema = DATABASE();

SET @drs_contract_drop_primary = IF(
    EXISTS(
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_contract_schema
          AND TABLE_NAME = 'drs_vehicle_contract_operations'
          AND INDEX_NAME = 'PRIMARY'
    ),
    'DROP PRIMARY KEY, ',
    ''
);

SET @drs_contract_drop_active = IF(
    EXISTS(
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_contract_schema
          AND TABLE_NAME = 'drs_vehicle_contract_operations'
          AND INDEX_NAME = 'ux_drs_vehicle_contract_active_plate'
    ),
    'DROP INDEX `ux_drs_vehicle_contract_active_plate`, ',
    ''
);

SET @drs_contract_drop_status = IF(
    EXISTS(
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_contract_schema
          AND TABLE_NAME = 'drs_vehicle_contract_operations'
          AND INDEX_NAME = 'idx_drs_vehicle_contract_status_updated'
    ),
    'DROP INDEX `idx_drs_vehicle_contract_status_updated`, ',
    ''
);

SET @drs_contract_drop_plate = IF(
    EXISTS(
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = @drs_contract_schema
          AND TABLE_NAME = 'drs_vehicle_contract_operations'
          AND INDEX_NAME = 'idx_drs_vehicle_contract_plate_created'
    ),
    'DROP INDEX `idx_drs_vehicle_contract_plate_created`, ',
    ''
);

SET @drs_contract_sql = CONCAT(
    'ALTER TABLE `drs_vehicle_contract_operations` ',
    @drs_contract_drop_primary,
    @drs_contract_drop_active,
    @drs_contract_drop_status,
    @drs_contract_drop_plate,
    'ADD PRIMARY KEY (`operation_id`), ',
    'ADD UNIQUE KEY `ux_drs_vehicle_contract_active_plate` (`active_plate`), ',
    'ADD KEY `idx_drs_vehicle_contract_status_updated` (`status`, `updated_at`), ',
    'ADD KEY `idx_drs_vehicle_contract_plate_created` (`plate`, `created_at`)'
);
PREPARE drs_contract_statement FROM @drs_contract_sql;
EXECUTE drs_contract_statement;
DEALLOCATE PREPARE drs_contract_statement;

SET SESSION sql_mode = @drs_contract_previous_sql_mode;

SELECT
    (SELECT COUNT(*) FROM `drs_vehicle_contract_operations`) AS `journal_rows`,
    (SELECT COUNT(*) FROM `drs_vehicle_contract_operations_repair_backup`) AS `backup_rows`;

-- Restart drs_garages and run `drsgarages:doctor`. Keep the backup until the
-- doctor passes and every `drsgarages:contracts` entry has been reconciled.
