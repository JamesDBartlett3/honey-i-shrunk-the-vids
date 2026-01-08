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
        'Initialize-SPVidComp-Config',
        'Connect-SPVidComp-SharePoint',
        'Disconnect-SPVidComp-SharePoint',
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
        'Get-SPVidComp-Statistics',
        'Get-SPVidComp-PlatformDefaults',
        'Get-SPVidComp-IllegalCharacters',
        'Test-SPVidComp-FilenameCharacters',
        'Repair-SPVidComp-Filename',
        'Test-SPVidComp-ConfigExists',
        'Get-SPVidComp-Config',
        'Set-SPVidComp-Config',
        'Test-SPVidComp-FFmpegAvailability',
        'Install-SPVidComp-FFmpeg'
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
