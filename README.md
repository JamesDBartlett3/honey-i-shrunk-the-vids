# SharePoint Video Compression & Archival Automation

Automate the process of scanning SharePoint for MP4 videos, compressing them using ffmpeg, and archiving originals to external storage with comprehensive verification.

## Features

- **Cross-Platform Compatible**: Runs on Windows, macOS, and Linux (PowerShell 7.0+)
- **Parallel Video Processing**: Process multiple videos concurrently (1-8 jobs) for dramatically faster batch operations
- **Two-Phase Approach**: Catalog all videos first, then process them systematically
- **SQLite Catalog**: Persistent database tracking with resume capability
- **Safety-First Design**: Archive and verify BEFORE compression
- **Hash Verification**: SHA256 verification of archived copies
- **Integrity Checking**: ffprobe verification to detect corruption
- **Duration Validation**: Ensure compressed videos match original length
- **Illegal Character Handling**: Automatic filename sanitization with configurable strategies
- **Email Notifications**: Automated reports on completion and errors (OAuth 2.0 with MFA support)
- **Progress Tracking**: Resume from any interruption
- **Comprehensive Logging**: Detailed logs with rotation

## Multi-Scope Configuration

The solution supports flexible video discovery across different organizational boundaries. You can choose from four scope levels during setup:

### Scope Modes

1. **Single Library** (Default)
   - Scan one specific document library
   - Ideal for targeted compression jobs
   - Fastest setup for focused tasks

2. **Site-Wide**
   - Select multiple libraries from a single SharePoint site
   - Useful for site-level video management
   - Process all video-containing libraries in one site

3. **Multiple Sites**
   - Choose specific libraries from multiple sites
   - Flexible cross-site video management
   - Great for departmental or regional rollouts

4. **Tenant-Wide**
   - Discover and select from all sites in your SharePoint tenant
   - **Requires SharePoint Admin permissions**
   - Admin URL format: `https://[tenant]-admin.sharepoint.com`
   - Ideal for organization-wide video optimization

### Interactive Selection

The setup wizard uses **Microsoft.PowerShell.ConsoleGuiTools** for an intuitive selection experience:
- Navigate with ↑↓ arrow keys
- Select/deselect items with Space bar
- Filter by typing keywords
- Confirm selections with Enter
- Multi-select support for sites and libraries

The module is automatically installed if not present.

### Setup Example

```powershell
# Run setup wizard
.\Compress-SharePointVideos.ps1 -Setup

# Choose scope mode (1-4)
# For Single Library:
#   1. Enter site URL
#   2. Select library from interactive grid
#   3. Optional: specify folder path within library
#   4. Choose recursive scanning (Y/n)

# For Tenant-Wide:
#   1. Enter SharePoint Admin Center URL
#   2. Wait for site discovery (may take 30s-2min for large tenants)
#   3. Select sites from grid (Space to select, Enter to confirm)
#   4. For each selected site, choose libraries
#   5. Review final configuration

# Run catalog phase across all configured scopes
.\Compress-SharePointVideos.ps1 -Phase Catalog

# Process videos from all scopes
.\Compress-SharePointVideos.ps1 -Phase Process
```

### Managing Scopes

After setup, your configured scopes are displayed when running the script:

```powershell
.\Compress-SharePointVideos.ps1

# Output shows:
# SharePoint Settings:
#   Scope Mode         : Multiple
#
#   Configured Scopes  : 3
#     [1] Documents @ contoso.sharepoint.com/sites/Marketing (25 videos, 2.5 GB)
#     [2] Videos @ contoso.sharepoint.com/sites/Sales (18 videos, 1.8 GB)
#     [3] Shared Documents @ contoso.sharepoint.com/sites/HR (not yet scanned)
```

Each scope is scanned independently during the catalog phase. Videos are tagged with their source scope for tracking and reporting.

### Note on Database Reset

If you have an existing development database and want to reconfigure scopes, simply delete the database and re-run setup:

```powershell
# Remove old database
Remove-Item data/video-catalog.db -ErrorAction SilentlyContinue

# Run setup with new multi-scope configuration
.\Compress-SharePointVideos.ps1 -Setup
```

## Prerequisites

### Required Software
- **PowerShell 7.0 or higher** - For cross-platform compatibility ([Download here](https://github.com/PowerShell/PowerShell/releases))
- **ffmpeg** - For video compression ([Download here](https://ffmpeg.org/download.html))
- **ffprobe** - For video verification (included with ffmpeg)

### Required PowerShell Modules
The following modules will be automatically installed if missing:
- **PnP.PowerShell** - SharePoint Online authentication and operations
- **PSSQLite** - SQLite database operations
- **Microsoft.PowerShell.ConsoleGuiTools** - Interactive site/library selection during setup

### Network & Access
- Network access to SharePoint Online tenant
- Write access to external archive storage path
- Sufficient disk space for temporary files (3x largest video recommended)

## Cross-Platform Compatibility

This solution is built on PowerShell 7.0+ and runs on **Windows**, **macOS**, and **Linux**.

### Installing PowerShell 7+

If you don't have PowerShell 7.0 or higher installed:

**Windows:**
```powershell
winget install --id Microsoft.Powershell --source winget
```

**macOS:**
```bash
brew install --cask powershell
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt-get update
sudo apt-get install -y powershell
```

For other platforms, see the [official installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell).

### Platform Detection

The setup wizard automatically detects your platform and provides appropriate default paths for temporary files, archive storage, and logs.

## Installation

### 1. Install ffmpeg

Download and install ffmpeg from [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)

Ensure `ffmpeg` and `ffprobe` are accessible in your PATH:

```powershell
ffmpeg -version
ffprobe -version
```

### 2. Clone/Download This Repository

```powershell
# Navigate to the project directory
cd C:\AzDO\honey-i-shrunk-the-vids
```

### 3. Run First-Time Setup

On first launch, the script will automatically run the interactive setup wizard:

```powershell
.\Compress-SharePointVideos.ps1
```

Or explicitly run setup:

```powershell
.\Compress-SharePointVideos.ps1 -Setup
```

The setup wizard will prompt you for all necessary configuration:
- **SharePoint Scope Configuration**: Choose scope mode (Single/Site/Multiple/Tenant) and select sites/libraries interactively
- **File Paths**: Temp download, external archive, logs (with platform-aware defaults)
- **Compression Settings**: Frame rate, codec, timeout
- **Processing Settings**: Max parallel jobs, retry attempts, disk space requirements
- **Illegal Character Handling**: Strategy for filenames with illegal characters
- **Email Notifications**: SMTP settings (optional)
- **Logging Settings**: Log level, output options

All configuration is stored in the SQLite database (`data/video-catalog.db`).

### 4. Verify Setup

After setup completes, you can run the script normally. It will display your current settings and ask for confirmation before proceeding:

```powershell
.\Compress-SharePointVideos.ps1
```

## Usage

### First Time Setup

On first launch (or with `-Setup` parameter), run the interactive setup wizard:

```powershell
.\Compress-SharePointVideos.ps1 -Setup
```

### Normal Execution

After initial setup, run the script normally:

```powershell
.\Compress-SharePointVideos.ps1
```

The script will:
1. Display current configuration
2. Ask if you want to proceed, modify settings, or quit
3. Execute the selected phase(s)

#### Interactive Menu Options:
- **[P] Proceed** - Continue with current settings
- **[M] Modify** - Re-run setup wizard to change settings
- **[Q] Quit** - Exit without running

### Phase-Specific Execution

**Catalog Only** (Discover videos without processing):
```powershell
.\Compress-SharePointVideos.ps1 -Phase Catalog
```

**Process Only** (Process previously cataloged videos):
```powershell
.\Compress-SharePointVideos.ps1 -Phase Process
```

**Run Both Phases** (default):
```powershell
.\Compress-SharePointVideos.ps1 -Phase Both
```

### Dry Run Mode

Test the workflow without making changes:
```powershell
.\Compress-SharePointVideos.ps1 -DryRun
```

### Modifying Configuration

To change settings after initial setup:

```powershell
.\Compress-SharePointVideos.ps1 -Setup
```

Or select **[M] Modify** when the script starts normally.

### Custom Database Path

By default, the database is stored at `data/video-catalog.db`. To use a different location:

```powershell
.\Compress-SharePointVideos.ps1 -DatabasePath "C:\Custom\Path\video-catalog.db"
```

## Workflow

### Phase 1: Catalog Discovery

1. Connect to SharePoint using interactive authentication
2. Scan specified libraries for MP4 files
3. Store metadata in SQLite database:
   - SharePoint URL
   - Filename, size, modified date
   - Site and library information
4. Display catalog statistics

### Phase 2: Video Processing

For each cataloged video:

1. **Download** - Retrieve original from SharePoint to temp location
2. **Archive** - Copy to external storage with SHA256 hash verification
3. **Compress** - Use ffmpeg to compress with configured settings
4. **Verify Integrity** - Use ffprobe to detect corruption
5. **Validate Duration** - Ensure compressed duration matches original
6. **Upload** - Replace original in SharePoint with compressed version
7. **Cleanup** - Remove temporary files

If any step fails, the video is marked as failed and the original is preserved.

## Safety Features

### Archive Verification
- Original is copied to external storage **BEFORE** compression
- SHA256 hash comparison ensures perfect copy
- Process aborts if verification fails

### Integrity Checking
- ffprobe validates video is not corrupted
- Duration comparison (±1 second tolerance)
- File size validation (not 0 bytes, reasonable compression)

### Resume Capability
- SQLite database tracks status of each video
- Interrupted runs can resume from last successful step
- Failed videos can be retried up to configured limit

### Error Handling
- Try-Catch blocks on all operations
- Detailed error logging
- Email notifications on failures
- Originals preserved on any error

## Configuration

### Configuration Storage

All configuration is stored in the SQLite database (`data/video-catalog.db`) as key-value pairs. No separate configuration file is needed.

### Configuration Categories

The interactive setup wizard collects configuration in these categories:

#### SharePoint Scope Settings
- **Scope Mode**: Discovery scope (Single/Site/Multiple/Tenant)
- **Admin Site URL**: SharePoint Admin Center URL (Tenant mode only)
- **Configured Scopes**: One or more site/library combinations selected interactively
  - Each scope includes: Site URL, Library Name, optional Folder Path, Recursive flag
- **Interactive Selection**: Use ConsoleGuiTools grid for intuitive site/library selection

#### File Paths
- **Temp Download Path**: Local temporary storage
- **External Archive Path**: Network/external storage for originals
- **Log Path**: Directory for log files

**Platform-Specific Defaults:**
- **Windows**:
  - Temp: `C:\Temp\VideoCompression`
  - Archive: `\\NAS\Archive\Videos`
  - Logs: `.\logs`
- **macOS**:
  - Temp: `/tmp/VideoCompression`
  - Archive: `/Volumes/NAS/Archive/Videos`
  - Logs: `./logs`
- **Linux**:
  - Temp: `/tmp/VideoCompression`
  - Archive: `/mnt/nas/Archive/Videos`
  - Logs: `./logs`

#### Compression Settings
- **Frame Rate**: Target frame rate (default: 10)
- **Video Codec**: Compression codec (default: libx265)
- **Timeout**: Max minutes per video (default: 60)

**Supported Codecs:**
- `libx265` - H.265/HEVC (best compression, default)
- `libx264` - H.264/AVC (wider compatibility)
- `h264_nvenc` - NVIDIA GPU acceleration
- `hevc_nvenc` - NVIDIA GPU H.265
- `h264_amf` - AMD GPU acceleration
- `hevc_amf` - AMD GPU H.265
- `h264_qsv` - Intel Quick Sync
- `hevc_qsv` - Intel Quick Sync H.265

#### Processing Settings
- **Max Parallel Jobs**: Number of videos to process concurrently (default: CPU cores - 1, range: 1-8)
  - Dramatically reduces total processing time for large catalogs
  - System auto-detects optimal value: reserves one core for main script and system
  - Set to 1 for sequential processing (backward compatible)
- **Retry Attempts**: Times to retry failed videos (default: 3)
- **Required Disk Space**: Minimum free space in GB (default: 50)
- **Duration Tolerance**: Acceptable duration difference in seconds (default: 1)

#### Illegal Character Handling
- **Strategy**: How to handle filenames with illegal characters
  - **Replace** (default): Replace illegal characters with a substitute character
  - **Omit**: Remove illegal characters entirely
  - **Error**: Stop processing the file, log error, and continue with next file
- **Replacement Character**: Character to use when strategy is "Replace" (default: `_`)

The solution automatically detects platform-specific illegal filename characters using the native .NET method `[System.IO.Path]::GetInvalidFileNameChars()`, ensuring compatibility across Windows, macOS, and Linux.

#### Email Notifications (Optional)

**OAuth 2.0 Authentication (Recommended for Microsoft 365 with MFA):**
- **Client ID**: Azure AD application client ID
- **Tenant ID**: Azure AD tenant ID
- **Token Cache File**: Path to store encrypted refresh tokens
- See **[EMAIL-OAUTH-SETUP.md](EMAIL-OAUTH-SETUP.md)** for complete setup instructions

**Basic Authentication (Fallback - requires App Passwords for MFA):**
- **Username**: Email account username
- **Password**: Email account password or app-specific password

**SMTP Settings:**
- **Enabled**: Enable/disable email notifications
- **SMTP Server**: Mail server address (e.g., `smtp.office365.com`)
- **SMTP Port**: Port number (default: 587)
- **Use SSL**: Enable SSL/TLS (recommended: `$true`)
- **From Address**: Sender email
- **To Addresses**: Recipients (comma-separated)
- **Send on Completion**: Notify when processing finishes
- **Send on Error**: Notify on errors

**Note**: For Microsoft 365 accounts with MFA, OAuth 2.0 is strongly recommended. See [EMAIL-OAUTH-SETUP.md](EMAIL-OAUTH-SETUP.md) for step-by-step setup instructions including Azure AD app registration.

#### Logging Settings
- **Log Level**: Debug, Info, Warning, or Error
- **Console Output**: Display logs in console
- **File Output**: Write logs to files
- **Max Log Size**: Maximum log file size in MB
- **Log Retention**: Days to keep old logs

### Viewing Current Configuration

The script displays your current configuration each time it runs. You can also query the database directly:

```powershell
Import-Module .\modules\VideoCompressionModule\VideoCompressionModule.psm1
Initialize-SPVidComp-Catalog -DatabasePath ".\data\video-catalog.db"
$config = Get-SPVidComp-Config
$config | Format-Table
```

## Database Schema

The SQLite database (`video-catalog.db`) contains:

### Tables

**videos** - Main catalog
- Video metadata (URL, filename, size, dates)
- Processing status and timestamps
- Compression statistics
- Hash values for verification
- Error tracking and retry counts

**processing_log** - Audit trail
- Status changes
- Timestamp and messages
- Linked to video records

**metadata** - System state and configuration
- **Configuration**: All settings stored as `config_*` keys
- **System State**: Last catalog/processing run, total counts
- **Statistics**: Aggregated metrics

## Troubleshooting

### PnP.PowerShell Module Issues

If you encounter authentication issues:
```powershell
# Manually install/update PnP.PowerShell
Install-Module -Name PnP.PowerShell -Force -AllowClobber
Update-Module -Name PnP.PowerShell
```

### ffmpeg Not Found

Ensure ffmpeg is in your PATH:
```powershell
$env:Path += ";C:\ffmpeg\bin"
```

### Insufficient Disk Space

The script checks for required disk space before processing. Increase `RequiredDiskSpaceGB` if needed or clean up temp directory.

### Failed Videos

Query failed videos:
```powershell
Import-Module .\modules\VideoCompressionModule\VideoCompressionModule.psm1
Initialize-SPVidComp-Config -DatabasePath ".\data\video-catalog.db"
$failed = Get-SPVidComp-Videos -Status 'Failed'
$failed | Format-Table filename, last_error, retry_count
```

Retry failed videos:
```powershell
.\scripts\Compress-SharePointVideos.ps1 -Phase Process
```

### View Logs

Logs are stored in `logs\` directory:
```powershell
Get-Content .\logs\video-compression-20260107.log -Tail 50
```

## Advanced Usage

### Query Database Directly

```powershell
Import-Module PSSQLite
$db = "C:\AzDO\honey-i-shrunk-the-vids\data\video-catalog.db"

# Get all videos
Invoke-SqliteQuery -DataSource $db -Query "SELECT * FROM videos"

# Get statistics
Invoke-SqliteQuery -DataSource $db -Query "SELECT status, COUNT(*) as count FROM videos GROUP BY status"
```

### Custom Processing

Import the module and use individual functions:
```powershell
Import-Module .\modules\VideoCompressionModule\VideoCompressionModule.psm1

# Initialize
Initialize-SPVidComp-Config -DatabasePath ".\data\video-catalog.db"

# Connect to SharePoint
Connect-SPVidComp-SharePoint -SiteUrl "https://contoso.sharepoint.com/sites/Videos"

# Get specific videos
$videos = Get-SPVidComp-Videos -Status 'Cataloged' -Limit 10

# Process individual video
# ... (use module functions)
```

## Function Reference

All functions follow the `Verb-SPVidComp-Noun` naming convention:

### Configuration & Connection
- `Initialize-SPVidComp-Config` - Load settings and initialize
- `Connect-SPVidComp-SharePoint` - Authenticate to SharePoint
- `Initialize-SPVidComp-Catalog` - Create/open database

### Catalog Operations
- `Add-SPVidComp-Video` - Add video to catalog
- `Get-SPVidComp-Videos` - Query videos by status
- `Update-SPVidComp-Status` - Update processing status
- `Get-SPVidComp-Files` - Scan SharePoint and catalog videos

### Processing Operations
- `Download-SPVidComp-Video` - Download from SharePoint
- `Copy-SPVidComp-Archive` - Archive with hash verification
- `Test-SPVidComp-ArchiveIntegrity` - Verify SHA256 hash
- `Invoke-SPVidComp-Compression` - Compress with ffmpeg
- `Test-SPVidComp-VideoIntegrity` - Check for corruption
- `Test-SPVidComp-VideoLength` - Compare durations
- `Upload-SPVidComp-Video` - Upload to SharePoint

### Utilities
- `Write-SPVidComp-Log` - Write log entry
- `Send-SPVidComp-Notification` - Send email
- `Test-SPVidComp-DiskSpace` - Check available space
- `Get-SPVidComp-Statistics` - Generate report

## Best Practices

1. **Test First**: Run with `-DryRun` to verify catalog
2. **Start Small**: Test with a small library before processing entire tenant
3. **Monitor Disk Space**: Ensure adequate temp storage
4. **Check Logs**: Review logs after each run
5. **Verify Archive**: Confirm archive storage has sufficient space
6. **Backup Database**: Periodically backup `video-catalog.db`
7. **Email Alerts**: Configure email notifications for unattended runs

## Architecture

```
honey-i-shrunk-the-vids/
├── Compress-SharePointVideos.ps1   # Main script with interactive setup
├── modules/
│   └── VideoCompressionModule/
│       ├── VideoCompressionModule.psm1  # Main module
│       ├── VideoCompressionModule.psd1  # Manifest
│       └── Private/
│           ├── Logger.ps1          # Logging infrastructure
│           ├── DatabaseManager.ps1 # SQLite operations & config storage
│           └── EmailHelper.ps1     # Email notifications
├── logs/                           # Log files (auto-generated)
├── data/
│   └── video-catalog.db            # SQLite database (auto-created)
│                                   #   - Video catalog
│                                   #   - Configuration storage
│                                   #   - Processing state
├── tests/                          # Pester test suite
│   ├── TestHelper.ps1              # Common test utilities
│   ├── Run-Tests.ps1               # Test runner script
│   ├── VideoCompressionModule.Tests.ps1
│   ├── Private/
│   │   ├── DatabaseManager.Tests.ps1
│   │   ├── Logger.Tests.ps1
│   │   └── EmailHelper.Tests.ps1
│   └── Integration/
│       └── Workflow.Tests.ps1      # Integration tests
└── temp/                           # Temporary storage (auto-cleaned)
```

## Testing

The project includes a comprehensive Pester test suite covering unit tests and integration tests.

### Prerequisites

- **Pester 5.0+** - Will be automatically installed if missing
- **PSSQLite** - Required for database tests (auto-installed)

### Running Tests

```powershell
# Run all tests
.\tests\Run-Tests.ps1

# Run only unit tests
.\tests\Run-Tests.ps1 -TestType Unit

# Run only integration tests
.\tests\Run-Tests.ps1 -TestType Integration

# Run specific test by name
.\tests\Run-Tests.ps1 -TestName 'Initialize-Database'

# Run with detailed output
.\tests\Run-Tests.ps1 -Output Detailed

# Run with code coverage
.\tests\Run-Tests.ps1 -CodeCoverage

# Export test results (NUnit XML format)
.\tests\Run-Tests.ps1 -OutputPath .\test-results.xml
```

### Test Categories

| Category | Description | Location |
|----------|-------------|----------|
| **DatabaseManager** | SQLite operations, schema creation, CRUD | `tests/Private/DatabaseManager.Tests.ps1` |
| **Logger** | Logging infrastructure, rotation, levels | `tests/Private/Logger.Tests.ps1` |
| **EmailHelper** | Email notifications, report generation | `tests/Private/EmailHelper.Tests.ps1` |
| **Module Functions** | Public module functions, utilities | `tests/VideoCompressionModule.Tests.ps1` |
| **Integration** | End-to-end workflow, status progression | `tests/Integration/Workflow.Tests.ps1` |

### Test Coverage

The test suite covers:
- Database initialization and schema creation
- Video catalog CRUD operations
- Status progression workflow
- Configuration persistence
- Filename sanitization and illegal character handling
- Archive copy with hash verification
- Disk space validation
- Error handling and retry logic
- Resume capability after interruption
- Statistics calculation

## License

Copyright (c) 2026. All rights reserved.

## Support

For issues, questions, or contributions, please refer to your organization's internal support channels.
