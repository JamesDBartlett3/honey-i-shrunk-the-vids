@{
    # Module metadata
    RootModule = 'VideoCompressionModule.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a7f8d3e2-5c91-4b6a-9f2e-1d4c8b7a3e6f'
    Author = 'SharePoint Video Compression Team'
    CompanyName = ''
    Copyright = '(c) 2026. All rights reserved.'
    Description = 'Cross-platform PowerShell module for automating SharePoint video compression and archival with SQLite catalog tracking, hash verification, integrity checks, and illegal character handling.'

    # Minimum PowerShell version (7.0+ for cross-platform compatibility)
    PowerShellVersion = '7.0'

    # Required modules
    RequiredModules = @(
        @{ ModuleName = 'PnP.PowerShell'; ModuleVersion = '1.0' },
        @{ ModuleName = 'PSSQLite'; ModuleVersion = '1.0' }
    )

    # Functions to export
    FunctionsToExport = @(
        'Initialize-SPVidCompConfig',
        'Connect-SPVidCompSharePoint',
        'Disconnect-SPVidCompSharePoint',
        'Initialize-SPVidCompCatalog',
        'Add-SPVidCompVideo',
        'Get-SPVidCompVideos',
        'Update-SPVidCompStatus',
        'Get-SPVidCompFiles',
        'Receive-SPVidCompVideo',
        'Copy-SPVidCompArchive',
        'Test-SPVidCompArchiveIntegrity',
        'Invoke-SPVidCompCompression',
        'Test-SPVidCompVideoIntegrity',
        'Test-SPVidCompVideoLength',
        'Send-SPVidCompVideo',
        'Write-SPVidCompLog',
        'Send-SPVidCompNotification',
        'Test-SPVidCompDiskSpace',
        'Get-SPVidCompStatistics',
        'Get-SPVidCompPlatformDefaults',
        'Get-SPVidCompIllegalCharacters',
        'Test-SPVidCompFilenameCharacters',
        'Repair-SPVidCompFilename',
        'Test-SPVidCompConfigExists',
        'Get-SPVidCompConfig',
        'Set-SPVidCompConfig',
        'Test-SPVidCompFFmpegAvailability',
        'Install-SPVidCompFFmpeg'
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
