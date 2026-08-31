# Qbox installation

## Resource layout

For the complete DRS stack, the manifests must be directly inside folders with
these exact runtime names:

```text
resources/[drs]/drs_garages/fxmanifest.lua
resources/[drs]/qbx_properties/fxmanifest.lua
resources/[drs]/drs_vehicleshop/fxmanifest.lua
```

Do not install an outer repository wrapper as the resource folder. Do not run
`lunar_garage`, `qbx_garages`, or `qb-garages` beside DRS. The legacy
`qr-vehicleshop` and `qbx_vehicleshop` are overlapping shop resources and must
not run beside `drs_vehicleshop`.

## Requirements and supported order

OneSync is required. Use this order for the garage/property/shop trio:

```cfg
ensure oxmysql
ensure ox_lib
ensure qbx_core
ensure qbx_vehicles
ensure qbx_vehiclekeys
ensure ox_inventory
ensure ox_target

# Choose one when paid society fleet purchases are enabled. Renewed-Banking is
# native to pure Qbox, but Doctor warns that its current balance write is async:
ensure Renewed-Banking
# qb-banking is preferred when your framework stack supports it because its
# mutation export returns an awaited database result.
# ensure qb-banking

# Only when selected qbx_properties interiors require it:
ensure bob74_ipl

ensure drs_garages
ensure qbx_properties
ensure drs_vehicleshop
```

Starting DRS first makes its schema-readiness result and exports available to
both consumers. After upgrading the three resources, restart them in this same
order. Prefer a full server restart for the first deployment.

Do not use Qbox `full` vehicle persistence alongside DRS. Its cached world
spawns can race DRS storage/restart reconciliation. Disable Qbox persistence or
use `qbx:vehiclePersistenceType semi`; the database gate and doctor both FAIL
closed when full mode is detected.

## Database setup

Qbox's existing `player_vehicles` table must include `citizenid`, `license`,
`plate`, `garage`, and `mods`, plus `vehicle` or `hash`. DRS never replaces the framework
table.

With `Config.Database.AutoMigrate = true`, DRS:

1. adds only missing `job`, `type`, `stored`, and `state` compatibility columns;
2. preserves an existing `stored` or `state` value when adding its counterpart;
3. verifies/creates its owner/type/storage lookup indexes;
4. checks for duplicate trimmed, case-normalized plate values; and
5. verifies/creates one UNIQUE index over the complete `plate` column; and
6. creates/validates the DRS impound, Contract V2, and job-fleet metadata and
   operation-journal tables.

At least one of `stored` or `state` must already exist as the authoritative
source. If both are absent, DRS stops instead of guessing every vehicle's
location.

Duplicate owned rows are never deleted or merged. They keep database-backed
garage actions unavailable until an administrator backs up the database and
resolves them manually.

DRS also rechecks metadata for rows still using `type = 'car'`, changing known
boats to `boat` and known planes/helicopters to `air`. Unknown models remain
`car` and are reported.

If the runtime account lacks schema privileges, stop DRS, take a backup, and
apply [`../sql/qbox_drs_garages.sql`](../sql/qbox_drs_garages.sql) with an
administrator account. The fallback is repeatable on Oracle MySQL 8 and
MariaDB. A final `[DRS][FAIL]` status is a blocker, not permission to continue.

Setting `Config.Database.AutoMigrate = false` selects read-only validation; it
does not bypass any schema requirement.

`qbx_properties` and `drs_vehicleshop` have their own database setup described
in their included documentation. Back up all three sets of tables before the
first combined upgrade.

## Integration behavior

`qbx_properties` is authoritative for ownership, keyholders, property labels,
and garage coordinates. It registers stable IDs such as `property_qbx_42` with
DRS and rebuilds registration after either resource restarts. DRS checks current
access before menu, interior, spawn, or parking actions.

`drs_vehicleshop` uses DRS active-vehicle exports during server-created
delivery. Its included defaults are aligned with:

```lua
Config.Storage.DefaultGarages = {
    car = 'pillboxgarage',
    boat = 'lsymcboathouse',
    air = 'airporthangar'
}
```

Leave `Config.Storage.Mode = 'global'` for an upgrade with unchanged player
behavior. Review the main README before enabling exact `garage` or isolated
`property` storage.

## Target and keys

The recommended stack uses `ox_target`. DRS can also detect `qb-target` or
`qtarget`; when no provider is available, it falls back to TextUI at `Position`
or the `PedPosition` coordinates. Qbox keys are issued through
`qbx_vehiclekeys` when `Config.UseKeySystem = true`.

Target-provider selection occurs when `drs_garages` starts. Start the provider
before DRS, and restart `drs_garages` after starting, stopping, removing, or
switching target providers.

## Contract safeguards

Contract V2 is enabled with only boss-to-society donation active. Player sales
and society withdrawals are separate opt-ins. Install the external inventory
item using [`ContractItem.md`](ContractItem.md); the doctor warns when the
configured `contract` item is absent. DRS uses the official Qbox ownership hook,
rotates the vehicle session id to invalidate prior explicit keys, and records
each transfer in `drs_vehicle_contract_operations` for restart reconciliation.

`Config.Contract.VehicleDistance` defaults to `5.0` metres, with the server's
standard `2.0`-metre network tolerance applied during validation. The default
effective upper bound is therefore `7.0` metres from the active vehicle.
The supplied `SocietyWithdrawalPermission = 'admin'` remains in force if the
withdrawal action is enabled. Use `drsgarages:contracts` to inspect unresolved
operations before manually resolving one.

## Job fleet and society purchasing

The MRPD job garage has the stable ID `mrpd_fleet`. Current-job bosses can open
Fleet Manager from the Society tab or `/jobfleet`, donate personal vehicles,
set minimum grades, move stored fleet assets, and retire them. ACE administrators
can also issue models from `Config.JobFleet.AllowedModels`; boss free issuance
is disabled by default.

Paid society purchasing requires Qbox, `qbx_vehicles`, the matching
`drs_vehicleshop` fleet configuration, and Renewed Banking or QB Banking. The
Doctor reports Renewed's current asynchronous persistence acknowledgement as a
best-effort warning; QB Banking provides an awaited mutation result. The
shop resolves the model/price and journals the society debit; DRS independently
validates the boss/job/garage/model and journals the stored fleet creation.
Ambiguous results stop for staff review.

## Verify the trio

Run `drsgarages:doctor` in the server console after all resources start. To
allow an administrator to run `/drsgarages:doctor` in game:

```cfg
add_ace group.admin command.drsgarages:doctor allow
add_ace group.admin drs_garages.contract.admin allow
add_ace group.admin drs_garages.fleet.admin allow
```

Before opening the server, verify:

1. the doctor report has no FAIL entries;
2. one car, boat, and aircraft can park, leave storage, restart, and impound;
3. a property garage works for its owner and keyholder but not a stranger;
4. a sold property removes access and its assigned vehicle follows the selected
   recovery policy; and
5. a purchased personal shop vehicle receives keys, uses the configured garage,
   and remains consistent after restart;
6. a boss can donate, grade, move, and retrieve a managed police vehicle while a
   lower grade cannot use it; and
7. one paid society purchase creates exactly one debit, shop journal row, fleet
   operation, and stored job vehicle.
