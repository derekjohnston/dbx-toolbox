BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:ReferencePath = Join-Path $script:RepoRoot 'docs/commands.md'
}

Describe 'Command reference' -Tag Unit {
    It 'matches the generated reference byte for byte' {
        $generated = Join-Path $TestDrive 'commands.md'
        & (Join-Path $script:RepoRoot 'scripts/Build-Docs.ps1') -OutputPath $generated
        $actual = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($generated))
        $expected = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:ReferencePath))
        $actual | Should -BeExactly $expected -Because 'run scripts/Build-Docs.ps1 when the reference is stale'
    }

    It 'documents every exported alias' {
        $module = Import-Module (Join-Path $script:RepoRoot 'DbxToolbox/DbxToolbox.psd1') -Force -PassThru
        $reference = [System.IO.File]::ReadAllText($script:ReferencePath)
        foreach ($name in $module.ExportedAliases.Keys) {
            $reference | Should -Match ([regex]::Escape(('| `{0}` |' -f $name)))
        }
    }
}
