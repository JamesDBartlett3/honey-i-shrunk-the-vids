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
# Helper Function: New-SPVidCompDirectory
# Purpose: DRY helper to ensure a directory exists, creating it if necessary
#------------------------------------------------------------------------------------------------------------------
function New-SPVidCompDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            Write-SPVidCompLog -Message "Created directory: $Path" -Level 'Debug'
        }
    }
    catch {
        Write-SPVidCompLog -Message "Failed to create directory '$Path': $_" -Level 'Warning'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Helper Function: Get-SPVidCompFFmpegPath
# Purpose: Find ffmpeg executable (system PATH or downloaded)
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompFFmpegPath {
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
# Helper Function: Get-SPVidCompFFprobePath
# Purpose: Find ffprobe executable (system PATH or downloaded)
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompFFprobePath {
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
# Function: Install-SPVidCompFFmpeg
# Purpose: Download and install ffmpeg/ffprobe for current platform
#------------------------------------------------------------------------------------------------------------------
function Install-SPVidCompFFmpeg {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    try {
        # Check if already installed (unless Force)
        if (-not $Force) {
            $ffmpegPath = Get-SPVidCompFFmpegPath
            $ffprobePath = Get-SPVidCompFFprobePath
            if ($ffmpegPath -and $ffprobePath) {
                Write-SPVidCompLog -Message "FFmpeg already available at: $ffmpegPath" -Level 'Info'
                return @{
                    Success = $true
                    FFmpegPath = $ffmpegPath
                    FFprobePath = $ffprobePath
                    Downloaded = $false
                }
            }
        }

        Write-SPVidCompLog -Message "Downloading FFmpeg for current platform..." -Level 'Info'

        # Get download info for current platform
        $downloadInfo = Get-SPVidCompFFmpegDownloadInfo
        if (-not $downloadInfo.Success) {
            return @{
                Success = $false
                Error = $downloadInfo.Error
            }
        }

        # Create bin directory
        New-SPVidCompDirectory -Path $Script:FFmpegBinDir

        # Download to temp location
        $tempPath = [System.IO.Path]::GetTempPath()
        $downloadPath = Join-Path -Path $tempPath -ChildPath $downloadInfo.Filename

        Write-SPVidCompLog -Message "Downloading from: $($downloadInfo.Url)" -Level 'Info'
        Invoke-WebRequest -Uri $downloadInfo.Url -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

        # Extract archive
        Write-SPVidCompLog -Message "Extracting FFmpeg..." -Level 'Info'

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

            Write-SPVidCompLog -Message "Looking for binaries in: $extractedDir" -Level 'Debug'

            # The archive structure might have binaries in a bin/ subdirectory
            $ffmpegBin = Get-ChildItem -Path $extractedDir -Filter 'ffmpeg' -Recurse -File | Select-Object -First 1
            $ffprobeBin = Get-ChildItem -Path $extractedDir -Filter 'ffprobe' -Recurse -File | Select-Object -First 1

            if ($ffmpegBin) {
                $destPath = Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffmpeg'
                Write-SPVidCompLog -Message "Copying ffmpeg from $($ffmpegBin.FullName) to $destPath" -Level 'Debug'
                Copy-Item -LiteralPath $ffmpegBin.FullName -Destination $destPath -Force
                & chmod +x $destPath 2>&1 | Out-Null
            }
            else {
                Write-SPVidCompLog -Message "ffmpeg binary not found in extracted archive" -Level 'Warning'
            }

            if ($ffprobeBin) {
                $destPath = Join-Path -Path $Script:FFmpegBinDir -ChildPath 'ffprobe'
                Write-SPVidCompLog -Message "Copying ffprobe from $($ffprobeBin.FullName) to $destPath" -Level 'Debug'
                Copy-Item -LiteralPath $ffprobeBin.FullName -Destination $destPath -Force
                & chmod +x $destPath 2>&1 | Out-Null
            }
            else {
                Write-SPVidCompLog -Message "ffprobe binary not found in extracted archive" -Level 'Warning'
            }

            # Cleanup
            Remove-Item -Path $extractedDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Cleanup download
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue

        # Verify installation
        $Script:FFmpegPath = $null
        $Script:FFprobePath = $null
        $ffmpegPath = Get-SPVidCompFFmpegPath
        $ffprobePath = Get-SPVidCompFFprobePath

        if ($ffmpegPath -and $ffprobePath) {
            Write-SPVidCompLog -Message "FFmpeg installed successfully to: $Script:FFmpegBinDir" -Level 'Info'
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
        Write-SPVidCompLog -Message "Failed to install FFmpeg: $_" -Level 'Error'
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Helper Function: Get-SPVidCompFFmpegDownloadInfo
# Purpose: Get download URL and filename for current platform
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompFFmpegDownloadInfo {
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
# Function: Initialize-SPVidCompConfig
# Purpose: Load and initialize configuration from database
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidCompConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        # Initialize database first
        $null = Initialize-SPVidCompCatalog -DatabasePath $DatabasePath

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

        Write-SPVidCompLog -Message "Configuration loaded successfully from database" -Level 'Info'

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
# Function: Connect-SPVidCompSharePoint
# Purpose: Authenticate to SharePoint using PnP.PowerShell
#------------------------------------------------------------------------------------------------------------------
function Connect-SPVidCompSharePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )

    try {
        # Check if PnP.PowerShell module is available
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Write-SPVidCompLog -Message "PnP.PowerShell module not found. Installing..." -Level 'Warning'
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
            Write-SPVidCompLog -Message "PnP.PowerShell module installed successfully" -Level 'Info'
        }

        # Import module
        Import-Module PnP.PowerShell -ErrorAction Stop

        # Connect to SharePoint
        Write-SPVidCompLog -Message "Connecting to SharePoint: $SiteUrl" -Level 'Info'
        $Script:SharePointConnection = Connect-PnPOnline -Url $SiteUrl -Interactive -ReturnConnection -ErrorAction Stop

        Write-SPVidCompLog -Message "Successfully connected to SharePoint" -Level 'Info'
        return $Script:SharePointConnection
    }
    catch {
        Write-SPVidCompLog -Message "Failed to connect to SharePoint: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Disconnect-SPVidCompSharePoint
# Purpose: Disconnect from SharePoint and cleanup connection
#------------------------------------------------------------------------------------------------------------------
function Disconnect-SPVidCompSharePoint {
    [CmdletBinding()]
    param()

    try {
        if ($Script:SharePointConnection) {
            Write-SPVidCompLog -Message "Disconnecting from SharePoint..." -Level 'Info'
            Disconnect-PnPOnline -Connection $Script:SharePointConnection -ErrorAction SilentlyContinue
            $Script:SharePointConnection = $null
            Write-SPVidCompLog -Message "Successfully disconnected from SharePoint" -Level 'Info'
            return $true
        }
        else {
            Write-SPVidCompLog -Message "No active SharePoint connection to disconnect" -Level 'Debug'
            return $true
        }
    }
    catch {
        Write-SPVidCompLog -Message "Error disconnecting from SharePoint: $_" -Level 'Warning'
        $Script:SharePointConnection = $null
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-SPVidCompCatalog
# Purpose: Create/open SQLite database
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidCompCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        Initialize-Database -DatabasePath $DatabasePath
        Write-SPVidCompLog -Message "Video catalog initialized" -Level 'Info'
    }
    catch {
        Write-SPVidCompLog -Message "Failed to initialize video catalog: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-SPVidCompVideo
# Purpose: Add video to catalog database
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidCompVideo {
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
            Write-SPVidCompLog -Message "Video added to catalog: $Filename" -Level 'Debug'
        }

        return $result
    }
    catch {
        Write-SPVidCompLog -Message "Failed to add video to catalog: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompVideos
# Purpose: Query videos from catalog by status
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompVideos {
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
        Write-SPVidCompLog -Message "Failed to query videos: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Update-SPVidCompStatus
# Purpose: Update video processing status
#------------------------------------------------------------------------------------------------------------------
function Update-SPVidCompStatus {
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
        Write-SPVidCompLog -Message "Failed to update video status: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompFiles
# Purpose: Scan SharePoint for MP4 files and add to catalog
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompFiles {
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
        Write-SPVidCompLog -Message "Scanning SharePoint library: $LibraryName" -Level 'Info'

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
            $added = Add-SPVidCompVideo -SharePointUrl $fullUrl -SiteUrl $SiteUrl `
                -LibraryName $LibraryName -FolderPath $fileFolderPath -Filename $filename `
                -OriginalSize $fileSize -ModifiedDate $modifiedDate

            if ($added) {
                $catalogedCount++
            }
        }

        Write-SPVidCompLog -Message "Cataloged $catalogedCount videos from $LibraryName" -Level 'Info'
        return $catalogedCount
    }
    catch {
        Write-SPVidCompLog -Message "Failed to scan SharePoint files: $_" -Level 'Error'
        return 0
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Receive-SPVidCompVideo
# Purpose: Download video from SharePoint to temp location
#------------------------------------------------------------------------------------------------------------------
function Receive-SPVidCompVideo {
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
        Write-SPVidCompLog -Message "Downloading video (ID: $VideoId)..." -Level 'Info'

        # Extract server-relative URL
        $uri = [System.Uri]$SharePointUrl
        $serverRelativeUrl = $uri.AbsolutePath

        # Ensure destination directory exists
        $destDir = Split-Path -Path $DestinationPath -Parent
        New-SPVidCompDirectory -Path $destDir

        # Download file
        Get-PnPFile -Url $serverRelativeUrl -Path $destDir -FileName (Split-Path -Path $DestinationPath -Leaf) `
            -AsFile -Force -Connection $Script:SharePointConnection -ErrorAction Stop

        if (Test-Path -LiteralPath $DestinationPath) {
            Write-SPVidCompLog -Message "Video downloaded successfully: $DestinationPath" -Level 'Info'
            return $true
        }
        else {
            Write-SPVidCompLog -Message "Download failed: File not found at destination" -Level 'Error'
            return $false
        }
    }
    catch {
        Write-SPVidCompLog -Message "Failed to download video: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Copy-SPVidCompArchive
# Purpose: Copy video to archive storage with hash verification
#------------------------------------------------------------------------------------------------------------------
function Copy-SPVidCompArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    try {
        Write-SPVidCompLog -Message "Archiving video to: $ArchivePath" -Level 'Info'

        # Ensure archive directory exists
        $archiveDir = Split-Path -Path $ArchivePath -Parent
        New-SPVidCompDirectory -Path $archiveDir

        # Copy file
        Copy-Item -LiteralPath $SourcePath -Destination $ArchivePath -Force -ErrorAction Stop

        # Verify copy with hash
        $verified = Test-SPVidCompArchiveIntegrity -SourcePath $SourcePath -DestinationPath $ArchivePath

        if ($verified.Success) {
            Write-SPVidCompLog -Message "Video archived and verified successfully" -Level 'Info'
            return @{
                Success = $true
                ArchivePath = $ArchivePath
                SourceHash = $verified.SourceHash
                DestinationHash = $verified.DestinationHash
                Error = $null
            }
        }
        else {
            Write-SPVidCompLog -Message "Archive verification failed: Hash mismatch" -Level 'Error'
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
        Write-SPVidCompLog -Message "Failed to archive video: $_" -Level 'Error'
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompArchiveIntegrity
# Purpose: Verify archive copy using SHA256 hash
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompArchiveIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    try {
        Write-SPVidCompLog -Message "Verifying archive integrity..." -Level 'Info'

        # Calculate hashes
        $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        $destHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash

        $success = ($sourceHash -eq $destHash)

        if ($success) {
            Write-SPVidCompLog -Message "Archive integrity verified: Hashes match" -Level 'Info'
        }
        else {
            Write-SPVidCompLog -Message "Archive integrity check failed: Hash mismatch" -Level 'Error'
        }

        return @{
            Success = $success
            SourceHash = $sourceHash
            DestinationHash = $destHash
            Error = $null
        }
    }
    catch {
        Write-SPVidCompLog -Message "Failed to verify archive integrity: $_" -Level 'Error'
        return @{
            Success = $false
            SourceHash = $null
            DestinationHash = $null
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Invoke-SPVidCompCompression
# Purpose: Compress video using ffmpeg
#------------------------------------------------------------------------------------------------------------------
function Invoke-SPVidCompCompression {
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
        Write-SPVidCompLog -Message "Compressing video: $InputPath (timeout: $TimeoutMinutes minutes)" -Level 'Info'

        # Get ffmpeg path
        $ffmpegPath = Get-SPVidCompFFmpegPath
        if (-not $ffmpegPath) {
            Write-SPVidCompLog -Message "FFmpeg not found. Attempting automatic installation..." -Level 'Warning'
            $installResult = Install-SPVidCompFFmpeg
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
        Write-SPVidCompLog -Message "Executing: $ffmpegCommand" -Level 'Debug'

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
            Write-SPVidCompLog -Message "Compression timed out after $TimeoutMinutes minutes" -Level 'Error'

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

            Write-SPVidCompLog -Message "Compression completed successfully. Ratio: $ratio" -Level 'Info'

            return @{
                Success = $true
                InputSize = $inputSize
                OutputSize = $outputSize
                CompressionRatio = $ratio
                Error = $null
            }
        }
        else {
            Write-SPVidCompLog -Message "Compression failed. Exit code: $($process.ExitCode). Error: $errorOutput" -Level 'Error'

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
        Write-SPVidCompLog -Message "Failed to compress video: $_" -Level 'Error'
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
# Function: Test-SPVidCompVideoIntegrity
# Purpose: Verify video is not corrupted using ffprobe
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompVideoIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )

    try {
        Write-SPVidCompLog -Message "Verifying video integrity: $VideoPath" -Level 'Debug'

        # Get ffprobe path
        $ffprobePath = Get-SPVidCompFFprobePath
        if (-not $ffprobePath) {
            Write-SPVidCompLog -Message "FFprobe not found. Attempting automatic installation..." -Level 'Warning'
            $installResult = Install-SPVidCompFFmpeg
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
            Write-SPVidCompLog -Message "Video integrity verified: No corruption detected" -Level 'Debug'
            return @{
                Success = $true
                IsValid = $true
                Error = $null
            }
        }
        else {
            Write-SPVidCompLog -Message "Video integrity check failed: $errorOutput" -Level 'Error'

            return @{
                Success = $false
                IsValid = $false
                Error = $errorOutput
            }
        }
    }
    catch {
        Write-SPVidCompLog -Message "Failed to verify video integrity: $_" -Level 'Error'
        return @{
            Success = $false
            IsValid = $false
            Error = $_.Exception.Message
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompVideoLength
# Purpose: Get video duration and compare original vs compressed
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompVideoLength {
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
        Write-SPVidCompLog -Message "Comparing video durations..." -Level 'Debug'

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
            Write-SPVidCompLog -Message "Video durations match (difference: $difference seconds)" -Level 'Info'
        }
        else {
            Write-SPVidCompLog -Message "Video duration mismatch: Original=$originalDuration, Compressed=$compressedDuration" -Level 'Warning'
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
        Write-SPVidCompLog -Message "Failed to compare video lengths: $_" -Level 'Error'
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
        $ffprobePath = Get-SPVidCompFFprobePath
        if (-not $ffprobePath) {
            Write-SPVidCompLog -Message "FFprobe not found for duration check" -Level 'Warning'
            return $null
        }

        $output = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$VideoPath`"" 2>&1

        if ($LASTEXITCODE -eq 0) {
            return [double]$output
        }
        else {
            Write-SPVidCompLog -Message "Failed to get video duration: $output" -Level 'Warning'
            return $null
        }
    }
    catch {
        Write-SPVidCompLog -Message "Error getting video duration: $_" -Level 'Warning'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Send-SPVidCompVideo
# Purpose: Upload compressed video back to SharePoint
#------------------------------------------------------------------------------------------------------------------
function Send-SPVidCompVideo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl
    )

    try {
        Write-SPVidCompLog -Message "Uploading compressed video to SharePoint..." -Level 'Info'

        # Extract server-relative URL
        $uri = [System.Uri]$SharePointUrl
        $serverRelativeUrl = $uri.AbsolutePath
        $folderPath = Split-Path -Path $serverRelativeUrl -Parent
        $filename = Split-Path -Path $serverRelativeUrl -Leaf

        # Upload file (overwrite existing)
        Add-PnPFile -Path $LocalPath -Folder $folderPath -Connection $Script:SharePointConnection -ErrorAction Stop

        Write-SPVidCompLog -Message "Video uploaded successfully to SharePoint" -Level 'Info'
        return $true
    }
    catch {
        Write-SPVidCompLog -Message "Failed to upload video: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Write-SPVidCompLog
# Purpose: Logging wrapper
#------------------------------------------------------------------------------------------------------------------
function Write-SPVidCompLog {
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
# Function: Send-SPVidCompNotification
# Purpose: Send email notification
#------------------------------------------------------------------------------------------------------------------
function Send-SPVidCompNotification {
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
        Write-SPVidCompLog -Message "Failed to send notification: $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompDiskSpace
# Purpose: Check available disk space
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompDiskSpace {
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
                Write-SPVidCompLog -Message "Created directory for disk space check: $Path" -Level 'Info'
            }
            catch {
                # If we can't create it, use the parent directory that exists
                $parent = Split-Path -Path $Path -Parent
                while ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    $parent = Split-Path -Path $parent -Parent
                }
                if ($parent) {
                    $pathToCheck = $parent
                    Write-SPVidCompLog -Message "Using parent directory for disk space check: $pathToCheck" -Level 'Info'
                } else {
                    # Fall back to the root of the path
                    $pathToCheck = [System.IO.Path]::GetPathRoot($Path)
                    Write-SPVidCompLog -Message "Using root path for disk space check: $pathToCheck" -Level 'Info'
                }
            }
        }

        $drive = (Get-Item -LiteralPath $pathToCheck).PSDrive
        $freeSpace = $drive.Free

        $hasSpace = ($freeSpace -ge $RequiredBytes)

        if (-not $hasSpace) {
            $requiredGB = [math]::Round($RequiredBytes / 1GB, 2)
            $freeGB = [math]::Round($freeSpace / 1GB, 2)
            Write-SPVidCompLog -Message "Insufficient disk space: Required=$requiredGB GB, Available=$freeGB GB" -Level 'Warning'
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
        Write-SPVidCompLog -Message "Failed to check disk space: $_" -Level 'Warning'
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
# Function: Get-SPVidCompStatistics
# Purpose: Generate statistics report from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompStatistics {
    [CmdletBinding()]
    param()

    try {
        return Get-DatabaseStatistics
    }
    catch {
        Write-SPVidCompLog -Message "Failed to retrieve statistics: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompPlatformDefaults
# Purpose: Get platform-specific default paths
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompPlatformDefaults {
    [CmdletBinding()]
    param()

    $defaults = @{}

    # Use cross-platform temp path
    $systemTempPath = [System.IO.Path]::GetTempPath()
    $defaults['TempPath'] = Join-Path -Path $systemTempPath -ChildPath 'VideoCompression'

    # Platform-specific log paths (relative to module location)
    if ($IsWindows) {
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '..\..\logs'
    }
    elseif ($IsMacOS) {
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }
    elseif ($IsLinux) {
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }
    else {
        # Fallback for unknown platforms
        $defaults['LogPath'] = Join-Path -Path $PSScriptRoot -ChildPath '../../logs'
    }

    return $defaults
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompIllegalCharacters
# Purpose: Get platform-specific illegal filename characters
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompIllegalCharacters {
    [CmdletBinding()]
    param()

    # Use native .NET method to get platform-specific invalid filename characters
    return [System.IO.Path]::GetInvalidFileNameChars()
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompFilenameCharacters
# Purpose: Check if filename contains illegal characters
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompFilenameCharacters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filename
    )

    try {
        $illegalChars = Get-SPVidCompIllegalCharacters

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
        Write-SPVidCompLog -Message "Failed to test filename characters: $_" -Level 'Error'
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
# Function: Repair-SPVidCompFilename
# Purpose: Sanitize filename based on configured strategy
#------------------------------------------------------------------------------------------------------------------
function Repair-SPVidCompFilename {
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
        $test = Test-SPVidCompFilenameCharacters -Filename $Filename

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

                Write-SPVidCompLog -Message "Filename sanitized (omit): '$Filename' -> '$sanitized'" -Level 'Info'

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

                Write-SPVidCompLog -Message "Filename sanitized (replace): '$Filename' -> '$sanitized'" -Level 'Info'

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
        Write-SPVidCompLog -Message "Failed to repair filename: $_" -Level 'Error'
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
# Function: Test-SPVidCompConfigExists
# Purpose: Check if configuration exists in database
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompConfigExists {
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
# Function: Get-SPVidCompConfig
# Purpose: Retrieve current configuration from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompConfig {
    [CmdletBinding()]
    param()

    try {
        return Get-AllConfig
    }
    catch {
        Write-SPVidCompLog -Message "Failed to retrieve configuration: $_" -Level 'Error'
        return @{}
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompFFmpegAvailability
# Purpose: Check if ffmpeg and ffprobe are available before processing
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompFFmpegAvailability {
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
            $ffmpegPath = Get-SPVidCompFFmpegPath
            if ($ffmpegPath) {
                $ffmpegTest = & $ffmpegPath -version 2>&1 | Select-Object -First 1
                if ($ffmpegTest -match 'ffmpeg version') {
                    $result.FFmpegAvailable = $true
                    $result.FFmpegPath = $ffmpegPath
                    if ($Detailed) {
                        $result.FFmpegVersion = $ffmpegTest
                    }
                    Write-SPVidCompLog -Message "ffmpeg is available at $ffmpegPath : $ffmpegTest" -Level 'Debug'
                }
            }
            else {
                $result.Errors += "ffmpeg not found in system PATH or module bin directory"
                Write-SPVidCompLog -Message "ffmpeg is not available" -Level 'Warning'
            }
        }
        catch {
            $result.Errors += "ffmpeg not found: $_"
            Write-SPVidCompLog -Message "ffmpeg is not available: $_" -Level 'Warning'
        }

        # Test ffprobe using path helper (checks system PATH and module bin directory)
        try {
            $ffprobePath = Get-SPVidCompFFprobePath
            if ($ffprobePath) {
                $ffprobeTest = & $ffprobePath -version 2>&1 | Select-Object -First 1
                if ($ffprobeTest -match 'ffprobe version') {
                    $result.FFprobeAvailable = $true
                    $result.FFprobePath = $ffprobePath
                    if ($Detailed) {
                        $result.FFprobeVersion = $ffprobeTest
                    }
                    Write-SPVidCompLog -Message "ffprobe is available at $ffprobePath : $ffprobeTest" -Level 'Debug'
                }
            }
            else {
                $result.Errors += "ffprobe not found in system PATH or module bin directory"
                Write-SPVidCompLog -Message "ffprobe is not available" -Level 'Warning'
            }
        }
        catch {
            $result.Errors += "ffprobe not found: $_"
            Write-SPVidCompLog -Message "ffprobe is not available: $_" -Level 'Warning'
        }

        $result.AllAvailable = $result.FFmpegAvailable -and $result.FFprobeAvailable

        if ($result.AllAvailable) {
            Write-SPVidCompLog -Message "All required video processing tools are available" -Level 'Info'
        }
        else {
            Write-SPVidCompLog -Message "Missing required tools. ffmpeg: $($result.FFmpegAvailable), ffprobe: $($result.FFprobeAvailable)" -Level 'Error'
        }

        return $result
    }
    catch {
        Write-SPVidCompLog -Message "Error checking ffmpeg/ffprobe availability: $_" -Level 'Error'
        $result.Errors += $_
        return $result
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-SPVidCompConfig
# Purpose: Store configuration in database
#------------------------------------------------------------------------------------------------------------------
function Set-SPVidCompConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigValues
    )

    try {
        $result = Set-Config -ConfigValues $ConfigValues
        if ($result) {
            Write-SPVidCompLog -Message "Configuration saved successfully" -Level 'Info'
        }
        return $result
    }
    catch {
        Write-SPVidCompLog -Message "Failed to save configuration: $_" -Level 'Error'
        return $false
    }
}

# Export public functions
Export-ModuleMember -Function Initialize-SPVidCompConfig, Connect-SPVidCompSharePoint, Disconnect-SPVidCompSharePoint, `
    Initialize-SPVidCompCatalog, Add-SPVidCompVideo, Get-SPVidCompVideos, Update-SPVidCompStatus, `
    Get-SPVidCompFiles, Receive-SPVidCompVideo, Copy-SPVidCompArchive, Test-SPVidCompArchiveIntegrity, `
    Invoke-SPVidCompCompression, Test-SPVidCompVideoIntegrity, Test-SPVidCompVideoLength, `
    Send-SPVidCompVideo, Write-SPVidCompLog, Send-SPVidCompNotification, Test-SPVidCompDiskSpace, `
    Get-SPVidCompStatistics, Test-SPVidCompConfigExists, Get-SPVidCompConfig, Set-SPVidCompConfig, `
    Get-SPVidCompPlatformDefaults, Get-SPVidCompIllegalCharacters, Test-SPVidCompFilenameCharacters, `
    Repair-SPVidCompFilename, Test-SPVidCompFFmpegAvailability, Install-SPVidCompFFmpeg
