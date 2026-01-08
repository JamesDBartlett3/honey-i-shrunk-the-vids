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

#------------------------------------------------------------------------------------------------------------------
# Import Module
#------------------------------------------------------------------------------------------------------------------
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\VideoCompressionModule\VideoCompressionModule.psm1'
Import-Module $modulePath -Force

#------------------------------------------------------------------------------------------------------------------
# Helper Functions
#------------------------------------------------------------------------------------------------------------------
function Show-Header {
    param([string]$Title)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Read-UserInput {
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

function Read-YesNo {
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

function Show-CurrentConfig {
    param([hashtable]$Config)

    Show-Header "CURRENT CONFIGURATION"

    Write-Host "SharePoint Settings:" -ForegroundColor Yellow
    Write-Host "  Site URL           : $($Config['sharepoint_site_url'])" -ForegroundColor White
    Write-Host "  Library Name       : $($Config['sharepoint_library_name'])" -ForegroundColor White
    Write-Host "  Folder Path        : $($Config['sharepoint_folder_path'])" -ForegroundColor White
    Write-Host "  Recursive Scan     : $($Config['sharepoint_recursive'])" -ForegroundColor White

    Write-Host "`nPaths:" -ForegroundColor Yellow
    Write-Host "  Temp Download      : $($Config['paths_temp_download'])" -ForegroundColor White
    Write-Host "  External Archive   : $($Config['paths_external_archive'])" -ForegroundColor White
    Write-Host "  Log Path           : $($Config['paths_log'])" -ForegroundColor White

    Write-Host "`nCompression:" -ForegroundColor Yellow
    Write-Host "  Frame Rate         : $($Config['compression_frame_rate'])" -ForegroundColor White
    Write-Host "  Video Codec        : $($Config['compression_video_codec'])" -ForegroundColor White
    Write-Host "  Timeout (minutes)  : $($Config['compression_timeout_minutes'])" -ForegroundColor White

    Write-Host "`nProcessing:" -ForegroundColor Yellow
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

function Initialize-Configuration {
    Show-Header "INTERACTIVE SETUP"

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

    # SharePoint Settings
    Write-Host "`n--- SharePoint Settings ---" -ForegroundColor Cyan
    $config['sharepoint_site_url'] = Read-UserInput -Prompt "SharePoint Site URL" -DefaultValue "https://contoso.sharepoint.com/sites/YourSite" -Required
    $config['sharepoint_library_name'] = Read-UserInput -Prompt "Library Name" -DefaultValue "Documents" -Required
    $config['sharepoint_folder_path'] = Read-UserInput -Prompt "Folder Path (optional, e.g., /Videos)" -DefaultValue ""
    $config['sharepoint_recursive'] = (Read-YesNo -Prompt "Scan subfolders recursively?" -DefaultValue $true).ToString()

    # Paths - Platform-aware defaults
    Write-Host "`n--- File Paths ---" -ForegroundColor Cyan
    $config['paths_temp_download'] = Read-UserInput -Prompt "Temp Download Path" -DefaultValue $platformDefaults['TempPath'] -Required
    $config['paths_external_archive'] = Read-UserInput -Prompt "External Archive Path" -DefaultValue $platformDefaults['ArchivePath'] -Required
    $config['paths_log'] = Read-UserInput -Prompt "Log Path" -DefaultValue $platformDefaults['LogPath'] -Required

    # Compression Settings
    Write-Host "`n--- Compression Settings ---" -ForegroundColor Cyan
    $config['compression_frame_rate'] = Read-UserInput -Prompt "Target Frame Rate" -DefaultValue "10"
    $config['compression_video_codec'] = Read-UserInput -Prompt "Video Codec (libx265, libx264, etc.)" -DefaultValue "libx265"
    $config['compression_timeout_minutes'] = Read-UserInput -Prompt "Compression Timeout (minutes)" -DefaultValue "60"

    # Processing Settings
    Write-Host "`n--- Processing Settings ---" -ForegroundColor Cyan
    $config['processing_retry_attempts'] = Read-UserInput -Prompt "Retry Attempts for Failed Videos" -DefaultValue "3"
    $config['processing_required_disk_space_gb'] = Read-UserInput -Prompt "Required Disk Space (GB)" -DefaultValue "50"
    $config['processing_duration_tolerance_seconds'] = Read-UserInput -Prompt "Duration Tolerance (seconds)" -DefaultValue "1"

    # Resume Settings
    Write-Host "`n--- Resume Settings ---" -ForegroundColor Cyan
    $config['resume_enable'] = (Read-YesNo -Prompt "Enable resume capability?" -DefaultValue $true).ToString()
    $config['resume_skip_processed'] = (Read-YesNo -Prompt "Skip already processed files?" -DefaultValue $true).ToString()
    $config['resume_reprocess_failed'] = (Read-YesNo -Prompt "Reprocess failed files?" -DefaultValue $true).ToString()

    # Email Settings
    Write-Host "`n--- Email Notifications ---" -ForegroundColor Cyan
    $emailEnabled = Read-YesNo -Prompt "Enable email notifications?" -DefaultValue $false
    $config['email_enabled'] = $emailEnabled.ToString()

    if ($emailEnabled) {
        $config['email_smtp_server'] = Read-UserInput -Prompt "SMTP Server" -DefaultValue "smtp.office365.com" -Required
        $config['email_smtp_port'] = Read-UserInput -Prompt "SMTP Port" -DefaultValue "587"
        $config['email_use_ssl'] = (Read-YesNo -Prompt "Use SSL?" -DefaultValue $true).ToString()
        $config['email_from'] = Read-UserInput -Prompt "From Address" -DefaultValue "automation@contoso.com" -Required
        $config['email_to'] = Read-UserInput -Prompt "To Addresses (comma-separated)" -DefaultValue "admin@contoso.com" -Required
        $config['email_send_on_completion'] = (Read-YesNo -Prompt "Send email on completion?" -DefaultValue $true).ToString()
        $config['email_send_on_error'] = (Read-YesNo -Prompt "Send email on error?" -DefaultValue $true).ToString()
    }
    else {
        $config['email_smtp_server'] = 'smtp.office365.com'
        $config['email_smtp_port'] = '587'
        $config['email_use_ssl'] = 'True'
        $config['email_from'] = ''
        $config['email_to'] = ''
        $config['email_send_on_completion'] = 'False'
        $config['email_send_on_error'] = 'False'
    }

    # Logging Settings
    Write-Host "`n--- Logging Settings ---" -ForegroundColor Cyan
    $config['logging_log_level'] = Read-UserInput -Prompt "Log Level (Debug, Info, Warning, Error)" -DefaultValue "Info"
    $config['logging_console_output'] = (Read-YesNo -Prompt "Enable console output?" -DefaultValue $true).ToString()
    $config['logging_file_output'] = (Read-YesNo -Prompt "Enable file output?" -DefaultValue $true).ToString()
    $config['logging_max_log_size_mb'] = Read-UserInput -Prompt "Max Log Size (MB)" -DefaultValue "100"
    $config['logging_log_retention_days'] = Read-UserInput -Prompt "Log Retention (days)" -DefaultValue "30"

    # Advanced Settings
    Write-Host "`n--- Advanced Settings ---" -ForegroundColor Cyan
    $config['advanced_cleanup_temp_files'] = (Read-YesNo -Prompt "Cleanup temp files after processing?" -DefaultValue $true).ToString()
    $config['advanced_verify_checksums'] = (Read-YesNo -Prompt "Verify checksums?" -DefaultValue $true).ToString()
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
        $config['illegal_char_replacement'] = Read-UserInput -Prompt "Replacement character" -DefaultValue "_"
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

    Write-Host "Configuration saved successfully!" -ForegroundColor Green

    return $config
}

#------------------------------------------------------------------------------------------------------------------
# Main Script
#------------------------------------------------------------------------------------------------------------------
try {
    Show-Header "SharePoint Video Compression & Archival"

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
        $config = Initialize-Configuration

        Write-Host "`nSetup complete! You can now run the script without -Setup parameter." -ForegroundColor Green
        Write-Host "To modify settings in the future, run: .\Compress-SharePointVideos.ps1 -Setup`n" -ForegroundColor Cyan
        exit 0
    }

    # Load configuration from database
    $currentConfig = Get-SPVidCompConfig

    # Display current settings and ask for confirmation
    Show-CurrentConfig -Config $currentConfig

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
        Show-Header "PHASE 1: CATALOG DISCOVERY"

        # Connect to SharePoint
        Write-Host "Connecting to SharePoint..." -ForegroundColor Yellow
        $siteUrl = Get-ConfigValue -Key 'sharepoint_site_url'
        $null = Connect-SPVidCompSharePoint -SiteUrl $siteUrl

        # Scan for videos
        Write-Host "`nScanning SharePoint for MP4 videos..." -ForegroundColor Yellow
        $libraryName = Get-ConfigValue -Key 'sharepoint_library_name'
        $folderPath = Get-ConfigValue -Key 'sharepoint_folder_path'
        $recursive = [bool]::Parse((Get-ConfigValue -Key 'sharepoint_recursive'))

        $catalogedCount = Get-SPVidCompFiles -SiteUrl $siteUrl `
            -LibraryName $libraryName `
            -FolderPath $folderPath `
            -Recursive $recursive

        Write-Host "`nCataloging complete!" -ForegroundColor Green
        Write-Host "Total videos cataloged: $catalogedCount" -ForegroundColor Green

        # Show catalog statistics
        Write-Host "`nCatalog Statistics:" -ForegroundColor Yellow
        $stats = Get-SPVidCompStatistics

        Write-Host "  Total Videos: $($stats.TotalCataloged)" -ForegroundColor White
        Write-Host "  Total Size: $([math]::Round($stats.TotalOriginalSize / 1GB, 2)) GB" -ForegroundColor White

        Write-Host "`nStatus Breakdown:" -ForegroundColor Yellow
        foreach ($status in $stats.StatusBreakdown) {
            Write-Host "  $($status.status): $($status.count)" -ForegroundColor White
        }

        # Store catalog run metadata
        $null = Set-Metadata -Key 'last_catalog_run' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $null = Set-Metadata -Key 'total_cataloged' -Value $stats.TotalCataloged.ToString()

        Write-Host "`nPhase 1 Complete!`n" -ForegroundColor Green
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
        Show-Header "PHASE 2: VIDEO PROCESSING"

        # Connect to SharePoint if not already connected
        if ($Phase -eq 'Process') {
            Write-Host "Connecting to SharePoint..." -ForegroundColor Yellow
            $siteUrl = Get-ConfigValue -Key 'sharepoint_site_url'
            $null = Connect-SPVidCompSharePoint -SiteUrl $siteUrl
        }

        # Query videos to process
        Write-Host "`nQuerying videos to process..." -ForegroundColor Yellow
        $retryAttempts = [int](Get-ConfigValue -Key 'processing_retry_attempts')
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
        $tempPath = Get-ConfigValue -Key 'paths_temp_download'
        $requiredSpaceGB = [int](Get-ConfigValue -Key 'processing_required_disk_space_gb')
        $requiredSpace = $requiredSpaceGB * 1GB
        $spaceCheck = Test-SPVidCompDiskSpace -Path $tempPath -RequiredBytes $requiredSpace

        if (-not $spaceCheck.HasSpace) {
            Write-Error "Insufficient disk space. Required: $requiredSpaceGB GB"
            exit 1
        }

        Write-Host "Disk space OK: $([math]::Round($spaceCheck.FreeSpace / 1GB, 2)) GB available`n" -ForegroundColor Green

        # Get configuration values
        $archivePath = Get-ConfigValue -Key 'paths_external_archive'
        $frameRate = [int](Get-ConfigValue -Key 'compression_frame_rate')
        $videoCodec = Get-ConfigValue -Key 'compression_video_codec'
        $timeoutMinutes = [int](Get-ConfigValue -Key 'compression_timeout_minutes')
        $durationTolerance = [int](Get-ConfigValue -Key 'processing_duration_tolerance_seconds')
        $illegalCharStrategy = Get-ConfigValue -Key 'illegal_char_strategy' -DefaultValue 'Replace'
        $illegalCharReplacement = Get-ConfigValue -Key 'illegal_char_replacement' -DefaultValue '_'

        # Process each video
        $processedCount = 0
        $failedCount = 0

        foreach ($video in $videosToProcess) {
            try {
                Write-Host "`n----------------------------------------" -ForegroundColor Cyan
                Write-Host "Processing: $($video.filename)" -ForegroundColor Cyan
                Write-Host "Video ID: $($video.id)" -ForegroundColor Gray
                Write-Host "Size: $([math]::Round($video.original_size / 1MB, 2)) MB" -ForegroundColor Gray
                Write-Host "----------------------------------------" -ForegroundColor Cyan

                if ($DryRun) {
                    Write-Host "[DRY RUN] Would process this video" -ForegroundColor Magenta
                    continue
                }

                # Temp file paths
                $tempOriginal = Join-Path -Path $tempPath -ChildPath "$($video.id)_original.mp4"
                $tempCompressed = Join-Path -Path $tempPath -ChildPath "$($video.id)_compressed.mp4"

                # Step 1: Download
                Write-Host "`n[1/6] Downloading from SharePoint..." -ForegroundColor Yellow
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Downloading'

                $downloadSuccess = Receive-SPVidCompVideo -SharePointUrl $video.sharepoint_url `
                    -DestinationPath $tempOriginal -VideoId $video.id

                if (-not $downloadSuccess) {
                    throw "Download failed"
                }

                # Step 2: Archive with hash verification
                Write-Host "[2/6] Archiving to external storage..." -ForegroundColor Yellow
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Archiving'

                # Sanitize filename for filesystem compatibility
                $sanitizeResult = Repair-SPVidCompFilename -Filename $video.filename `
                    -Strategy $illegalCharStrategy -ReplacementChar $illegalCharReplacement

                if (-not $sanitizeResult.Success) {
                    throw "Filename sanitization failed: $($sanitizeResult.Error)"
                }

                if ($sanitizeResult.Changed) {
                    Write-Host "  Filename sanitized: '$($video.filename)' -> '$($sanitizeResult.SanitizedFilename)'" -ForegroundColor Yellow
                }

                # Build mirrored folder structure: <archive>/<site>/<library>/<folder_path>/<filename>
                # Extract site path from URL (e.g., "https://contoso.sharepoint.com/sites/MySite")
                $siteUri = [System.Uri]$video.site_url
                $sitePath = $siteUri.AbsolutePath.TrimStart('/')

                if ([string]::IsNullOrEmpty($sitePath)) {
                    $sitePath = $siteUri.Host.Split('.')[0]  # Use hostname if path is empty
                }

                # Split site path components and join using platform-appropriate separator
                $sitePathComponents = $sitePath.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)

                # Start with archive root
                $videoArchivePath = $archivePath

                # Add site path components (e.g., "sites", "MySite")
                foreach ($component in $sitePathComponents) {
                    $videoArchivePath = Join-Path -Path $videoArchivePath -ChildPath $component
                }

                # Add library name
                $videoArchivePath = Join-Path -Path $videoArchivePath -ChildPath $video.library_name

                # Add folder path components if present
                if (-not [string]::IsNullOrEmpty($video.folder_path)) {
                    $folderPathComponents = $video.folder_path.TrimStart('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
                    foreach ($component in $folderPathComponents) {
                        $videoArchivePath = Join-Path -Path $videoArchivePath -ChildPath $component
                    }
                }

                # Add sanitized filename
                $videoArchivePath = Join-Path -Path $videoArchivePath -ChildPath $sanitizeResult.SanitizedFilename

                Write-Host "  Archive path: $videoArchivePath" -ForegroundColor Gray
                $archiveResult = Copy-SPVidCompArchive -SourcePath $tempOriginal -ArchivePath $videoArchivePath

                if (-not $archiveResult.Success) {
                    throw "Archive failed: $($archiveResult.Error)"
                }

                # Update database with archive info
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Archiving' -AdditionalFields @{
                    archive_path = $archiveResult.ArchivePath
                    original_hash = $archiveResult.SourceHash
                    archive_hash = $archiveResult.DestinationHash
                    hash_verified = 1
                }

                # Step 3: Compress
                Write-Host "[3/6] Compressing video..." -ForegroundColor Yellow
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Compressing'

                $compressionResult = Invoke-SPVidCompCompression -InputPath $tempOriginal `
                    -OutputPath $tempCompressed -FrameRate $frameRate `
                    -VideoCodec $videoCodec -TimeoutMinutes $timeoutMinutes

                if (-not $compressionResult.Success) {
                    throw "Compression failed: $($compressionResult.Error)"
                }

                # Step 4: Verify integrity
                Write-Host "[4/6] Verifying compressed video..." -ForegroundColor Yellow
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Verifying'

                $integrityCheck = Test-SPVidCompVideoIntegrity -VideoPath $tempCompressed

                if (-not $integrityCheck.IsValid) {
                    throw "Integrity check failed: Video is corrupted"
                }

                $lengthCheck = Test-SPVidCompVideoLength -OriginalPath $tempOriginal -CompressedPath $tempCompressed `
                    -ToleranceSeconds $durationTolerance

                if (-not $lengthCheck.WithinTolerance) {
                    throw "Duration mismatch: Original=$($lengthCheck.OriginalDuration)s, Compressed=$($lengthCheck.CompressedDuration)s"
                }

                # Update database with verification info
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Verifying' -AdditionalFields @{
                    compressed_size = $compressionResult.OutputSize
                    compression_ratio = $compressionResult.CompressionRatio
                    original_duration = $lengthCheck.OriginalDuration
                    compressed_duration = $lengthCheck.CompressedDuration
                    integrity_verified = 1
                }

                # Step 5: Upload compressed version
                Write-Host "[5/6] Uploading to SharePoint..." -ForegroundColor Yellow
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Uploading'

                $uploadSuccess = Send-SPVidCompVideo -LocalPath $tempCompressed -SharePointUrl $video.sharepoint_url

                if (-not $uploadSuccess) {
                    throw "Upload failed"
                }

                # Step 6: Cleanup
                Write-Host "[6/6] Cleaning up temp files..." -ForegroundColor Yellow

                if (Test-Path -LiteralPath $tempOriginal) {
                    Remove-Item -LiteralPath $tempOriginal -Force
                }
                if (Test-Path -LiteralPath $tempCompressed) {
                    Remove-Item -LiteralPath $tempCompressed -Force
                }

                # Mark as completed
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Completed'

                Write-Host "`nSUCCESS!" -ForegroundColor Green
                Write-Host "Compression ratio: $($compressionResult.CompressionRatio)" -ForegroundColor Green
                Write-Host "Space saved: $([math]::Round(($video.original_size - $compressionResult.OutputSize) / 1MB, 2)) MB" -ForegroundColor Green

                $processedCount++
            }
            catch {
                Write-SPVidCompLog -Message "Failed to process video $($video.filename): $_" -Level 'Error'
                Write-Host "`nFAILED: $_" -ForegroundColor Red

                # Update retry count and mark as failed
                $retryCount = $video.retry_count + 1
                $null = Update-SPVidCompStatus -VideoId $video.id -Status 'Failed' -AdditionalFields @{
                    last_error = $_.Exception.Message
                    retry_count = $retryCount
                }

                # Clean up temp files
                if (Test-Path -LiteralPath $tempOriginal) {
                    Remove-Item -LiteralPath $tempOriginal -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path -LiteralPath $tempCompressed) {
                    Remove-Item -LiteralPath $tempCompressed -Force -ErrorAction SilentlyContinue
                }

                $failedCount++

                # Send error notification if configured
                $emailEnabled = [bool]::Parse((Get-ConfigValue -Key 'email_enabled'))
                $sendOnError = [bool]::Parse((Get-ConfigValue -Key 'email_send_on_error'))

                if ($emailEnabled -and $sendOnError) {
                    $errorBody = Build-ErrorReport -ErrorMessage $_.Exception.Message `
                        -VideoFilename $video.filename -SharePointUrl $video.sharepoint_url
                    Send-SPVidCompNotification -Subject "Video Compression Error: $($video.filename)" `
                        -Body $errorBody -IsHtml $true
                }
            }
        }

        Show-Header "PROCESSING COMPLETE"
        Write-Host "Processed: $processedCount" -ForegroundColor Green
        Write-Host "Failed: $failedCount" -ForegroundColor Red
        Write-Host ""

        # Generate final report
        $finalStats = Get-SPVidCompStatistics

        Write-Host "Final Statistics:" -ForegroundColor Yellow
        Write-Host "  Total Cataloged: $($finalStats.TotalCataloged)" -ForegroundColor White
        Write-Host "  Total Completed: $($finalStats.StatusBreakdown | Where-Object { $_.status -eq 'Completed' } | Select-Object -ExpandProperty count)" -ForegroundColor White
        Write-Host "  Space Saved: $([math]::Round($finalStats.SpaceSaved / 1GB, 2)) GB" -ForegroundColor White
        Write-Host "  Average Compression: $($finalStats.AverageCompressionRatio)" -ForegroundColor White

        # Send completion notification if configured
        $emailEnabled = [bool]::Parse((Get-ConfigValue -Key 'email_enabled'))
        $sendOnCompletion = [bool]::Parse((Get-ConfigValue -Key 'email_send_on_completion'))

        if ($emailEnabled -and $sendOnCompletion) {
            Write-Host "`nSending completion notification..." -ForegroundColor Yellow

            $failedVideos = Get-SPVidCompVideos -Status 'Failed'
            $reportBody = Build-CompletionReport -Statistics $finalStats -FailedVideos $failedVideos
            Send-SPVidCompNotification -Subject "SharePoint Video Compression Report" `
                -Body $reportBody -IsHtml $true

            Write-Host "Notification sent!" -ForegroundColor Green
        }

        # Store processing run metadata
        $null = Set-Metadata -Key 'last_processing_run' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $null = Set-Metadata -Key 'total_processed' -Value $processedCount.ToString()
    }
    catch {
        Write-SPVidCompLog -Message "Processing phase failed: $_" -Level 'Error'
        Write-Error "Processing phase failed: $_"
        exit 1
    }
}

Write-Host "`nScript completed successfully!`n" -ForegroundColor Green
