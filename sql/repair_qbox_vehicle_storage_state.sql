-- Repairs existing QB/Qbox vehicle rows where `stored` and `state` drifted apart.
-- This also returns currently out vehicles to garages, matching Config.AutoRespawn = true.

UPDATE `player_vehicles`
SET `stored` = 1, `state` = 1
WHERE `stored` = 1 OR `state` = 1;

UPDATE `player_vehicles`
SET `stored` = 1, `state` = 1
WHERE `stored` = 0 OR `state` = 0;
