-- DRS Garages job-fleet metadata and durable operation journal.
-- Config.Database.AutoMigrate creates these tables automatically. Import this
-- file only when automatic migration is disabled or the database user cannot
-- CREATE tables. Framework-owned vehicle rows remain in player_vehicles or
-- owned_vehicles; these tables only hold DRS metadata and an audit trail.

CREATE TABLE IF NOT EXISTS `drs_job_fleet_vehicles` (
    `vehicle_row_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `job` VARCHAR(50) NOT NULL,
    `model` VARCHAR(64) NOT NULL,
    `vehicle_type` VARCHAR(20) NOT NULL,
    `garage` VARCHAR(50) NOT NULL,
    `min_grade` INT UNSIGNED NOT NULL DEFAULT 0,
    `status` VARCHAR(16) NOT NULL DEFAULT 'active',
    `added_by_identifier` VARCHAR(80) NOT NULL,
    `added_by_name` VARCHAR(100) NOT NULL,
    `added_at` BIGINT UNSIGNED NOT NULL,
    `updated_at` BIGINT UNSIGNED NOT NULL,
    `retired_at` BIGINT UNSIGNED NULL,
    `retire_reason` VARCHAR(500) NULL,
    PRIMARY KEY (`vehicle_row_id`),
    UNIQUE KEY `ux_drs_job_fleet_plate` (`plate`),
    KEY `idx_drs_job_fleet_job_status` (`job`, `status`),
    KEY `idx_drs_job_fleet_job_garage` (`job`, `garage`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `drs_job_fleet_operations` (
    `operation_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `external_request_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `action` VARCHAR(32) NOT NULL,
    `status` VARCHAR(16) NOT NULL DEFAULT 'pending',
    `vehicle_row_id` VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    `plate` VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    `job` VARCHAR(50) NOT NULL,
    `model` VARCHAR(64) NULL,
    `garage_from` VARCHAR(50) NULL,
    `garage_to` VARCHAR(50) NULL,
    `min_grade` INT UNSIGNED NULL,
    `actor_source` INT UNSIGNED NOT NULL DEFAULT 0,
    `actor_identifier` VARCHAR(80) NOT NULL,
    `actor_name` VARCHAR(100) NOT NULL,
    `actor_job` VARCHAR(50) NULL,
    `actor_grade` INT NOT NULL DEFAULT 0,
    `source_resource` VARCHAR(64) NOT NULL DEFAULT 'drs_garages',
    `reason` VARCHAR(500) NULL,
    `vehicle_snapshot` LONGTEXT NULL,
    `request_json` LONGTEXT NULL,
    `error_code` VARCHAR(100) NULL,
    `error_detail` VARCHAR(500) NULL,
    `created_at` BIGINT UNSIGNED NOT NULL,
    `updated_at` BIGINT UNSIGNED NOT NULL,
    `completed_at` BIGINT UNSIGNED NULL,
    PRIMARY KEY (`operation_id`),
    UNIQUE KEY `ux_drs_job_fleet_external_request` (`source_resource`, `external_request_id`),
    KEY `idx_drs_job_fleet_operations_plate` (`plate`, `created_at`),
    KEY `idx_drs_job_fleet_operations_job` (`job`, `created_at`),
    KEY `idx_drs_job_fleet_operations_status` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
