# dbx-toolbox
DbxToolbox: short `dbx-*` PowerShell commands for the Databricks CLI (explore Unity Catalog, run SQL, move files, warehouses, jobs). Public, MIT. Generic: nothing in it may name a project, employer, workspace host or catalog. Plan: `~/vault/Projects/dbx-toolbox/plan.md`.

## Stack
- Language/framework: PowerShell module, Windows PowerShell 5.1 and PowerShell 7+, wrapping the Databricks CLI (0.200+)
- Database: none
- Tests: Pester 5 (5.9.1 pinned for Windows PowerShell 5.1 support); lint: PSScriptAnalyzer

## Setup
```bash
pwsh -NoProfile -c 'Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -SkipPublisherCheck'
pwsh -NoProfile -c 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
```

## Run
```bash
pwsh -NoProfile -c 'Import-Module ./DbxToolbox -Force; dbx-help'
```

## Test and check
```bash
pwsh -NoProfile -NonInteractive -c 'Import-Module Pester -RequiredVersion 5.9.1; Invoke-Pester ./tests -Tag Unit -Output Detailed'
pwsh -NoProfile -c 'Invoke-ScriptAnalyzer -Path ./DbxToolbox -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
```
Both must pass before a task counts as done. Unit tests never touch Databricks.

## Structure
- `DbxToolbox/` — the module: `DbxToolbox.psd1` (manifest: version, exports) and `DbxToolbox.psm1` (all commands)
- `tests/` — Pester tests; `-Tag Unit` runs without Databricks
- `CHANGELOG.md` — every user-visible change, newest first
- `PSScriptAnalyzerSettings.psd1` — lint settings; each exclusion says why
- `.github/workflows/ci.yml` — lint + unit tests on Windows PowerShell 5.1, PowerShell 7 Windows and Linux

## Project-specific rules
- Keep every source file ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
- Every command that changes anything supports `-WhatIf`/`-Confirm`, asks first (default No), and does nothing if the question can't be asked.
- Settings live in `~/.dbx-toolbox.json`; commands take `-Catalog`/`-Schema` and fall back on settings only for what's left out, saying so in grey (Write-Host, never in returned objects).
- New command: add its function, add it to `$script:Aliases`, add it to the manifest's `FunctionsToExport`/`AliasesToExport`, add a test, add a CHANGELOG line.
- No 5.1-breaking syntax: no `??`, `?.`, ternary, `&&`/`||`, three-argument `Join-Path`.
- Never put a workspace host, token, catalog name or employer name in code, tests, docs or commits.

## Status / known issues
- 2026-11-01: split out of a single-file copy in another of my repositories (history starts here). Pester unit tests in `tests/DbxToolbox.Tests.ps1` (fake `databricks` function, settings in TestDrive). CI in `.github/workflows/ci.yml`. Next: command reference (task 6), release workflow (task 7). Live Databricks tests deferred.
