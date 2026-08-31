# Vehicle contract item

DRS Garages registers the configured `Config.Contract.Item` as usable, but it
does not modify another resource's item catalog. Add **one** matching item to
the inventory used by your framework, then restart the inventory and
`drs_garages`. A missing catalog entry is reported as a doctor warning rather
than a database-startup failure, but players cannot use contracts until the
item exists.

## ox_inventory (Qbox, QB-Core, or ESX)

Add this entry inside the table returned by `ox_inventory/data/items.lua`:

```lua
['contract'] = {
    label = 'Vehicle Contract',
    weight = 0,
    stack = true,
    close = true,
    description = 'A signed document used for an authorized vehicle ownership transfer.'
},
```

## QB-Core inventory

Add this entry to `qb-core/shared/items.lua`:

```lua
contract = {
    name = 'contract',
    label = 'Vehicle Contract',
    weight = 0,
    type = 'item',
    image = 'contract.png',
    unique = false,
    useable = true,
    shouldClose = true,
    combinable = nil,
    description = 'A signed document used for an authorized vehicle ownership transfer.'
},
```

The image is optional; either add `contract.png` to the inventory image folder
or change/remove the image field according to that inventory's requirements.

## Stock ESX inventory

```sql
INSERT IGNORE INTO `items` (`name`, `label`, `weight`)
VALUES ('contract', 'Vehicle Contract', 0);
```

If `Config.Contract.Item` is changed, use that exact name in the selected item
definition as well.

## Contract administrator ACE

The safe default requires the configured ACE for society withdrawals and for
manual journal reconciliation. Grant it to the appropriate staff principal in
`server.cfg`:

```cfg
add_ace group.admin drs_garages.contract.admin allow
```

Use `drsgarages:contracts` in the server console to list interrupted operations.
After manually verifying inventory, money, ownership, and keys, resolve one with:

```text
drsgarages:contractresolve <operation_id> <completed|compensated|cancelled>
```

## Journal schema repair

Automatic migration creates `drs_vehicle_contract_operations` when contract
actions are enabled. With `Config.Database.AutoMigrate = false`, import
`sql/drs_vehicle_contract_operations.sql` once before startup.

If the table already exists but the doctor reports an incompatible column or
index, importing the create SQL again will not change it. Stop `drs_garages`,
back up the database, and run
`sql/repair_drs_vehicle_contract_operations.sql`. The repair script copies the
current journal to `drs_vehicle_contract_operations_repair_backup` before it
alters definitions, and it never deletes journal rows. Keep that backup until
the doctor passes and all entries shown by `drsgarages:contracts` have been
manually verified.

If the repair stops because a column is missing, data is too long, or active
plates are duplicated, do not force or truncate the migration. Preserve the
backup and reconcile those rows with staff before changing the source data.
