# DRS Garages

`drs_garages` is the DRS-maintained garage resource based on Lunar Scripts' `lunar_garage` 2.0.3. This build retains the garage's QB, ESX, and Qbox paths and includes automatic database setup, stock QB housing discovery, and the integrations developed for `qbx_properties` and `qr-vehicleshop`.

The runtime resource name must be exactly `drs_garages`. Its event and callback namespace is `drs_garages:*`; integrations call its public API through `exports.drs_garages`.

Do not run `drs_garages` and `lunar_garage` together. Both resources would operate on the same garage locations and vehicle rows.

## DRS Integration Changes

- Added Qbox/QBX compatibility paths for `player_vehicles`.
- Added an idempotent QB/Qbox database installer for missing compatibility columns and indexes.
- Added support for `state`, `stored`, `type`, `job`, and `garage` vehicle columns.
- Synced `stored` and `state` whenever vehicles are taken out, parked, retrieved from impound, or auto-returned on restart.
- Added vehicle type normalization so QB/Qbox values such as `automobile`, `bike`, `boat`, `plane`, and `heli` map correctly to DRS garage types.
- Fixed air and boat garage filtering so those vehicles do not get mixed into car garages.
- Added dynamic property garage registration exports for `qbx_properties`.
- Added automatic, read-only import and synchronization of stock `qb-houses` garages.
- Added property garage access validation for owners and keyholders.
- Added property garage interior support.
- Split property garage behavior into two points:
  - Entry point: open the garage menu or enter the garage interior on foot.
  - Spawn/parking point: spawn vehicles and park vehicles.
- Added configurable property interaction distances:
  - `Config.PropertyGarageDistance`
  - `Config.PropertyGarageParkingDistance`
- Added `Config.AutoRespawn` support for Qbox `state` and `stored`.
- Hardened the vehicle contract registration so it waits for `Config.Contract` and `Framework` before registering the item.

## Integration Exports

`qbx_properties` uses these exports when `drs_garages` is started:

```lua
exports.drs_garages:RegisterPropertyGarage(name, data)
exports.drs_garages:RemovePropertyGarage(name)
exports.drs_garages:RefreshPropertyGarage(name)
```

`qr-vehicleshop` uses these exports to track a server-created delivery vehicle:

```lua
exports.drs_garages:RegisterActiveVehicle(source, plate, netId)
exports.drs_garages:UnregisterActiveVehicle(plate, netId)
```

The dynamic property garage data supports this shape:

```lua
{
    id = 'property_example',
    label = 'Example Property',
    vehicleType = 'car',
    entryCoords = vec4(0.0, 0.0, 0.0, 0.0),
    spawnCoords = vec4(0.0, 0.0, 0.0, 0.0),
    interior = 'large',
    owner = 'citizenid',
    keyholders = {}
}
```

Old single-coordinate property garages are still normalized for backwards compatibility.

## Automatic Database Setup

On QB-Core and Qbox, `Config.Database.AutoMigrate = true` checks the existing `player_vehicles` table during startup and adds only missing DRS compatibility columns and indexes. The migration is repeatable, never drops or recreates the table, and never deletes owned-vehicle rows; it only synchronizes the compatibility fields described below.

The framework's base `player_vehicles` table must already exist and retain the standard columns DRS reads and writes: `citizenid`, `plate`, `garage`, and `mods`, plus at least one vehicle-model column (`vehicle` or `hash`). DRS adds these compatibility columns when needed:

- `job`
- `type`
- `stored`
- `state`

With automatic setup enabled, every validated startup checks rows that still have the compatibility default `type = 'car'` against the framework's vehicle metadata. Recognized boats map to `boat`, recognized planes and helicopters map to `air`, and known road vehicles remain `car`. Failed attempts and manual SQL installations are therefore retried safely. Rows whose model or category cannot be identified retain `car`; the startup log reports their count so legacy non-car rows can be reviewed and corrected manually.

It also creates and verifies the packaged lookup indexes. If the resource database account lacks `ALTER` or `INDEX` permission, use one of these administrator-run fallback paths:

- `sql/qbox_drs_garages.sql` for a repeatable Oracle MySQL 8/MariaDB fallback that conditionally adds the missing DRS columns and named indexes.
- The QR Vehicle Shop compatibility SQL if you are also using that resource. Its file is a superset and includes finance columns too.

When exactly one of `stored` or `state` existed before the manual fallback, its values are copied into the newly-added counterpart; when both were missing, both safely default to `1` (stored). Restart DRS after the fallback completes. The startup installer verifies the resulting schema and keeps database-backed garage features unavailable if a required column or named index is still missing or has an unexpected definition.

If old rows have mismatched `stored` and `state` values, run:

```sql
sql/repair_qbox_vehicle_storage_state.sql
```

That repair returns out vehicles to a garaged state, matching `Config.AutoRespawn = true`.

The repair SQL is intentionally not executed automatically because it changes the state of existing out vehicles.

## QB Houses and Apartments

When QB-Core and the configured `qb-houses` resource are running, DRS automatically reads owned garages from the stock `houselocations` and `player_houses` tables. Housing remains authoritative: DRS never writes those tables.

The bridge automatically:

- registers owned houses that have a valid garage coordinate;
- grants access to the current owner and keyholders by citizen ID;
- updates ownership, keys, labels, and coordinates;
- removes sold, deleted, or unavailable garages; and
- restores registrations after either resource restarts.

Changes are reconciled on startup and every `Config.Integrations.QbHousing.SyncInterval` milliseconds. The default is 60 seconds.

Stock `qb-apartments` does not store private garage coordinates. DRS detects it without inventing unsafe spawn points; apartment residents use the public locations in `Config.Garages`, including the configured Alta parking location. Custom apartment systems that expose private garage data should use the property exports documented above.

Do not run the full stock `qb-garages` resource alongside DRS unless all overlapping vehicle and public-garage behavior has been disabled.

## Important Config

```lua
Config.AutoRespawn = true
Config.PropertyGarageDistance = 3.0
Config.PropertyGarageParkingDistance = 3.0
Config.Database.AutoMigrate = true
Config.Integrations.QbHousing.Enabled = true
Config.Integrations.QbHousing.Resource = 'qb-houses'
Config.Integrations.QbHousing.SyncInterval = 60000
Config.Integrations.QbApartments.Enabled = true
Config.Integrations.QbApartments.Resource = 'qb-apartments'
```

For the included vehicle shop defaults, make sure these DRS garage names exist:

- `pillboxgarage`
- `lsymcboathouse`
- `airporthangar`

## Start Order

Recommended Qbox order:

```cfg
ensure oxmysql
ensure ox_lib
ensure qbx_core
ensure drs_garages
ensure qbx_properties
ensure qr-vehicleshop
```

If you use bob74_ipl interiors through `qbx_properties`, start `bob74_ipl` before `qbx_properties`.

Use the companion `qbx_properties` and `qr-vehicleshop` builds from this development workspace. They resolve `drs_garages` first and retain a `lunar_garage` fallback for legacy installations. Unmodified integrations that hard-code `exports.lunar_garage` must be updated before they can call this resource.

Recommended QB-Core order:

```cfg
ensure oxmysql
ensure ox_lib
ensure qb-core
ensure drs_garages
ensure qb-apartments
ensure qb-houses
```

The bridge supports either housing-before-DRS or DRS-before-housing startup and reconciles late starts automatically. Starting DRS first makes its installer result available before housing garages are registered.

## Attribution and License

This is a modified fork of [Lunar Scripts' `lunar_garage`](https://github.com/Lunar-Scripts/lunar_garage), originally version 2.0.3. DRS maintains the automatic installer, QB and Qbox property integrations, vehicle-shop handoff support, persistence fixes, and the `drs_garages` namespace.

The original GPLv3 license is retained in `LICENSE`. See `NOTICE.md` for the fork notice. The upstream version checker and Lunar-branded Discord icon were removed because they do not represent DRS releases.
