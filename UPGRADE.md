# Upgrade to 2.2.0-drs.3

This release is designed for a non-destructive upgrade, but it tightens the
database contract and runtime validation. Complete the checks below before
opening the server to players.

## 1. Prepare and back up

1. Schedule downtime and stop `drs_garages`, `qbx_properties`, and
   `drs_vehicleshop`.
2. Back up the full database, especially `player_vehicles` or
   `owned_vehicles` and the companion property/shop tables.
3. Back up the current resource folders and `server.cfg`.
4. Record local edits in `config/config.lua`, `config/cl_edit.lua`, and
   `config/sv_config.lua`. Merge them deliberately into the new files instead
   of copying an old config over the new release.

Do not run a cleanup query against duplicate plates. Ownership and financial
history determine which row is valid; that decision must be made manually from
a backup.

## 2. Check resource identity and conflicts

The manifest must be directly inside a folder named `drs_garages`. Update
hard-coded integrations from `lunar_garage` and the old event namespace to
`drs_garages`.

Remove overlapping start entries. In particular, do not run:

- `lunar_garage`, `qb-garages`, or `qbx_garages` beside `drs_garages`;
- the legacy `qr-vehicleshop` or `qbx_vehicleshop` beside
  `drs_vehicleshop`; or
- more than one of `qbx_core`, `qb-core`, and `es_extended`.

Retaining a fallback call in a stopped legacy companion is harmless; starting
both implementations is not.

## 3. Merge new configuration

Keep the compatibility default for the first start:

```lua
Config.Storage = {
    Mode = 'global',
    DefaultGarages = {
        car = 'pillboxgarage',
        boat = 'lsymcboathouse',
        air = 'airporthangar'
    },
    RecoverUnassigned = true,
    RecoverInaccessibleProperties = true
}
```

Confirm that those three IDs exist and match the defaults in
`drs_vehicleshop`. Preserve `Config.Database.AutoMigrate = true` unless an
administrator will prepare every required column and index before startup.

Use `global` until all legacy garage values have been reviewed. Later:

- choose `garage` to make public and property assignments exact;
- choose `property` to keep public garages shared while isolating accessible
  property assignments; or
- keep `global` for the original type-wide shared pool.

Recovery is virtual and does not bulk-update rows. A recovered QB/Qbox vehicle
receives its canonical assignment when it is parked again.

## 4. Prepare the database

### QB-Core/Qbox automatic path

The standard `player_vehicles` table must already contain `citizenid`, `license`,
`plate`, `garage`, `mods`, and either `vehicle` or `hash`. Give the runtime account
`ALTER` and `INDEX` permission for the first start.

DRS conditionally adds `job`, `type`, `stored`, and `state`, preserves an
existing storage-state counterpart, creates its lookup indexes, and enforces a
UNIQUE full-column `plate` index. Before index creation it reports duplicate
trimmed, case-normalized plate groups and stops database-backed garage actions
instead of modifying those rows.

At least one of `stored` or `state` must already exist. If both are absent, DRS
requires a manual vehicle-location reconciliation and will not assume that all
preexisting vehicles are stored.

### QB-Core/Qbox administrator SQL path

When the runtime account cannot change schema:

1. keep DRS stopped;
2. take a fresh database backup;
3. run [`sql/qbox_drs_garages.sql`](sql/qbox_drs_garages.sql) with an Oracle
   MySQL 8 or MariaDB administrator account;
4. inspect the duplicate result set; and
5. continue only when the final result is `[DRS][PASS]`.

A `[DRS][FAIL]` result is intentionally non-destructive. Correct duplicate
owned rows or a conflicting named index manually, rerun the file, and confirm
PASS.

### ESX

The existing `owned_vehicles` table must satisfy the ESX adapter's required
columns. DRS does not add missing ESX columns. With automatic migration enabled
it may add only the UNIQUE full-column plate index after a safe duplicate
check. The packaged Qbox SQL does not apply to ESX.

### Automatic migration disabled

`Config.Database.AutoMigrate = false` means read-only validation, not “skip
database checks.” All compatibility and UNIQUE plate indexes must already be
correct or garage actions remain unavailable.

Do not run `sql/repair_qbox_vehicle_storage_state.sql` as part of a routine
upgrade. It changes out/stored state and is provided only for an intentionally
reviewed repair after a backup. It must be run offline with the FiveM server
and all vehicle-persistence resources stopped and no live vehicle entities
remaining. NULL or unsupported state values stay unchanged for manual review.

## 5. Use the supported start order

For the complete Qbox trio:

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

For QB-Core or ESX, use the matching file in `install/`. OneSync must be enabled
for every path.

DRS selects its target provider at `drs_garages` startup. Keep the provider
before DRS in the start order, and restart `drs_garages` after starting,
stopping, removing, or switching target providers.

## 6. Run diagnostics

After every resource has started, run this in the server console:

```text
drsgarages:doctor
```

For in-game administrators:

```cfg
add_ace group.admin command.drsgarages:doctor allow
```

Run `/drsgarages:doctor` and inspect the full F8 report. Resolve every FAIL.
Review WARN results for intentional omissions such as an unused optional
companion.

## 7. Acceptance checklist

Use test characters and inexpensive vehicles first.

- Personal car: park, take out, restart while out, impound, and retrieve.
- Boat and aircraft: confirm each appears only at its matching garage/impound.
- Society vehicle: verify the correct job can use it and another job cannot.
- Duplicate action: attempt rapid/double takeout and confirm only one entity is
  created and only one impound payment occurs.
- Property owner: list, park, take out, enter/leave the garage interior.
- Property keyholder: repeat access, then remove the key and verify removal.
- Sold/deleted property: confirm vehicle recovery follows the selected mode.
- Unauthorized player: confirm no property list, spawn, parking, interior, or
  coordinate access.
- `drs_vehicleshop`: purchase car/boat/air deliveries and confirm garage ID,
  keys, stored/state values, active tracking, and restart persistence.
- Resource restart/disconnect inside an interior: confirm the routing bucket is
  restored safely.
- Target disabled/stopped: restart `drs_garages`, then confirm locations use
  TextUI at `Position` or the `PedPosition` coordinates and the doctor reports
  the fallback warning.
- Vehicle contracts are disabled by default because their framework-side money,
  inventory, and ownership effects are not one crash-durable transaction. If
  you explicitly enable them, test with `Config.Contract.VehicleDistance = 5.0`:
  confirm an active vehicle inside that radius succeeds, while one beyond the
  additional `2.0`-metre server tolerance is rejected.
- Society withdrawal: with the default
  `Config.Contract.SocietyWithdrawalRequiresBoss = true`, confirm the current
  matching-job boss can privatize the vehicle and a non-boss cannot.

## Rollback

If validation fails and cannot be resolved during the maintenance window:

1. stop the DRS trio;
2. preserve the failed startup logs and doctor report;
3. restore the previous resource folders and `server.cfg`; and
4. restore the database backup when any companion migration or manual repair
   changed data in a way the prior build cannot read.

The DRS garage migration itself is additive, but do not assume every companion
or manual database change is backward-compatible. Never drop new columns,
indexes, or rows merely to make a rollback look clean without first checking
the backup and the previous resource's schema contract.
