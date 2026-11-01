#Requires -Version 5.1
<#
DbxToolbox: short PowerShell commands for the Databricks CLI.

Generic: it knows nothing about any project. Your profile, catalog, schema, warehouse and
volume are settings, not code.

Install: unzip a release into a folder on $env:PSModulePath (e.g. Documents\PowerShell\Modules\
DbxToolbox) and it loads itself on first use, or Import-Module <folder>\DbxToolbox.

Settings live in ~/.dbx-toolbox.json (set with dbx-config), so upgrading never loses them.
`dbx-help` lists every command. Commands that change anything ask before they act; add
-WhatIf to see what one would do, or -Confirm:$false to skip the question.
https://github.com/derekjohnston/dbx-toolbox
#>

# ---- Settings ----------------------------------------------------------------------------
$script:ConfigPath = Join-Path $HOME '.dbx-toolbox.json'
$script:Cfg = [ordered]@{
    Profile    = 'DEFAULT'  # Databricks CLI profile
    Catalog    = ''         # default catalog
    Schema     = ''         # default schema
    Warehouse  = ''         # SQL warehouse ID; empty = the first one listed
    Volume     = ''         # default volume in that schema, for dbx-ls/put/get/mkdir/rm/du
    VolumePath = ''         # or a full default folder (/Volumes/...); wins over Volume
}
if (Test-Path $script:ConfigPath) {
    $saved = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $saved.PSObject.Properties) { $script:Cfg[$p.Name] = $p.Value }
}

# ---- Helpers (not exported) --------------------------------------------------------------

# Runs the CLI with the current profile and JSON output; returns objects, or $null on error.
function Invoke-DbxCli([string[]]$CliArgs, [switch]$NoProfile) {
    $all = @($CliArgs) + @('-o', 'json')
    if (-not $NoProfile) { $all += @('-p', $script:Cfg.Profile) }
    $json = & databricks @all
    if ($LASTEXITCODE -ne 0) { return }  # the CLI has already printed the error
    if (-not $json) { return }
    $data = ($json | Out-String) | ConvertFrom-Json
    $data  # returning it unrolls a list into one object per row
}

function Get-DbxVolumeRoot {
    if ($script:Cfg.VolumePath) { return $script:Cfg.VolumePath.TrimEnd('/') }
    if ($script:Cfg.Catalog -and $script:Cfg.Schema -and $script:Cfg.Volume) {
        return "/Volumes/$($script:Cfg.Catalog)/$($script:Cfg.Schema)/$($script:Cfg.Volume)"
    }
    throw 'No default volume: set one with dbx-config -Volume <name> (or -VolumePath /Volumes/...), or give a full /Volumes/... path'
}

# 'folder/sub' -> dbfs:/Volumes/<default volume>/folder/sub; '/Volumes/...' or 'dbfs:/...' kept as given.
function Resolve-DbxPath([string]$Path) {
    if ($Path -like 'dbfs:*') { return $Path }
    if ($Path -like '/*') { return "dbfs:$Path" }
    $root = Get-DbxVolumeRoot
    Write-Host "(using default volume $root)" -ForegroundColor DarkGray
    if (-not $Path) { return "dbfs:$root" }
    "dbfs:$root/$($Path.TrimStart('/'))"
}

# Says which saved defaults a command fell back on, so it's always clear where it runs.
# Write-Host: shown on screen, never mixed into the objects a command returns.
function Write-DbxDefaults([System.Collections.IDictionary]$Bound, [string[]]$Keys) {
    $used = @($Keys | Where-Object { -not $Bound.ContainsKey($_) } |
        ForEach-Object { "$($_.ToLower()) $($script:Cfg[$_])" })
    if ($used) { Write-Host "(using default $($used -join ', '))" -ForegroundColor DarkGray }
}

# 'my_table' -> `cat`.`schema`.`my_table`; 'other.t' -> `cat`.`other`.`t`; three parts kept.
function Resolve-DbxTable([string]$Name) {
    $parts = @($Name.Replace('`', '') -split '\.')
    if ($parts.Count -eq 1) { $parts = @($script:Cfg.Catalog, $script:Cfg.Schema) + $parts }
    elseif ($parts.Count -eq 2) { $parts = @($script:Cfg.Catalog) + $parts }
    if ($parts.Count -eq 3 -and $Name.Replace('`', '').Split('.').Count -lt 3) {
        Write-Host "(using $($parts[0]).$($parts[1]))" -ForegroundColor DarkGray
    }
    ($parts | ForEach-Object { '`' + $_ + '`' }) -join '.'
}

# Asks "Are you sure?" with No as the default, so a stray Enter changes nothing.
# -WhatIf only describes the change; -Confirm:$false skips the question. If PowerShell
# can't ask (a non-interactive run), the answer is no: a failed prompt never lets a change through.
function Confirm-Dbx {
    # A helper: it asks on behalf of the calling command, using that command's -WhatIf/-Confirm.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Calls ShouldProcess on the calling cmdlet')]
    param($Cmdlet, [string]$Target, [string]$Action)
    $bound = $Cmdlet.MyInvocation.BoundParameters
    if ($bound.ContainsKey('WhatIf') -and $bound['WhatIf']) { return $Cmdlet.ShouldProcess($Target, $Action) }
    if ($bound.ContainsKey('Confirm') -and -not $bound['Confirm']) { return $true }
    $choices = [System.Management.Automation.Host.ChoiceDescription[]]@('&Yes', '&No')
    try { $Host.UI.PromptForChoice('Are you sure?', "$Action`n  $Target", $choices, 1) -eq 0 }
    catch {
        Write-Warning "Not done: couldn't ask for confirmation ($($_.Exception.Message))"
        $false
    }
}

function Test-DbxReadOnlySql([string]$Sql) {
    $clean = ($Sql -replace '(?s)/\*.*?\*/', '' -replace '(?m)--.*$', '').Trim()
    $clean -match '^(SELECT|WITH|SHOW|DESCRIBE|DESC|EXPLAIN|LIST|VALUES)\b'
}

function ConvertFrom-DbxMs($Ms) {
    if (-not $Ms) { return $null }
    [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Ms).LocalDateTime
}

function Get-DbxWarehouseId([string]$Id) {
    if ($Id) { return $Id }
    if ($script:Cfg.Warehouse) { return $script:Cfg.Warehouse }
    $first = @(Invoke-DbxCli @('warehouses', 'list'))
    if (-not $first) { throw 'No SQL warehouse visible. Set one with: dbx-config -Warehouse <id>' }
    $first[0].id
}

# Runs one statement on the warehouse; returns rows as objects. No confirmation here:
# callers decide whether to ask.
function Invoke-DbxStatement([string]$Sql, [string]$Warehouse) {
    $body = @{
        warehouse_id = (Get-DbxWarehouseId $Warehouse)
        statement    = $Sql
        wait_timeout = '50s'
    }
    if ($script:Cfg.Catalog) { $body.catalog = $script:Cfg.Catalog }
    if ($script:Cfg.Schema) { $body.schema = $script:Cfg.Schema }
    # Pass the body as a file: Windows PowerShell mangles quotes in JSON given inline.
    $file = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($file.FullName, ($body | ConvertTo-Json))  # UTF-8, no BOM
        $r = Invoke-DbxCli @('api', 'post', '/api/2.0/sql/statements', '--json', "@$($file.FullName)")
        while ($r -and $r.status.state -in 'PENDING', 'RUNNING') {
            Start-Sleep -Seconds 3
            $r = Invoke-DbxCli @('api', 'get', "/api/2.0/sql/statements/$($r.statement_id)")
        }
    }
    finally { Remove-Item $file.FullName -ErrorAction SilentlyContinue }
    if (-not $r) { return }
    if ($r.status.state -ne 'SUCCEEDED') {
        Write-Warning "$($r.status.state): $($r.status.error.message)"
        return
    }
    if (-not ($r.PSObject.Properties.Name -contains 'result') -or -not $r.result) { return }
    if (-not ($r.result.PSObject.Properties.Name -contains 'data_array')) { return }
    $columns = @($r.manifest.schema.columns.name)  # @() keeps one column a list, not a string
    foreach ($row in $r.result.data_array) {
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $columns.Count; $i++) { $obj[$columns[$i]] = $row[$i] }
        [pscustomobject]$obj
    }
}


# ==== Settings and profiles ================================================================

function Invoke-Dbx {
    <#
    .SYNOPSIS
    Any CLI command with your profile and JSON added: dbx schemas get cat.schema
    #>
    Invoke-DbxCli $args
}

function Get-DbxConfig {
    <#
    .SYNOPSIS
    Show the current settings and where they are saved
    #>
    [pscustomobject]$script:Cfg
    "Saved in $script:ConfigPath"
}

function Set-DbxConfig {
    <#
    .SYNOPSIS
    Save default profile, catalog, schema, warehouse, volume or volume path for every session
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only this module''s settings file, never Databricks')]
    # -Profile is an alias: $Profile itself is a built-in PowerShell variable.
    param([Alias('Profile')][string]$CliProfile, [string]$Catalog, [string]$Schema, [string]$Warehouse, [string]$Volume, [string]$VolumePath)
    foreach ($key in 'CliProfile', 'Catalog', 'Schema', 'Warehouse', 'Volume', 'VolumePath') {
        $setting = if ($key -eq 'CliProfile') { 'Profile' } else { $key }
        if ($PSBoundParameters.ContainsKey($key)) { $script:Cfg[$setting] = $PSBoundParameters[$key] }
    }
    # Only this toolbox's own settings file changes, nothing in Databricks: no question asked.
    [IO.File]::WriteAllText($script:ConfigPath, ([pscustomobject]$script:Cfg | ConvertTo-Json))
    Get-DbxConfig
}

function Set-DbxDefault {
    <#
    .SYNOPSIS
    Change catalog, schema or profile for this terminal only: dbx-use cat schema
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only this terminal''s settings, never Databricks')]
    param([string]$Catalog = $script:Cfg.Catalog, [string]$Schema = $script:Cfg.Schema, [Alias('Profile')][string]$CliProfile = $script:Cfg.Profile)
    $script:Cfg.Catalog = $Catalog
    $script:Cfg.Schema = $Schema
    $script:Cfg.Profile = $CliProfile
    "Catalog: $Catalog  Schema: $Schema  Profile: $CliProfile  (this terminal only; dbx-config saves)"
}

function Get-DbxProfiles {
    <#
    .SYNOPSIS
    Your saved CLI sign-ins and whether each is valid
    #>
    $r = Invoke-DbxCli @('auth', 'profiles') -NoProfile
    if ($r) { $r.profiles | Select-Object name, host, valid, default }
}

function Get-DbxMe {
    <#
    .SYNOPSIS
    Who you are signed in as
    #>
    Invoke-DbxCli @('current-user', 'me') | Select-Object userName, displayName, active
}

# ==== Catalogs, schemas, tables, volumes ===================================================

function Get-DbxCatalogs {
    <#
    .SYNOPSIS
    Catalogs you can see
    #>
    Invoke-DbxCli @('catalogs', 'list') | Select-Object name, catalog_type, owner
}

function Get-DbxSchemas {
    <#
    .SYNOPSIS
    Schemas in a catalog (default catalog if none given)
    #>
    param([string]$Catalog = $script:Cfg.Catalog)
    Write-DbxDefaults $PSBoundParameters 'Catalog'
    Invoke-DbxCli @('schemas', 'list', $Catalog) | Select-Object name, owner, created_by
}

function Get-DbxTables {
    <#
    .SYNOPSIS
    Tables in a schema; -Filter 'm*' narrows by name
    #>
    param([string]$Schema = $script:Cfg.Schema, [string]$Catalog = $script:Cfg.Catalog, [string]$Filter = '*')
    Write-DbxDefaults $PSBoundParameters 'Catalog', 'Schema'
    # Without the omit flags every column of every table comes back: 10x the JSON.
    Invoke-DbxCli @('tables', 'list', $Catalog, $Schema, '--omit-columns', '--omit-properties') |
        Where-Object name -like $Filter | Select-Object name, table_type, owner
}

function Get-DbxVolumes {
    <#
    .SYNOPSIS
    Volumes in a schema
    #>
    param([string]$Schema = $script:Cfg.Schema, [string]$Catalog = $script:Cfg.Catalog)
    Write-DbxDefaults $PSBoundParameters 'Catalog', 'Schema'
    Invoke-DbxCli @('volumes', 'list', $Catalog, $Schema) | Select-Object name, volume_type, owner
}

function Get-DbxColumns {
    <#
    .SYNOPSIS
    Columns of a table and their types: dbx-cols my_table
    #>
    param([Parameter(Mandatory)][string]$Table)
    $name = (Resolve-DbxTable $Table).Replace('`', '')
    (Invoke-DbxCli @('tables', 'get', $name)).columns | Select-Object name, type_name, nullable
}

function Open-DbxExplorer {
    <#
    .SYNOPSIS
    Open a table, schema or catalog in Catalog Explorer in your browser
    #>
    param([string]$Name)
    $host_ = (Invoke-DbxCli @('auth', 'profiles') -NoProfile).profiles |
        Where-Object name -eq $script:Cfg.Profile | Select-Object -ExpandProperty host
    $path = if ($Name) { (Resolve-DbxTable $Name).Replace('`', '').Replace('.', '/') }
            else { "$($script:Cfg.Catalog)/$($script:Cfg.Schema)" }
    $url = "$($host_.TrimEnd('/'))/explore/data/$path"
    Start-Process $url
    $url
}

function New-DbxSchema {
    <#
    .SYNOPSIS
    Create a schema (asks first): dbx-mkschema my_schema [-Comment 'what it holds']
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [string]$Catalog = $script:Cfg.Catalog, [string]$Comment)
    Write-DbxDefaults $PSBoundParameters 'Catalog'
    if (Confirm-Dbx $PSCmdlet "$Catalog.$Name" 'Create schema') {
        $cli = @('schemas', 'create', $Name, $Catalog)
        if ($Comment) { $cli += @('--comment', $Comment) }
        Invoke-DbxCli $cli | Select-Object full_name, owner, comment
    }
}

function Remove-DbxSchema {
    <#
    .SYNOPSIS
    Delete a schema and everything in it (shows what's inside, asks first): dbx-rmschema my_schema
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [string]$Catalog = $script:Cfg.Catalog)
    Write-DbxDefaults $PSBoundParameters 'Catalog'
    $full = "$Catalog.$Name"
    $tables = @(Invoke-DbxCli @('tables', 'list', $Catalog, $Name, '--omit-columns', '--omit-properties'))
    $volumes = @(Invoke-DbxCli @('volumes', 'list', $Catalog, $Name))
    $what = "$full ($($tables.Count) tables, $($volumes.Count) volumes: all deleted, files in volumes too)"
    if ($Name -eq $script:Cfg.Schema -and $Catalog -eq $script:Cfg.Catalog) {
        Write-Warning "$full is your default schema (dbx-settings); change it afterwards with dbx-config -Schema"
    }
    if (Confirm-Dbx $PSCmdlet $what 'Delete schema') {
        Invoke-DbxCli @('schemas', 'delete', $full, '--force') | Out-Null
        if ($LASTEXITCODE -eq 0) { "deleted $full" }
    }
}

function New-DbxVolume {
    <#
    .SYNOPSIS
    Create a managed volume (asks first): dbx-mkvolume my_volume [-Comment 'what it holds']
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name, [string]$Schema = $script:Cfg.Schema, [string]$Catalog = $script:Cfg.Catalog, [string]$Comment)
    Write-DbxDefaults $PSBoundParameters 'Catalog', 'Schema'
    if (Confirm-Dbx $PSCmdlet "$Catalog.$Schema.$Name" 'Create managed volume') {
        $cli = @('volumes', 'create', $Catalog, $Schema, $Name, 'MANAGED')
        if ($Comment) { $cli += @('--comment', $Comment) }
        Invoke-DbxCli $cli | Select-Object full_name, storage_location, comment
    }
}

# ==== Explore data (SQL, read-only) ========================================================

function Find-DbxTable {
    <#
    .SYNOPSIS
    Find tables, or with -Columns columns, whose name contains some text
    #>
    param([Parameter(Mandatory)][string]$Text, [switch]$Columns, [string]$Catalog = $script:Cfg.Catalog)
    Write-DbxDefaults $PSBoundParameters 'Catalog'
    $like = "'%" + $Text.Replace("'", "''") + "%'"
    $is = '`' + $Catalog + '`.information_schema'
    if ($Columns) {
        Invoke-DbxStatement "SELECT table_schema, table_name, column_name, data_type FROM $is.columns WHERE column_name ILIKE $like ORDER BY ALL LIMIT 500"
    }
    else {
        Invoke-DbxStatement "SELECT table_schema, table_name, table_type FROM $is.tables WHERE table_name ILIKE $like ORDER BY ALL LIMIT 500"
    }
}

function Get-DbxCount {
    <#
    .SYNOPSIS
    Row count of a table; -By col1,col2 groups; -Where filters
    #>
    param([Parameter(Mandatory)][string]$Table, [string[]]$By, [string]$Where)
    $sql = 'SELECT '
    if ($By) { $sql += ($By -join ', ') + ', ' }
    $sql += "count(*) AS rows FROM $(Resolve-DbxTable $Table)"
    if ($Where) { $sql += " WHERE $Where" }
    if ($By) { $sql += ' GROUP BY ALL ORDER BY ALL' }
    Invoke-DbxStatement $sql
}

function Get-DbxHead {
    <#
    .SYNOPSIS
    First rows of a table: dbx-head my_table 20
    #>
    param([Parameter(Mandatory)][string]$Table, [int]$Rows = 10, [string]$Where)
    $sql = "SELECT * FROM $(Resolve-DbxTable $Table)"
    if ($Where) { $sql += " WHERE $Where" }
    Invoke-DbxStatement "$sql LIMIT $Rows"
}

function Get-DbxTableDetail {
    <#
    .SYNOPSIS
    Size, file count, format and last change of a table
    #>
    param([Parameter(Mandatory)][string]$Table)
    Invoke-DbxStatement "DESCRIBE DETAIL $(Resolve-DbxTable $Table)" | ForEach-Object {
        [pscustomobject]@{
            name         = $_.name
            format       = $_.format
            files        = [int64]$_.numFiles
            size_mb      = [math]::Round([int64]$_.sizeInBytes / 1MB, 1)
            lastModified = $_.lastModified
            location     = $_.location
        }
    }
}

function Get-DbxHistory {
    <#
    .SYNOPSIS
    Recent changes to a Delta table (who, when, what)
    #>
    param([Parameter(Mandatory)][string]$Table, [int]$Rows = 10)
    Invoke-DbxStatement "DESCRIBE HISTORY $(Resolve-DbxTable $Table) LIMIT $Rows" |
        Select-Object version, timestamp, userName, operation
}

function Get-DbxGrants {
    <#
    .SYNOPSIS
    Who has which permission on a table, schema, catalog or volume
    #>
    param([Parameter(Mandatory)][string]$Name, [ValidateSet('TABLE', 'SCHEMA', 'CATALOG', 'VOLUME')][string]$On = 'TABLE')
    $target = switch ($On) {
        'TABLE' { Resolve-DbxTable $Name }
        'VOLUME' { Resolve-DbxTable $Name }
        default { ($Name.Replace('`', '') -split '\.' | ForEach-Object { '`' + $_ + '`' }) -join '.' }
    }
    $rows = @(Invoke-DbxStatement "SHOW GRANTS ON $On $target")
    if ($rows) { $rows } else { "No grants on $target besides its owner's (see dbx-tables / dbx-schemas for the owner)" }
}

# ==== SQL ==================================================================================

function Invoke-DbxSql {
    <#
    .SYNOPSIS
    Run SQL, rows back as objects; asks first unless it only reads. -Table, -Csv file, -Clip
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Sql, [string]$Csv, [switch]$Clip, [switch]$Table, [string]$Warehouse)
    if (-not (Test-DbxReadOnlySql $Sql)) {
        if (-not (Confirm-Dbx $PSCmdlet $Sql 'Run SQL that may change data')) { return }
    }
    $rows = @(Invoke-DbxStatement $Sql $Warehouse)
    if ($Csv) {
        $rows | Export-Csv $Csv -NoTypeInformation
        "$($rows.Count) rows saved to $Csv"
    }
    elseif ($Clip) {
        $rows | ConvertTo-Csv -NoTypeInformation -Delimiter "`t" | Set-Clipboard
        "$($rows.Count) rows copied; paste into Excel"
    }
    # Display only: PowerShell lists objects with 5+ columns one field per line, not as a table.
    elseif ($Table) { $rows | Format-Table -AutoSize -Wrap }
    else { $rows }
}

function Invoke-DbxSqlFile {
    <#
    .SYNOPSIS
    Run a .sql file; statements end with ; at the end of a line
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Path, [string]$Warehouse)
    $text = Get-Content $Path -Raw
    $statements = @($text -split ';\s*(?:\r?\n|$)' | Where-Object { $_.Trim() })
    $changes = @($statements | Where-Object { -not (Test-DbxReadOnlySql $_) })
    if ($changes -and -not (Confirm-Dbx $PSCmdlet "$Path ($($changes.Count) of $($statements.Count) statements change data)" 'Run SQL file')) { return }
    foreach ($s in $statements) {
        Write-Host "-- $(($s.Trim() -split "`n")[0])" -ForegroundColor DarkGray
        Invoke-DbxStatement $s $Warehouse
    }
}

function Get-DbxQueries {
    <#
    .SYNOPSIS
    Your recent SQL queries: status, time taken, rows, start of the text
    #>
    param([int]$Rows = 20)
    $r = Invoke-DbxCli @('query-history', 'list', '--max-results', "$Rows")
    if (-not $r) { return }
    $r.res | ForEach-Object {
        $q = $_
        [pscustomobject]@{
            started = ConvertFrom-DbxMs $q.query_start_time_ms
            status  = $q.status
            seconds = if ($q.PSObject.Properties.Name -contains 'duration') { [math]::Round($q.duration / 1000, 1) } else { $null }
            rows    = if ($q.PSObject.Properties.Name -contains 'rows_produced') { $q.rows_produced } else { $null }
            user    = $q.user_name
            query   = ($q.query_text -replace '\s+', ' ').Substring(0, [math]::Min(80, ($q.query_text -replace '\s+', ' ').Length))
        }
    }
}

# ==== Files in volumes =====================================================================

function Get-DbxFiles {
    <#
    .SYNOPSIS
    List files: dbx-ls (default volume), dbx-ls folder/sub, dbx-ls /Volumes/...
    #>
    param([string]$Path)
    Invoke-DbxCli @('fs', 'ls', (Resolve-DbxPath $Path)) | ForEach-Object {
        [pscustomobject]@{
            name     = $_.name
            folder   = $_.is_directory
            size_mb  = if ($_.is_directory) { $null } else { [math]::Round($_.size / 1MB, 2) }
            modified = if ($_.is_directory) { $null } else { $_.last_modified }
        }
    }
}

function Get-DbxFolderSize {
    <#
    .SYNOPSIS
    Total size and file count of a folder, including subfolders
    #>
    param([string]$Path)
    $target = Resolve-DbxPath $Path
    $files = 0; $bytes = 0
    $todo = New-Object System.Collections.Queue
    $todo.Enqueue($target)
    while ($todo.Count) {
        $dir = $todo.Dequeue()
        foreach ($e in @(Invoke-DbxCli @('fs', 'ls', $dir))) {
            if ($e.is_directory) { $todo.Enqueue("$dir/$($e.name)") }
            else { $files++; $bytes += [int64]$e.size }
        }
    }
    [pscustomobject]@{ path = $target; files = $files; size_mb = [math]::Round($bytes / 1MB, 1) }
}

function Get-DbxFile {
    <#
    .SYNOPSIS
    Download a file or (-Recurse) a folder to your PC
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$To = '.', [switch]$Recurse)
    $cli = @('fs', 'cp', (Resolve-DbxPath $Path), $To)
    if ($Recurse) { $cli += '--recursive' }
    & databricks @cli -p $script:Cfg.Profile
}

function Send-DbxFile {
    <#
    .SYNOPSIS
    Upload a file or (-Recurse) a folder to a volume (asks first)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$LocalPath, [string]$To, [switch]$Recurse, [switch]$Overwrite)
    $target = Resolve-DbxPath $To
    if (Confirm-Dbx $PSCmdlet $target "Upload $LocalPath") {
        $cli = @('fs', 'cp', $LocalPath, $target)
        if ($Recurse) { $cli += '--recursive' }
        if ($Overwrite) { $cli += '--overwrite' }
        & databricks @cli -p $script:Cfg.Profile
    }
}

function New-DbxFolder {
    <#
    .SYNOPSIS
    Create a folder in a volume (asks first)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Path)
    $target = Resolve-DbxPath $Path
    if (Confirm-Dbx $PSCmdlet $target 'Create folder') { & databricks fs mkdir $target -p $script:Cfg.Profile }
}

function Remove-DbxFile {
    <#
    .SYNOPSIS
    Delete a file, or a folder with -Recurse (asks first; can't be undone)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse)
    $target = Resolve-DbxPath $Path
    $what = if ($Recurse) { 'Delete folder and everything in it' } else { 'Delete' }
    if (Confirm-Dbx $PSCmdlet $target $what) {
        $cli = @('fs', 'rm', $target)
        if ($Recurse) { $cli += '--recursive' }
        & databricks @cli -p $script:Cfg.Profile
    }
}

# ==== Warehouses and jobs ==================================================================

function Get-DbxWarehouses {
    <#
    .SYNOPSIS
    SQL warehouses: name, ID, state, size
    #>
    Invoke-DbxCli @('warehouses', 'list') | Select-Object name, id, state, cluster_size
}

function Start-DbxWarehouse {
    <#
    .SYNOPSIS
    Start a SQL warehouse (asks first; it costs while running)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Id)
    $Id = Get-DbxWarehouseId $Id
    if (Confirm-Dbx $PSCmdlet $Id 'Start SQL warehouse') {
        & databricks warehouses start $Id --no-wait -p $script:Cfg.Profile
        'Starting; check with dbx-warehouses'
    }
}

function Stop-DbxWarehouse {
    <#
    .SYNOPSIS
    Stop a SQL warehouse (asks first; stops it for everyone using it)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Id)
    $Id = Get-DbxWarehouseId $Id
    if (Confirm-Dbx $PSCmdlet $Id 'Stop SQL warehouse') {
        & databricks warehouses stop $Id --no-wait -p $script:Cfg.Profile
        'Stopping; check with dbx-warehouses'
    }
}

function Get-DbxJobs {
    <#
    .SYNOPSIS
    Jobs you can see; -Name filters (exact name, any case)
    #>
    param([string]$Name)
    $cli = @('jobs', 'list')
    if ($Name) { $cli += @('--name', $Name) }
    Invoke-DbxCli $cli | ForEach-Object {
        [pscustomobject]@{ job_id = $_.job_id; name = $_.settings.name; creator = $_.creator_user_name }
    }
}

function Get-DbxRuns {
    <#
    .SYNOPSIS
    Recent job runs and how they ended; -JobId for one job
    #>
    param([int64]$JobId, [int]$Rows = 10)
    $cli = @('jobs', 'list-runs', '--limit', "$Rows")
    if ($JobId) { $cli += @('--job-id', "$JobId") }
    Invoke-DbxCli $cli | ForEach-Object {
        $state = $_.state
        [pscustomobject]@{
            run_id  = $_.run_id
            name    = $_.run_name
            started = ConvertFrom-DbxMs $_.start_time
            minutes = if ($_.PSObject.Properties.Name -contains 'run_duration') { [math]::Round($_.run_duration / 60000, 1) } else { $null }
            state   = $state.life_cycle_state
            result  = if ($state.PSObject.Properties.Name -contains 'result_state') { $state.result_state } else { $null }
            url     = $_.run_page_url
        }
    }
}

function Start-DbxJob {
    <#
    .SYNOPSIS
    Run a job now (asks first)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][int64]$JobId)
    if (Confirm-Dbx $PSCmdlet "job $JobId" 'Run now') {
        Invoke-DbxCli @('jobs', 'run-now', "$JobId", '--no-wait') | Select-Object run_id, number_in_job
        'Started; follow it with: dbx-runs -JobId ' + $JobId
    }
}

# ==== Help and short names =================================================================

$script:Aliases = [ordered]@{
    'dbx' = 'Invoke-Dbx'; 'dbx-config' = 'Set-DbxConfig'; 'dbx-settings' = 'Get-DbxConfig'
    'dbx-use' = 'Set-DbxDefault'; 'dbx-profiles' = 'Get-DbxProfiles'; 'dbx-me' = 'Get-DbxMe'
    'dbx-catalogs' = 'Get-DbxCatalogs'; 'dbx-schemas' = 'Get-DbxSchemas'; 'dbx-tables' = 'Get-DbxTables'
    'dbx-volumes' = 'Get-DbxVolumes'; 'dbx-cols' = 'Get-DbxColumns'; 'dbx-open' = 'Open-DbxExplorer'
    'dbx-mkschema' = 'New-DbxSchema'; 'dbx-mkvolume' = 'New-DbxVolume'; 'dbx-rmschema' = 'Remove-DbxSchema'
    'dbx-find' = 'Find-DbxTable'; 'dbx-count' = 'Get-DbxCount'; 'dbx-head' = 'Get-DbxHead'
    'dbx-detail' = 'Get-DbxTableDetail'; 'dbx-history' = 'Get-DbxHistory'; 'dbx-grants' = 'Get-DbxGrants'
    'dbx-sql' = 'Invoke-DbxSql'; 'dbx-sqlfile' = 'Invoke-DbxSqlFile'; 'dbx-queries' = 'Get-DbxQueries'
    'dbx-ls' = 'Get-DbxFiles'; 'dbx-du' = 'Get-DbxFolderSize'; 'dbx-get' = 'Get-DbxFile'
    'dbx-put' = 'Send-DbxFile'; 'dbx-mkdir' = 'New-DbxFolder'; 'dbx-rm' = 'Remove-DbxFile'
    'dbx-warehouses' = 'Get-DbxWarehouses'; 'dbx-wh-start' = 'Start-DbxWarehouse'; 'dbx-wh-stop' = 'Stop-DbxWarehouse'
    'dbx-jobs' = 'Get-DbxJobs'; 'dbx-runs' = 'Get-DbxRuns'; 'dbx-run' = 'Start-DbxJob'
}

function Show-DbxHelp {
    <#
    .SYNOPSIS
    This list. Get-Help <command> -Full shows the details of one
    #>
    foreach ($alias in $script:Aliases.Keys) {
        $cmd = Get-Command $script:Aliases[$alias]
        $asks = $cmd.Parameters.ContainsKey('WhatIf')
        [pscustomobject]@{
            command = $alias
            asks    = if ($asks) { 'yes' } else { '' }
            does    = (Get-Help $script:Aliases[$alias]).Synopsis
        }
    }
    [pscustomobject]@{ command = 'dbx-help'; asks = ''; does = 'This list' }
}

foreach ($alias in $script:Aliases.Keys) { Set-Alias $alias $script:Aliases[$alias] }
Set-Alias dbx-help Show-DbxHelp
Export-ModuleMember -Function @($script:Aliases.Values + 'Show-DbxHelp') -Alias @($script:Aliases.Keys + 'dbx-help')
