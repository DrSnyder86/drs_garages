# Changelog

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
