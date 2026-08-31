# DRS Garages

`drs_garages` is the DRS-maintained garage resource based on Lunar Scripts'
`lunar_garage` 2.0.3. Version `2.6.0-drs.1` supports Qbox, QB-Core, and ESX,
with automatic schema validation, safe QB/Qbox compatibility migrations,
configurable vehicle-storage behavior, stock QB housing discovery, and the DRS
builds of `qbx_properties` and `drs_vehicleshop`.

The folder and runtime resource name must be exactly `drs_garages`. Its events
and callbacks use the `drs_garages:*` namespace, and companion resources call
its API through `exports.drs_garages`.

## What changed in 2.6

- Contract V2 separates player sales, society donations, and society
  withdrawals; ships with only boss donations enabled; and journals every
  multi-step transfer for restart recovery and administrator review.
- Bosses can adopt personal vehicles into a job fleet, assign a garage and
  minimum grade, move or retire stored assets, and open Fleet Manager directly
  from the Society tab. ACE administrators can issue allowlisted vehicles.
- Qbox bosses can purchase allowlisted fleet vehicles from the current
  `drs_vehicleshop` catalog with society funds. Both resources keep independent
  idempotency/recovery journals, and uncertain payment or creation results stop
  for review instead of being replayed blindly.

## What changed in 2.5

- A nearby, accessible garage now appears dynamically in `qbx_radialmenu`,
  `qb-radialmenu`, or the built-in ox_lib radial fallback.
- Empty, stationary vehicles can be targeted inside the correct parking area;
  personal and society ownership remain server-authoritative.
- Every parking route now uses a configurable, cancellable five-second progress
  bar and repeats entity, occupant, location, identity, and movement checks
  before the server commits storage.

## What changed in 2.4

- Impound recovery now uses the same spawn-point check and presentation as a
  normal garage takeout and leaves the player on foot beside the recovered car.
- Owned impounds commit their protected database record immediately, remain
  locked and immobilized for a configurable tow delay, then disappear safely.
- Authorized jobs can remove natural GTA traffic and parked vehicles without
  creating an ownership, garage, DRS impound, or MDT record. Mission and script
  vehicles fail closed.
- The impound panel now sizes itself to short lists, keeps recovery actions
  readable, and separates the reason, fee, officer, and timestamp metadata.

## What changed in 2.3

- Added a job-authorized global vehicle target for police, law-enforcement job
  types, and other explicitly configured jobs such as tow or mechanic.
- Added officer-entered reasons and per-vehicle release fees, with the same
  authorization, distance, occupancy, identity, ownership, and state checks
  repeated by the server.
- Added automatic creation and validation of the namespaced
  `drs_vehicle_impounds` active-record table.
- Preserved Qbox/QB police compatibility: priced `/depot` vehicles remain
  payable, while state-2 `/impound` vehicles without a DRS record remain an
  authority hold by default.

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
- Qbox fleet issuance requires `qbx_vehicles`; paid society fleet purchases also
  require the current `drs_vehicleshop` and a configured society banking provider
- optionally `ox_target`, `qb-target`, or `qtarget`; TextUI is used when no
  supported target is available
- optionally `qbx_radialmenu` or `qb-radialmenu`; ox_lib provides the automatic
  radial fallback

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
ensure qbx_radialmenu # optional; otherwise DRS uses ox_lib radial directly
ensure qbx_vehicles
ensure qbx_vehiclekeys
ensure ox_inventory
ensure ox_target

# Required only for paid society fleet purchases (choose the provider you use):
# Pure Qbox commonly uses Renewed-Banking; Doctor reports its async persistence limitation.
ensure Renewed-Banking
# qb-banking is preferred when your framework stack supports it because mutations are awaited.
# ensure qb-banking

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

On Qbox, native `bike` vehicles (motorcycles and bicycles) are handed off
unlocked to match the default `qbx_vehiclekeys` no-lock policy. Other vehicle
types retain the normal locked takeout presentation. A failed or unverified
key-resource handoff is logged as a DRS warning without discarding the
successfully spawned vehicle.

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

### Enforcement records

Automatic migration creates and validates the namespaced
`drs_vehicle_impounds` table even when creation of new enforcement impounds is
disabled. This keeps existing records recoverable if the target action is later
turned off. It stores one active record per plate, including ownership scope,
reason, fee, release mode, officer identity/job, source resource, and timestamp.
It does not add DRS reason or officer columns to the framework vehicle table.
The active record is removed after a successful payable release.

With automatic migration disabled, import
[`sql/drs_vehicle_impounds.sql`](sql/drs_vehicle_impounds.sql) before starting
this version. Startup validates its required columns, exact primary/unique
indexes, and existing active rows; an incompatible table blocks database
readiness instead of being rebuilt or having records discarded.

The framework vehicle table and `drs_vehicle_impounds` must both use InnoDB.
Startup rejects nontransactional storage engines because vehicle state and DRS
impound metadata are committed together.

### Contract and job-fleet journals

With automatic migration enabled, DRS also creates and exactly validates:

- `drs_vehicle_contract_operations`, the Contract V2 recovery ledger;
- `drs_job_fleet_vehicles`, the policy metadata for managed society assets; and
- `drs_job_fleet_operations`, the durable fleet mutation/idempotency journal.

With automatic migration disabled, import
[`sql/drs_vehicle_contract_operations.sql`](sql/drs_vehicle_contract_operations.sql)
and [`sql/drs_job_fleet.sql`](sql/drs_job_fleet.sql) before starting DRS. These
tables never replace the framework vehicle table. An incompatible existing
journal is not dropped or rewritten automatically; preserve its audit rows and
follow the reported repair instructions.

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
database readiness, target/radial and vehicle-key resources, known conflicts,
companions, configured locations, parking behavior, storage mode, garage IDs,
runtime state, contract registration/journal health, and fleet service/purchase
health.

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

The enforcement impound action targets live vehicles, so it has no TextUI
equivalent. A local GTA vehicle is promoted to a network entity before the
server classifies it. The action requires a started supported target provider;
trusted client/server integrations remain available when one is not used.

## Nearby radial and vehicle parking

The new interaction layer is additive. Attendant targets, TextUI prompts, and
the existing parking keybind remain available.

```lua
Config.RadialMenu = {
    Enabled = true,
    Provider = 'auto', -- qbx_radialmenu, qb-radialmenu, ox_lib
    Distance = 10.0,
    PropertyDistance = 3.0
}

Config.Parking = {
    ProgressDuration = 5000,
    ProgressCanCancel = true,
    MaximumSpeed = 0.5,
    TargetEnabled = true,
    TargetDistance = 3.0
}
```

Radial auto-detection prefers `qbx_radialmenu`, then `qb-radialmenu`, then the
ox_lib radial already required by DRS. The option exists only while the player
is near an accessible garage entry and resolves the closest valid garage again
when selected. Dynamic property removal, job changes, logout, death-state
changes, and provider restarts remove or rebuild the option safely.

The global `Park vehicle · DRS` target appears only for an empty, stationary,
networked vehicle while both player and vehicle are in a compatible garage
parking area. Local target checks intentionally contain no ownership data; the
selection therefore runs a read-only server ownership/identity preflight before
showing the progress bar. The final transaction independently decides personal
ownership first, then the current society job outside property garages. An
unowned or stale vehicle is rejected immediately without changing or deleting it.

All parking routes share the same cancellable progress. Moving the vehicle,
entering/leaving it unexpectedly, adding an occupant, changing its identity,
leaving the area, losing job/property access, or changing the dynamic property
garage cancels the operation before any database work begins. After progress,
the server repeats the stationary, access, proximity, type, entity, ownership,
and storage-state checks before deletion and the exact database update.

## Enforcement impounds

Configure the built-in police/job action in `config/config.lua`:

```lua
Config.EnforcementImpound = {
    Enabled = true,
    Distance = 3.0,
    MaximumSpeed = 1.0,
    Duration = 5000,
    MinimumReasonLength = 3,
    MaximumReasonLength = 200,
    DefaultFee = 500,
    MinimumFee = 0,
    MaximumFee = 25000,
    RemovalDelay = 30000,

    AmbientVehicles = {
        Enabled = true,
        NetworkTimeout = 2000,
        MaximumDisplacement = 5.0,
        MaximumPendingPerOfficer = 3,
        AllowedPopulationTypes = { 1, 2, 3, 4, 5 }
    },

    Jobs = {
        police = { MinGrade = 0, RequireDuty = true },
        -- tow = { MinGrade = 0, RequireDuty = false },
    },

    JobTypes = {
        leo = { MinGrade = 0, RequireDuty = true }
    },

    LegacyStateTwoHold = true
}
```

`Jobs` uses exact framework job names on Qbox, QB-Core, and ESX. `JobTypes` is
for Qbox job types; the default `leo` rule covers all departments configured as
law enforcement. Each rule can require a minimum grade and on-duty status. Add
tow, mechanic, sheriff, or other jobs explicitly rather than granting a broad
client-side target option.

Stock ESX does not expose one universal duty flag, so DRS treats the current ESX
job as active when neither `onduty` nor `onDuty` exists. Custom ESX duty values
are honored when present; set `RequireDuty = false` to ignore them deliberately.

An authorized player on foot can target a nearby, stopped, empty vehicle. An
owned player/society vehicle opens the reason and bounded release-fee dialog;
the server repeats the job, routing bucket, distance, speed, occupant, identity,
ownership, and storage-state checks before committing it. The reason, fee,
officer, and time are shown in the impound interface immediately. The exact live
entity stays locked and immobilized for `RemovalDelay` milliseconds (30 seconds
by default) before physical removal. A zero delay removes it immediately.

Natural GTA traffic and parked vehicles use a separate confirmation. They are
removed after the same delay without writing to the framework vehicle table,
`drs_vehicle_impounds`, garage history, or MDT. DRS accepts only configured
natural population types 1-5 and rechecks ownership at removal time; persistent,
managed, mission, and script vehicles are never treated as ambient.

The DRS option can coexist with an unmodified `qbx_police`:

- `qbx_police` `/depot [price]` remains a legacy priced depot. When no active
  DRS record exists, DRS honors `player_vehicles.depotprice` at recovery.
- `qbx_police` `/impound` leaves a QB/Qbox vehicle in state 2 without a DRS
  release record. With `LegacyStateTwoHold = true`, DRS treats that as an
  authority hold and will not allow the owner to pay it out. The police/MDT
  workflow must release the hold, or officers can use the DRS target when a
  payable reason-and-fee record is intended.

DRS-recorded fees take precedence over legacy `depotprice`. If neither is
available, `Config.ImpoundPrice` remains the fallback for legacy or natural
impound recovery.

The optional DRS police-integration patch routes both `qbx_police` `/depot` and
`/impound` into the DRS reason/fee dialog instead. In that setup those commands
create payable DRS records; permanent authority holds remain available only
through an explicitly retained legacy/administrative workflow.

## Vehicle-list interface

`Config.Interface.Mode = 'auto'` uses the compact vehicle panel after its NUI
readiness handshake succeeds and otherwise opens the original ox_lib context
menus. Use `'nui'` to prefer the panel or `'context'` to keep the original menu.
`ContextFallback = true` keeps the context menu available if a forced NUI does
not load.

The panel automatically asks a started `drs_vehicleshop` for configured names,
brands, and ordered image candidates. Add-on artwork is served from the shop
resource without being copied into DRS Garages; Cfx renders and the bundled DRS
silhouette provide fallbacks. The shop is optional and is not a manifest
dependency.

One- and two-vehicle lists use a content-sized panel. Impound cards show labeled
reason, release fee, officer, and timestamp fields; paid recovery keeps the fee
in the card instead of repeating it in a clipped button. Recovering a vehicle
checks the impound spawn point, plays the normal retrieval presentation, and
does not teleport the player into the driver seat.

The browser receives only short-lived item IDs and display fields. Plates,
vehicle properties, ownership scope, garage identity, and the actual action are
resolved from the current Lua session and revalidated by the existing server
callbacks.

## Vehicle Contract V2

The master contract feature is enabled, but its three actions are independent.
The supplied safe policy enables only boss-authorized personal-to-society
donations. Player sales and society-to-personal withdrawals remain disabled.
The withdrawal policy is `admin`, so enabling that action still requires
`drs_garages.contract.admin`.

Add the configured `contract` item to the active inventory by following
[`install/ContractItem.md`](install/ContractItem.md). DRS cannot safely edit an
external inventory catalog automatically. Contract signing is cancellable and
does not consume the item or mutate ownership until the server has revalidated
the item, players, job/boss policy, exact nearby vehicle row, routing bucket,
price, and operation locks.

Every transfer is recorded in `drs_vehicle_contract_operations`. Startup
reconciles provable outcomes and quarantines ambiguous plates. Inspect and
resolve only after checking inventory, money, ownership, and keys:

```text
drsgarages:contracts
drsgarages:contractresolve <operation_id> <completed|compensated|cancelled>
```

`Config.Contract.VehicleDistance` defaults to `5.0` metres and
`PlayerDistance` to `10.0`. `PaymentAccount` accepts `money` (cash on QB/Qbox)
or `bank`. Stock QB `qb-vehiclekeys` cannot safely reset global/offline plate
keys, so DRS blocks contract registration on that unsupported combination.

## Job Fleet Manager

Any static public garage with an exact `Jobs` allowlist can host a managed job
fleet. Give it a stable `Garage` ID; the supplied MRPD example uses
`mrpd_fleet`. At that garage an authorized boss can use the Society tab's
**Manage fleet** button or `/jobfleet` to:

- permanently donate one of their personal stored/nearby out vehicles;
- move a stored managed asset between compatible garages for the same job;
- set the minimum job grade required to list, locate, recover, or take it out;
- retire a stored asset with plate confirmation and an audit reason; and
- on Qbox, purchase from `drs_vehicleshop` with society funds.

ACE administrators can manage another configured job and use the separate free
issuance action. Boss free issuance is disabled by default so it cannot bypass
society purchasing. Models must exist in both the framework catalog and
`Config.JobFleet.AllowedModels`; paid models must also be allowed by the shop's
`Config.Fleet.Catalogs`. Managed assets always honor their assigned garage even
when `Config.Storage.Mode = 'global'`; untouched legacy job rows retain the
legacy global behavior until adopted.

Add these administrator permissions:

```cfg
add_ace group.admin drs_garages.contract.admin allow
add_ace group.admin drs_garages.fleet.admin allow
```

Fleet mutations are recorded in `drs_job_fleet_operations`. Attention rows
keep their plates quarantined until an administrator verifies the framework row
and journal, then deliberately resolves them:

```text
drsgarages:fleetops [plate]
drsgarages:fleetresolve <operationId> <committed|failed> <reason>
```

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

Trusted server-side fleet issuance (normally called only by
`drs_vehicleshop`):

```lua
local result = exports.drs_garages:CreateJobFleetVehicle({
    requestId = 'stable-id-from-caller',
    actorSource = source,
    action = 'society_purchase', -- or admin_grant from an allowed resource
    job = 'police',
    model = 'police3',
    garageIndex = configuredGarageIndex,
    minGrade = 0,
    reason = 'Optional audit note'
})
```

The invoking resource must be in `Config.JobFleet.TrustedResources`; the
connected actor, exact boss/admin permission, garage/job/model allowlists,
request fingerprint, and final database row are all revalidated server-side.

Server-side enforcement impound integration:

```lua
local success, reason = exports.drs_garages:ImpoundVehicle(
    source,
    NetworkGetNetworkIdFromEntity(vehicle),
    'Blocking an emergency access lane',
    500
)
```

For the server export, `source` must be the connected, currently authorized
officer/player. It does not bypass `Enabled`, job/grade/duty rules, fee/reason
limits, or any entity and ownership checks. It returns `true` when the protected
impound and delayed tow have been scheduled, or `false` plus a stable failure
reason such as `not_authorized`, `invalid_fee`, `vehicle_occupied`, or
`vehicle_not_owned`. Optional third/fourth returns report the mode and delay in
milliseconds; existing callers using only `success, reason` remain compatible.

Client-side police command integration can open the same DRS dialog as the
global target. The optional fee only pre-fills the input and is clamped to the
configured limits:

```lua
exports.drs_garages:OpenEnforcementImpound(vehicle, optionalDefaultFee)
```

The export does not impound or delete the vehicle by itself. DRS classifies the
exact entity server-side: owned vehicles use the recorded reason/fee workflow,
while enabled natural ambient vehicles use the unrecorded confirmation path.
Every permission, proximity, identity, ownership, and database check is repeated
before scheduling either removal.

## First-start verification

1. Back up the database and the current resource folders.
2. Confirm the folder is named `drs_garages` and only one framework core is
   running.
3. Start resources in the documented order and wait for schema readiness.
4. Run `drsgarages:doctor`; resolve every FAIL.
5. Test one car, boat, and aircraft through park, takeout, restart, and impound.
6. Near a public and property garage, open the radial option and verify it
   disappears after leaving. Target an empty owned vehicle, cancel one parking
   attempt, then complete the five-second park; confirm a moving or occupied
   vehicle cannot be parked.
7. As an authorized on-duty job, target an empty owned vehicle, enter a reason
   and fee, verify it remains immobilized for 30 seconds, then confirm the owner
   sees both and can pay the exact fee. Recovery must leave the owner on foot.
8. Verify an unauthorized/off-duty job cannot see or call the action, and that a
   `qbx_police` state-2 hold cannot be paid out through DRS.
9. Remove a natural parked/local vehicle and confirm it creates no database,
   garage, DRS, or MDT record; confirm a mission/script vehicle is rejected.
10. Test a property as owner, keyholder, and unauthorized player.
11. Buy one vehicle through `drs_vehicleshop` and confirm its configured garage,
    keys, storage state, and restart persistence.
12. As a job boss at MRPD, donate a personal vehicle, set a grade restriction,
    verify a lower grade cannot see/use it, move it, then retire a disposable
    test asset. As an ACE admin, test one free allowlisted issuance.
13. With society banking funded, purchase one police vehicle through Fleet
    Manager and confirm exactly one debit, one shop order, one fleet operation,
    and one stored job vehicle. Test the contract item donation path separately.

## Attribution and license

This is a modified fork of
[Lunar Scripts' `lunar_garage`](https://github.com/Lunar-Scripts/lunar_garage),
originally version 2.0.3. DRS maintains the database safety work, QB/Qbox
property integrations, vehicle-shop handoff support, persistence fixes,
diagnostics, storage modes, and the `drs_garages` namespace.

The original GPLv3 license is retained in `LICENSE`. See `NOTICE.md` for the
fork notice. The upstream version checker and Lunar-branded Discord icon were
removed because they do not represent DRS releases.
