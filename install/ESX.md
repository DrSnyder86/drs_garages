# ESX installation

## Requirements and start order

- OneSync enabled
- `oxmysql`
- `ox_lib`
- `es_extended`
- optionally `ox_target`, `qb-target`, or `qtarget`

Keep the folder and runtime resource name exactly `drs_garages`:

```cfg
ensure oxmysql
ensure ox_lib
ensure es_extended
ensure ox_target # or one supported target provider
ensure drs_garages
```

Run only `es_extended`; a simultaneously started Qbox or QB core is an error.
Do not run `lunar_garage`, `qb-garages`, `qbx_garages`, or another overlapping
garage resource.

`qbx_properties` is a Qbox integration, and the current `drs_vehicleshop`
companion supports Qbox/QB. They are not part of the ESX installation path.

## Owned-vehicle schema

DRS uses the existing `owned_vehicles` table. Its required ESX columns are
`owner`, `plate`, `vehicle`, `stored`, and `job`. DRS does not create the table
or add missing ESX columns.

An existing `type` column is optional. When present and populated, DRS uses it
to filter menus before a vehicle action. Type values understood by this build
are:

```text
car
boat
air
```

When an ESX row has no database type, DRS permits the legacy row to be listed
but does not trust that omission. It validates the requested spawn class and
the live server-created entity against the current garage before the row can
remain out, and it validates the live entity again when parking. A mismatched
spawn is removed and its row is returned to storage. Adding and correctly
populating an optional `type` column is recommended for clean car/boat/air menu
filtering, but it is not part of automatic migration.

With `Config.Database.AutoMigrate = true`, ESX startup remains read-only for
columns but may create one UNIQUE index over the complete `owned_vehicles.plate`
column. DRS first performs a non-destructive duplicate check using trimmed,
case-normalized plate values. If duplicates exist, database-backed garage
actions stay unavailable. Back up the table and resolve every duplicate
manually; DRS never chooses, merges, or deletes an owned row.

With `Config.Database.AutoMigrate = false`, DRS only validates and requires the
UNIQUE plate index to exist already.

The packaged `sql/qbox_drs_garages.sql` is only for QB-Core/Qbox
`player_vehicles`. Do not run it against an ESX database.

## Storage behavior

Use:

```lua
Config.Storage.Mode = 'global'
```

The `garage` and `property` modes need a verified garage-assignment column that
is not part of the default ESX contract, so DRS warns and safely falls back to
`global`. Vehicle type is still enforced between car, boat, and aircraft
garages and impounds.

## Target, keys, and contracts

With `Config.Target = true`, DRS detects `ox_target`, `qb-target`, then
`qtarget`. When none is available, locations fall back to TextUI at `Position`
or the `PedPosition` coordinates.

Target-provider selection occurs when `drs_garages` starts. Start the provider
before DRS, and restart `drs_garages` after starting, stopping, removing, or
switching target providers.

There is no default ESX vehicle-key handoff in this build. Either set
`Config.UseKeySystem = false` or implement `SetVehicleOwner` in
`config/cl_edit.lua` for the key resource used by your server. The doctor
reports this as a warning.

Contract V2 is enabled with only boss society donations active; player sales and
society withdrawals remain separate opt-ins. Multi-step results are written to
the DRS contract journal for startup reconciliation and explicit administrator
review when an outcome cannot be proven.

Create the item named by `Config.Contract.Item` in the ESX inventory system and
add its image when the UI requires one. See [`ContractItem.md`](ContractItem.md).

Contract vehicle validation uses `Config.Contract.VehicleDistance = 5.0` by
default, plus the server's standard `2.0`-metre network tolerance, for a default
effective upper bound of `7.0` metres from the active vehicle.
The supplied `SocietyWithdrawalPermission = 'admin'` requires the
`drs_garages.contract.admin` ACE if that action is enabled.

## Verify

Run `drsgarages:doctor` in the server console after startup. For in-game use:

```cfg
add_ace group.admin command.drsgarages:doctor allow
add_ace group.admin drs_garages.contract.admin allow
add_ace group.admin drs_garages.fleet.admin allow
```

Resolve every FAIL, then test a personal and society vehicle through parking,
takeout, restart reconciliation, and impound. Test each enabled vehicle type and
confirm that it cannot be spawned or parked through the wrong garage type. If
you use an optional `owned_vehicles.type` column, also verify its values.
