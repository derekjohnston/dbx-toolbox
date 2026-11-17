# Changelog

All notable changes to DbxToolbox. Versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- Secret commands: `dbx-secret-scopes` (scopes and their backend), `dbx-secrets <scope>`
  (key names and when set, never values), `dbx-secret-access <scope>` (who can read, write
  or manage), and, asking first, `dbx-mkscope <scope>`, `dbx-secret-set <scope> <key>` and
  `dbx-secret-grant <scope> <principal> -Permission READ|WRITE|MANAGE`. `dbx-secret-set`
  asks for the value with hidden input and passes it to the CLI on standard input, so it
  never appears on the command line, on screen or in history.

## [0.2.0] - 2026-11-15

### Added
- Bundle commands (Databricks Asset Bundles), run in the folder holding databricks.yml:
  `dbx-bundle` (what a target holds: folder, jobs and Apps with links), `dbx-bundle-check`
  (validate), `dbx-deploy` (shows where it goes, who jobs run as and what it makes, then
  asks) and `dbx-bundle-run` (run a job or start an App, asks first). All take `-Target`
  and `-Var @{ name = 'value' }`.

## [0.1.0] - 2026-11-07
First release as its own project (previously a single file inside another repository).

### Added
- Generated command reference in `docs/commands.md`; regenerate with `scripts/Build-Docs.ps1`.
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
