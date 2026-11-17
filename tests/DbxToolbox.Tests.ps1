# Unit tests: a fake `databricks` function stands in for the CLI, so nothing reaches
# Databricks. Run non-interactively (pwsh -NonInteractive), as CI does: some tests check that
# a change is never made when the "Are you sure?" question can't be asked.

Describe 'DbxToolbox' -Tag Unit {
    BeforeAll {
        Import-Module "$PSScriptRoot/../DbxToolbox/DbxToolbox.psd1" -Force

        # Functions win over programs, so the module calls this instead of the real CLI.
        # It records each call as one string and answers with canned JSON.
        function global:databricks {
            $global:DbxCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = 0
            $verb = "$($args[0]) $($args[1])"
            switch ($verb) {
                'auth profiles' { '{"profiles":[{"name":"work","host":"https://h","valid":true,"default":true}]}' }
                'tables list' { '[{"name":"my_table","table_type":"MANAGED","owner":"me"},{"name":"other","table_type":"MANAGED","owner":"me"}]' }
                'warehouses list' { '[{"name":"wh","id":"wh1","state":"RUNNING","cluster_size":"2X-Small"}]' }
                'api post' { '{"statement_id":"s1","status":{"state":"SUCCEEDED"},"manifest":{"schema":{"columns":[{"name":"n"}]}},"result":{"data_array":[["42"]]}}' }
                'bundle validate' {
                    if ($global:DbxBundleInvalid) { $global:LASTEXITCODE = 1; return }
                    if ($args -contains 'json') {
                        '{"bundle":{"name":"proj","target":"shared","mode":"production"},"workspace":{"root_path":"/Workspace/Shared/.bundle/proj"},"run_as":{"service_principal_name":"sp-1"},"resources":{"jobs":{"ingest":{"name":"ingest"}},"apps":{"web":{"name":"proj-web"}}}}'
                    } else { 'Validation OK!' }
                }
                'secrets list-scopes' { '[{"name":"team","backend_type":"DATABRICKS"}]' }
                'secrets list-secrets' { '[{"key":"api-token","last_updated_timestamp":1763380800000}]' }
                'secrets list-acls' { '[{"principal":"users","permission":"READ"}]' }
                'bundle summary' { '{"bundle":{"name":"proj","target":"dev"},"workspace":{"root_path":"/Workspace/Users/me/.bundle/proj/dev"},"resources":{"jobs":{"ingest":{"name":"[dev me] ingest","url":"https://h/jobs/1"}}}}' }
                default { '[]' }
            }
        }

    }

    AfterAll {
        Remove-Item function:global:databricks -ErrorAction SilentlyContinue
        Remove-Module DbxToolbox -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:DbxCalls = [System.Collections.Generic.List[string]]::new()
        # Settings in a temporary file, never the real ~/.dbx-toolbox.json.
        InModuleScope DbxToolbox -Parameters @{ Path = (Join-Path $TestDrive 'settings.json') } {
            param($Path)
            $script:ConfigPath = $Path
            $script:Cfg = [ordered]@{
                Profile = 'work'; Catalog = 'cat'; Schema = 'sch'; Warehouse = ''; Volume = 'vol'; VolumePath = ''
            }
        }
    }

    Context 'Names and paths' {
        It 'fills in the default catalog and schema for short table names' {
            InModuleScope DbxToolbox {
                Resolve-DbxTable 'my_table' 6>$null | Should -Be '`cat`.`sch`.`my_table`'
                Resolve-DbxTable 'other.t' 6>$null | Should -Be '`cat`.`other`.`t`'
                Resolve-DbxTable 'a.b.c' 6>$null | Should -Be '`a`.`b`.`c`'
            }
        }

        It 'asks for a volume when none is set, and calls nothing' {
            InModuleScope DbxToolbox { $script:Cfg.Volume = '' }
            { dbx-ls 6>$null } | Should -Throw '*dbx-config -Volume*'
            $global:DbxCalls | Where-Object { $_ -like 'fs ls*' } | Should -BeNullOrEmpty
        }
    }

    Context 'Read-only SQL' {
        It 'recognises reads after comments, and changes as changes' {
            InModuleScope DbxToolbox {
                Test-DbxReadOnlySql "/* x */ -- y`nselect 1" | Should -BeTrue
                Test-DbxReadOnlySql 'SHOW TABLES' | Should -BeTrue
                Test-DbxReadOnlySql 'DROP TABLE t' | Should -BeFalse
                Test-DbxReadOnlySql 'INSERT INTO t VALUES (1)' | Should -BeFalse
            }
        }

        It 'runs a SELECT without asking and returns rows' {
            (dbx-sql 'SELECT 42 AS n').n | Should -Be '42'
            $global:DbxCalls | Where-Object { $_ -like 'api post /api/2.0/sql/statements*' } | Should -Not -BeNullOrEmpty
        }

        It 'shows rows as a table with -Table' {
            $lines = @((dbx-sql 'SELECT 42 AS n' -Table | Out-String) -split "`r?`n" |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $lines[0..2] | Should -Be @('n', '-', '42')
        }
    }

    Context 'Changes ask first' {
        It 'never makes a change when the question cannot be asked' -Skip:(-not ([Environment]::GetCommandLineArgs() -contains '-NonInteractive')) {
            $warnings = @(
                dbx-sql 'DROP TABLE t' 3>&1 6>$null
                dbx-rm folder -Recurse 3>&1 6>$null
                dbx-mkschema x 3>&1 6>$null
                dbx-rmschema old_schema 3>&1 6>$null
                dbx-deploy -Target shared 3>&1 6>$null
                dbx-bundle-run ingest 3>&1 6>$null
                dbx-mkscope team 3>&1 6>$null
                dbx-secret-set team api-token 3>&1 6>$null
                dbx-secret-grant team users 3>&1 6>$null
            ) | Where-Object { "$_" -like 'Not done*' }
            $warnings.Count | Should -Be 9
            $global:DbxCalls | Where-Object { $_ -match '^(api post|fs rm|schemas create|schemas delete|bundle deploy|bundle run|secrets create-scope|secrets put-acl)' } |
                Should -BeNullOrEmpty
        }

        It 'changes nothing with -WhatIf' {
            dbx-rm folder -Recurse -WhatIf 6>$null
            $global:DbxCalls | Where-Object { $_ -like 'fs rm*' } | Should -BeNullOrEmpty
        }

        It 'makes the change with -Confirm:$false, using the profile' {
            dbx-rm folder -Recurse -Confirm:$false 6>$null
            $call = $global:DbxCalls | Where-Object { $_ -like 'fs rm*' }
            $call | Should -Match '^fs rm dbfs:/Volumes/cat/sch/vol/folder --recursive'
            $call | Should -Match '-p work'
        }
    }

    Context 'Schemas' {
        It 'dbx-rmschema says what it would delete before asking' {
            Mock Confirm-Dbx -ModuleName DbxToolbox { $global:DbxAsked = $Target; $false }
            dbx-rmschema old_schema 6>$null
            $global:DbxAsked | Should -BeLike 'cat.old_schema (2 tables, 0 volumes*'
            $global:DbxCalls | Where-Object { $_ -like 'schemas delete*' } | Should -BeNullOrEmpty
        }

        It 'dbx-rmschema deletes with --force when confirmed' {
            $out = dbx-rmschema old_schema -Confirm:$false 6>$null
            $global:DbxCalls | Where-Object { $_ -like 'schemas delete*' } | Should -Match '^schemas delete cat\.old_schema --force'
            $out | Should -Be 'deleted cat.old_schema'
        }

        It 'dbx-mkschema passes a comment' {
            dbx-mkschema new_schema -Comment 'holds x' -Confirm:$false 6>$null | Out-Null
            $global:DbxCalls | Where-Object { $_ -like 'schemas create*' } |
                Should -Match '^schemas create new_schema cat --comment holds x'
        }
    }

    Context 'Tables' {
        It 'lists tables without columns and filters by name' {
            (dbx-tables -Filter 'my*' 6>$null).name | Should -Be 'my_table'
            $global:DbxCalls | Should -Contain 'tables list cat sch --omit-columns --omit-properties -o json -p work'
        }
    }

    Context 'Settings' {
        It 'saves settings and reads them back' {
            dbx-config -Catalog other | Out-Null
            $saved = Get-Content (Join-Path $TestDrive 'settings.json') -Raw | ConvertFrom-Json
            $saved.Catalog | Should -Be 'other'
            $saved.Profile | Should -Be 'work'
            (dbx-settings)[0].Catalog | Should -Be 'other'
        }

        It 'still takes -Profile (an alias: $Profile is built into PowerShell)' {
            dbx-config -Profile other_profile | Out-Null
            (Get-Content (Join-Path $TestDrive 'settings.json') -Raw | ConvertFrom-Json).Profile | Should -Be 'other_profile'
            dbx-use -Profile third | Out-Null
            InModuleScope DbxToolbox { $script:Cfg.Profile } | Should -Be 'third'
        }

        It 'says when it uses saved defaults, and not when names are given' {
            (dbx-tables 6>&1 | Out-String) | Should -BeLike '*(using default catalog cat, schema sch)*'
            (dbx-tables -Catalog c2 -Schema s2 6>&1 | Out-String) | Should -Not -BeLike '*(using*'
            (dbx-tables -Catalog c2 6>&1 | Out-String) | Should -BeLike '*(using default schema sch)*'
        }
    }

    Context 'Bundles' {
        AfterEach { $global:DbxBundleInvalid = $false }

        It 'dbx-deploy says where it goes, who jobs run as and what it makes, before asking' {
            $plan = InModuleScope DbxToolbox { Format-DbxBundlePlan (Get-DbxBundleConfig 'shared' $null) }
            $plan | Should -BeLike '*proj to target shared (production)*'
            $plan | Should -BeLike '*folder:  /Workspace/Shared/.bundle/proj*'
            $plan | Should -BeLike '*jobs run as: service principal sp-1*'
            $plan | Should -BeLike '*job: ingest*'
            $plan | Should -BeLike '*app: proj-web*'
        }

        It 'dbx-deploy deploys with the target, settings and profile when confirmed' {
            dbx-deploy -Target shared -Var @{ catalog = 'c'; warehouse_id = 'w' } -Confirm:$false 6>$null
            $global:DbxCalls | Where-Object { $_ -like 'bundle deploy*' } |
                Should -Be 'bundle deploy -t shared --var catalog=c --var warehouse_id=w -p work'
        }

        It 'dbx-deploy changes nothing with -WhatIf, or when the bundle is invalid' {
            dbx-deploy -Target shared -WhatIf 6>$null
            $global:DbxBundleInvalid = $true
            dbx-deploy -Confirm:$false 6>$null
            $global:DbxCalls | Where-Object { $_ -like 'bundle deploy*' } | Should -BeNullOrEmpty
        }

        It 'dbx-bundle lists what a target holds, with links; default target when none given' {
            $rows = @(dbx-bundle 6>$null)
            $rows.Count | Should -Be 1
            $rows[0].type | Should -Be 'job'
            $rows[0].key | Should -Be 'ingest'
            $rows[0].url | Should -Be 'https://h/jobs/1'
            $global:DbxCalls | Should -Contain 'bundle summary -o json -p work'
        }

        It 'dbx-bundle-check validates without changing anything' {
            dbx-bundle-check -Target shared | Should -Be 'Validation OK!'
            $global:DbxCalls | Should -Be @('bundle validate -t shared -p work')
        }

        It 'dbx-bundle-run runs one resource of the target when confirmed' {
            dbx-bundle-run ingest -Target shared -Confirm:$false 6>$null
            $global:DbxCalls | Should -Contain 'bundle run ingest -t shared -p work'
        }
    }

    Context 'Secrets' {
        It 'lists scopes, key names and access, never values' {
            (dbx-secret-scopes).scope | Should -Be 'team'
            $secret = dbx-secrets team
            $secret.key | Should -Be 'api-token'
            $secret.PSObject.Properties.Name | Should -Not -Contain 'value'
            (dbx-secret-access team).permission | Should -Be 'READ'
            $global:DbxCalls | Should -Contain 'secrets list-secrets team -o json -p work'
        }

        It 'sends the value on standard input, never on the command line' {
            Mock -ModuleName DbxToolbox Invoke-DbxCliStdin { 0 }
            $value = ConvertTo-SecureString 's3cr3t' -AsPlainText -Force
            dbx-secret-set team api-token -Value $value -Confirm:$false | Should -BeLike 'Set team/api-token*'
            Should -Invoke -ModuleName DbxToolbox Invoke-DbxCliStdin -Times 1 -ParameterFilter {
                ($CliArgs -join ' ') -eq 'secrets put-secret team api-token -p work' -and $InputText -eq 's3cr3t'
            }
            $global:DbxCalls | Where-Object { $_ -like '*s3cr3t*' } | Should -BeNullOrEmpty
        }

        It 'creates a scope and grants access only after asking' {
            dbx-mkscope team -ManagePrincipal users -Confirm:$false | Out-Null
            dbx-secret-grant team sp-1 -Permission READ -Confirm:$false | Out-Null
            $global:DbxCalls | Should -Contain 'secrets create-scope team --initial-manage-principal users -o json -p work'
            $global:DbxCalls | Should -Contain 'secrets put-acl team sp-1 READ -o json -p work'
        }
    }
}
