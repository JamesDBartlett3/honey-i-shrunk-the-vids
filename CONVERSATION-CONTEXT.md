# Conversation Context - SharePoint Video Compression Project

Use this file to resume context on another machine. Copy the contents below into your first message to Claude Code.

---

## Project Overview

This is a PowerShell 7.0+ cross-platform solution for automating SharePoint video compression and archival. The solution:
- Downloads MP4 videos from SharePoint
- Archives originals to external storage with hash verification and folder structure mirroring
- Compresses videos using ffmpeg (libx265, 10fps) with automatic ffmpeg installation if not found
- Uploads compressed versions back to SharePoint
- Tracks everything in a SQLite database with comprehensive error handling

## Project Structure

```
honey-i-shrunk-the-vids/
├── Compress-SharePointVideos.ps1    # Main entry script
├── modules/
│   └── VideoCompressionModule/
│       ├── VideoCompressionModule.psm1   # Public functions (Verb-SPVidComp-Noun)
│       ├── VideoCompressionModule.psd1   # Module manifest (49 exported functions)
│       └── Private/
│           ├── DatabaseManager.ps1       # SQLite operations
│           ├── Logger.ps1                # Logging system
│           └── EmailHelper.ps1           # OAuth 2.0 email (MailKit)
├── tests/
│   ├── TestHelper.ps1                    # Test utilities
│   ├── Run-Tests.ps1                     # Test runner
│   ├── VideoCompressionModule.Tests.ps1  # Main module tests (62 tests)
│   ├── Private/
│   │   ├── DatabaseManager.Tests.ps1     # (83 tests)
│   │   ├── Logger.Tests.ps1              # (26 tests)
│   │   └── EmailHelper.Tests.ps1         # (35 tests)
│   └── Integration/
│       ├── ComponentIntegration.Tests.ps1 # (37 tests)
│       └── Workflow.Tests.ps1             # (35 tests)
├── config/
│   └── config.example.json
├── CLAUDE.md                             # Project instructions for Claude
├── TODO.md                               # Completed tasks + future error testing
├── FUTURE-ENHANCEMENTS.md                # 6 planned enhancements
├── CONVERSATION-CONTEXT.md               # This file
└── .gitattributes                        # Line ending normalization
```

## Current Status

**All 248 Pester tests are passing** (244 fast tests + 4 integration tests with real downloads).

### Recently Completed (Current Session)
1. ✅ **All Medium Priority Audit Items**
   - Standardized error handling (Success/Error properties in all hashtable returns)
   - Extracted directory creation to `New-SPVidComp-Directory` helper
   - Added `Disconnect-SPVidComp-SharePoint` cleanup function
   - Fixed README documentation (ConfigPath → DatabasePath)

2. ✅ **FFmpeg Auto-Download Feature**
   - Automatic detection in system PATH or module bin directory
   - Cross-platform downloads: GitHub (Windows/Linux), evermeet.cx (macOS)
   - Automatic extraction, permission setting, and verification
   - Integrated into compression workflow with automatic fallback
   - Function: `Install-SPVidComp-FFmpeg` with `-Force` parameter

3. ✅ **Comprehensive Unit Testing**
   - Increased from 235 to 248 tests
   - Proper test isolation with temporary directories
   - Module scope manipulation for true unit testing
   - Real download testing (25-60s per test)
   - Tagged tests for selective execution (`-ExcludeTagFilter 'Download'`)

4. ✅ **Code Quality Improvements**
   - All helper functions follow `Verb-SPVidComp-Noun` convention
   - Added `-File` filter to `Get-ChildItem` for binary detection
   - Improved logging with Debug level diagnostics
   - Cross-platform chmod handling

## Key Technical Details

### FFmpeg Auto-Download (New Feature)
- **Detection Order**: System PATH → Module bin directory (`modules/VideoCompressionModule/bin/ffmpeg/`)
- **Download Sources**:
  - Windows/Linux: `https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/`
  - macOS: `https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip`
- **Archive Handling**: ZIP (Windows/macOS) and tar.xz (Linux)
- **Binary Search**: Recursive search with `-File` filter in extracted archive
- **Permissions**: Automatic `chmod +x` on Linux/macOS
- **Caching**: Module-level variables (`$Script:FFmpegPath`, `$Script:FFprobePath`)
- **Integration**: Compression functions auto-install if binaries not found

### Filename Sanitization
- Uses `[System.IO.Path]::GetInvalidFileNameChars()` for cross-platform support
- Character-by-character array operations for reliable null character handling
- Strategies: Replace (default), Omit, Error
- Functions: `Test-SPVidComp-FilenameCharacters`, `Repair-SPVidComp-Filename`

### Error Handling Pattern (Standardized)
All hashtable-returning functions include:
- `Success` (boolean): Operation success/failure
- `Error` (string or null): Error message if failed
- Semantic properties: `HasSpace`, `IsValid`, `WithinTolerance`, etc.

### Database Schema (SQLite)
- `videos` table: tracks all videos and their processing status
- `processing_log` table: audit trail of status changes
- `metadata` table: key-value store for config (prefixed with `config_`)

### Status Flow
Cataloged → Downloading → Archiving → Compressing → Verifying → Uploading → Completed

### Dependencies
- PowerShell 7.0+ (cross-platform)
- PnP.PowerShell (SharePoint operations)
- PSSQLite (database operations)
- ffmpeg/ffprobe (auto-installed if not found)
- MailKit + MSAL.PS (OAuth 2.0 email, replaces deprecated Send-MailMessage)
- Pester 5.0+ (testing framework)

## Completed Audit Findings

**All Critical Items:**
- ✅ Replaced `Send-MailMessage` with OAuth 2.0 + MailKit
- ✅ Fixed `$input` variable shadowing (renamed to `$userInput`)
- ✅ Fixed ffmpeg argument quoting (using ProcessStartInfo properly)

**All High Priority Items:**
- ✅ Changed `Get-FileHash -Path` to `-LiteralPath` for consistency
- ✅ Module manifest now exports all 49 functions explicitly

**All Medium Priority Items:**
- ✅ Standardized error handling pattern (Success/Error properties)
- ✅ Extracted directory creation to `New-SPVidComp-Directory` helper
- ✅ Added `Disconnect-SPVidComp-SharePoint` cleanup function
- ✅ Fixed README documentation (ConfigPath → DatabasePath)

## Pending Work

### Error Path Testing (TODO.md)
Additional error testing that would require mocking/complex test setup:
- Network download failures in `Install-SPVidComp-FFmpeg`
- Archive extraction failures (corrupted downloads, unsupported formats)
- FFmpeg binaries not found in extracted archive structure
- Permission denied during `chmod +x` on Linux/macOS
- Unsupported platform detection (non-Windows/Linux/macOS)
- Disk space exhaustion during FFmpeg download/extraction

These error paths have proper try/catch handling and logging but aren't covered by unit tests yet.

## Future Enhancements (FUTURE-ENHANCEMENTS.md)

1. Parallel Video Processing (runspaces/jobs)
2. Hardware Codec Auto-Detection (NVENC, QSV, VideoToolbox)
3. Tenant-Wide SharePoint Discovery
4. Compression Profile Presets
5. Webhook Notifications & Dashboard
6. Interactive Video Selection (ConsoleGuiTools)

## Running Tests

### Fast Tests (Exclude Downloads)
```powershell
cd honey-i-shrunk-the-vids
Invoke-Pester -Path '.\tests' -ExcludeTagFilter 'Download' -Output Detailed
# 244 tests in ~30-40s
```

### All Tests (Including Download Integration Tests)
```powershell
Invoke-Pester -Path '.\tests' -Output Detailed
# 248 tests in ~3-4 minutes (includes real ffmpeg downloads)
```

### Download Tests Only
```powershell
Invoke-Pester -Path '.\tests' -TagFilter 'Download' -Output Detailed
# 4 tests in ~2-3 minutes
```

### Using Test Runner Script
```powershell
.\tests\Run-Tests.ps1 -TestType All -Output Detailed
```

## Important Notes

- **Use PowerShell syntax** (not Bash) for all commands
- **Use `-LiteralPath`** instead of `-Path` for file operations with special characters
- **The solution is cross-platform** (Windows, macOS, Linux with PowerShell 7.0+)
- **All helper functions** follow `Verb-SPVidComp-Noun` naming convention
- **FFmpeg auto-installs** on first compression if not found in PATH
- **Tests use module scope manipulation** to properly isolate test state

## Key Functions Reference

### Configuration
- `Initialize-SPVidComp-Config` - Interactive setup wizard
- `Get-SPVidComp-Config` / `Set-SPVidComp-Config` - Config management
- `Test-SPVidComp-ConfigExists` - Check if configured

### SharePoint Connection
- `Connect-SPVidComp-SharePoint` - Establish connection
- `Disconnect-SPVidComp-SharePoint` - Cleanup connection

### Video Catalog
- `Initialize-SPVidComp-Catalog` - Create/open database
- `Add-SPVidComp-Video` - Add video to catalog
- `Get-SPVidComp-Videos` - Query videos by status
- `Update-SPVidComp-Status` - Update processing status

### Video Operations
- `Get-SPVidComp-Files` - List videos from SharePoint
- `Download-SPVidComp-Video` - Download from SharePoint
- `Copy-SPVidComp-Archive` - Archive with folder mirroring
- `Test-SPVidComp-ArchiveIntegrity` - Hash verification
- `Invoke-SPVidComp-Compression` - Compress with ffmpeg
- `Test-SPVidComp-VideoIntegrity` - Verify compressed video
- `Test-SPVidComp-VideoLength` - Duration tolerance check
- `Upload-SPVidComp-Video` - Upload to SharePoint

### FFmpeg Management
- `Test-SPVidComp-FFmpegAvailability` - Check ffmpeg/ffprobe availability
- `Install-SPVidComp-FFmpeg` - Download and install ffmpeg/ffprobe

### Utilities
- `Write-SPVidComp-Log` - Logging
- `Send-SPVidComp-Notification` - Email notifications (OAuth 2.0)
- `Test-SPVidComp-DiskSpace` - Check available space
- `Get-SPVidComp-Statistics` - Generate statistics report
- `Get-SPVidComp-PlatformDefaults` - Platform-specific defaults
- `Test-SPVidComp-FilenameCharacters` - Check filename validity
- `Repair-SPVidComp-Filename` - Sanitize filenames
