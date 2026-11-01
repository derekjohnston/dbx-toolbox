# Changelog

All notable changes to DbxToolbox. Versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-01
First release as its own project (previously a single file inside another repository).

### Added
- Module manifest (`DbxToolbox.psd1`): installs as a normal PowerShell module and loads itself.
- `dbx-rmschema`: delete a schema and everything in it, after showing what it holds.
- `-Comment` on `dbx-mkschema` and `dbx-mkvolume`.
- A grey `(using default …)` note whenever a command falls back on saved settings.

### Fixed
- `dbx-config -Profile` and `dbx-use -Profile` no longer assign to PowerShell's built-in
  `$Profile` variable inside the command (`-Profile` still works; it's now an alias).

### Changed
- No project-specific defaults: no default schema, no built-in volume name. Set them with
  `dbx-config -Catalog … -Schema … -Volume …`; file commands ask for a volume if none is set.
