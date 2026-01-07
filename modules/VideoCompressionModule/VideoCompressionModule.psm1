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
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

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
        if (-not (Test-Path -LiteralPath $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        }

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
        $sourceHash = (Get-FileHash -Path $SourcePath -Algorithm SHA256).Hash
        $destHash = (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash

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
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to verify archive integrity: $_" -Level 'Error'
        return @{
            Success = $false
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
        Write-SPVidComp-Log -Message "Compressing video: $InputPath" -Level 'Info'

        # Build ffmpeg command
        $ffmpegArgs = @(
            '-hwaccel', 'auto',
            '-i', "`"$InputPath`"",
            '-vf', "fps=$FrameRate",
            '-c:v', $VideoCodec,
            '-ac', '1',
            '-ar', '22050',
            "`"$OutputPath`""
        )

        $ffmpegCommand = "ffmpeg $($ffmpegArgs -join ' ')"

        Write-SPVidComp-Log -Message "Executing: $ffmpegCommand" -Level 'Debug'

        # Execute ffmpeg
        $process = Start-Process -FilePath 'ffmpeg' -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\ffmpeg-error.log"

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
            }
        }
        else {
            $errorLog = Get-Content -LiteralPath "$env:TEMP\ffmpeg-error.log" -Raw -ErrorAction SilentlyContinue
            Write-SPVidComp-Log -Message "Compression failed. Exit code: $($process.ExitCode). Error: $errorLog" -Level 'Error'

            return @{
                Success = $false
                Error = "ffmpeg exited with code $($process.ExitCode)"
                ErrorLog = $errorLog
            }
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to compress video: $_" -Level 'Error'
        return @{
            Success = $false
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

        # Run ffprobe to check video
        $process = Start-Process -FilePath 'ffprobe' -ArgumentList @('-v', 'error', "`"$VideoPath`"") `
            -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\ffprobe-error.log"

        if ($process.ExitCode -eq 0) {
            Write-SPVidComp-Log -Message "Video integrity verified: No corruption detected" -Level 'Debug'
            return @{
                Success = $true
                IsValid = $true
            }
        }
        else {
            $errorLog = Get-Content -LiteralPath "$env:TEMP\ffprobe-error.log" -Raw -ErrorAction SilentlyContinue
            Write-SPVidComp-Log -Message "Video integrity check failed: $errorLog" -Level 'Error'

            return @{
                Success = $false
                IsValid = $false
                Error = $errorLog
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
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to compare video lengths: $_" -Level 'Error'
        return @{
            Success = $false
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
        $output = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "`"$VideoPath`"" 2>&1

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
        $drive = (Get-Item -LiteralPath $Path).PSDrive
        $freeSpace = $drive.Free

        $hasSpace = ($freeSpace -ge $RequiredBytes)

        if (-not $hasSpace) {
            $requiredGB = [math]::Round($RequiredBytes / 1GB, 2)
            $freeGB = [math]::Round($freeSpace / 1GB, 2)
            Write-SPVidComp-Log -Message "Insufficient disk space: Required=$requiredGB GB, Available=$freeGB GB" -Level 'Warning'
        }

        return @{
            HasSpace = $hasSpace
            FreeSpace = $freeSpace
            RequiredSpace = $RequiredBytes
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to check disk space: $_" -Level 'Warning'
        return @{
            HasSpace = $false
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
                IsValid = $false
                IllegalCharacters = $foundIllegal
                OriginalFilename = $Filename
            }
        }

        return @{
            IsValid = $true
            IllegalCharacters = @()
            OriginalFilename = $Filename
        }
    }
    catch {
        Write-SPVidComp-Log -Message "Failed to test filename characters: $_" -Level 'Error'
        return @{
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
Export-ModuleMember -Function Initialize-SPVidComp-Config, Connect-SPVidComp-SharePoint, `
    Initialize-SPVidComp-Catalog, Add-SPVidComp-Video, Get-SPVidComp-Videos, Update-SPVidComp-Status, `
    Get-SPVidComp-Files, Download-SPVidComp-Video, Copy-SPVidComp-Archive, Test-SPVidComp-ArchiveIntegrity, `
    Invoke-SPVidComp-Compression, Test-SPVidComp-VideoIntegrity, Test-SPVidComp-VideoLength, `
    Upload-SPVidComp-Video, Write-SPVidComp-Log, Send-SPVidComp-Notification, Test-SPVidComp-DiskSpace, `
    Get-SPVidComp-Statistics, Test-SPVidComp-ConfigExists, Get-SPVidComp-Config, Set-SPVidComp-Config, `
    Get-SPVidComp-PlatformDefaults, Get-SPVidComp-IllegalCharacters, Test-SPVidComp-FilenameCharacters, `
    Repair-SPVidComp-Filename
