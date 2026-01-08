#------------------------------------------------------------------------------------------------------------------
# VideoCompressionModule.psm1 - SharePoint Video Compression and Archival Automation
# Main module with public functions
#------------------------------------------------------------------------------------------------------------------

# Import private modules
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
. (Join-Path -Path $privatePath -ChildPath 'Logger.ps1')
. (Join-Path -Path $privatePath -ChildPath 'DatabaseManager.ps1')
. (Join-Path -Path $privatePath -ChildPath 'EmailHelper.ps1')

# Module-level variables
$Script:Config = $null
$Script:SharePointConnection = $null
$Script:FFmpegPath = $null
$Script:FFprobePath = $null
$Script:FFmpegBinDir = Join-Path -Path $PSScriptRoot -ChildPath 'bin/ffmpeg'

#------------------------------------------------------------------------------------------------------------------
# Helper Function: New-SPVidComp-Directory
# Purpose: DRY helper to ensure a directory exists, creating it if necessary
#------------------------------------------------------------------------------------------------------------------
function New-SPVidComp-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            Write-SPVidComp-Log -Message "Created directory: $Path" -Level 'Debug'
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to create directory '$Path': $_" -Level 'Warning'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Helper Function: Get-SPVidComp-FFmpegPath
# Purpose: Find ffmpeg executable (system PATH or downloaded)
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-FFmpegPath {
    [CmdletBinding()]
    param()

    # Return cached path if available
    if ($Script:FFmpegPath -and (Test-Path -LiteralPath $Script:FFmpegPath)) {
        return $Script:FFmpegPath
    }

    # Check system PATH first
    $systemFFmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($systemFFmpeg) {
        $Script:FFmpegPath = $systemFFmpeg.Source
        return $Script:FFmpegPath
    }

    # Check module bin directory
    $exe = if ($IsWindows) { 'ffmpeg.exe' } else { 'ffmpeg' }
    $modulePath = Join-Path -Path $Script:FFmpegBinDir -ChildPath $exe
    if (Test-Path -LiteralPath $modulePath) {
        $Script:FFmpegPath = $modulePath
        return $Script:FFmpegPath
    }

    return $null
}

#------------------------------------------------------------------------------------------------------------------
# Helper Function: Get-SPVidComp-FFprobePath
# Purpose: Find ffprobe executable (system PATH or downloaded)
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-FFprobePath {
    [CmdletBinding()]
    param()

    # Return cached path if available
    if ($Script:FFprobePath -and (Test-Path -LiteralPath $Script:FFprobePath)) {
        return $Script:FFprobePath
    }

    # Check system PATH first
    $systemFFprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($systemFFprobe) {
        $Script:FFprobePath = $systemFFprobe.Source
        return $Script:FFprobePath
    }

    # Check module bin directory
    $exe = if ($IsWindows) { 'ffprobe.exe' } else { 'ffprobe' }
    $modulePath = Join-Path -Path $Script:FFmpegBinDir -ChildPath $exe
    if (Test-Path -LiteralPath $modulePath) {
        $Script:FFprobePath = $modulePath
        return $Script:FFprobePath
    }

    return $null
}

#------------------------------------------------------------------------------------------------------------------
# Function: Install-SPVidComp-FFmpeg
# Purpose: Download and install ffmpeg/ffprobe for current platform
#------------------------------------------------------------------------------------------------------------------
function Install-SPVidComp-FFmpeg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    try {
        # Check if already installed (unless Force)
        if (-not $Force) {
            $ffmpegPath = Get-SPVidComp-FFmpegPath
            $ffprobePath = Get-SPVidComp-FFprobePath
            if ($ffmpegPath -and $ffprobePath) {
                Write-SPVidComp-Log -Message "FFmpeg already available at: $ffmpegPath" -Level 'Info'
                return @{
                    Success = $true
                    FFmpegPath = $ffmpegPath
                    FFprobePath = $ffprobePath
                    Downloaded = $false
                }
            }
        }

        Write-SPVidComp-Log -Message "Downloading FFmpeg for current platform..." -Level 'Info'

        # Get download info for current platform
        $downloadInfo = Get-SPVidComp-FFmpegDownloadInfo
        if (-not $downloadInfo.Success) {
            return @{
                Success = $false
                Error = $downloadInfo.Error
            }
        }

        # Create bin directory
        New-SPVidComp-Directory -Path $Script:FFmpegBinDir

        # Download to temp location
        $tempPath = [System.IO.Path]::GetTempPath()
        $downloadPath = Join-Path -Path $tempPath -ChildPath $downloadInfo.Filename

        Write-SPVidComp-Log -Message "Downloading from: $($downloadInfo.Url)" -Level 'Info'
        Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

        # Extract archive
        Write-SPVidComp-Log -Message "Extracting FFmpeg..." -Level 'Info'

        if ($downloadInfo.Filename -match '\.zip$') {
            # Windows ZIP
            Expand-Archive -Path $downloadPath -DestinationPath $tempPath -Force

            # Find ffmpeg.exe and ffprobe.exe in extracted folder
            $extractedDir = Join-Path -Path $tempPath -ChildPath ($downloadInfo.Filename -replace '\.zip$', '')
            $ffmpegExe = Get-ChildItem -Path $extractedDir -Filter 'ffmpeg.exe' -Recurse | Select-Object -First 1
            $ffprobeExe = Get-ChildItem -Path $extractedDir -Filter 'ffprobe.exe' -Recurse | Select-Object -First 1

            if ($ffmpegExe) {
                Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffmpeg.exe') -Force
            }
            if ($ffprobeExe) {
                Copy-Item -LiteralPath $ffprobeExe.FullName -Destination (Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffprobe.exe') -Force
            }

            # Cleanup
            Remove-Item -Path $extractedDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            # Linux/macOS tar.xz
            $extractCmd = "tar -xJf `"$downloadPath`" -C `"$tempPath`""
            Invoke-Expression $extractCmd

            # Find ffmpeg and ffprobe in extracted folder
            $extractedDir = Join-Path -Path $tempPath -ChildPath ($downloadInfo.Filename -replace '\.tar\.xz$', '')

            Write-SPVidComp-Log -Message "Looking for binaries in: $extractedDir" -Level 'Debug'

            # The archive structure might have binaries in a bin/ subdirectory
            $ffmpegBin = Get-ChildItem -Path $extractedDir -Filter 'ffmpeg' -Recurse -File | Select-Object -First 1
            $ffprobeBin = Get-ChildItem -Path $extractedDir -Filter 'ffprobe' -Recurse -File | Select-Object -First 1

            if ($ffmpegBin) {
                $destPath = Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffmpeg'
                Write-SPVidComp-Log -Message "Copying ffmpeg from $($ffmpegBin.FullName) to $destPath" -Level 'Debug'
                Copy-Item -LiteralPath $ffmpegBin.FullName -Destination $destPath -Force
                & chmod +x $destPath 2>&1 | Out-Null
            }
            else {
                Write-SPVidComp-Log -Message "ffmpeg binary not found in extracted archive" -Level 'Warning'
            }

            if ($ffprobeBin) {
                $destPath = Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffprobe'
                Write-SPVidComp-Log -Message "Copying ffprobe from $($ffprobeBin.FullName) to $destPath" -Level 'Debug'
                Copy-Item -LiteralPath $ffprobeBin.FullName -Destination $destPath -Force
                & chmod +x $destPath 2>&1 | Out-Null
            }
            else {
                Write-SPVidComp-Log -Message "ffprobe binary not found in extracted archive" -Level 'Warning'
            }

            # Cleanup
            Remove-Item -Path $extractedDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Cleanup download
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue

        # Verify installation
        $Script:FFmpegPath = $null
        $Script:FFprobePath = $null
        $ffmpegPath = Get-SPVidComp-FFmpegPath
        $ffprobePath = Get-SPVidComp-FFprobePath

        if ($ffmpegPath -and $ffprobePath) {
            Write-SPVidComp-Log -Message "FFmpeg installed successfully to: $Script:FFmpegBinDir" -Level 'Info'
            return @{
                Success = $true
                FFmpegPath = $ffmpegPath
                FFprobePath = $ffprobePath
                Downloaded = $true
            }
        }
        else {
            return @{
                Success = $false
                Error = "FFmpeg binaries not found after extraction"
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to install FFmpeg: $_" -Level 'Error'
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Helper Function: Get-SPVidComp-FFmpegDownloadInfo
# Purpose: Get download URL and filename for current platform
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-FFmpegDownloadInfo {
    [CmdletBinding()]
    param()

    try {
        # Using GitHub BtbN/FFmpeg-Builds releases for consistency across platforms
        # These are static builds that don't require additional dependencies

        if ($IsWindows) {
            return @{
                Success = $true
                Url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
                Filename = 'ffmpeg-master-latest-win64-gpl.zip'
                Platform = 'Windows'
            }
        }
        elseif ($IsLinux) {
            return @{
                Success = $true
                Url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz'
                Filename = 'ffmpeg-master-latest-linux64-gpl.tar.xz'
                Platform = 'Linux'
            }
        }
        elseif ($IsMacOS) {
            return @{
                Success = $true
                Url = 'https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip'
                Filename = 'ffmpeg-macos.zip'
                Platform = 'macOS'
            }
        }
        else {
            return @{
                Success = $false
                Error = "Unsupported platform for automatic FFmpeg download"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-SPVidComp-Config
# Purpose: Load and initialize configuration from database
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidComp-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        # Initialize database first
        Initialize-SPVidComp-Catalog -DatabasePath $DatabasePath

        # Load configuration from database
        $configHash = Get-AllConfig

        if ($configHash.Count -eq 0) {
            throw "No configuration found in database. Please run with -Setup parameter first."
        }

        # Build config object from database values
        $Script:Config = [PSCustomObject]@{
            SharePoint = [PSCustomObject]@{
                SiteUrl = $configHash['sharepoint_site_url']
                LibraryName = $configHash['sharepoint_library_name']
                FolderPath = $configHash['sharepoint_folder_path']
                Recursive = [bool]::Parse($configHash['sharepoint_recursive'])
            }
            Paths = [PSCustomObject]@{
                TempDownloadPath = $configHash['paths_temp_download']
                ExternalArchivePath = $configHash['paths_external_archive']
                LogPath = $configHash['paths_log']
                DatabasePath = $DatabasePath
            }
            Compression = [PSCustomObject]@{
                FrameRate = [int]$configHash['compression_frame_rate']
                VideoCodec = $configHash['compression_video_codec']
                TimeoutMinutes = [int]$configHash['compression_timeout_minutes']
            }
            Processing = [PSCustomObject]@{
                RetryAttempts = [int]$configHash['processing_retry_attempts']
                RequiredDiskSpaceGB = [int]$configHash['processing_required_disk_space_gb']
                DurationToleranceSeconds = [int]$configHash['processing_duration_tolerance_seconds']
            }
            Resume = [PSCustomObject]@{
                EnableResumeCapability = [bool]::Parse($configHash['resume_enable'])
                SkipProcessedFiles = [bool]::Parse($configHash['resume_skip_processed'])
                ReprocessFailedFiles = [bool]::Parse($configHash['resume_reprocess_failed'])
            }
            Email = [PSCustomObject]@{
                Enabled = [bool]::Parse($configHash['email_enabled'])
                SmtpServer = $configHash['email_smtp_server']
                SmtpPort = [int]$configHash['email_smtp_port']
                UseSSL = [bool]::Parse($configHash['email_use_ssl'])
                From = $configHash['email_from']
                To = $configHash['email_to'] -split ','
                SendOnCompletion = [bool]::Parse($configHash['email_send_on_completion'])
                SendOnError = [bool]::Parse($configHash['email_send_on_error'])
            }
            Logging = [PSCustomObject]@{
                LogLevel = $configHash['logging_log_level']
                ConsoleOutput = [bool]::Parse($configHash['logging_console_output'])
                FileOutput = [bool]::Parse($configHash['logging_file_output'])
                MaxLogSizeMB = [int]$configHash['logging_max_log_size_mb']
                LogRetentionDays = [int]$configHash['logging_log_retention_days']
            }
            Advanced = [PSCustomObject]@{
                CleanupTempFiles = [bool]::Parse($configHash['advanced_cleanup_temp_files'])
                VerifyChecksums = [bool]::Parse($configHash['advanced_verify_checksums'])
                DryRun = [bool]::Parse($configHash['advanced_dry_run'])
            }
            IllegalCharacterHandling = [PSCustomObject]@{
                Strategy = $configHash['illegal_char_strategy']
                ReplacementChar = $configHash['illegal_char_replacement']
            }
        }

        # Initialize logger
        Initialize-Logger -LogPath $Script:Config.Paths.LogPath `
            -LogLevel $Script:Config.Logging.LogLevel `
            -ConsoleOutput $Script:Config.Logging.ConsoleOutput `
            -FileOutput $Script:Config.Logging.FileOutput `
            -MaxLogSizeMB $Script:Config.Logging.MaxLogSizeMB `
            -LogRetentionDays $Script:Config.Logging.LogRetentionDays

        Write-SPVidComp-Log -Message "Configuration loaded successfully from database" -Level 'Info'

        # Initialize email config
        Initialize-EmailConfig -Config @{
            Enabled = $Script:Config.Email.Enabled
            SmtpServer = $Script:Config.Email.SmtpServer
            SmtpPort = $Script:Config.Email.SmtpPort
            UseSSL = $Script:Config.Email.UseSSL
            From = $Script:Config.Email.From
            To = $Script:Config.Email.To
            Username = $Script:Config.Email.Username
            Password = $Script:Config.Email.Password
            ClientId = $Script:Config.Email.ClientId
            TenantId = $Script:Config.Email.TenantId
            TokenCacheFile = $Script:Config.Email.TokenCacheFile
            SendOnCompletion = $Script:Config.Email.SendOnCompletion
            SendOnError = $Script:Config.Email.SendOnError
        }

        return $true
    }
    catch {
        Write-Error "Failed to initialize configuration: $_"
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Connect-SPVidComp-SharePoint
# Purpose: Authenticate to SharePoint using PnP.PowerShell
#------------------------------------------------------------------------------------------------------------------
function Connect-SPVidComp-SharePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )

    try {
        # Check if PnP.PowerShell module is available
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Write-SPVidComp-Log -Message "PnP.PowerShell module not found. Installing..." -Level 'Warning'
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
            Write-SPVidComp-Log -Message "PnP.PowerShell module installed successfully" -Level 'Info'
        }

        # Import module
        Import-Module PnP.PowerShell -ErrorAction Stop

        # Connect to SharePoint
        Write-SPVidComp-Log -Message "Connecting to SharePoint: $SiteUrl" -Level 'Info'
        $Script:SharePointConnection = Connect-PnPOnline -Url $SiteUrl -Interactive -ReturnConnection -ErrorAction Stop

        Write-SPVidComp-Log -Message "Successfully connected to SharePoint" -Level 'Info'
        return $Script:SharePointConnection
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to connect to SharePoint: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Disconnect-SPVidComp-SharePoint
# Purpose: Disconnect from SharePoint and cleanup connection
#------------------------------------------------------------------------------------------------------------------
function Disconnect-SPVidComp-SharePoint {
    [CmdletBinding()]
    param()

    try {
        if ($Script:SharePointConnection) {
            Write-SPVidComp-Log -Message "Disconnecting from SharePoint..." -Level 'Info'
            Disconnect-PnPOnline -Connection $Script:SharePointConnection -ErrorAction SilentlyContinue
            $Script:SharePointConnection = $null
            Write-SPVidComp-Log -Message "Successfully disconnected from SharePoint" -Level 'Info'
            return $true
        }
        else {
            Write-SPVidComp-Log -Message "No active SharePoint connection to disconnect" -Level 'Debug'
            return $true
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Error disconnecting from SharePoint: $_" -Level 'Warning'
        $Script:SharePointConnection = $null
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-SPVidComp-Catalog
# Purpose: Create/open SQLite database
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidComp-Catalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        Initialize-Database -DatabasePath $DatabasePath
        Write-SPVidComp-Log -Message "Video catalog initialized" -Level 'Info'
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to initialize video catalog: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-SPVidComp-Video
# Purpose: Add video to catalog database
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidComp-Video {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl,

        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$LibraryName,

        [Parameter(Mandatory = $false)]
        [string]$FolderPath = '',

        [Parameter(Mandatory = $true)]
        [string]$Filename,

        [Parameter(Mandatory = $true)]
        [long]$OriginalSize,

        [Parameter(Mandatory = $true)]
        [DateTime]$ModifiedDate
    )

    try {
        $result = Add-VideoToDatabase -SharePointUrl $SharePointUrl -SiteUrl $SiteUrl `
            -LibraryName $LibraryName -FolderPath $FolderPath -Filename $Filename `
            -OriginalSize $OriginalSize -ModifiedDate $ModifiedDate

        if ($result) {
            Write-SPVidComp-Log -Message "Video added to catalog: $Filename" -Level 'Debug'
        }

        return $result
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to add video to catalog: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-Videos
# Purpose: Query videos from catalog by status
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-Videos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetryCount = 999,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 0
    )

    try {
        return Get-VideosFromDatabase -Status $Status -MaxRetryCount $MaxRetryCount -Limit $Limit
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to query videos: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Update-SPVidComp-Status
# Purpose: Update video processing status
#------------------------------------------------------------------------------------------------------------------
function Update-SPVidComp-Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VideoId,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalFields = @{}
    )

    try {
        return Update-VideoStatus -VideoId $VideoId -Status $Status -AdditionalFields $AdditionalFields
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to update video status: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-Files
# Purpose: Scan SharePoint for MP4 files and add to catalog
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-Files {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$LibraryName,

        [Parameter(Mandatory = $false)]
        [string]$FolderPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$Recursive = $true
    )

    try {
        Write-SPVidComp-Log -Message "Scanning SharePoint library: $LibraryName" -Level 'Info'

        # Get files from SharePoint
        $files = Get-PnPListItem -List $LibraryName -PageSize 500 -Connection $Script:SharePointConnection | Where-Object {
            $_.FileSystemObjectType -eq 'File' -and $_.FieldValues.FileLeafRef -like '*.mp4'
        }

        $catalogedCount = 0

        foreach ($file in $files) {
            $fileUrl = $file.FieldValues.FileRef
            $fullUrl = "$SiteUrl$fileUrl"
            $filename = $file.FieldValues.FileLeafRef
            $fileSize = [long]$file.FieldValues.File_x0020_Size
            $modifiedDate = [DateTime]$file.FieldValues.Modified

            # Extract folder path
            $fileFolderPath = Split-Path -Path $fileUrl -Parent

            # Add to catalog
            $added = Add-SPVidComp-Video -SharePointUrl $fullUrl -SiteUrl $SiteUrl `
                -LibraryName $LibraryName -FolderPath $fileFolderPath -Filename $filename `
                -OriginalSize $fileSize -ModifiedDate $modifiedDate

            if ($added) {
                $catalogedCount++
            }
        }

        Write-SPVidComp-Log -Message "Cataloged $catalogedCount videos from $LibraryName" -Level 'Info'
        return $catalogedCount
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to scan SharePoint files: $_" -Level 'Error'
        return 0
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Download-SPVidComp-Video
# Purpose: Download video from SharePoint to temp location
#------------------------------------------------------------------------------------------------------------------
function Download-SPVidComp-Video {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [int]$VideoId
    )

    try {
        Write-SPVidComp-Log -Message "Downloading video (ID: $VideoId)..." -Level 'Info'

        # Extract server-relative URL
        $uri = [System.Uri]$SharePointUrl
        $serverRelativeUrl = $uri.AbsolutePath

        # Ensure destination directory exists
        $destDir = Split-Path -Path $DestinationPath -Parent
        New-SPVidComp-Directory -Path $destDir

        # Download file
        Get-PnPFile -Url $serverRelativeUrl -Path $destDir -FileName (Split-Path -Path $DestinationPath -Leaf) `
            -AsFile -Force -Connection $Script:SharePointConnection -ErrorAction Stop

        if (Test-Path -LiteralPath $DestinationPath) {
            Write-SPVidComp-Log -Message "Video downloaded successfully: $DestinationPath" -Level 'Info'
            return $true
        }
        else {
            Write-SPVidComp-Log -Message "Download failed: File not found at destination" -Level 'Error'
            return $false
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to download video: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Copy-SPVidComp-Archive
# Purpose: Copy video to archive storage with hash verification
#------------------------------------------------------------------------------------------------------------------
function Copy-SPVidComp-Archive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    try {
        Write-SPVidComp-Log -Message "Archiving video to: $ArchivePath" -Level 'Info'

        # Ensure archive directory exists
        $archiveDir = Split-Path -Path $ArchivePath -Parent
        New-SPVidComp-Directory -Path $archiveDir

        # Copy file
        Copy-Item -LiteralPath $SourcePath -Destination $ArchivePath -Force -ErrorAction Stop

        # Verify copy with hash
        $verified = Test-SPVidComp-ArchiveIntegrity -SourcePath $SourcePath -DestinationPath $ArchivePath

        if ($verified.Success) {
            Write-SPVidComp-Log -Message "Video archived and verified successfully" -Level 'Info'
            return @{
                Success = $true
                ArchivePath = $ArchivePath
                SourceHash = $verified.SourceHash
                DestinationHash = $verified.DestinationHash
                Error = $null
            }
        }
        else {
            Write-SPVidComp-Log -Message "Archive verification failed: Hash mismatch" -Level 'Error'
            # Delete corrupted archive
            if (Test-Path -LiteralPath $ArchivePath) {
                Remove-Item -LiteralPath $ArchivePath -Force
            }
            return @{
                Success = $false
                Error = "Hash verification failed"
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to archive video: $_" -Level 'Error'
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-ArchiveIntegrity
# Purpose: Verify archive copy using SHA256 hash
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-ArchiveIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        Write-SPVidComp-Log -Message "Verifying archive integrity..." -Level 'Info'

        # Calculate hashes
        $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        $destHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash

        $success = ($sourceHash -eq $destHash)

        if ($success) {
            Write-SPVidComp-Log -Message "Archive integrity verified: Hashes match" -Level 'Info'
        }
        else {
            Write-SPVidComp-Log -Message "Archive integrity check failed: Hash mismatch" -Level 'Error'
        }

        return @{
            Success = $success
            SourceHash = $sourceHash
            DestinationHash = $destHash
            Error = $null
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to verify archive integrity: $_" -Level 'Error'
        return @{
            Success = $false
            SourceHash = $null
            DestinationHash = $null
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Invoke-SPVidComp-Compression
# Purpose: Compress video using ffmpeg
#------------------------------------------------------------------------------------------------------------------
function Invoke-SPVidComp-Compression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [int]$FrameRate = 10,

        [Parameter(Mandatory = $false)]
        [string]$VideoCodec = 'libx265',

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 60
    )

    try {
        Write-SPVidComp-Log -Message "Compressing video: $InputPath (timeout: $TimeoutMinutes minutes)" -Level 'Info'

        # Get ffmpeg path
        $ffmpegPath = Get-SPVidComp-FFmpegPath
        if (-not $ffmpegPath) {
            Write-SPVidComp-Log -Message "FFmpeg not found. Attempting automatic installation..." -Level 'Warning'
            $installResult = Install-SPVidComp-FFmpeg
            if (-not $installResult.Success) {
                throw "FFmpeg not available and automatic installation failed: $($installResult.Error)"
            }
            $ffmpegPath = $installResult.FFmpegPath
        }

        # Build ffmpeg command - Start-Process -ArgumentList handles quoting automatically
        $ffmpegArgs = @(
            '-y'                    # Auto-confirm file overwrites
            '-hwaccel', 'auto'
            '-i', $InputPath
            '-vf', "fps=$FrameRate"
            '-c:v', $VideoCodec
            '-ac', '1'
            '-ar', '22050'
            $OutputPath
        )

        $ffmpegCommand = "$ffmpegPath $($ffmpegArgs -join ' ')"
        Write-SPVidComp-Log -Message "Executing: $ffmpegCommand" -Level 'Debug'

        # Execute ffmpeg with timeout
        $ffmpegErrorLog = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "ffmpeg-error.log"

        # Start process in background to allow timeout monitoring
        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = $ffmpegPath
        $processStartInfo.Arguments = $ffmpegArgs -join ' '
        $processStartInfo.RedirectStandardError = $true
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processStartInfo
        $process.Start() | Out-Null

        # Wait with timeout (convert minutes to milliseconds)
        $timeoutMs = $TimeoutMinutes * 60 * 1000
        $completed = $process.WaitForExit($timeoutMs)

        if (-not $completed) {
            # Timeout occurred
            $process.Kill()
            $process.WaitForExit()
            Write-SPVidComp-Log -Message "Compression timed out after $TimeoutMinutes minutes" -Level 'Error'

            # Save error log
            $errorOutput = $process.StandardError.ReadToEnd()
            Set-Content -LiteralPath $ffmpegErrorLog -Value $errorOutput -Force

            return @{
                Success = $false
                Error = "Compression timed out after $TimeoutMinutes minutes"
                ErrorLog = $errorOutput
            }
        }

        # Save stderr to log file
        $errorOutput = $process.StandardError.ReadToEnd()
        Set-Content -LiteralPath $ffmpegErrorLog -Value $errorOutput -Force

        # Check result
        if ($process.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutputPath)) {
            $inputSize = (Get-Item -LiteralPath $InputPath).Length
            $outputSize = (Get-Item -LiteralPath $OutputPath).Length
            $ratio = [math]::Round(($outputSize / $inputSize), 2)

            Write-SPVidComp-Log -Message "Compression completed successfully. Ratio: $ratio" -Level 'Info'

            return @{
                Success = $true
                InputSize = $inputSize
                OutputSize = $outputSize
                CompressionRatio = $ratio
                Error = $null
            }
        }
        else {
            Write-SPVidComp-Log -Message "Compression failed. Exit code: $($process.ExitCode). Error: $errorOutput" -Level 'Error'

            return @{
                Success = $false
                InputSize = $null
                OutputSize = $null
                CompressionRatio = $null
                Error = "ffmpeg exited with code $($process.ExitCode)"
                ErrorLog = $errorOutput
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to compress video: $_" -Level 'Error'
        return @{
            Success = $false
            InputSize = $null
            OutputSize = $null
            CompressionRatio = $null
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-VideoIntegrity
# Purpose: Verify video is not corrupted using ffprobe
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-VideoIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )

    try {
        Write-SPVidComp-Log -Message "Verifying video integrity: $VideoPath" -Level 'Debug'

        # Get ffprobe path
        $ffprobePath = Get-SPVidComp-FFprobePath
        if (-not $ffprobePath) {
            Write-SPVidComp-Log -Message "FFprobe not found. Attempting automatic installation..." -Level 'Warning'
            $installResult = Install-SPVidComp-FFmpeg
            if (-not $installResult.Success) {
                throw "FFprobe not available and automatic installation failed: $($installResult.Error)"
            }
            $ffprobePath = $installResult.FFprobePath
        }

        # Run ffprobe to check video - Start-Process -ArgumentList handles quoting automatically
        $ffprobeErrorLog = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "ffprobe-error.log"

        # Build ffprobe arguments
        $ffprobeArgs = @(
            '-v', 'error'
            $VideoPath
        )

        # Start process with proper argument handling
        $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = $ffprobePath
        $processStartInfo.Arguments = $ffprobeArgs -join ' '
        $processStartInfo.RedirectStandardError = $true
        $processStartInfo.RedirectStandardOutput = $true
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processStartInfo
        $process.Start() | Out-Null
        $process.WaitForExit()

        # Get error output
        $errorOutput = $process.StandardError.ReadToEnd()
        Set-Content -LiteralPath $ffprobeErrorLog -Value $errorOutput -Force

        if ($process.ExitCode -eq 0) {
            Write-SPVidComp-Log -Message "Video integrity verified: No corruption detected" -Level 'Debug'
            return @{
                Success = $true
                IsValid = $true
                Error = $null
            }
        }
        else {
            Write-SPVidComp-Log -Message "Video integrity check failed: $errorOutput" -Level 'Error'

            return @{
                Success = $false
                IsValid = $false
                Error = $errorOutput
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to verify video integrity: $_" -Level 'Error'
        return @{
            Success = $false
            IsValid = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-VideoLength
# Purpose: Get video duration and compare original vs compressed
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-VideoLength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalPath,

        [Parameter(Mandatory = $true)]
        [string]$CompressedPath,

        [Parameter(Mandatory = $false)]
        [int]$ToleranceSeconds = 1
    )

    try {
        Write-SPVidComp-Log -Message "Comparing video durations..." -Level 'Debug'

        # Get original duration
        $originalDuration = Get-VideoDuration -VideoPath $OriginalPath
        $compressedDuration = Get-VideoDuration -VideoPath $CompressedPath

        if ($null -eq $originalDuration -or $null -eq $compressedDuration) {
            return @{
                Success = $false
                Error = "Failed to retrieve video duration"
            }
        }

        $difference = [math]::Abs($originalDuration - $compressedDuration)
        $withinTolerance = ($difference -le $ToleranceSeconds)

        if ($withinTolerance) {
            Write-SPVidComp-Log -Message "Video durations match (difference: $difference seconds)" -Level 'Info'
        }
        else {
            Write-SPVidComp-Log -Message "Video duration mismatch: Original=$originalDuration, Compressed=$compressedDuration" -Level 'Warning'
        }

        return @{
            Success = $true
            OriginalDuration = $originalDuration
            CompressedDuration = $compressedDuration
            Difference = $difference
            WithinTolerance = $withinTolerance
            Error = $null
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to compare video lengths: $_" -Level 'Error'
        return @{
            Success = $false
            OriginalDuration = $null
            CompressedDuration = $null
            Difference = $null
            WithinTolerance = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-VideoDuration (Helper)
# Purpose: Extract video duration using ffprobe
#------------------------------------------------------------------------------------------------------------------
function Get-VideoDuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )

    try {
        # Get ffprobe path
        $ffprobePath = Get-SPVidComp-FFprobePath
        if (-not $ffprobePath) {
            Write-SPVidComp-Log -Message "FFprobe not found for duration check" -Level 'Warning'
            return $null
        }

        $output = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$VideoPath`"" 2>&1

        if ($LASTEXITCODE -eq 0) {
            return [double]$output
        }
        else {
            Write-SPVidComp-Log -Message "Failed to get video duration: $output" -Level 'Warning'
            return $null
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Error getting video duration: $_" -Level 'Warning'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Upload-SPVidComp-Video
# Purpose: Upload compressed video back to SharePoint
#------------------------------------------------------------------------------------------------------------------
function Upload-SPVidComp-Video {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl
    )

    try {
        Write-SPVidComp-Log -Message "Uploading compressed video to SharePoint..." -Level 'Info'

        # Extract server-relative URL
        $uri = [System.Uri]$SharePointUrl
        $serverRelativeUrl = $uri.AbsolutePath
        $folderPath = Split-Path -Path $serverRelativeUrl -Parent
        $filename = Split-Path -Path $serverRelativeUrl -Leaf

        # Upload file (overwrite existing)
        Add-PnPFile -Path $LocalPath -Folder $folderPath -Connection $Script:SharePointConnection -ErrorAction Stop

        Write-SPVidComp-Log -Message "Video uploaded successfully to SharePoint" -Level 'Info'
        return $true
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to upload video: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Write-SPVidComp-Log
# Purpose: Logging wrapper
#------------------------------------------------------------------------------------------------------------------
function Write-SPVidComp-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$Component = ''
    )

    Write-LogEntry -Message $Message -Level $Level -Component $Component
}

#------------------------------------------------------------------------------------------------------------------
# Function: Send-SPVidComp-Notification
# Purpose: Send email notification
#------------------------------------------------------------------------------------------------------------------
function Send-SPVidComp-Notification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [bool]$IsHtml = $true
    )

    try {
        return Send-EmailNotification -Subject $Subject -Body $Body -IsHtml $IsHtml
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to send notification: $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-DiskSpace
# Purpose: Check available disk space
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-DiskSpace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [long]$RequiredBytes
    )

    try {
        # Handle non-existent paths by creating them or checking parent directory
        $pathToCheck = $Path
        if (-not (Test-Path -LiteralPath $Path)) {
            # Try to create the directory if it doesn't exist
            try {
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
                Write-SPVidComp-Log -Message "Created directory for disk space check: $Path" -Level 'Info'
            }
            catch {
                # If we can't create it, use the parent directory that exists
                $parent = Split-Path -Path $Path -Parent
                while ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    $parent = Split-Path -Path $parent -Parent
                }
                if ($parent) {
                    $pathToCheck = $parent
                    Write-SPVidComp-Log -Message "Using parent directory for disk space check: $pathToCheck" -Level 'Info'
                } else {
                    # Fall back to the root of the path
                    $pathToCheck = [System.IO.Path]::GetPathRoot($Path)
                    Write-SPVidComp-Log -Message "Using root path for disk space check: $pathToCheck" -Level 'Info'
                }
            }
        }

        $drive = (Get-Item -LiteralPath $pathToCheck).PSDrive
        $freeSpace = $drive.Free

        $hasSpace = ($freeSpace -ge $RequiredBytes)

        if (-not $hasSpace) {
            $requiredGB = [math]::Round($RequiredBytes / 1GB, 2)
            $freeGB = [math]::Round($freeSpace / 1GB, 2)
            Write-SPVidComp-Log -Message "Insufficient disk space: Required=$requiredGB GB, Available=$freeGB GB" -Level 'Warning'
        }

        return @{
            Success = $true
            HasSpace = $hasSpace
            FreeSpace = $freeSpace
            RequiredSpace = $RequiredBytes
            Error = $null
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to check disk space: $_" -Level 'Warning'
        return @{
            Success = $false
            HasSpace = $false
            FreeSpace = $null
            RequiredSpace = $RequiredBytes
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-Statistics
# Purpose: Generate statistics report from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-Statistics {
    [CmdletBinding()]
    param()

    try {
        return Get-DatabaseStatistics
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to retrieve statistics: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-PlatformDefaults
# Purpose: Get platform-specific default paths
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-PlatformDefaults {
    [CmdletBinding()]
    param()

    $defaults = @{}

    if ($IsWindows) {
        $defaults['TempPath'] = 'C:\Temp\VideoCompression'
        $defaults['ArchivePath'] = '\\NAS\Archive\Videos'
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '..\..\logs'
    }
    elseif ($IsMacOS) {
        $defaults['TempPath'] = '/tmp/VideoCompression'
        $defaults['ArchivePath'] = '/Volumes/NAS/Archive/Videos'
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }
    elseif ($IsLinux) {
        $defaults['TempPath'] = '/tmp/VideoCompression'
        $defaults['ArchivePath'] = '/mnt/nas/Archive/Videos'
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }
    else {
        # Fallback for unknown platforms
        $defaults['TempPath'] = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'VideoCompression'
        $defaults['ArchivePath'] = '/mnt/archive/Videos'
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }

    return $defaults
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-IllegalCharacters
# Purpose: Get platform-specific illegal filename characters
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-IllegalCharacters {
    [CmdletBinding()]
    param()

    # Use native .NET method to get platform-specific invalid filename characters
    return [System.IO.Path]::GetInvalidFileNameChars()
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-FilenameCharacters
# Purpose: Check if filename contains illegal characters
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-FilenameCharacters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    try {
        $illegalChars = Get-SPVidComp-IllegalCharacters

        # Use character-by-character comparison for reliable detection
        # (String.Contains may not reliably detect all special characters like null)
        $filenameChars = $Filename.ToCharArray()
        $foundIllegal = @()

        foreach ($char in $illegalChars) {
            if ($filenameChars -contains $char) {
                $foundIllegal += $char
            }
        }

        if ($foundIllegal.Count -gt 0) {
            return @{
                Success = $true
                IsValid = $false
                IllegalCharacters = $foundIllegal
                OriginalFilename = $Filename
                Error = $null
            }
        }

        return @{
            Success = $true
            IsValid = $true
            IllegalCharacters = @()
            OriginalFilename = $Filename
            Error = $null
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to test filename characters: $_" -Level 'Error'
        return @{
            Success = $false
            IsValid = $false
            IllegalCharacters = @()
            OriginalFilename = $Filename
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Repair-SPVidComp-Filename
# Purpose: Sanitize filename based on configured strategy
#------------------------------------------------------------------------------------------------------------------
function Repair-SPVidComp-Filename {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Omit', 'Replace', 'Error')]
        [string]$Strategy = 'Replace',

        [Parameter(Mandatory = $false)]
        [string]$ReplacementChar = '_'
    )

    try {
        $test = Test-SPVidComp-FilenameCharacters -Filename $Filename

        if ($test.IsValid) {
            return @{
                Success = $true
                OriginalFilename = $Filename
                SanitizedFilename = $Filename
                Changed = $false
                Error = $null
            }
        }

        # Handle based on strategy
        switch ($Strategy) {
            'Error' {
                return @{
                    Success = $false
                    OriginalFilename = $Filename
                    SanitizedFilename = $null
                    Changed = $false
                    Error = "Filename contains illegal characters: $($test.IllegalCharacters -join ', ')"
                }
            }
            'Omit' {
                # Use character-by-character rebuild for reliable removal
                $chars = $Filename.ToCharArray()
                $illegalList = @($test.IllegalCharacters)
                $sanitizedChars = foreach ($c in $chars) {
                    if ($illegalList -notcontains $c) {
                        $c
                    }
                }
                $sanitized = -join $sanitizedChars

                Write-SPVidComp-Log -Message "Filename sanitized (omit): '$Filename' -> '$sanitized'" -Level 'Info'

                return @{
                    Success = $true
                    OriginalFilename = $Filename
                    SanitizedFilename = $sanitized
                    Changed = $true
                    RemovedCharacters = $test.IllegalCharacters
                    Error = $null
                }
            }
            'Replace' {
                # Use character-by-character rebuild for reliable replacement
                $chars = $Filename.ToCharArray()
                $illegalList = @($test.IllegalCharacters)
                $sanitizedChars = foreach ($c in $chars) {
                    if ($illegalList -contains $c) {
                        $ReplacementChar
                    } else {
                        $c
                    }
                }
                $sanitized = -join $sanitizedChars

                Write-SPVidComp-Log -Message "Filename sanitized (replace): '$Filename' -> '$sanitized'" -Level 'Info'

                return @{
                    Success = $true
                    OriginalFilename = $Filename
                    SanitizedFilename = $sanitized
                    Changed = $true
                    ReplacedCharacters = $test.IllegalCharacters
                    ReplacementChar = $ReplacementChar
                    Error = $null
                }
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to repair filename: $_" -Level 'Error'
        return @{
            Success = $false
            OriginalFilename = $Filename
            SanitizedFilename = $null
            Changed = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-ConfigExists
# Purpose: Check if configuration exists in database
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-ConfigExists {
    [CmdletBinding()]
    param()

    try {
        return Test-ConfigExists
    }
    catch {
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidComp-Config
# Purpose: Retrieve current configuration from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidComp-Config {
    [CmdletBinding()]
    param()

    try {
        return Get-AllConfig
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to retrieve configuration: $_" -Level 'Error'
        return @{}
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidComp-FFmpegAvailability
# Purpose: Check if ffmpeg and ffprobe are available before processing
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidComp-FFmpegAvailability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )

    $result = @{
        FFmpegAvailable = $false
        FFprobeAvailable = $false
        FFmpegVersion = $null
        FFprobeVersion = $null
        FFmpegPath = $null
        FFprobePath = $null
        AllAvailable = $false
        Errors = @()
    }

    try {
        # Test ffmpeg using path helper (checks system PATH and module bin directory)
        try {
            $ffmpegPath = Get-SPVidComp-FFmpegPath
            if ($ffmpegPath) {
                $ffmpegTest = & $ffmpegPath -version 2>&1 | Select-Object -First 1
                if ($ffmpegTest -match 'ffmpeg version') {
                    $result.FFmpegAvailable = $true
                    $result.FFmpegPath = $ffmpegPath
                    if ($Detailed) {
                        $result.FFmpegVersion = $ffmpegTest
                    }
                    Write-SPVidComp-Log -Message "ffmpeg is available at $ffmpegPath : $ffmpegTest" -Level 'Debug'
                }
            }
            else {
                $result.Errors += "ffmpeg not found in system PATH or module bin directory"
                Write-SPVidComp-Log -Message "ffmpeg is not available" -Level 'Warning'
            }
        }
        catch {
            $result.Errors += "ffmpeg not found: $_"
            Write-SPVidComp-Log -Message "ffmpeg is not available: $_" -Level 'Warning'
        }

        # Test ffprobe using path helper (checks system PATH and module bin directory)
        try {
            $ffprobePath = Get-SPVidComp-FFprobePath
            if ($ffprobePath) {
                $ffprobeTest = & $ffprobePath -version 2>&1 | Select-Object -First 1
                if ($ffprobeTest -match 'ffprobe version') {
                    $result.FFprobeAvailable = $true
                    $result.FFprobePath = $ffprobePath
                    if ($Detailed) {
                        $result.FFprobeVersion = $ffprobeTest
                    }
                    Write-SPVidComp-Log -Message "ffprobe is available at $ffprobePath : $ffprobeTest" -Level 'Debug'
                }
            }
            else {
                $result.Errors += "ffprobe not found in system PATH or module bin directory"
                Write-SPVidComp-Log -Message "ffprobe is not available" -Level 'Warning'
            }
        }
        catch {
            $result.Errors += "ffprobe not found: $_"
            Write-SPVidComp-Log -Message "ffprobe is not available: $_" -Level 'Warning'
        }

        $result.AllAvailable = $result.FFmpegAvailable -and $result.FFprobeAvailable

        if ($result.AllAvailable) {
            Write-SPVidComp-Log -Message "All required video processing tools are available" -Level 'Info'
        }
        else {
            Write-SPVidComp-Log -Message "Missing required tools. ffmpeg: $($result.FFmpegAvailable), ffprobe: $($result.FFprobeAvailable)" -Level 'Error'
        }

        return $result
    }
    catch {
        Write-SPVidComp-Log -Message "Error checking ffmpeg/ffprobe availability: $_" -Level 'Error'
        $result.Errors += $_
        return $result
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-SPVidComp-Config
# Purpose: Store configuration in database
#------------------------------------------------------------------------------------------------------------------
function Set-SPVidComp-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigValues
    )

    try {
        foreach ($key in $ConfigValues.Keys) {
            Set-ConfigValue -Key $key -Value $ConfigValues[$key]
        }
        Write-SPVidComp-Log -Message "Configuration saved successfully" -Level 'Info'
        return $true
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to save configuration: $_" -Level 'Error'
        return $false
    }
}

# Export public functions
Export-ModuleMember -Function Initialize-SPVidComp-Config, Connect-SPVidComp-SharePoint, Disconnect-SPVidComp-SharePoint, `
    Initialize-SPVidComp-Catalog, Add-SPVidComp-Video, Get-SPVidComp-Videos, Update-SPVidComp-Status, `
    Get-SPVidComp-Files, Download-SPVidComp-Video, Copy-SPVidComp-Archive, Test-SPVidComp-ArchiveIntegrity, `
    Invoke-SPVidComp-Compression, Test-SPVidComp-VideoIntegrity, Test-SPVidComp-VideoLength, `
    Upload-SPVidComp-Video, Write-SPVidComp-Log, Send-SPVidComp-Notification, Test-SPVidComp-DiskSpace, `
    Get-SPVidComp-Statistics, Test-SPVidComp-ConfigExists, Get-SPVidComp-Config, Set-SPVidComp-Config, `
    Get-SPVidComp-PlatformDefaults, Get-SPVidComp-IllegalCharacters, Test-SPVidComp-FilenameCharacters, `
    Repair-SPVidComp-Filename, Test-SPVidComp-FFmpegAvailability, Install-SPVidComp-FFmpeg
