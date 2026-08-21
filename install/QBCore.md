# QB-Core installation

## Requirements

- `oxmysql`
- `ox_lib`
- `qb-core`
- `ox_target`, `qtarget`, or `qb-target` only when your target configuration uses it

Keep the folder and runtime resource name exactly `drs_garages`, then use this start order:

```cfg
ensure oxmysql
ensure ox_lib
ensure qb-core
ensure drs_garages
ensure qb-apartments
ensure qb-houses
```

Do not run `qb-garages`, `lunar_garage`, or another garage resource with overlapping vehicle management unless that overlap has been disabled.

## Database setup

Keep QB-Core's existing `player_vehicles` table and vehicle data. The table must contain the standard framework columns `citizenid`, `plate`, `garage`, and `mods`, plus at least one vehicle-model column: `vehicle` or `hash`.

With the default setting below, DRS checks the table on startup and adds only missing compatibility columns and indexes:

```lua
Config.Database.AutoMigrate = true
```

The migration is repeatable and never drops, recreates, truncates, or deletes the table. When it adds `stored` or `state`, it synchronizes the new column from the existing storage-state column.

With automatic setup enabled, every validated startup checks rows that still have the compatibility default `type = 'car'` against QB-Core's vehicle metadata. Recognized boats and aircraft are updated to their DRS garage type, so a failed attempt or manual SQL installation is safely retried. Unknown models remain `car` and are counted in the startup log so you can review and correct those rows manually.

If startup reports that the resource database account lacks `ALTER` or `INDEX` permission, make a database backup and apply [`sql/qbox_drs_garages.sql`](../sql/qbox_drs_garages.sql) with a database-administrator account. The fallback is repeatable on Oracle MySQL 8 and MariaDB: it adds only missing compatibility columns and named indexes, preserves an existing `stored` or `state` value when adding its missing counterpart, and never deletes or recreates `player_vehicles`.

Restart `drs_garages` after the fallback completes. The startup installer verifies every required column and index before enabling database-backed garage features. If it reports that an existing named index has an unexpected definition, have a database administrator correct that index explicitly; the fallback never drops or replaces an existing index.

To manage the schema yourself, set `Config.Database.AutoMigrate = false` only after the required compatibility columns and indexes are present.

## Contract item

If vehicle contracts are enabled, add the item named by `Config.Contract.Item` to `qb-core/shared/items.lua`. The default item is:

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

Add a matching inventory image if your inventory UI requires one.
