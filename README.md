# DbxToolbox

[![CI](https://github.com/derekjohnston/dbx-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/derekjohnston/dbx-toolbox/actions/workflows/ci.yml)

Short `dbx-*` PowerShell commands for the [Databricks CLI](https://docs.databricks.com/dev-tools/cli/):
browse Unity Catalog, run SQL and save the results, move files in volumes, start and stop
warehouses, and look at jobs. Anything that changes something asks first.

Works in Windows PowerShell 5.1 and PowerShell 7+, on Windows, macOS and Linux.

## Install

1. Install the Databricks CLI (0.200 or later) and sign in: `databricks auth login --host <workspace-url>`.
2. Download the latest release zip
   ([`DbxToolbox.zip`](https://github.com/derekjohnston/dbx-toolbox/releases/latest/download/DbxToolbox.zip),
   or a versioned one from [Releases](https://github.com/derekjohnston/dbx-toolbox/releases)) and unzip its
   `DbxToolbox` folder into a module folder, for example
   `Documents\PowerShell\Modules\DbxToolbox` (PowerShell 7) or
   `Documents\WindowsPowerShell\Modules\DbxToolbox` (5.1). It then loads itself.
   Or keep it anywhere and run `Import-Module <folder>\DbxToolbox`.
3. If PowerShell says *running scripts is disabled*:
   `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, then `Unblock-File` the files.

## Quick start

```powershell
dbx-config -Profile <cli-profile> -Catalog <catalog> -Schema <schema> -Volume <volume>
dbx-help                                   # every command, and which ones ask first
dbx-tables                                 # tables in the default schema
dbx-cols my_table
dbx-sql "SELECT * FROM my_table LIMIT 20" -Table
dbx-sql "SELECT * FROM my_table" -Csv C:\temp\my_table.csv
dbx-ls                                     # files in the default volume
```

Settings are saved in `~/.dbx-toolbox.json`; `dbx-settings` shows them, `dbx-use` changes
them for one terminal only. Every command also takes `-Catalog` / `-Schema`, a full
`catalog.schema.table` name or a full `/Volumes/...` path; when it falls back on a saved
setting it says so in grey, e.g. `(using default catalog …, schema …)`.

## Changes ask first

Creating, uploading, deleting, running SQL that may change data, and starting or stopping
warehouses all ask `Are you sure?` (default **No**). `-WhatIf` shows what would happen;
`-Confirm:$false` skips the question. If the question can't be shown (a script with no
console), nothing changes. `dbx-rmschema` shows how many tables and volumes a schema holds
before it asks.

## Development

```powershell
Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-Pester ./tests -Tag Unit      # from pwsh -NonInteractive, as CI does
Invoke-ScriptAnalyzer -Path ./DbxToolbox -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Unit tests never touch Databricks. CI runs them on Windows PowerShell 5.1 and
PowerShell 7 (Windows and Linux) for every pull request. See `AGENTS.md` for the project's rules and
`CHANGELOG.md` for what changed.

## Licence

MIT. See `LICENSE`.
