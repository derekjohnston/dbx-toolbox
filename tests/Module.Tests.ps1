BeforeAll {
    $script:ManifestPath = "$PSScriptRoot/../DbxToolbox/DbxToolbox.psd1"
}

Describe 'Module' -Tag Unit {
    It 'has a valid manifest' {
        { Test-ModuleManifest $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports every command the manifest lists' {
        $manifest = Import-PowerShellDataFile $script:ManifestPath
        $module = Import-Module $script:ManifestPath -Force -PassThru
        @($module.ExportedAliases.Keys | Sort-Object) | Should -Be @($manifest.AliasesToExport | Sort-Object)
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be @($manifest.FunctionsToExport | Sort-Object)
    }
}
