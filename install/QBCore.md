# QB-Core installation

## Requirements and start order

- OneSync enabled
- `oxmysql`
- `ox_lib`
- `qb-core`
- `qb-vehiclekeys` when `Config.UseKeySystem = true`
- optionally `ox_target`, `qb-target`, or `qtarget`

Keep the folder and runtime resource name exactly `drs_garages`:

```cfg
ensure oxmysql
ensure ox_lib
ensure qb-core
ensure qb-vehiclekeys
ensure ox_target # or one supported target provider
ensure drs_garages
ensure qb-apartments
ensure qb-houses
```

The housing bridge also reconciles a later `qb-houses` start. Do not run
`qb-garages`, `qbx_garages`, or `lunar_garage` with overlapping vehicle
management enabled.

## Database setup

Keep QB-Core's existing `player_vehicles` table and owned vehicle data. DRS
requires `citizenid`, `license`, `plate`, `garage`, and `mods`, plus at least one model
column (`vehicle` or `hash`). It never creates or replaces the framework table.

The default setting is:

```lua
Config.Database.AutoMigrate = true
```

On startup DRS conditionally adds only `job`, `type`, `stored`, and `state`,
synchronizes a newly added storage-state counterpart, and creates/verifies its
lookup indexes. It also requires a UNIQUE index over the complete `plate`
column. Creation happens only after a read-only check for duplicate trimmed,
case-normalized plates. Duplicate rows stop database-backed garage actions and
must be reviewed manually after a backup; DRS never deletes or merges them.
At least one of `stored` or `state` must already exist; when both are absent DRS
fails closed instead of guessing the location of every preexisting vehicle.

Known boats and aircraft still marked with the compatibility default
`type = 'car'` are reclassified from QB vehicle metadata. Unknown models stay
`car` and are counted in the startup log.

If the runtime account lacks `ALTER` or `INDEX` permission, stop DRS, back up
the database, and run
[`../sql/qbox_drs_garages.sql`](../sql/qbox_drs_garages.sql) with an
administrator account. The fallback is repeatable on Oracle MySQL 8 and
MariaDB. Inspect its duplicate result set and final `[DRS][PASS]` or
`[DRS][FAIL]` status, then restart DRS.

With `Config.Database.AutoMigrate = false`, no schema writes occur. All required
columns and indexes must already exist, and startup still validates them.

## Housing and apartments

The stock `qb-houses` bridge reads garage coordinates, owner, and keyholder
data from `houselocations` and `player_houses`. Those tables remain
authoritative and DRS never writes them. Changes reconcile on startup and every
`Config.Integrations.QbHousing.SyncInterval` milliseconds.

Stock `qb-apartments` has no private garage-coordinate contract. Residents use
the public locations in `Config.Garages`, including Alta Parking. DRS does not
invent a private spawn point.

## Storage

Leave `Config.Storage.Mode = 'global'` for the legacy shared public pool. The
`garage` mode enforces the exact saved public/property garage and the
`property` mode keeps public garages shared while isolating active accessible
property assignments. See the main README before changing modes on a live
database.

The included `drs_vehicleshop` defaults match these garage IDs:

```lua
car = 'pillboxgarage'
boat = 'lsymcboathouse'
air = 'airporthangar'
```

## Target behavior

With `Config.Target = true`, DRS detects `ox_target`, `qb-target`, then
`qtarget`. If no target is started, locations fall back to TextUI at `Position`
or, when needed, at the `PedPosition` coordinates. Use `Config.Target = false`
to prefer TextUI.

Target-provider selection occurs when `drs_garages` starts. Start the provider
before DRS, and restart `drs_garages` after starting, stopping, removing, or
switching target providers.

## Contract item

Contracts are disabled by default because QB money, inventory, ownership, and
key persistence do not expose one atomic, crash-durable transfer. Leave
`Config.Contract.Enabled = false` unless you have reviewed that operational
limitation. Stock `qb-vehiclekeys` also has no global offline plate-key reset,
so ownership-domain contracts must remain disabled when it is the active key
resource.

When `Config.Contract.Enabled = true`, add the item named by
`Config.Contract.Item` to `qb-core/shared/items.lua`. The default is:

```lua
contract = {
    name = 'contract',
    label = 'Contract',
    weight = 100,
    type = 'item',
    image = 'contract.png',
    unique = false,
    useable = true,
    shouldClose = false,
    combinable = nil,
    description = 'Used for selling or transferring vehicles.'
},
```

Add the matching inventory image when your inventory UI requires it.

Contract vehicle validation uses `Config.Contract.VehicleDistance = 5.0` by
default, plus the server's standard `2.0`-metre network tolerance, for a default
effective upper bound of `7.0` metres from the active vehicle.
`Config.Contract.SocietyWithdrawalRequiresBoss = true` permits only a current
boss of the matching job to privatize a society vehicle.

## Verify

After startup, run `drsgarages:doctor` in the server console. For in-game use:

```cfg
add_ace group.admin command.drsgarages:doctor allow
```

Test parking, takeout, restart persistence, and impound for each enabled vehicle
type. Also test a house as owner, keyholder, and unauthorized player.
