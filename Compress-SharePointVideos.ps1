#------------------------------------------------------------------------------------------------------------------
# Compress-SharePointVideos.ps1
# Main orchestration script for SharePoint video compression and archival
# Two-Phase Approach: 1) Catalog Discovery, 2) Processing
#------------------------------------------------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatabasePath = "$PSScriptRoot\data\video-catalog.db",

    [Parameter(Mandatory = $false)]
    [ValidateSet('Catalog', 'Process', 'Both')]
    [string]$Phase = 'Both',

    [Parameter(Mandatory = $false)]
    [switch]$Setup,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Register cleanup on Ctrl+C
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-Host "`n`nCleaning up background jobs..." -ForegroundColor Yellow
    Get-Job | Stop-Job -PassThru | Remove-Job -Force
    Write-Host "Cleanup complete. Exiting." -ForegroundColor Green
}

#------------------------------------------------------------------------------------------------------------------
# Import Module
#------------------------------------------------------------------------------------------------------------------
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\VideoCompressionModule\VideoCompressionModule.psm1'
Import-Module $modulePath -Force

#------------------------------------------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------------------------------------------
function Show-SPVidCompHeader {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Read-SPVidCompUserInput {
    param(
        [string]$Prompt,
        [string]$DefaultValue = '',
        [switch]$Required
    )

    $promptText = if ($DefaultValue) { "$Prompt [$DefaultValue]" } else { $Prompt }
    $promptText += ": "

    do {
        $userInput = Read-Host -Prompt $promptText
        if ([string]::IsNullOrWhiteSpace($userInput) -and $DefaultValue) {
            return $DefaultValue
        }
        if ($Required -and [string]::IsNullOrWhiteSpace($userInput)) {
            Write-Host "This field is required. Please enter a value." -ForegroundColor Red
        }
    } while ($Required -and [string]::IsNullOrWhiteSpace($userInput))

    return $userInput
}

function Read-SPVidCompYesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultValue = $true
    )

    $defaultText = if ($DefaultValue) { "Y/n" } else { "y/N" }
    $response = Read-Host -Prompt "$Prompt [$defaultText]"

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $DefaultValue
    }

    return $response -match '^[Yy]'
}

function Get-SPVidCompConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = $null
    )

    if ($Script:Config.PSObject.Properties.Name -contains $Key) {
        $value = $Script:Config.$Key
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    if ($null -ne $DefaultValue) {
        return $DefaultValue
    }

    throw "Configuration key '$Key' not found and no default value provided"
}

function Test-SPVidCompFileIsLocked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    try {
        # Try to open the file with exclusive read/write access
        # If another process has it locked (like ffmpeg writing to it), this will fail
        $fileStream = [System.IO.File]::Open(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )

        # If we got here, file is NOT locked - close it immediately
        $fileStream.Close()
        $fileStream.Dispose()
        return $false  # File is NOT locked (ready to use)
    }
    catch {
        # File is locked by another process
        return $true  # File IS locked (still being written)
    }
}

function Show-SPVidCompCurrentConfig {
    param([hashtable]$Config)

    Show-SPVidCompHeader "CURRENT CONFIGURATION"

    Write-Host "SharePoint Settings:" -ForegroundColor Yellow
    $scopeMode = if ($Config.ContainsKey('scope_mode')) { $Config['scope_mode'] } else { 'Single' }
    Write-Host "  Scope Mode         : $scopeMode" -ForegroundColor White

    if ($scopeMode -eq 'Tenant' -and $Config.ContainsKey('admin_site_url')) {
        Write-Host "  Admin Center URL   : $($Config['admin_site_url'])" -ForegroundColor White
    }

    # Display configured scopes
    $scopes = Get-SPVidCompScopes -EnabledOnly
    Write-Host "`n  Configured Scopes  : $($scopes.Count)" -ForegroundColor White
    if ($scopes.Count -gt 0) {
        foreach ($scope in $scopes) {
            $stats = if ($scope.video_count -gt 0) {
                "($($scope.video_count) videos, $([math]::Round($scope.total_size / 1GB, 2)) GB)"
            } else {
                "(not yet scanned)"
            }
            Write-Host "    [$($scope.id)] $($scope.display_name) $stats" -ForegroundColor Gray
        }
    } else {
        Write-Host "    (No scopes configured - run -Setup)" -ForegroundColor Red
    }

    Write-Host "`nPaths:" -ForegroundColor Yellow
    Write-Host "  Temp Download      : $($Config['paths_temp_download'])" -ForegroundColor White
    Write-Host "  External Archive   : $($Config['paths_external_archive'])" -ForegroundColor White

    Write-Host "`nCompression:" -ForegroundColor Yellow
    Write-Host "  Frame Rate         : $($Config['compression_frame_rate'])" -ForegroundColor White
    Write-Host "  Video Codec        : $($Config['compression_video_codec'])" -ForegroundColor White
    Write-Host "  Timeout (minutes)  : $($Config['compression_timeout_minutes'])" -ForegroundColor White

    Write-Host "`nProcessing:" -ForegroundColor Yellow
    Write-Host "  Max Parallel Jobs  : $($Config['processing_max_parallel_jobs'])" -ForegroundColor White
    Write-Host "  Retry Attempts     : $($Config['processing_retry_attempts'])" -ForegroundColor White
    Write-Host "  Required Disk Space: $($Config['processing_required_disk_space_gb']) GB" -ForegroundColor White
    Write-Host "  Duration Tolerance : $($Config['processing_duration_tolerance_seconds']) seconds" -ForegroundColor White

    Write-Host "`nEmail Notifications:" -ForegroundColor Yellow
    Write-Host "  Enabled            : $($Config['email_enabled'])" -ForegroundColor White
    if ($Config['email_enabled'] -eq 'True') {
        Write-Host "  SMTP Server        : $($Config['email_smtp_server'])" -ForegroundColor White
        Write-Host "  From               : $($Config['email_from'])" -ForegroundColor White
        Write-Host "  To                 : $($Config['email_to'])" -ForegroundColor White
    }

    Write-Host "`nLogging:" -ForegroundColor Yellow
    Write-Host "  Log Level          : $($Config['logging_log_level'])" -ForegroundColor White
    Write-Host "  Console Output     : $($Config['logging_console_output'])" -ForegroundColor White

    Write-Host "`nIllegal Character Handling:" -ForegroundColor Yellow
    Write-Host "  Strategy           : $($Config['illegal_char_strategy'])" -ForegroundColor White
    if ($Config['illegal_char_strategy'] -eq 'Replace') {
        Write-Host "  Replacement Char   : '$($Config['illegal_char_replacement'])'" -ForegroundColor White
    }
    Write-Host ""
}

function Initialize-SPVidCompConfiguration {
    Show-SPVidCompHeader "INTERACTIVE SETUP"

    Write-Host "Welcome to the SharePoint Video Compression setup wizard." -ForegroundColor Green
    Write-Host "Please provide the following configuration details.`n" -ForegroundColor Green

    # Detect platform and get defaults
    $platformDefaults = Get-SPVidCompPlatformDefaults

    if ($IsWindows) {
        Write-Host "Detected Platform: Windows" -ForegroundColor Green
    }
    elseif ($IsMacOS) {
        Write-Host "Detected Platform: macOS" -ForegroundColor Green
    }
    elseif ($IsLinux) {
        Write-Host "Detected Platform: Linux" -ForegroundColor Green
    }

    $config = @{}

    # SharePoint Scope Configuration
    Write-Host "`n--- SharePoint Scope Configuration ---" -ForegroundColor Cyan
    Write-Host "Choose the scope of video discovery:" -ForegroundColor Yellow
    Write-Host "  [1] Single Library - One specific library" -ForegroundColor White
    Write-Host "  [2] Site-Wide - All libraries in one site" -ForegroundColor White
    Write-Host "  [3] Multiple Sites - Select from multiple sites" -ForegroundColor White
    Write-Host "  [4] Tenant-Wide - All sites in tenant (requires admin)" -ForegroundColor White

    $scopeChoice = Read-Host "`nYour choice [1-4]"

    $scopeMode = switch ($scopeChoice) {
        '1' { 'Single' }
        '2' { 'Site' }
        '3' { 'Multiple' }
        '4' { 'Tenant' }
        default { 'Single' }
    }

    Write-Host "Selected mode: $scopeMode" -ForegroundColor Green

    # If tenant mode, require admin URL
    $adminSiteUrl = $null
    if ($scopeMode -eq 'Tenant') {
        $adminSiteUrl = Read-SPVidCompUserInput -Prompt "SharePoint Admin Center URL (e.g., https://contoso-admin.sharepoint.com)" -Required
        $config['admin_site_url'] = $adminSiteUrl
    }
    else {
        $config['admin_site_url'] = ''
    }

    # Check for ConsoleGuiTools
    Write-Host "`nChecking for Microsoft.PowerShell.ConsoleGuiTools..." -ForegroundColor Yellow
    $hasConsoleGuiTools = Get-Module -ListAvailable -Name Microsoft.PowerShell.ConsoleGuiTools
    if (-not $hasConsoleGuiTools) {
        Write-Host "Installing Microsoft.PowerShell.ConsoleGuiTools..." -ForegroundColor Yellow
        Install-Module -Name Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module Microsoft.PowerShell.ConsoleGuiTools -ErrorAction Stop

    # Interactive scope selection
    Write-Host "`nStarting interactive scope selection..." -ForegroundColor Cyan
    Write-Host "  (Use arrow keys to navigate, Space to select, Enter to confirm)" -ForegroundColor Gray

    $scopes = Select-SPVidCompScopesInteractive -ScopeMode $scopeMode -AdminSiteUrl $adminSiteUrl

    if ($scopes.Count -eq 0) {
        throw "No scopes selected. Setup cannot proceed without at least one scope."
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Selected $($scopes.Count) scope(s):" -ForegroundColor Green
    foreach ($scope in $scopes) {
        Write-Host "  ✓ $($scope.DisplayName)" -ForegroundColor White
    }
    Write-Host "========================================`n" -ForegroundColor Green

    # Store scope mode in config
    $config['scope_mode'] = $scopeMode

    # Paths - Platform-aware defaults
    Write-Host "`n--- File Paths ---" -ForegroundColor Cyan
    $config['paths_temp_download'] = Read-SPVidCompUserInput -Prompt "Temp Download Path" -DefaultValue $platformDefaults['TempPath'] -Required
    $config['paths_external_archive'] = Read-SPVidCompUserInput -Prompt "External Archive Path (where originals will be stored)" -Required

    # Compression Settings
    Write-Host "`n--- Compression Settings ---" -ForegroundColor Cyan
    $config['compression_frame_rate'] = Read-SPVidCompUserInput -Prompt "Target Frame Rate" -DefaultValue "10"
    $config['compression_video_codec'] = Read-SPVidCompUserInput -Prompt "Video Codec (libx265, libx264, etc.)" -DefaultValue "libx265"
    $config['compression_timeout_minutes'] = Read-SPVidCompUserInput -Prompt "Compression Timeout (minutes)" -DefaultValue "60"

    # Processing Settings
    Write-Host "`n--- Processing Settings ---" -ForegroundColor Cyan

    # Calculate default parallel jobs (CPU cores - 1, minimum of 1)
    $cpuCores = [Environment]::ProcessorCount
    $defaultParallelJobs = [Math]::Max(1, $cpuCores - 1)
    Write-Host "Detected $cpuCores CPU cores" -ForegroundColor Gray

    $config['processing_max_parallel_jobs'] = Read-SPVidCompUserInput -Prompt "Max Parallel Processing Jobs (1-8)" -DefaultValue $defaultParallelJobs.ToString()
    $config['processing_retry_attempts'] = Read-SPVidCompUserInput -Prompt "Retry Attempts for Failed Videos" -DefaultValue "3"
    $config['processing_required_disk_space_gb'] = Read-SPVidCompUserInput -Prompt "Required Disk Space (GB)" -DefaultValue "50"
    $config['processing_duration_tolerance_seconds'] = Read-SPVidCompUserInput -Prompt "Duration Tolerance (seconds)" -DefaultValue "1"

    # Resume Settings
    Write-Host "`n--- Resume Settings ---" -ForegroundColor Cyan
    $config['resume_enable'] = (Read-SPVidCompYesNo -Prompt "Enable resume capability?" -DefaultValue $true).ToString()
    $config['resume_skip_processed'] = (Read-SPVidCompYesNo -Prompt "Skip already processed files?" -DefaultValue $true).ToString()
    $config['resume_reprocess_failed'] = (Read-SPVidCompYesNo -Prompt "Reprocess failed files?" -DefaultValue $true).ToString()

    # Email Settings
    Write-Host "`n--- Email Notifications ---" -ForegroundColor Cyan
    $emailEnabled = Read-SPVidCompYesNo -Prompt "Enable email notifications?" -DefaultValue $false
    $config['email_enabled'] = $emailEnabled.ToString()

    if ($emailEnabled) {
        $config['email_smtp_server'] = Read-SPVidCompUserInput -Prompt "SMTP Server (e.g., smtp.office365.com or smtp.gmail.com)" -Required
        $config['email_smtp_port'] = Read-SPVidCompUserInput -Prompt "SMTP Port" -DefaultValue "587"
        $config['email_use_ssl'] = (Read-SPVidCompYesNo -Prompt "Use SSL?" -DefaultValue $true).ToString()
        $config['email_from'] = Read-SPVidCompUserInput -Prompt "From Address" -Required
        $config['email_to'] = Read-SPVidCompUserInput -Prompt "To Addresses (comma-separated)" -Required
        $config['email_send_on_completion'] = (Read-SPVidCompYesNo -Prompt "Send email on completion?" -DefaultValue $true).ToString()
        $config['email_send_on_error'] = (Read-SPVidCompYesNo -Prompt "Send email on error?" -DefaultValue $true).ToString()
    }
    else {
        # Email disabled - set empty/default values
        $config['email_smtp_server'] = ''
        $config['email_smtp_port'] = '587'
        $config['email_use_ssl'] = 'True'
        $config['email_from'] = ''
        $config['email_to'] = ''
        $config['email_send_on_completion'] = 'False'
        $config['email_send_on_error'] = 'False'
    }

    # Logging Settings (database-based)
    Write-Host "`n--- Logging Settings ---" -ForegroundColor Cyan
    $config['logging_log_level'] = Read-SPVidCompUserInput -Prompt "Log Level (Debug, Info, Warning, Error)" -DefaultValue "Info"
    $config['logging_console_output'] = (Read-SPVidCompYesNo -Prompt "Enable console output?" -DefaultValue $false).ToString()
    $config['logging_retention_days'] = Read-SPVidCompUserInput -Prompt "Log Retention (days)" -DefaultValue "30"

    # Advanced Settings
    Write-Host "`n--- Advanced Settings ---" -ForegroundColor Cyan
    $config['advanced_cleanup_temp_files'] = (Read-SPVidCompYesNo -Prompt "Cleanup temp files after processing?" -DefaultValue $true).ToString()
    $config['advanced_verify_checksums'] = (Read-SPVidCompYesNo -Prompt "Verify checksums?" -DefaultValue $true).ToString()
    $config['advanced_dry_run'] = 'False'

    # Illegal Character Handling
    Write-Host "`n--- Illegal Character Handling ---" -ForegroundColor Cyan
    Write-Host "How should illegal filename characters be handled?" -ForegroundColor Yellow
    Write-Host "  [R] Replace - Replace illegal characters with a substitute (default)" -ForegroundColor White
    Write-Host "  [O] Omit - Remove illegal characters entirely" -ForegroundColor White
    Write-Host "  [E] Error - Stop processing and log error" -ForegroundColor White

    $strategyChoice = Read-Host -Prompt "`nYour choice [R/O/E]"

    switch ($strategyChoice.ToUpper()) {
        'O' { $config['illegal_char_strategy'] = 'Omit' }
        'E' { $config['illegal_char_strategy'] = 'Error' }
        default { $config['illegal_char_strategy'] = 'Replace' }
    }

    if ($config['illegal_char_strategy'] -eq 'Replace') {
        $config['illegal_char_replacement'] = Read-SPVidCompUserInput -Prompt "Replacement character" -DefaultValue "_"
    }
    else {
        $config['illegal_char_replacement'] = '_'
    }

    Write-Host "`nSelected strategy: $($config['illegal_char_strategy'])" -ForegroundColor Green
    if ($config['illegal_char_strategy'] -eq 'Replace') {
        Write-Host "Replacement character: '$($config['illegal_char_replacement'])'" -ForegroundColor Green
    }

    # Save configuration to database
    Write-Host "`n`nSaving configuration to database..." -ForegroundColor Yellow

    # Initialize database first (without loading config)
    $null = Initialize-SPVidCompCatalog -DatabasePath $DatabasePath

    # Save configuration
    $null = Set-SPVidCompConfig -ConfigValues $config

    # Save scopes to database
    Write-Host "Saving scope configuration..." -ForegroundColor Yellow
    foreach ($scope in $scopes) {
        $scopeId = Add-SPVidCompScope -SiteUrl $scope.SiteUrl `
            -LibraryName $scope.LibraryName `
            -ScopeMode $scopeMode `
            -DisplayName $scope.DisplayName `
            -FolderPath $scope.FolderPath `
            -Recursive $scope.Recursive
        Write-Host "  Saved: $($scope.DisplayName) (Scope ID: $scopeId)" -ForegroundColor Gray
    }

    Write-Host "`nSetup complete!" -ForegroundColor Green

    return $config
}

#------------------------------------------------------------------------------------------------------------------
# Main Script
#------------------------------------------------------------------------------------------------------------------
try {
    Show-SPVidCompHeader "SharePoint Video Compression & Archival"

    # Initialize database first
    $null = Initialize-SPVidCompCatalog -DatabasePath $DatabasePath

    # Check if configuration exists or if Setup is requested
    $configExists = Test-SPVidCompConfigExists

    if (-not $configExists -or $Setup) {
        if (-not $configExists) {
            Write-Host "No configuration found. Running first-time setup...`n" -ForegroundColor Yellow
        }
        else {
            Write-Host "Running setup to modify configuration...`n" -ForegroundColor Yellow
        }

        # Run interactive setup
        $config = Initialize-SPVidCompConfiguration

        Write-Host "`nSetup complete! You can now run the script without -Setup parameter." -ForegroundColor Green
        Write-Host "To modify settings in the future, run: .\Compress-SharePointVideos.ps1 -Setup`n" -ForegroundColor Cyan
        exit 0
    }

    # Load configuration from database
    $currentConfig = Get-SPVidCompConfig

    # Display current settings and ask for confirmation
    Show-SPVidCompCurrentConfig -Config $currentConfig

    Write-Host "Do you want to:" -ForegroundColor Yellow
    Write-Host "  [P] Proceed with these settings" -ForegroundColor White
    Write-Host "  [M] Modify settings" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor White
    $choice = Read-Host -Prompt "`nYour choice"

    switch ($choice.ToUpper()) {
        'M' {
            Write-Host "`nRestarting with -Setup to modify configuration...`n" -ForegroundColor Yellow
            & $PSCommandPath -DatabasePath $DatabasePath -Setup
            exit 0
        }
        'Q' {
            Write-Host "`nExiting...`n" -ForegroundColor Yellow
            exit 0
        }
        'P' {
            Write-Host "`nProceeding with current configuration...`n" -ForegroundColor Green
        }
        default {
            Write-Host "`nProceeding with current configuration...`n" -ForegroundColor Green
        }
    }

    # Initialize configuration
    Write-Host "Loading configuration..." -ForegroundColor Yellow
    $null = Initialize-SPVidCompConfig -DatabasePath $DatabasePath

    # Get config object for reference
    $Script:Config = [PSCustomObject]$currentConfig

    if ($DryRun) {
        Write-Host "`nDRY RUN MODE - No changes will be made`n" -ForegroundColor Magenta
    }
}
catch {
    Write-Error "Failed to initialize: $_"
    exit 1
}

#------------------------------------------------------------------------------------------------------------------
# Phase 1: Catalog Discovery
#------------------------------------------------------------------------------------------------------------------
if ($Phase -in @('Catalog', 'Both')) {
    try {
        Show-SPVidCompHeader "PHASE 1: CATALOG DISCOVERY"

        Write-SPVidCompLog -Message "Starting catalog phase" -Level 'Info'

        # Get all enabled scopes
        $scopes = Get-SPVidCompScopes -EnabledOnly

        if ($scopes.Count -eq 0) {
            throw "No enabled scopes found. Run with -Setup to configure scopes."
        }

        Write-Host "Scanning $($scopes.Count) enabled scope(s)...`n" -ForegroundColor Yellow

        # Connect to SharePoint ONCE at the beginning
        # PnP.PowerShell can access multiple sites in the same tenant after authentication
        Write-Host "Connecting to SharePoint..." -ForegroundColor Yellow
        $firstSiteUrl = $scopes[0].site_url
        $Script:SPConnection = Connect-SPVidCompSharePoint -SiteUrl $firstSiteUrl
        Write-Host "Authentication successful. Connection will be reused for all scopes.`n" -ForegroundColor Green

        $totalCataloged = 0
        $scopeIndex = 0

        foreach ($scope in $scopes) {
            $scopeIndex++

            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "Scope $scopeIndex of $($scopes.Count): $($scope.display_name)" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "  Site URL       : $($scope.site_url)" -ForegroundColor Gray
            Write-Host "  Library        : $($scope.library_name)" -ForegroundColor Gray
            if ($scope.folder_path) {
                Write-Host "  Folder Path    : $($scope.folder_path)" -ForegroundColor Gray
            }
            Write-Host "  Recursive Scan : $($scope.recursive -eq 1)" -ForegroundColor Gray
            Write-Host ""

            try {
                # Scan library for videos (reuses existing connection)
                Write-Host "Enumerating videos..." -ForegroundColor Yellow
                $catalogedCount = Get-SPVidCompFiles -SiteUrl $scope.site_url `
                    -LibraryName $scope.library_name `
                    -FolderPath $scope.folder_path `
                    -Recursive ([bool]$scope.recursive) `
                    -ScopeId $scope.id

                $totalCataloged += $catalogedCount

                # Update scope statistics
                Update-SPVidCompScopeStats -ScopeId $scope.id

                Write-Host "  ✓ Cataloged: $catalogedCount videos" -ForegroundColor Green
                Write-SPVidCompLog -Message "Scope '$($scope.display_name)' cataloged $catalogedCount videos" -Level 'Info'
            }
            catch {
                Write-Host "  ✗ Failed to catalog scope: $_" -ForegroundColor Red
                Write-SPVidCompLog -Message "Scope '$($scope.display_name)' failed: $_" -Level 'Error'
                # Continue to next scope (don't fail entire catalog)
            }

            Write-Host ""
        }

        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Catalog Phase Complete" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Total videos cataloged: $totalCataloged" -ForegroundColor White
        Write-Host ""

        # Display aggregate statistics
        $stats = Get-SPVidCompStatistics
        Write-Host "Database Statistics:" -ForegroundColor Cyan
        Write-Host "  Total Videos       : $($stats.TotalCataloged)" -ForegroundColor White
        Write-Host "  Cataloged          : " -NoNewline -ForegroundColor White
        $catalogedStatus = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Cataloged' }
        Write-Host "$(if ($catalogedStatus) { $catalogedStatus.count } else { 0 })" -ForegroundColor White
        Write-Host "  Processing         : " -NoNewline -ForegroundColor White
        $processingStatus = $stats.StatusBreakdown | Where-Object { $_.status -in @('Downloading', 'Compressing', 'Uploading') }
        $processingCount = if ($processingStatus) { ($processingStatus | Measure-Object -Property count -Sum).Sum } else { 0 }
        Write-Host "$processingCount" -ForegroundColor White
        Write-Host "  Completed          : " -NoNewline -ForegroundColor White
        $completedStatus = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Completed' }
        Write-Host "$(if ($completedStatus) { $completedStatus.count } else { 0 })" -ForegroundColor White
        Write-Host "  Failed             : " -NoNewline -ForegroundColor White
        $failedStatus = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Failed' }
        Write-Host "$(if ($failedStatus) { $failedStatus.count } else { 0 })" -ForegroundColor White
        Write-Host "  Total Size         : $([math]::Round($stats.TotalOriginalSize / 1GB, 2)) GB" -ForegroundColor White
        Write-Host ""

        # Store catalog run metadata
        $null = Set-SPVidCompMetadata -Key 'last_catalog_run' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $null = Set-SPVidCompMetadata -Key 'total_cataloged' -Value $stats.TotalCataloged.ToString()

        Write-SPVidCompLog -Message "Catalog phase completed. Total cataloged: $totalCataloged" -Level 'Info'
    }
    catch {
        Write-SPVidCompLog -Message "Catalog phase failed: $_" -Level 'Error'
        Write-Error "Catalog phase failed: $_"
        exit 1
    }
}

#------------------------------------------------------------------------------------------------------------------
# Phase 2: Processing
#------------------------------------------------------------------------------------------------------------------
if ($Phase -in @('Process', 'Both')) {
    try {
        Show-SPVidCompHeader "PHASE 2: VIDEO PROCESSING"

        # Ensure SharePoint connection exists (reuse from catalog or create new)
        if (-not $Script:SPConnection) {
            Write-Host "Connecting to SharePoint..." -ForegroundColor Yellow

            # Get first video to determine site URL for initial connection
            $firstVideo = (Get-SPVidCompVideos -Status 'Cataloged' -MaxRetryCount 999 | Select-Object -First 1)
            if (-not $firstVideo) {
                Write-Host "No videos to process." -ForegroundColor Yellow
                exit 0
            }

            $Script:SPConnection = Connect-SPVidCompSharePoint -SiteUrl $firstVideo.site_url
            Write-Host "Authentication successful.`n" -ForegroundColor Green
        }
        else {
            Write-Host "Using existing SharePoint connection from catalog phase...`n" -ForegroundColor Yellow
        }

        # Query videos to process
        Write-Host "`nQuerying videos to process..." -ForegroundColor Yellow
        $retryAttempts = [int](Get-SPVidCompConfigValue -Key 'processing_retry_attempts')
        $videosToProcess = Get-SPVidCompVideos -Status 'Cataloged' -MaxRetryCount $retryAttempts

        if (-not $videosToProcess -or $videosToProcess.Count -eq 0) {
            Write-Host "No videos to process." -ForegroundColor Yellow
            Write-Host "`nChecking for failed videos to retry..." -ForegroundColor Yellow
            $videosToProcess = Get-SPVidCompVideos -Status 'Failed' -MaxRetryCount $retryAttempts
        }

        if (-not $videosToProcess -or $videosToProcess.Count -eq 0) {
            Write-Host "No videos to process or retry." -ForegroundColor Green
            exit 0
        }

        Write-Host "Found $($videosToProcess.Count) videos to process`n" -ForegroundColor Green

        # Check disk space
        Write-Host "Checking disk space..." -ForegroundColor Yellow
        $tempPath = Get-SPVidCompConfigValue -Key 'paths_temp_download'
        $requiredSpaceGB = [int](Get-SPVidCompConfigValue -Key 'processing_required_disk_space_gb')
        $requiredSpace = $requiredSpaceGB * 1GB
        $spaceCheck = Test-SPVidCompDiskSpace -Path $tempPath -RequiredBytes $requiredSpace

        if (-not $spaceCheck.HasSpace) {
            Write-Error "Insufficient disk space. Required: $requiredSpaceGB GB"
            exit 1
        }

        Write-Host "Disk space OK: $([math]::Round($spaceCheck.FreeSpace / 1GB, 2)) GB available`n" -ForegroundColor Green

        # Get configuration values
        $archivePath = Get-SPVidCompConfigValue -Key 'paths_external_archive'
        $frameRate = [int](Get-SPVidCompConfigValue -Key 'compression_frame_rate')
        $videoCodec = Get-SPVidCompConfigValue -Key 'compression_video_codec'
        $timeoutMinutes = [int](Get-SPVidCompConfigValue -Key 'compression_timeout_minutes')
        $durationTolerance = [int](Get-SPVidCompConfigValue -Key 'processing_duration_tolerance_seconds')
        $illegalCharStrategy = Get-SPVidCompConfigValue -Key 'illegal_char_strategy' -DefaultValue 'Replace'
        $illegalCharReplacement = Get-SPVidCompConfigValue -Key 'illegal_char_replacement' -DefaultValue '_'
        $maxParallelJobs = [int](Get-SPVidCompConfigValue -Key 'processing_max_parallel_jobs' -DefaultValue '2')

        # Validate and cap parallel jobs
        if ($maxParallelJobs -lt 1) { $maxParallelJobs = 1 }
        if ($maxParallelJobs -gt 8) { $maxParallelJobs = 8 }

        Write-Host "Processing Architecture: Pipeline (Download → Compress in parallel → Upload)`n" -ForegroundColor Cyan
        Write-Host "Max parallel compressions: $maxParallelJobs`n" -ForegroundColor Cyan

        # Counters
        $processedCount = 0
        $failedCount = 0

        # Job tracking - only track jobs WE create
        $compressionJobs = @()
        $completedVideos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

        #==================================================================================
        # PIPELINE: Download → Compress (parallel jobs) → Upload
        #==================================================================================
        Write-Host "Starting pipeline processing of $($videosToProcess.Count) videos...`n" -ForegroundColor Yellow

        foreach ($video in $videosToProcess) {
            Write-Host "----------------------------------------" -ForegroundColor Cyan
            Write-Host "[$($processedCount + $failedCount + 1)/$($videosToProcess.Count)] $($video.filename)" -ForegroundColor Cyan
            # Step 1: Download
            Write-Host "[1/3] Downloading..." -ForegroundColor Yellow

            try {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would download this video" -ForegroundColor Magenta
                    continue
                }

                # Temp file paths
                $tempOriginal = Join-Path -Path $tempPath -ChildPath "$($video.id)_original.mp4"
                $tempCompressed = Join-Path -Path $tempPath -ChildPath "$($video.id)_compressed.mp4"

                # Download from SharePoint (main thread)
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Downloading'

                $downloadSuccess = Receive-SPVidCompVideo -SharePointUrl $video.sharepoint_url `
                    -DestinationPath $tempOriginal -VideoId $video.id

                if (-not $downloadSuccess) {
                    throw "Download failed"
                }

                Write-Host "  Downloaded: $([math]::Round((Get-Item $tempOriginal).Length / 1MB, 2)) MB" -ForegroundColor Green

                # Step 2: Start compression job (background)
                Write-Host "[2/3] Starting compression job..." -ForegroundColor Yellow

                # Wait if we're at max parallel jobs
                # Simply count jobs in our tracking array that haven't been uploaded yet
                $runningCount = ($compressionJobs | Where-Object { -not $_.Uploaded }).Count

                while ($runningCount -ge $maxParallelJobs) {
                    Write-Host "  Waiting for compression slots ($runningCount/$maxParallelJobs active)..." -ForegroundColor Yellow

                    # Check for hung jobs (timeout + 5 minute buffer for archive/verify)
                    $maxJobRuntime = ($timeoutMinutes + 5) * 60
                    $now = Get-Date
                    $hungJobs = $compressionJobs | Where-Object {
                        -not $_.Uploaded -and
                        $_.Job.State -eq 'Running' -and
                        (($now - $_.StartTime).TotalSeconds -gt $maxJobRuntime)
                    }

                    foreach ($hungJob in $hungJobs) {
                        Write-Host "`n  WARNING: Job $($hungJob.Job.Id) for $($hungJob.Video.filename) exceeded timeout. Killing job..." -ForegroundColor Red
                        Stop-Job -Job $hungJob.Job
                        $null = Update-SPVidCompStatus -VideoId $hungJob.Video.id -Status 'Failed' -AdditionalFields @{
                            last_error = "Job timeout: exceeded $maxJobRuntime seconds"
                            retry_count = $hungJob.Video.retry_count + 1
                        }
                        Remove-Job -Job $hungJob.Job -Force
                        $failedCount++
                    }

                    Start-Sleep -Milliseconds 500

                    # Check for completed jobs in our tracking array
                    $completedJobs = $compressionJobs | Where-Object {
                        -not $_.Uploaded -and
                        $_.Job.State -eq 'Completed'
                    }
                    foreach ($job in $completedJobs) {
                        $job.Uploaded = $true
                        $jobResult = Receive-Job -Job $job.Job

                        Write-Host "`n[Job Completed] $($job.Video.filename)" -ForegroundColor Cyan
                        Write-Host "  Success: $($jobResult.Success)" -ForegroundColor $(if ($jobResult.Success) { 'Green' } else { 'Red' })
                        if (-not $jobResult.Success) {
                            Write-Host "  Error: $($jobResult.Error)" -ForegroundColor Red
                        }

                        if ($jobResult.Success) {
                            # Upload immediately
                            Write-Host "[Uploading] $($jobResult.Filename)..." -ForegroundColor Cyan
                            try {
                                $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Uploading'

                                $uploadSuccess = Send-SPVidCompVideo -LocalPath $jobResult.TempCompressed -SharePointUrl $jobResult.SharePointUrl

                                if ($uploadSuccess) {
                                    $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Completed'
                                    Write-Host "  Uploaded successfully" -ForegroundColor Green
                                    $processedCount++

                                    # Only cleanup temp files after successful upload
                                    if (Test-Path $jobResult.TempOriginal) { Remove-Item $jobResult.TempOriginal -Force -ErrorAction SilentlyContinue }
                                    if (Test-Path $jobResult.TempCompressed) { Remove-Item $jobResult.TempCompressed -Force -ErrorAction SilentlyContinue }
                                }
                                else {
                                    throw "Upload failed"
                                }
                            }
                            catch {
                                Write-Host "  Upload FAILED: $_" -ForegroundColor Red
                                Write-Host "  Files preserved in temp folder for retry" -ForegroundColor Yellow
                                $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Failed' -AdditionalFields @{
                                    last_error = "Upload failed: $($_.Exception.Message)"
                                    retry_count = $jobResult.RetryCount + 1
                                }
                                $failedCount++
                            }
                        }
                        else {
                            $failedCount++
                        }

                        Remove-Job -Job $job.Job -Force
                    }

                    # Remove completed jobs from tracking array
                    $compressionJobs = @($compressionJobs | Where-Object { -not $_.Uploaded })

                    # Recalculate running count for next iteration
                    $runningCount = $compressionJobs.Count
                }

                # Start compression job
                $modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\VideoCompressionModule\VideoCompressionModule.psm1'

                $job = Start-Job -ScriptBlock {
                    param($ModulePath, $DatabasePath, $Video, $TempOriginal, $TempCompressed, $ArchivePath,
                          $FrameRate, $VideoCodec, $TimeoutMinutes, $DurationTolerance,
                          $IllegalCharStrategy, $IllegalCharReplacement)

                    # Import module
                    Import-Module $ModulePath -Force -WarningAction SilentlyContinue

                    # Initialize database
                    $null = Initialize-SPVidCompCatalog -DatabasePath $DatabasePath

                    try {
                        # Archive
                        $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Archiving'

                        $sanitizeResult = Repair-SPVidCompFilename -Filename $Video.filename `
                            -Strategy $IllegalCharStrategy -ReplacementChar $IllegalCharReplacement

                        if (-not $sanitizeResult.Success) {
                            throw "Filename sanitization failed"
                        }

                        # Build archive path
                        $siteUri = [System.Uri]$Video.site_url
                        $sitePath = $siteUri.AbsolutePath.TrimStart('/')
                        if ([string]::IsNullOrEmpty($sitePath)) {
                            $sitePath = $siteUri.Host.Split('.')[0]
                        }

                        # Start with archive base path + site path
                        $videoArchivePath = $ArchivePath
                        $sitePath.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
                            $videoArchivePath = Join-Path $videoArchivePath $_
                        }
                        $videoArchivePath = Join-Path $videoArchivePath $Video.library_name

                        # Extract folder path relative to library
                        # folder_path may contain full server-relative path like "/sites/playground/Shared Documents/Vids1"
                        # We need just the part after the library name
                        if ($Video.folder_path) {
                            $folderPathClean = $Video.folder_path.TrimStart('/\')

                            # Find where the library name ends in the folder path
                            $libraryIndex = $folderPathClean.IndexOf($Video.library_name, [System.StringComparison]::OrdinalIgnoreCase)
                            if ($libraryIndex -ge 0) {
                                # Skip past site path and library name to get relative folder path
                                $relativePath = $folderPathClean.Substring($libraryIndex + $Video.library_name.Length).TrimStart('/\')
                            } else {
                                # If library name not found, try to find "Shared Documents" or just use as-is
                                $sharedDocsIndex = $folderPathClean.IndexOf("Shared Documents", [System.StringComparison]::OrdinalIgnoreCase)
                                if ($sharedDocsIndex -ge 0) {
                                    $relativePath = $folderPathClean.Substring($sharedDocsIndex + "Shared Documents".Length).TrimStart('/\')
                                } else {
                                    # Last resort: remove site path if present
                                    $relativePath = $folderPathClean -replace "^sites/[^/]+/[^/]+/", ""
                                }
                            }

                            if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
                                $relativePath.Split('/\', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
                                    $videoArchivePath = Join-Path $videoArchivePath $_
                                }
                            }
                        }

                        $videoArchivePath = Join-Path $videoArchivePath $sanitizeResult.SanitizedFilename

                        $archiveResult = Copy-SPVidCompArchive -SourcePath $TempOriginal -ArchivePath $videoArchivePath

                        if (-not $archiveResult.Success) {
                            throw "Archive failed"
                        }

                        $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Archiving' -AdditionalFields @{
                            archive_path = $archiveResult.ArchivePath
                            original_hash = $archiveResult.SourceHash
                            archive_hash = $archiveResult.DestinationHash
                            hash_verified = 1
                        }

                        # Compress
                        $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Compressing'

                        $compressionResult = Invoke-SPVidCompCompression -InputPath $TempOriginal `
                            -OutputPath $TempCompressed -FrameRate $FrameRate `
                            -VideoCodec $VideoCodec -TimeoutMinutes $TimeoutMinutes

                        if (-not $compressionResult.Success) {
                            throw "Compression failed"
                        }

                        # Verify - TEMPORARILY DISABLED TO TEST
                        # $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Verifying'

                        # $integrityCheck = Test-SPVidCompVideoIntegrity -VideoPath $TempCompressed
                        # if (-not $integrityCheck.IsValid) {
                        #     throw "Integrity check failed"
                        # }

                        # $lengthCheck = Test-SPVidCompVideoLength -OriginalPath $TempOriginal -CompressedPath $TempCompressed `
                        #     -ToleranceSeconds $DurationTolerance

                        # if (-not $lengthCheck.WithinTolerance) {
                        #     throw "Duration mismatch"
                        # }

                        $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Verifying' -AdditionalFields @{
                            compressed_size = $compressionResult.OutputSize
                            compression_ratio = $compressionResult.CompressionRatio
                            # original_duration = $lengthCheck.OriginalDuration
                            # compressed_duration = $lengthCheck.CompressedDuration
                            integrity_verified = 0
                        }

                        return @{
                            Success = $true
                            VideoId = $Video.id
                            Filename = $Video.filename
                            SharePointUrl = $Video.sharepoint_url
                            TempOriginal = $TempOriginal
                            TempCompressed = $TempCompressed
                            RetryCount = $Video.retry_count
                            CompressionRatio = $compressionResult.CompressionRatio
                        }
                    }
                    catch {
                        $null = Update-SPVidCompStatus -VideoId $Video.id -Status 'Failed' -AdditionalFields @{
                            last_error = $_.Exception.Message
                            retry_count = $Video.retry_count + 1
                        }

                        # DO NOT cleanup on failure - preserve files for manual inspection/retry
                        # Files will remain in temp folder for debugging

                        return @{
                            Success = $false
                            VideoId = $Video.id
                            Filename = $Video.filename
                            Error = $_.Exception.Message
                        }
                    }
                } -ArgumentList $modulePath, $DatabasePath, $video, $tempOriginal, $tempCompressed, $archivePath,
                                $frameRate, $videoCodec, $timeoutMinutes, $durationTolerance,
                                $illegalCharStrategy, $illegalCharReplacement

                # Add job to tracking array
                $compressionJobs += @{
                    Job = $job
                    Video = $video
                    State = 'Running'
                    Uploaded = $false
                    StartTime = Get-Date
                }

                # Count active jobs (jobs not yet uploaded)
                $runningJobCount = ($compressionJobs | Where-Object { -not $_.Uploaded }).Count

                Write-Host "  Compression job started (Job ID: $($job.Id)) - Active jobs: $runningJobCount/$maxParallelJobs" -ForegroundColor Green
            }
            catch {
                Write-SPVidCompLog -Message "Failed to download video $($video.filename): $_" -Level 'Error'
                Write-Host "  Download FAILED: $_" -ForegroundColor Red

                $retryCount = $video.retry_count + 1
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Failed' -AdditionalFields @{
                    last_error = $_.Exception.Message
                    retry_count = $retryCount
                }

                $failedCount++
            }
        }

        # Wait for remaining compression jobs to complete and upload them
        Write-Host "`nWaiting for remaining compression jobs to complete...`n" -ForegroundColor Yellow

        # Clean up stale job references
        $compressionJobs = @($compressionJobs | Where-Object {
            $_.Job -and
            (Get-Job -Id $_.Job.Id -ErrorAction SilentlyContinue) -ne $null
        })

        $ellipsisCounter = 0
        while ($compressionJobs.Count -gt 0) {
            # Only work with jobs we're tracking - don't query all system jobs

            # Check all compressed files and categorize them
            $compressedFiles = Get-ChildItem -Path $tempPath -Filter "*_compressed.mp4" -ErrorAction SilentlyContinue
            $readyToUploadCount = 0
            $compressingCount = 0

            foreach ($file in $compressedFiles) {
                # Check if file is locked by ffmpeg (still being written)
                $isLocked = Test-SPVidCompFileIsLocked -FilePath $file.FullName
                if ($isLocked) {
                    $compressingCount++  # Still being written
                } else {
                    $readyToUploadCount++  # Complete and ready to upload
                }
            }

            if ($compressingCount -gt 0 -or $readyToUploadCount -gt 0) {
                # Animated ellipsis: cycles through ".", "..", "..."
                $ellipsis = "." * (($ellipsisCounter % 3) + 1)
                $ellipsisCounter++

                # Overwrite current line with carriage return
                Write-Host "`r  Status: $compressingCount compressing, $readyToUploadCount ready to upload$ellipsis   " -NoNewline -ForegroundColor Cyan
            }

            # Check for hung jobs (timeout + 5 minute buffer for archive/verify)
            $maxJobRuntime = ($timeoutMinutes + 5) * 60
            $now = Get-Date
            $hungJobs = $compressionJobs | Where-Object {
                $_.Job -and
                (Get-Job -Id $_.Job.Id -ErrorAction SilentlyContinue).State -eq 'Running' -and
                (($now - $_.StartTime).TotalSeconds -gt $maxJobRuntime)
            }

            foreach ($hungJob in $hungJobs) {
                # Clear status line before printing warning
                Write-Host "`r                                                                                     "
                Write-Host "  WARNING: Job $($hungJob.Job.Id) for $($hungJob.Video.filename) exceeded timeout. Killing job..." -ForegroundColor Red
                Stop-Job -Job $hungJob.Job
                $null = Update-SPVidCompStatus -VideoId $hungJob.Video.id -Status 'Failed' -AdditionalFields @{
                    last_error = "Job timeout: exceeded $maxJobRuntime seconds"
                    retry_count = $hungJob.Video.retry_count + 1
                }
                Remove-Job -Job $hungJob.Job -Force
                $failedCount++
            }

            Start-Sleep -Milliseconds 500

            # Check for completed jobs in our tracking array
            $completedJobs = $compressionJobs | Where-Object {
                $_.Job -and
                (Get-Job -Id $_.Job.Id -ErrorAction SilentlyContinue).State -eq 'Completed' -and
                -not $_.Uploaded
            }
            foreach ($job in $completedJobs) {
                $job.Uploaded = $true
                $job.State = 'Completed'
                $jobResult = Receive-Job -Job $job.Job

                # Clear status line before printing job completion
                Write-Host "`r                                                                                     "
                Write-Host "[Job Completed] $($job.Video.filename)" -ForegroundColor Cyan
                Write-Host "  Success: $($jobResult.Success)" -ForegroundColor $(if ($jobResult.Success) { 'Green' } else { 'Red' })
                if (-not $jobResult.Success) {
                    Write-Host "  Error: $($jobResult.Error)" -ForegroundColor Red
                }

                if ($jobResult.Success) {
                    Write-Host "[Uploading] $($jobResult.Filename)..." -ForegroundColor Cyan
                    try {
                        $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Uploading'

                        $uploadSuccess = Send-SPVidCompVideo -LocalPath $jobResult.TempCompressed -SharePointUrl $jobResult.SharePointUrl

                        if ($uploadSuccess) {
                            $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Completed'
                            Write-Host "  Uploaded successfully (Ratio: $($jobResult.CompressionRatio))" -ForegroundColor Green
                            $processedCount++

                            # Only cleanup temp files after successful upload
                            if (Test-Path $jobResult.TempOriginal) { Remove-Item $jobResult.TempOriginal -Force -ErrorAction SilentlyContinue }
                            if (Test-Path $jobResult.TempCompressed) { Remove-Item $jobResult.TempCompressed -Force -ErrorAction SilentlyContinue }
                        }
                        else {
                            throw "Upload failed"
                        }
                    }
                    catch {
                        Write-Host "  Upload FAILED: $_" -ForegroundColor Red
                        Write-Host "  Files preserved in temp folder for retry" -ForegroundColor Yellow
                        $null = Update-SPVidCompStatus -VideoId $jobResult.VideoId -Status 'Failed' -AdditionalFields @{
                            last_error = "Upload failed: $($_.Exception.Message)"
                            retry_count = $jobResult.RetryCount + 1
                        }
                        $failedCount++
                    }
                }
                else {
                    $failedCount++
                }

                Remove-Job -Job $job.Job -Force
            }

            # Remove completed jobs from tracking array
            $compressionJobs = @($compressionJobs | Where-Object { -not $_.Uploaded })

            # Clean up stale job references for next iteration
            $compressionJobs = @($compressionJobs | Where-Object {
                $_.Job -and
                (Get-Job -Id $_.Job.Id -ErrorAction SilentlyContinue) -ne $null
            })
        }

        # Clear the status line and move to next line
        Write-Host "`r                                                                                     "

        Write-Host "
All pipeline processing complete!
" -ForegroundColor Green

        Show-SPVidCompHeader "PROCESSING COMPLETE"
        Write-Host "Processed: $processedCount" -ForegroundColor Green
        Write-Host "Failed: $failedCount" -ForegroundColor Red
        Write-Host ""

        # Generate final report
        $finalStats = Get-SPVidCompStatistics

        Write-Host "Final Statistics:" -ForegroundColor Yellow
        Write-Host "  Total Cataloged: $($finalStats.TotalCataloged)" -ForegroundColor White
        $completedCount = $finalStats.StatusBreakdown | Where-Object { $_.status -eq 'Completed' }
        Write-Host "  Total Completed: $(if ($completedCount) { $completedCount.count } else { 0 })" -ForegroundColor White
        Write-Host "  Space Saved: $([math]::Round($finalStats.SpaceSaved / 1GB, 2)) GB" -ForegroundColor White
        Write-Host "  Average Compression: $($finalStats.AverageCompressionRatio)" -ForegroundColor White

        # Send completion notification if configured
        $emailEnabled = [bool]::Parse((Get-SPVidCompConfigValue -Key 'email_enabled'))
        $sendOnCompletion = [bool]::Parse((Get-SPVidCompConfigValue -Key 'email_send_on_completion'))

        if ($emailEnabled -and $sendOnCompletion) {
            Write-Host "`nSending completion notification..." -ForegroundColor Yellow

            $failedVideos = Get-SPVidCompVideos -Status 'Failed'
            $reportBody = Build-CompletionReport -Statistics $finalStats -FailedVideos $failedVideos
            Send-SPVidCompNotification -Subject "SharePoint Video Compression Report" `
                -Body $reportBody -IsHtml $true

            Write-Host "Notification sent!" -ForegroundColor Green
        }

        # Store processing run metadata
        $null = Set-SPVidCompMetadata -Key 'last_processing_run' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $null = Set-SPVidCompMetadata -Key 'total_processed' -Value $processedCount.ToString()
    }
    catch {
        Write-SPVidCompLog -Message "Processing phase failed: $_" -Level 'Error'
        Write-Error "Processing phase failed: $_"
        exit 1
    }
}

Write-Host "`nScript completed successfully!`n" -ForegroundColor Green
