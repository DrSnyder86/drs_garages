Config = {}
Config.MaxDistance = 10.0 -- Max interact distance
Config.MaxVehiclePropsBytes = 64 * 1024 -- Maximum encoded vehicle-properties payload accepted when parking (64 KiB).
Config.PropertyGarageDistance = 3.0 -- Property garage TextUI interact distance
Config.PropertyGarageParkingDistance = 3.0 -- Property garage vehicle parking TextUI distance
Config.UseKeySystem = true -- Qbox and current qb-vehiclekeys keys are issued by validated server flows.
Config.SpawnpointCheck = true -- Checks if the vehicle spawnpoint is empty before spawning it.
Config.AutoRespawn = true -- True == auto respawn cars that are outside into your garage on script restart, false == does not put them into your garage and players have to go to the impound

-- Vehicle storage visibility. `global` preserves the original behavior, `garage`
-- keeps vehicles at their exact public/property garage, and `property` keeps the
-- public network global while isolating each property garage.
Config.Storage = {
    Mode = 'global', -- global, garage, property
    DefaultGarages = {
        car = 'pillboxgarage',
        boat = 'lsymcboathouse',
        air = 'airporthangar'
    },
    -- In garage mode, recover NULL/empty/stale garage values at the type's
    -- configured default instead of leaving legacy vehicles inaccessible.
    RecoverUnassigned = true,
    -- Recover vehicles from deleted/sold properties or after keyholder access is
    -- removed. Recovery is virtual until the vehicle is parked again.
    RecoverInaccessibleProperties = true
}

-- Idempotent startup installer. It creates the namespaced DRS impound table and
-- only adds missing compatibility columns/indexes to an existing QB/Qbox
-- player_vehicles table; it never drops or recreates framework vehicle data.
Config.Database = {
    AutoMigrate = true
}

-- Stock resource integrations are detected at runtime. Housing data remains owned by
-- qb-houses; DRS reads and mirrors its garage access without writing housing tables.
Config.Integrations = {
    QbHousing = {
        Enabled = true,
        Resource = 'qb-houses',
        SyncInterval = 60000
    },
    QbApartments = {
        Enabled = true,
        Resource = 'qb-apartments'
    }
}

-- true/`auto` detects ox_target, qb-target, then qtarget. If none is running,
-- interactions fall back to ox_lib TextUI at Position or PedPosition.
-- You can also use false, a provider name, or { Enabled = true, Resource = 'ox_target' }.
-- Provider selection runs when drs_garages starts. Restart drs_garages after
-- starting, stopping, removing, or switching a target provider.
Config.Target = true

-- Nearby garage quality-of-life interactions. Radial providers are detected in
-- framework order: qbx_radialmenu, qb-radialmenu, then ox_lib's built-in radial.
-- Each feature can be disabled independently without removing the existing
-- attendant target, TextUI, or keybind interactions.
Config.RadialMenu = {
    Enabled = true,
    Provider = 'auto', -- auto, qbx_radialmenu, qb-radialmenu, ox_lib
    Distance = 10.0, -- Public/job garage entry distance; capped to Config.MaxDistance.
    PropertyDistance = 3.0 -- Property entry distance; capped to PropertyGarageDistance.
}

Config.Parking = {
    ProgressDuration = 5000, -- Milliseconds; set to 0 for immediate parking.
    ProgressCanCancel = true,
    MaximumSpeed = 0.5, -- Metres per second. Checked by both client and server.
    TargetEnabled = true,
    TargetDistance = 3.0
}

-- Vehicle-list presentation. `auto` uses the compact NUI when it has finished
-- loading and falls back to the original ox_lib context menu when necessary.
-- Set Mode to `nui` to prefer only the compact interface or `context` to always
-- use the original menus.
Config.Interface = {
    Mode = 'auto', -- auto, nui, context
    ContextFallback = true,
    VehicleShopResource = 'drs_vehicleshop',
    UseVehicleShopImages = true,
    UseCfxImages = true
}

---@alias VehicleType string

---@class BlipData
---@field Name string
---@field Sprite integer
---@field Size number
---@field Color integer

---@type table<VehicleType, table<'Garage' | 'Impound', BlipData>>
Config.Blips = {
    ['car'] = {
        Garage = {
            Name = 'Garage',
            Sprite = 357,
            Size = 0.5,
            Color = 38
        },
        Impound = {
            Name = 'Impound',
            Sprite = 357,
            Size = 0.5,
            Color = 5
        },
    },
    ['air'] = {
        Garage = {
            Name = 'Air Garage',
            Sprite = 759,
            Size = 0.5,
            Color = 17
        },
        Impound = {
            Name = 'Air Impound',
            Sprite = 759,
            Size = 0.5,
            Color = 5
        },
    },
    ['boat'] = {
        Garage = {
            Name = 'Boat Garage',
            Sprite = 455,
            Size = 0.5,
            Color = 17
        },
        Impound = {
            Name = 'Boat Impound',
            Sprite = 455,
            Size = 0.5,
            Color = 5
        },
    },
}

---@class LocationData
---@field Visible boolean Blip visibility on map.
---@field Type VehicleType The vehicle type.
---@field Position? vector3 Needs to be defined if PedPosition isn't.
---@field PedPosition? vector4 Needs to be defined if Position isn't.
---@field Model? number | string Needs to be defined if PedPosition is defined.
---@field SpawnPosition vector4 The vehicle spawn position.
---@field Jobs? string | string[] Optionally limit to jobs.
---@field Garage? string Stable database storage id. Coordinate-derived when omitted.
---@field Id? string Alias for Garage.

---@class GarageData : LocationData
---@field Interior string? The interior name.

---@type GarageData[]
Config.Garages = {
    {
        Visible = true,
        Type = 'car',
        Garage = 'pillboxgarage',
        Position = vector3(220.1418, -800.1686, 30.7227),
        PedPosition = vector4(215.4677, -808.5453, 30.7597, 248.1795),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(229.3425, -801.4708, 30.5659, 161.8591),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(273.0, -343.85, 44.91),
        PedPosition = vector4(276.0835, -343.4283, 44.9198, 344.8690),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(270.75, -340.51, 44.92, 342.03),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-71.46, -1821.83, 26.94),
        PedPosition = vector4(-71.1413, -1829.9701, 26.9420, 230.2688),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-66.51, -1828.01, 26.94, 235.64),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(1032.84, -765.1, 58.18),
        PedPosition = vector4(1035.1685, -765.1791, 57.9946, 152.8775),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1023.2, -764.27, 57.96, 319.66),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-1248.69, -1425.71, 4.32),
        PedPosition = vector4(-1253.3109, -1420.1212, 4.3231, 306.8438),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1244.27, -1422.08, 4.32, 37.12),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-2961.58, 375.93, 15.02),
        PedPosition = vector4(-2961.7307, 375.5100, 14.8210, 171.7270),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-2964.96, 372.07, 14.78, 86.07),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(217.33, 2605.65, 46.04),
        PedPosition = vector4(217.9141, 2602.0601, 45.7792, 13.1270),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(216.94, 2608.44, 46.33, 14.07),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(1878.44, 3760.1, 32.94),
        PedPosition = vector4(1873.9102, 3752.6917, 32.9840, 306.1647),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1880.14, 3757.73, 32.93, 215.54),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(365.21, 295.6, 103.46),
        PedPosition = vector4(363.3373, 296.9839, 103.5044, 251.6143),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(364.84, 289.73, 103.42, 164.23),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(1713.06, 4745.32, 41.96),
        PedPosition = vector4(1713.2983, 4742.9219, 42.0254, 16.6958),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1710.64, 4746.94, 41.95, 90.11),
        Interior = 'small'
    },
    -- paleo ltd
    {
        Visible = true,
        Type = 'car',
        Position = vector3(123.57, 6627.9, 31.92),
        PedPosition = vector4(123.57, 6627.9, 31.92, 229.77),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(134.14, 6631.52, 31.69, 135.13),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(328.6457, -210.4855, 54.0863),
        PedPosition = vector4(337.9874, -214.8659, 54.0863, 73.4874),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(325.5470, -211.0033, 54.0863, 156.9495),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-176.8074, -1305.2096, 31.2980),
        PedPosition = vector4(-167.2547, -1310.2228, 31.3727, 8.5375),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-164.0872, -1306.4490, 31.3066, 9.2604),
        Interior = 'large'
    },
    -- mrpd
    {
        Visible = false,
        Type = 'car',
        Position = vector3(458.2, -1022.67, 28.35),
        PedPosition = vector4(458.2, -1022.67, 28.35, 90.85),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(449.39, -1025.05, 28.58, 6.58),
        Interior = 'large'
    },
    -- mrpd garage
    {
        Visible = false,
        Type = 'car',
        Position = vector3(442.54, -974.89, 25.7),
        PedPosition = vector4(442.54, -974.89, 25.7, 178.7),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(450.43, -975.7, 25.7, 95.01),
        Jobs = { 'police', 'leo' },
        -- Jobs = 'police',
        Interior = 'large',
    },
    -- sahp lsf
    {
        Visible = false,
        Type = 'car',
        Position = vector3(1578.94, 836.96, 77.44),
        PedPosition = vector4(1578.94, 836.96, 77.44, 60.82),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1576.05, 843.07, 77.64, 57.87),
        Interior = 'large'
    },
    -- harmony ranger
    {
        Visible = false,
        Type = 'car',
        Position = vector3(1741.03, 3035.2, 61.64),
        PedPosition = vector4(1741.03, 3035.2, 61.64, 321.32),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1745.43, 3038.64, 61.91, 85.66),
        Interior = 'small'
    },
    -- harmony bcso
    {
        Visible = false,
        Type = 'car',
        Position = vector3(492.97, 2639.9, 43.17),
        PedPosition = vector4(492.97, 2639.9, 43.17, 186.69),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(495.61, 2634.69, 43.03, 280.14),
        Interior = 'small'
    },
    -- sandy pd
    {
        Visible = false,
        Type = 'car',
        Position = vector3(1818.78, 3661.19, 34.28),
        PedPosition = vector4(1818.78, 3661.19, 34.28, 208.09),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1818.97, 3656.22, 34.38, 212.59),
        Interior = 'small'
    },
    -- paleto pd
    {
        Visible = false,
        Type = 'car',
        Position = vector3(-460.95, 6030.16, 31.63),
        PedPosition = vector4(-459.41, 6029.75, 31.49, 223.84),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-466.12, 6031.58, 31.34, 137.99),
        Interior = 'small'
    },
    -- richman fire
    {
        Visible = false,
        Type = 'car',
        Position = vector3(-1682.89, 51.46, 63.94),
        PedPosition = vector4(-1682.89, 51.46, 63.94, 240.29),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1674.25, 49.45, 63.98, 140.64),
        Interior = 'small'
    },
    -- vespucci fire
    {
        Visible = false,
        Type = 'car',
        Position = vector3(-1229.45, -1409.17, 4.37),
        PedPosition = vector4(-1229.45, -1409.17, 4.37, 128.18),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1236.51, -1404.19, 4.44, 35.13),
        Interior = 'small'
    },
    -- grapeseed fire
    {
        Visible = false,
        Type = 'car',
        Position = vector3(1782.23, 4605.67, 37.72),
        PedPosition = vector4(1782.23, 4605.67, 37.72, 282.25),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(1787.93, 4606.72, 37.76, 184.15),
        Interior = 'small'
    },
    -- pillbox upper
    {
        Visible = false,
        Type = 'car',
        Position = vector3(295.36, -599.83, 43.15),
        PedPosition = vector4(295.36, -599.83, 43.15, 163.21),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(294.46, -607.05, 43.00, 68.43),
        Interior = 'small'
    },
    -- pillbox lower
    {
        Visible = false,
        Type = 'car',
        Position = vector3(317.25, -562.31, 28.8),
        PedPosition = vector4(317.25, -562.31, 28.8, 253.46),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(320.09, -569.88, 28.56, 249.83),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(2422.3440, 4959.5835, 45.9706),
        PedPosition = vector4(2425.1272, 4960.6118, 46.1977, 140.0077),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(2421.7756, 4959.3447, 46.0200, 44.8010),
        Interior = 'small'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-608.2778, -875.6619, 25.2812),
        PedPosition = vector4(-613.7393, -881.1906, 25.1290, 327.8892),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-608.2778, -875.6619, 25.2812, 230.8461),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-1480.0311, -496.4789, 32.8068),
        PedPosition = vector4(-1471.2198, -490.6253, 32.8068, 129.3045),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1480.0311, -496.4789, 32.8068, 215.6816),
        Interior = 'large'
    },
    -- Alta Parking
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-340.09, -876.43, 30.75),
        PedPosition = vector4(-348.82, -876.5, 31.07, 164.04),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-340.09, -876.43, 30.75, 167.72),
        Interior = 'large'
    },
    -- -- Richman Fire
    -- {
    --     Visible = true,
    --     Type = 'car',
    --     Position = vector3(-1667.8083, 72.3026, 63.5343),
    --     PedPosition = vector4(-1677.5203, 66.0455, 63.9183, 317.4938),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-1667.8083, 72.3026, 63.5343, 48.9008),
    --     Interior = 'large'
    -- },
    {
        Visible = true,
        Type = 'car',
        Position = vector3(-387.9319, -107.0117, 38.6853),
        PedPosition = vector4(-389.6788, -101.4820, 38.7576, 212.3671),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-387.9319, -107.0117, 38.6853, 215.1336),
        Interior = 'large'
    },
    {
        Visible = true,
        Type = 'air',
        Garage = 'airporthangar',
        Position = vector3(-1182.7245, -2852.9495, 14.0404),
        PedPosition = vector4(-1186.2985, -2841.2820, 13.9461, 236.5903),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1178.4406, -2845.8442, 13.9457, 333.0016),
    },
    -- mission row heli
    -- {
    --     Visible = false,
    --     Type = 'air',
    --     Position = vector3(463.93, -982.38, 43.69),
    --     PedPosition = vector4(463.93, -982.38, 43.69, 92.75),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(449.168, -981.325, 43.691, 87.234),
    -- },
    -- -- lspd admin bldg
    -- {
    --     Visible = false,
    --     Type = 'air',
    --     Position = vector3(63.77, -405.36, 92.75),
    --     PedPosition = vector4(63.77, -405.36, 92.75, 249.58),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(76.6, -416.15, 94.55, 69.82),
    -- },
    -- -- sahp north
    -- {
    --     Visible = false,
    --     Type = 'air',
    --     Position = vector3(2531.1, 5044.69, 44.89),
    --     PedPosition = vector4(2531.1, 5044.69, 44.89, 108.37),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(2522.96, 5032.36, 44.64, 285.66),
    -- },
    -- -- paleto heliport
    -- {
    --     Visible = true,
    --     Type = 'air',
    --     Position = vector3(-298.34, 6109.07, 31.52),
    --     PedPosition = vector4(-298.34, 6109.07, 31.52, 45.07),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-305.87, 6116.61, 33.41, 221.01),
    -- },
    -- -- paleto pd heli
    -- {
    --     Visible = false,
    --     Type = 'air',
    --     Position = vector3(-454.38, 5985.44, 31.28),
    --     PedPosition = vector4(-454.38, 5985.44, 31.28, 49.99),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-475.4, 5988.29, 31.34, 320.05),
    -- },
    -- -- paleto airport heli
    -- {
    --     Visible = true,
    --     Type = 'air',
    --     Position = vector3(-1767.51, 5292.75, 6.95),
    --     PedPosition = vector4(-1767.51, 5292.75, 6.95, 310.87),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-1775.26, 5285.55, 8.96, 312.92),
    -- },
    -- -- lsia heli
    -- {
    --     Visible = true,
    --     Type = 'air',
    --     Position = vector3(-1855.04, -3150.94, 13.94),
    --     PedPosition = vector4(-1855.04, -3150.94, 13.94, 335.73),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-1849.8, -3141.67, 15.98, 154.11),
    -- },
    -- -- higgins heli
    -- {
    --     Visible = true,
    --     Type = 'air',
    --     Position = vector3(-749.51, -1510.65, 5.02),
    --     PedPosition = vector4(-750.88, -1509.92, 5.03, 19.66),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-765.91, -1497.59, 5.0, 290.30),
    -- },
    -- lsymc boathouse
    {
        Visible = true,
        Type = 'boat',
        Garage = 'lsymcboathouse',
        Position = vector3(-733.79, -1384.35, 1.6),
        PedPosition = vector4(-733.79, -1384.35, 1.6, 52.19),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-735.42, -1378.0, 0.88, 118.12)
    },
    -- -- millars boathouse
    -- {
    --     Visible = true,
    --     Type = 'boat',
    --     Position = vector3(1299.02, 4216.42, 33.91),
    --     PedPosition = vector4(1299.02, 4216.42, 33.91, 166.8),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(1296.78, 4203.76, 30.12, 169.03)
    -- },
    -- -- paleto pier
    -- {
    --     Visible = true,
    --     Type = 'boat',
    --     Position = vector3(-362.03, 6660.86, 6.47),
    --     PedPosition = vector4(-362.03, 6660.86, 6.47, 132.17),
    --     Model = `s_m_m_armoured_01`,
    --     SpawnPosition = vector4(-365.37, 6657.15, 0.1, 54.0)
    -- },
}

Config.GarageInteriors = {
    ['small'] = {
        -- The teleport coords
        Coords = vector4(637.1520, 4750.6572, -59.0000, 91.4643), 
        -- The vehicle spot coords array
        Vehicles = {
            vector4(623.0, 4750.4780, -59.5000, 179.0),
            vector4(626.0, 4750.4790, -59.5000, 179.0),
            vector4(629.0, 4750.5620, -59.5000, 179.0),
            vector4(632.0, 4750.5078, -59.5000, 179.0),
        }
    },
    ['large'] = {
        -- The teleport coords
        Coords = vector4(238.0297, -1004.8235, -99.0000, 90.0),
        -- The vehicle spot coords array
        Vehicles = {
            vector4(232.7722, -984.5818, -99.0000, 90.0),
            vector4(232.7722, -988.5818, -99.0000, 90.0),
            vector4(232.7722, -992.5818, -99.0000, 90.0),
            vector4(232.7722, -996.5818, -99.0000, 90.0),
            vector4(232.7722, -1000.5818, -99.0000, 90.0),
            vector4(223.7722, -984.5818, -99.0000, -90.0),
            vector4(223.7722, -988.5818, -99.0000, -90.0),
            vector4(223.7722, -992.5818, -99.0000, -90.0),
            vector4(223.7722, -996.5818, -99.0000, -90.0),
            vector4(223.7722, -1000.5818, -99.0000, -90.0),
        }
    }
}

-- Officer/job initiated impounds. The target option is shown only to an
-- authorized job, but every permission, entity, distance, occupant, ownership,
-- and fee check is repeated by the server before a vehicle is removed.
Config.EnforcementImpound = {
    Enabled = true,
    Distance = 3.0,
    MaximumSpeed = 1.0, -- Metres per second; prevents impounding a moving vehicle.
    Duration = 5000,
    MinimumReasonLength = 3,
    MaximumReasonLength = 200,
    DefaultFee = 500,
    MinimumFee = 0,
    MaximumFee = 25000,

    -- Milliseconds, 0-300000. The database/impound record is committed
    -- immediately, but the empty vehicle remains immobilized in the world for
    -- this visible tow delay. Use 0 for immediate physical removal.
    RemovalDelay = 30000,

    -- Natural GTA traffic and parked vehicles can use the same target action.
    -- They are removed after the delay without creating a player-vehicle,
    -- DRS impound, or MDT record. Script/mission vehicles fail closed.
    AmbientVehicles = {
        Enabled = true,
        NetworkTimeout = 2000, -- 250-5000ms to promote a local entity for server validation.
        MaximumDisplacement = 5.0, -- Metres it may move during the tow delay.
        MaximumPendingPerOfficer = 3, -- Simultaneous unrecorded removals, 1-20.
        AllowedPopulationTypes = { 1, 2, 3, 4, 5 } -- Natural GTA population only; never mission/script type 7.
    },

    -- Exact job names work on every supported framework. Add tow/mechanic jobs
    -- here. Stock ESX has no duty flag and treats its current job as active;
    -- custom ESX onduty/onDuty values are honored when present.
    Jobs = {
        police = { MinGrade = 0, RequireDuty = true },
        -- sheriff = { MinGrade = 0, RequireDuty = true },
        -- tow = { MinGrade = 0, RequireDuty = false },
    },

    -- Qbox exposes job types. `leo` automatically covers every configured law
    -- enforcement department without hard-coding each department name.
    JobTypes = {
        leo = { MinGrade = 0, RequireDuty = true }
    },

    -- A QB/Qbox state-2 vehicle without a DRS release record is treated as an
    -- authority hold. This preserves legacy `/impound` and MDT seizure intent.
    LegacyStateTwoHold = true
}

-- Legacy/natural impounds without a recorded per-vehicle fee use this fallback.
-- Framework cash and vehicle-state changes are not one crash-durable transaction,
-- so a process crash during paid recovery can still require manual review.
Config.ImpoundPrice = 0

---@class ImpoundData : LocationData

---@type ImpoundData[]
Config.Impounds = {
    {
        Visible = true,
        Type = 'car',
        Position = vector3(401.7906, -1631.6171, 29.2920),
        PedPosition = vector4(399.1730, -1629.3943, 29.2919, 232.0665),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(407.8341, -1645.6790, 29.2921, 228.1345)
    },
    {
        Visible = true,
        Type = 'air',
        Position = vector3(-1150.4854, -2871.9438, 13.9459),
        PedPosition = vector4(-1153.9452, -2860.0886, 13.9460, 241.3252),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-1146.0892, -2864.6094, 13.9460, 331.5881)
    },
    {
        Visible = true,
        Type = 'boat',
        Position = vector3(-844.2191, -1366.7213, 1.6052),
        PedPosition = vector4(-848.3743, -1368.4086, 1.6052, 291.1638),
        Model = `s_m_m_armoured_01`,
        SpawnPosition = vector4(-843.4146, -1372.2310, -0.4749, 114.3669)
    },
}

Config.Contract = {
    -- Opt-in: framework money, inventory, and ownership APIs do not provide one
    -- atomic transaction. A process crash during a transfer can require manual
    -- reconciliation even though normal runtime failures are compensated.
    Enabled = false,
    Duration = 5000, -- The animation duration
    Item = 'contract', -- The item name
    VehicleDistance = 5.0, -- Maximum vehicle distance for a server-authorized contract (plus the 2m network tolerance).
    MinimumPrice = 0,
    MaximumPrice = 100000000,
    SocietyWithdrawalRequiresBoss = true -- Only the current job boss can privatize a society vehicle.
}
