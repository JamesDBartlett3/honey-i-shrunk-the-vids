# Conversation Context - SharePoint Video Compression Project

Use this file to resume context on another machine. Copy the contents below into your first message to Claude Code.

---

## Project Overview

This is a PowerShell 7.0+ solution for automating SharePoint video compression and archival. The solution:
- Downloads MP4 videos from SharePoint
- Archives originals to external storage with hash verification
- Compresses videos using ffmpeg (libx265, 10fps)
- Uploads compressed versions back to SharePoint
- Tracks everything in a SQLite database

## Project Structure

```
honey-i-shrunk-the-vids/
├── Compress-SharePointVideos.ps1    # Main entry script
├── modules/
│   └── VideoCompressionModule/
│       ├── VideoCompressionModule.psm1   # Public functions (SPVidComp-* prefix)
│       ├── VideoCompressionModule.psd1   # Module manifest
│       └── Private/
│           ├── DatabaseManager.ps1       # SQLite operations
│           ├── Logger.ps1                # Logging system
│           └── EmailHelper.ps1           # Email notifications
├── tests/
│   ├── TestHelper.ps1                    # Test utilities
│   ├── Run-Tests.ps1                     # Test runner
│   ├── VideoCompressionModule.Tests.ps1  # Main module tests
│   ├── Private/
│   │   ├── DatabaseManager.Tests.ps1
│   │   ├── Logger.Tests.ps1
│   │   └── EmailHelper.Tests.ps1
│   └── Integration/
│       └── Workflow.Tests.ps1
├── config/
│   └── config.example.json
├── CLAUDE.md                             # Project instructions for Claude
├── TODO.md                               # Audit findings and tasks
├── FUTURE-ENHANCEMENTS.md                # 6 planned enhancements
└── .gitattributes                        # Line ending normalization
```

## Current Status

**All 182 Pester tests are passing.**

Recent work completed:
1. Created comprehensive Pester test suite (182 tests)
2. Fixed test failures related to:
   - Database state isolation between tests
   - Script-scope variable access (`$Script:` variables)
   - Filename sanitization with special characters (null char handling)
   - SpaceSaved calculation (now only counts completed videos)
   - Config prefix handling in database

## Key Technical Details

### Filename Sanitization
- Uses `[System.IO.Path]::GetInvalidFileNameChars()` for cross-platform support
- Character-by-character array operations for reliable null character handling
- Strategies: Replace (default), Omit, Error

### Database Schema (SQLite)
- `videos` table: tracks all videos and their processing status
- `processing_log` table: audit trail of status changes
- `metadata` table: key-value store for config (prefixed with `config_`)

### Status Flow
Cataloged → Downloading → Archiving → Compressing → Verifying → Uploading → Completed

### Dependencies
- PowerShell 7.0+
- PnP.PowerShell (SharePoint)
- PSSQLite (database)
- ffmpeg/ffprobe (compression)
- Pester 5.0+ (testing)

## Audit Findings (TODO.md)

**Critical:**
- `Send-MailMessage` is deprecated (needs Graph API replacement)
- `$input` variable shadowing in some functions
- ffmpeg argument quoting issues

**High:**
- `Get-FileHash` uses `-Path` instead of `-LiteralPath`
- Module manifest missing explicit function exports

## Future Enhancements (FUTURE-ENHANCEMENTS.md)

1. Parallel Video Processing (runspaces/jobs)
2. Hardware Codec Auto-Detection (NVENC, QSV, VideoToolbox)
3. Tenant-Wide SharePoint Discovery
4. Compression Profile Presets
5. Webhook Notifications & Dashboard
6. Interactive Video Selection (ConsoleGuiTools)

## Running Tests

```powershell
cd honey-i-shrunk-the-vids
.\tests\Run-Tests.ps1 -TestType All -Output Detailed
```

Or directly with Pester:
```powershell
Invoke-Pester -Path '.\tests' -Output Detailed
```

## Important Notes

- Use PowerShell syntax (not Bash) for all commands
- Use `-LiteralPath` instead of `-Path` for file operations with special characters
- The solution is cross-platform (Windows, macOS, Linux)
