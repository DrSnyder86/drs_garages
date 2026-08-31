# Changelog

## 2.6.0-drs.1 — 2026-08-29

### Contract V2

- Split player sales, boss society donations, and society withdrawals into
  independent policies; only boss donations are enabled by default.
- Added eligibility-aware/cancellable signing plus exact server revalidation.
- Added a durable transfer journal, restart reconciliation, ambiguous-plate
  quarantine, administrator inspection/resolution commands, and item setup docs.

### Job fleets

- Added boss/admin Fleet Manager for personal donations, stable garage
  assignments, minimum-grade access, moves, audited retirement, and separate
  ACE-admin issuance from a server model allowlist.
- Enforced managed fleet grade/garage policy across listing, takeout, impound
  recovery, and location; legacy job rows remain compatible until adopted.
- Added fleet metadata/audit tables, idempotent external creation, restart
  reconciliation, plate quarantine, and administrator recovery commands.

### Society purchasing and interface

- Added a protected `drs_vehicleshop` bridge for Qbox boss purchases using
  society banking, independent shop/fleet recovery journals, and fail-closed
  payment/creation handoff semantics.
- Added **Manage fleet** to the Society tab/context fallback and minimum-grade
  badges to managed vehicle cards.
- Expanded the doctor with contract item/journal, fleet service, purchase bridge,
  free-issuance policy, and unresolved-operation reporting.

## 2.5.0-drs.1 — 2026-08-26

### Garage interaction quality of life

- Added dynamic nearby-garage radial access with automatic `qbx_radialmenu`,
  `qb-radialmenu`, and ox_lib provider support, including safe removal on exit,
  logout, death-state changes, property removal, and resource restart.
- Added a global `Park vehicle` target action for empty, networked vehicles in
  a compatible public, job, or authorized property parking area, with a read-only
  ownership preflight before the progress bar. The existing attendant, TextUI,
  and keybind paths remain available.
- Added a configurable, cancellable five-second parking progress bar shared by
  every parking path. Movement, occupants, vehicle identity, network identity,
  garage access, and parking geometry are rechecked throughout the progress and
  immediately before the protected server transaction.
- Parking now requires a configurable complete stop on both client and server,
  and high-capacity modded vehicles receive expanded occupant checks.

### Diagnostics

- The doctor now reports the selected radial provider/fallback and the effective
  parking progress, movement, and target settings.

## 2.4.0-drs.2 — 2026-08-25

### Fixed

- Qbox motorcycles and bicycles now leave garage and impound takeout unlocked,
  matching the default `qbx_vehiclekeys` no-lock policy instead of creating a
  locked bike that the key resource intentionally refuses to unlock.
- The takeout property payload carries the final lock state, preventing delayed
  property restoration from re-locking a native bike.

### Diagnostics

- Failed or unverified Qbox/QB vehicle-key handoffs now produce a plate/source
  warning in the server log instead of being silently discarded.

## 2.4.0-drs.1 — 2026-08-25

### Impound quality of life

- Impound recovery now mirrors normal garage takeout, including spawn-point
  occupancy checks, retrieval presentation, keys/fuel, and leaving the player
  on foot instead of warping into the vehicle.
- Owned impounds commit immediately and keep the exact empty vehicle locked and
  immobilized for a configurable 30-second delay before physical removal.
- Natural GTA traffic and parked vehicles can be marked for delayed removal
  without creating ownership, garage, DRS impound, database, or MDT records.
  Managed, persistent, mission, and script vehicles fail closed.

### Interface

- One- and two-vehicle lists now use a content-sized panel, while larger lists
  retain the fixed-height scroll view.
- Impound cards use labeled reason, fee, officer, and timestamp fields, a fully
  readable recovery action, useful impound sorting, and an amber count state.

## 2.3.0-drs.2 — 2026-08-24

### Added

- Added the client-side `OpenEnforcementImpound` export so trusted police-job
  commands can open the same DRS reason/fee dialog as the global vehicle target.
- The optional caller-provided fee is clamped to the configured DRS limits; all
  authorization, entity, ownership, and persistence checks remain server-side.

### Police integration

- `qbx_police` can now route its legacy `/depot` and `/impound` entry points to
  DRS without maintaining a second physical-impound transaction.
- Structured DRS and MDT records remain owned by their originating workflow,
  preventing legacy police-lot release paths from orphaning an active record.

## 2.3.0-drs.1 — 2026-08-24

### Added

- Added a configurable global vehicle target for authorized police, law
  enforcement job types, and explicitly configured tow/mechanic jobs.
- Added required impound reasons, bounded per-vehicle release fees, officer/job
  audit details, and matching context-menu/NUI presentation.
- Added automatic creation and strict validation of the namespaced
  `drs_vehicle_impounds` active-record table, plus a manual SQL installer.
- Added the server-side `ImpoundVehicle` export for trusted job integrations;
  it retains all DRS authorization, identity, distance, and ownership checks.

### Compatibility and reliability

- DRS-recorded fees take precedence over legacy pricing; Qbox/QB
  `depotprice` remains payable, including across resource restarts.
- Qbox/QB state-2 vehicles without a DRS release record remain authority holds
  by default, preserving `qbx_police` permanent impound behavior.
- Failed retrievals restore released DRS records, vehicle state, legacy depot
  prices, and player payment only when the exact operation can be rolled back.
- Live vehicle deletion and database transitions use exact plate/model/row
  identity and per-plate exclusion checks to prevent cloned or raced impounds.

## 2.2.0-drs.7 — 2026-08-24

### Fixed

- Vehicle placeholders now disappear as soon as a real photo loads, preventing
  the fallback silhouette from showing through transparent vehicle images.
- The placeholder remains available when every configured image source fails.

## 2.2.0-drs.6 — 2026-08-23

### Improved

- Refined compact UI vehicle-image framing so photos remain fully visible, with
  clearer secondary text, calmer condition meters, larger controls, and a more
  readable scrolling edge above the footer.
- Clarified sorting labels, improved compact-screen sizing, and protected long
  vehicle categories and translated action labels from clipping the card layout.
- Vehicle search now also matches the spawn model, and the dialog reports busy
  state and initial keyboard focus more clearly to assistive technology.

## 2.2.0-drs.5 — 2026-08-23

### Fixed

- Target-based parking now accepts the intended nearby last vehicle after the
  driver steps out, while requiring the vehicle to be empty, within the garage
  parking area, close to the player, server-registered, and database-owned.
- Qbox semi-persistence replacements can restore a missing active-vehicle
  mapping only after exact row identity, plate, model, state, ownership, and
  duplicate-entity validation.
- Parking failures now report an accurate player-facing category and log the
  exact server rejection reason instead of labeling every failure as an
  ownership problem.

## 2.2.0-drs.4 — 2026-08-23

### Added

- Optional compact garage and impound NUI with personal/society tabs, search,
  sorting, vehicle status, fuel, condition, and contextual actions.
- Automatic vehicle presentation integration with `drs_vehicleshop`, Cfx image
  fallback, and a bundled missing-image silhouette.
- `Config.Interface` modes for automatic NUI selection, forced NUI, or the
  original ox_lib context menus.

### Security and compatibility

- Browser selections use expiring opaque item IDs; trusted plates, vehicle
  properties, ownership scope, location, and actions remain in Lua and retain
  the existing server validation.
- The original context menus remain available as an automatic/configurable
  fallback, and `drs_vehicleshop` remains optional.
- The NUI root canvas explicitly uses a normal transparent color scheme so
  FiveM does not replace the game view with a dark browser background.

## 2.2.0-drs.3 — 2026-08-22

### Fixed

- MariaDB's unquoted `NULL` representation for an explicit SQL NULL column
  default is now accepted during schema validation. Literal string defaults
  such as `'NULL'` remain incompatible.
- Incompatible existing-column guidance now states that those definitions need
  manual correction; automatic and supplied migrations only add missing
  compatibility columns.

## 2.2.0-drs.2 — 2026-08-22

### Fixed

- Framework diagnostics and automatic database setup now distinguish concrete
  resources from fxmanifest `provide` aliases. Qbox's `qb-core` compatibility
  alias no longer reports a second running core.
- Database setup now requires exactly one resolved core and verifies that it
  matches the loaded framework adapter before inspecting or changing schema.
- Target diagnostics no longer count `ox_target` and its `qtarget`
  compatibility alias as two separate providers.
- The legacy QB adapter no longer initializes under Qbox through its
  compatibility alias; Qbox uses only the native Qbox adapter.

## 2.2.0-drs.1 — 2026-08-22

### Added

- `Config.Storage` with `global` (default), `garage`, and `property` modes.
- Type-specific default garage and virtual legacy/property recovery settings.
- Stable storage identities for public and dynamic property garages.
- Restricted `/drsgarages:doctor` diagnostics with PASS/WARN/FAIL reporting.
- Target adapters for `ox_target`, `qb-target`, and `qtarget`, plus TextUI
  fallback at `Position` or the configured `PedPosition` coordinates.
- Read-only schema validation when automatic migration is disabled.
- UNIQUE full-column plate validation/migration for QB/Qbox and ESX.
- Qbox, QB-Core, ESX, and upgrade documentation.

### Changed

- The manifest now identifies DRS version `2.2.0-drs.1` and requires
  `ox_lib`, `oxmysql`, and OneSync.
- QB/Qbox parking saves the canonical public or property garage assignment.
- Garage, interior, and impound lists enforce the database vehicle type.
- Property assignments remain isolated or recover according to the selected
  storage mode without startup bulk mutations.
- ESX validates its existing schema and uses `global` storage when a non-global
  mode is configured.
- ESX rows without a database `type` use live server-created entity validation
  to prevent cross-type takeout or parking; an optional type column improves
  menu filtering.
- The supported vehicle-shop companion is `drs_vehicleshop`.
- Vehicle contracts are now opt-in because framework money, inventory,
  ownership, and persistent-key effects are not one crash-durable transaction.
- Paid impound redemption is now opt-in (`Config.ImpoundPrice = 0` by default)
  for the same crash-durability reason.

### Security and reliability

- Added normalized per-plate locks around takeout, retrieval, and parking.
- Revalidated ownership, job access, location distance, stored state, model,
  type, and active entity before state transitions.
- Made storage changes conditional on successful database transitions.
- Added bounded network-owner waits and cleanup/refund handling for failed
  spawns and impound retrievals.
- Routed Qbox entity cleanup through its persistence-aware vehicle deletion so
  compatible semi-persisted vehicles cannot respawn after being stored.
- Restricted vehicle-coordinate lookup to authorized owners/jobs.
- Added routing-bucket cleanup for garage interior disconnects and resource
  stops.
- Database migration refuses ambiguous framework cores and duplicate normalized
  plates. It never deletes or merges an owned vehicle.

### Compatibility

- Retained `qbx_properties` property registration and canonical-ID exports.
- Retained stock `qb-houses` discovery and safe `qb-apartments` detection.
- Retained `drs_vehicleshop` active delivery-vehicle exports.
- Retained the original GPLv3 license and Lunar Scripts attribution.
