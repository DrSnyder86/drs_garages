-- Repairs existing QB/Qbox vehicle rows where `stored` and `state` drifted apart.
-- This returns normal out vehicles to garages, matching Config.AutoRespawn = true,
-- while preserving the framework's state 2 impound rows.
--
-- OFFLINE REPAIR ONLY: stop the FiveM server (including drs_garages and every
-- vehicle persistence resource), verify no live vehicle entities remain, and
-- take a current database backup before running this file. Rows containing a
-- NULL or unsupported stored/state value are intentionally left unchanged for
-- manual investigation.

UPDATE `player_vehicles`
SET `stored` = 0
WHERE `state` = 2 AND `stored` IN (0, 1);

UPDATE `player_vehicles`
SET `stored` = 1, `state` = 1
WHERE `state` IN (0, 1) AND `stored` IN (0, 1);
