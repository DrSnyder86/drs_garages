# DRS Garages

`drs_garages` is the DRS-maintained garage resource based on Lunar Scripts'
`lunar_garage` 2.0.3. Version `2.2.0-drs.3` supports Qbox, QB-Core, and ESX,
with automatic schema validation, safe QB/Qbox compatibility migrations,
configurable vehicle-storage behavior, stock QB housing discovery, and the DRS
builds of `qbx_properties` and `drs_vehicleshop`.

The folder and runtime resource name must be exactly `drs_garages`. Its events
and callbacks use the `drs_garages:*` namespace, and companion resources call
its API through `exports.drs_garages`.

## What changed in 2.2

- Added `global`, `garage`, and `property` storage modes. The default remains
  `global`, so upgrading does not split an existing public garage pool.
- Added safe recovery for legacy, unknown, deleted-property, and inaccessible
  property assignments without bulk-rewriting owned vehicle rows.
- Added server-authoritative type, ownership, storage-state, distance, and
  active-entity checks around garage, interior, and impound actions.
- Added per-plate operation locks and safer spawn/payment rollback behavior.
- Added a required UNIQUE full-column plate invariant. Duplicate rows are
  reported for manual review; DRS never deletes or merges an owned vehicle.
- Added the restricted `/drsgarages:doctor` health report.
- Added automatic support for `ox_target`, `qb-target`, and `qtarget`, with
  TextUI fallback at `Position` or the configured `PedPosition` coordinates.
- Added explicit dependencies and a OneSync requirement to the manifest.
- Kept the `qbx_properties`, stock QB housing/apartment, and
  `drs_vehicleshop` integration contracts.

See [CHANGELOG.md](CHANGELOG.md) for the release summary and
[UPGRADE.md](UPGRADE.md) before replacing an existing build.

## Requirements

- OneSync enabled
- `oxmysql`
- `ox_lib`
- exactly one supported core: `qbx_core`, `qb-core`, or `es_extended`
- optionally `ox_target`, `qb-target`, or `qtarget`; TextUI is used when no
  supported target is available

Framework-specific instructions:

- [Qbox](install/Qbox.md)
- [QB-Core](install/QBCore.md)
- [ESX](install/ESX.md)

Do not run an overlapping garage resource such as `lunar_garage`,
`qb-garages`, or `qbx_garages`. Do not run the legacy `qr-vehicleshop` or
`qbx_vehicleshop` beside `drs_vehicleshop`.

## Qbox DRS trio

Use these three resource names exactly:

```text
resources/[drs]/drs_garages/fxmanifest.lua
resources/[drs]/qbx_properties/fxmanifest.lua
resources/[drs]/drs_vehicleshop/fxmanifest.lua
```

The supported start order for the complete Qbox stack is:

```cfg
ensure oxmysql
ensure ox_lib
ensure qbx_core
ensure qbx_vehicles
ensure qbx_vehiclekeys
ensure ox_inventory
ensure ox_target

# Only when selected qbx_properties interiors require it:
ensure bob74_ipl

ensure drs_garages
ensure qbx_properties
ensure drs_vehicleshop
```

Starting `drs_garages` before its two consumers makes the database readiness
result and exports available before property registration or vehicle delivery.
After updating the trio, restart them in that same order; a full server restart
is preferred for the first upgrade.

Qbox `full` vehicle persistence must be disabled (or changed to `semi`) because
it owns a competing restart/world-spawn lifecycle. DRS fails database readiness
and the doctor reports FAIL when the conflicting full mode is detected.

`drs_vehicleshop` stores purchased vehicles in these included garage IDs:

- `pillboxgarage` for cars
- `lsymcboathouse` for boats
- `airporthangar` for aircraft

## Storage modes

Storage behavior is configured in `config/config.lua`:

```lua
Config.Storage = {
    Mode = 'global', -- global, garage, property
    DefaultGarages = {
        car = 'pillboxgarage',
        boat = 'lsymcboathouse',
        air = 'airporthangar'
    },
    RecoverUnassigned = true,
    RecoverInaccessibleProperties = true
}
```

| Mode | Public garages | Property garages |
| --- | --- | --- |
| `global` (default) | A stored vehicle is available at every accessible public garage of its trusted vehicle type. | An authorized property garage uses the same type-wide pool. |
| `garage` | A vehicle is available only at its exact assigned public garage. An unassigned or unknown assignment can appear at the configured type fallback when `RecoverUnassigned` is enabled. | A valid accessible property assignment stays at that property. Deleted or inaccessible property assignments can appear at the type fallback when recovery is enabled. |
| `property` | Public garages share one type-wide pool unless the vehicle is assigned to an active property the player can access. | An active accessible property assignment is isolated to that exact property. Deleted or inaccessible property assignments can recover into the public pool. |

Recovery is virtual: startup does not bulk-move legacy vehicle rows. The
canonical garage assignment is saved the next time a QB/Qbox vehicle is parked.
Vehicle type is always enforced, so cars, boats, and aircraft do not cross
garage or impound types. Society vehicles cannot be assigned to property
garages.

If a configured default is missing or has the wrong type, DRS warns and uses
the first configured public garage of that type. Non-global modes currently
fall back to `global` on ESX because the stock `owned_vehicles` contract has no
verified garage-assignment column.

## Automatic database setup

### QB-Core and Qbox

The framework's standard `player_vehicles` table must already exist. DRS never
creates, drops, replaces, or truncates that table. It requires these framework
columns:

- `citizenid`, `license`, `plate`, `garage`, and `mods`
- at least one model column: `vehicle` or `hash`

With the default `Config.Database.AutoMigrate = true`, startup adds only missing
DRS compatibility columns:

- `job`
- `type`
- `stored`
- `state`

At least one of `stored` or `state` must already exist as the authoritative
vehicle-location source. If both are missing, automatic and administrator
migrations stop rather than guessing that every preexisting vehicle is stored.

It also creates/verifies the two DRS lookup indexes and a UNIQUE index on the
complete `plate` column. Before creating the UNIQUE index, DRS checks
case-normalized, trimmed plate values and refuses to enable database-backed
garage actions when duplicates exist. Back up the database and decide which
row is valid; DRS never guesses, merges, or deletes rows.

Plate values must trim to 1-8 characters containing only letters, numbers, and
spaces. Invalid legacy/custom rows fail readiness with examples so they can be
repaired deliberately instead of remaining invisible in menus.

If only one of `stored` or `state` existed before migration, its values are
copied into the newly added counterpart. Rows still carrying the compatibility
default `type = 'car'` are checked against framework vehicle metadata so known
boats and aircraft can be classified. Unknown models remain `car` and are
reported in the startup log.

If the runtime database account intentionally lacks `ALTER` or `INDEX`
permission, back up the database and run
[`sql/qbox_drs_garages.sql`](sql/qbox_drs_garages.sql) with an administrator
account. It is repeatable on Oracle MySQL 8 and MariaDB. Its duplicate report is
read-only; a final `[DRS][FAIL]` result means the issue must be fixed manually
before restarting DRS.

### ESX

DRS requires an existing `owned_vehicles` table and validates its runtime
columns. It does not add or rebuild ESX columns. With automatic migration
enabled, it may create only the UNIQUE full-column plate index after the same
non-destructive duplicate check. Non-global storage modes are not enabled for
the default ESX schema. An optional populated `type` column improves menu
filtering. When a legacy row has no type, DRS validates the requested class and
the live server-created entity against the garage before allowing it to remain
out, then validates the live entity again when it is parked.

### Read-only validation

Setting `Config.Database.AutoMigrate = false` makes startup read-only on every
framework. All required columns and indexes, including the UNIQUE plate index,
must already be present. Schema validation still runs, and database-backed
garage actions stay unavailable when it fails.

The optional [`sql/repair_qbox_vehicle_storage_state.sql`](sql/repair_qbox_vehicle_storage_state.sql)
repair changes existing vehicle state and is never run automatically. Review it
and take a backup before using it. It is an offline repair: stop the FiveM
server and every vehicle-persistence resource, and make sure no live vehicle
entities remain before running it. NULL or unsupported state values are left
unchanged for manual investigation.

## Diagnostics

After all resources start, run this from the server console:

```text
drsgarages:doctor
```

To allow an administrator to run it in game, add an ACE rule:

```cfg
add_ace group.admin command.drsgarages:doctor allow
```

Then use `/drsgarages:doctor`. The complete report is written to the server
console and the administrator's F8 console. It reports PASS, WARN, or FAIL for
the resource name/version, dependencies, OneSync, framework ambiguity,
database readiness, target and vehicle-key resources, known conflicts,
companions, configured locations, storage mode, garage IDs, and runtime state.

Treat every FAIL as a deployment blocker. Review WARN entries to confirm they
are intentional.

## Target behavior

With `Config.Target = true` (or `'auto'`), DRS detects a started target adapter
in this order: `ox_target`, `qb-target`, then `qtarget`. If more than one is
started, the doctor warns and reports that preference order. Set
`Config.Target = 'ox_target'`, `'qb-target'`, or `'qtarget'` to select one
explicitly.

Provider selection occurs when `drs_garages` starts. Start the selected target
resource before DRS, and restart `drs_garages` after starting, stopping,
removing, or switching target providers so interactions are registered against
the current provider.

If the selected/automatic provider is unavailable, DRS falls back to ox_lib
TextUI at `Position`, or at the `PedPosition` coordinates when no separate
position exists. The doctor reports the fallback as a warning so the missing
provider is visible without blocking a valid TextUI deployment.

Set `Config.Target = false` (or `'textui'`) to use TextUI; the doctor reports
that intentional configuration as PASS. Individual locations can provide both
`Position` and `PedPosition`, allowing the same configuration to use a
dedicated TextUI point or a target ped.

## Vehicle contract safeguards

Vehicle contracts are disabled by default in this release. Set
`Config.Contract.Enabled = true` only after accepting that framework money,
inventory, and ownership APIs cannot be committed as one durable transaction;
a server/process crash during a transfer can still require administrator
reconciliation. Normal runtime failures are validated and compensated, but
that cannot guarantee crash-time exactly-once behavior.

For the same reason, `Config.ImpoundPrice` defaults to `0`. A nonzero paid
redemption remains supported with runtime rollback/refund checks, but a process
crash between the framework cash debit and database state commit can require a
manual refund.

`Config.Contract.VehicleDistance` defaults to `5.0` metres. Contract actions
must reference the active vehicle near the player in the same routing bucket;
server validation adds the standard `2.0`-metre network tolerance, making the
default effective upper bound `7.0` metres.

`Config.Contract.SocietyWithdrawalRequiresBoss` defaults to `true`. Only a
player whose current matching job is marked as a boss can use a contract to
privatize a society vehicle. Set it to `false` only when every member of the
matching job should have that authority.

## Property and housing integrations

`qbx_properties` registers owned property garages at runtime. Ownership and
keys remain authoritative in the property resource; DRS validates the current
owner/keyholder list before listing, entering, spawning, or parking. The
property build uses stable IDs such as `property_qbx_42`, and registration is
rebuilt after either resource restarts.

On QB-Core, the stock `qb-houses` bridge reads valid garage coordinates,
owners, and keyholders from the housing tables. It never writes those tables.
Changes reconcile at startup and at
`Config.Integrations.QbHousing.SyncInterval` (60 seconds by default).

Stock `qb-apartments` does not expose private garage coordinates. DRS detects
it but does not invent spawn points; residents use configured public garages,
including Alta Parking. A custom property system can use the exports below.

## Integration exports

Property registration:

```lua
local canonicalId = exports.drs_garages:RegisterPropertyGarage(name, data)
exports.drs_garages:RemovePropertyGarage(canonicalId)
exports.drs_garages:RefreshPropertyGarage(canonicalId)
```

The dynamic data shape is:

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

Old one-coordinate property data is normalized for compatibility.

Server-created vehicle tracking, used by `drs_vehicleshop` delivery:

```lua
exports.drs_garages:RegisterActiveVehicle(source, plate, netId)
exports.drs_garages:UnregisterActiveVehicle(plate, netId)
```

## First-start verification

1. Back up the database and the current resource folders.
2. Confirm the folder is named `drs_garages` and only one framework core is
   running.
3. Start resources in the documented order and wait for schema readiness.
4. Run `drsgarages:doctor`; resolve every FAIL.
5. Test one car, boat, and aircraft through park, takeout, restart, and impound.
6. Test a property as owner, keyholder, and unauthorized player.
7. Buy one vehicle through `drs_vehicleshop` and confirm its configured garage,
   keys, storage state, and restart persistence.

## Attribution and license

This is a modified fork of
[Lunar Scripts' `lunar_garage`](https://github.com/Lunar-Scripts/lunar_garage),
originally version 2.0.3. DRS maintains the database safety work, QB/Qbox
property integrations, vehicle-shop handoff support, persistence fixes,
diagnostics, storage modes, and the `drs_garages` namespace.

The original GPLv3 license is retained in `LICENSE`. See `NOTICE.md` for the
fork notice. The upstream version checker and Lunar-branded Discord icon were
removed because they do not represent DRS releases.
