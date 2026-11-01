# Lint settings, used by CI and AGENTS.md. Each exclusion is a deliberate choice:
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Command names follow what they return: Get-DbxTables lists tables.
        'PSUseSingularNouns'
        # The grey "(using default ...)" notes are on screen only, never in returned objects.
        'PSAvoidUsingWriteHost'
    )
}
