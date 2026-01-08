#------------------------------------------------------------------------------------------------------------------
# TestHelper.ps1 - Common test utilities and setup for Pester tests
#------------------------------------------------------------------------------------------------------------------

# Get the project root directory
$Script:ProjectRoot = Split-Path -Path $PSScriptRoot -Parent
$Script:ModulePath = Join-Path -Path $ProjectRoot -ChildPath 'modules\VideoCompressionModule'
$Script:PrivatePath = Join-Path -Path $ModulePath -ChildPath 'Private'

# Get cross-platform temp directory
$Script:TempPath = [System.IO.Path]::GetTempPath()

# Test database path (in-memory or temp file)
$Script:TestDatabasePath = Join-Path -Path $Script:TempPath -ChildPath "test-video-catalog-$(Get-Random).db"

# Global test database path (for tests that expect this variable name)
$Script:GlobalTestDbPath = $Script:TestDatabasePath

# Test log path
$Script:TestLogPath = Join-Path -Path $Script:TempPath -ChildPath "test-logs-$(Get-Random)"

#------------------------------------------------------------------------------------------------------------------
# Function: Import-TestModule
# Purpose: Import the module for testing
#------------------------------------------------------------------------------------------------------------------
function Import-TestModule {
    [CmdletBinding()]
    param()

    # Import the main module (which imports private scripts internally)
    Import-Module (Join-Path -Path $Script:ModulePath -ChildPath 'VideoCompressionModule.psm1') -Force -Global
}

#------------------------------------------------------------------------------------------------------------------
# Function: New-TestDatabase
# Purpose: Create a fresh test database
#------------------------------------------------------------------------------------------------------------------
function New-TestDatabase {
    [CmdletBinding()]
    param(
        [string]$Path = $Script:TestDatabasePath
    )

    # Remove existing test database
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    return $Path
}

#------------------------------------------------------------------------------------------------------------------
# Function: Remove-TestDatabase
# Purpose: Clean up test database
#------------------------------------------------------------------------------------------------------------------
function Remove-TestDatabase {
    [CmdletBinding()]
    param(
        [string]$Path = $Script:TestDatabasePath
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: New-TestLogDirectory
# Purpose: Create a fresh test log directory
#------------------------------------------------------------------------------------------------------------------
function New-TestLogDirectory {
    [CmdletBinding()]
    param(
        [string]$Path = $Script:TestLogPath
    )

    # Remove existing test log directory
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    return $Path
}

#------------------------------------------------------------------------------------------------------------------
# Function: Remove-TestLogDirectory
# Purpose: Clean up test log directory
#------------------------------------------------------------------------------------------------------------------
function Remove-TestLogDirectory {
    [CmdletBinding()]
    param(
        [string]$Path = $Script:TestLogPath
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-TestVideoRecord
# Purpose: Create a sample video record for testing
#------------------------------------------------------------------------------------------------------------------
function Get-TestVideoRecord {
    [CmdletBinding()]
    param(
        [string]$Filename = "test-video-$(Get-Random).mp4",
        [long]$Size = 104857600,  # 100 MB
        [string]$SiteUrl = 'https://contoso.sharepoint.com/sites/TestSite',
        [string]$LibraryName = 'Documents',
        [string]$FolderPath = '/Videos/2024'
    )

    return @{
        SharePointUrl = "$SiteUrl/$LibraryName$FolderPath/$Filename"
        SiteUrl = $SiteUrl
        LibraryName = $LibraryName
        FolderPath = $FolderPath
        Filename = $Filename
        OriginalSize = $Size
        ModifiedDate = (Get-Date).AddDays(-7)
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: New-MockVideoFile
# Purpose: Create a mock video file for testing (small file, not actual video)
#------------------------------------------------------------------------------------------------------------------
function New-MockVideoFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$SizeKB = 10
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Create a file with random content
    $bytes = New-Object byte[] ($SizeKB * 1024)
    [System.Random]::new().NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($Path, $bytes)

    return $Path
}

#------------------------------------------------------------------------------------------------------------------
# Function: Remove-MockVideoFile
# Purpose: Clean up mock video file
#------------------------------------------------------------------------------------------------------------------
function Remove-MockVideoFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-TestConfig
# Purpose: Returns a complete test configuration with all required fields
#------------------------------------------------------------------------------------------------------------------
function Get-TestConfig {
    [CmdletBinding()]
    param()

    return @{
        'scope_mode' = 'Single'
        'admin_site_url' = ''
        'paths_temp_download' = '/tmp/test'
        'paths_external_archive' = '/tmp/archive'
        'compression_frame_rate' = '10'
        'compression_video_codec' = 'libx265'
        'compression_timeout_minutes' = '60'
        'processing_max_parallel_jobs' = '2'
        'processing_retry_attempts' = '3'
        'processing_required_disk_space_gb' = '50'
        'processing_duration_tolerance_seconds' = '1'
        'resume_enable' = 'True'
        'resume_skip_processed' = 'True'
        'resume_reprocess_failed' = 'True'
        'email_enabled' = 'False'
        'email_smtp_server' = 'smtp.test.com'
        'email_smtp_port' = '587'
        'email_use_ssl' = 'True'
        'email_from' = 'test@test.com'
        'email_to' = 'admin@test.com'
        'email_send_on_completion' = 'True'
        'email_send_on_error' = 'True'
        'logging_log_level' = 'Info'
        'logging_console_output' = 'False'
        'logging_retention_days' = '30'
        'advanced_cleanup_temp_files' = 'True'
        'advanced_verify_checksums' = 'True'
        'advanced_dry_run' = 'False'
        'illegal_char_strategy' = 'Replace'
        'illegal_char_replacement' = '_'
    }
}

# Note: This file is dot-sourced, not imported as a module.
# All functions and variables defined here are available in the calling scope.
