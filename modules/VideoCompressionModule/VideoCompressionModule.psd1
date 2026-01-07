@{
    # Module metadata
    RootModule = 'VideoCompressionModule.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a7f8d3e2-5c91-4b6a-9f2e-1d4c8b7a3e6f'
    Author = 'SharePoint Video Compression Team'
    CompanyName = ''
    Copyright = '(c) 2026. All rights reserved.'
    Description = 'PowerShell module for automating SharePoint video compression and archival with SQLite catalog tracking, hash verification, and integrity checks.'

    # Minimum PowerShell version
    PowerShellVersion = '5.1'

    # Required modules
    RequiredModules = @(
        @{ ModuleName = 'PnP.PowerShell'; ModuleVersion = '1.0' },
        @{ ModuleName = 'PSSQLite'; ModuleVersion = '1.0' }
    )

    # Functions to export
    FunctionsToExport = @(
        'Initialize-SPVidComp-Config',
        'Connect-SPVidComp-SharePoint',
        'Initialize-SPVidComp-Catalog',
        'Add-SPVidComp-Video',
        'Get-SPVidComp-Videos',
        'Update-SPVidComp-Status',
        'Get-SPVidComp-Files',
        'Download-SPVidComp-Video',
        'Copy-SPVidComp-Archive',
        'Test-SPVidComp-ArchiveIntegrity',
        'Invoke-SPVidComp-Compression',
        'Test-SPVidComp-VideoIntegrity',
        'Test-SPVidComp-VideoLength',
        'Upload-SPVidComp-Video',
        'Write-SPVidComp-Log',
        'Send-SPVidComp-Notification',
        'Test-SPVidComp-DiskSpace',
        'Get-SPVidComp-Statistics'
    )

    # Cmdlets to export
    CmdletsToExport = @()

    # Variables to export
    VariablesToExport = @()

    # Aliases to export
    AliasesToExport = @()

    # Private data
    PrivateData = @{
        PSData = @{
            Tags = @('SharePoint', 'Video', 'Compression', 'Automation', 'FFmpeg', 'Archive', 'SQLite')
            LicenseUri = ''
            ProjectUri = ''
            IconUri = ''
            ReleaseNotes = 'Initial release with full catalog, compression, and archival functionality'
        }
    }

    # Help Info URI
    HelpInfoURI = ''

    # Default prefix for commands
    DefaultCommandPrefix = ''
}
