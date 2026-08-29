-- DRS Garages enforcement-impound metadata.
-- Config.Database.AutoMigrate creates and validates this table automatically.
-- Import this file only when automatic migration is disabled or the database
-- user does not have CREATE permission.

CREATE TABLE IF NOT EXISTS `drs_vehicle_impounds` (
    `impound_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `vehicle_row_id` VARCHAR(64) NOT NULL,
    `ownership_type` VARCHAR(16) NOT NULL,
    `owner_key` VARCHAR(80) NOT NULL,
    `reason` VARCHAR(500) NOT NULL,
    `fee` INT UNSIGNED NOT NULL DEFAULT 0,
    `release_mode` VARCHAR(16) NOT NULL DEFAULT 'payable',
    `impounded_by_identifier` VARCHAR(80) NOT NULL,
    `impounded_by_name` VARCHAR(100) NOT NULL,
    `impounded_by_job` VARCHAR(50) NOT NULL,
    `impounded_by_grade` INT NOT NULL DEFAULT 0,
    `source_resource` VARCHAR(64) NOT NULL DEFAULT 'drs_garages',
    `impounded_at` BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (`impound_id`),
    UNIQUE KEY `ux_drs_vehicle_impounds_plate` (`plate`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
