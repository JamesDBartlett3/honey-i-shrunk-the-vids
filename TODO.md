# TODO

## In Progress

## Pending (Audit Findings - Critical)
*(All critical items completed!)*

## Pending (Audit Findings - High)
*(All high priority items completed!)*

## Pending (Audit Findings - Medium)
*(All medium priority items completed!)*

## Pending (Feature)
*(All planned features completed!)*

## Pending (Testing - Error Paths - Future Work)
**Assessment (2026-01-08):** Error path testing for edge cases would require complex mocking infrastructure:
- Network download failures in `Install-SPVidCompFFmpeg` (requires mocking Invoke-WebRequest)
- Archive extraction failures (requires creating corrupted test archives)
- FFmpeg binaries not found in extracted archive (feasible but low priority)
- Permission denied during `chmod +x` on Linux/macOS (difficult to test cross-platform)
- Unsupported platform detection (requires mocking $IsWindows/$IsLinux/$IsMacOS)
- Disk space exhaustion during download/extraction (impractical to test)

**Decision:** Marked as future work. Current test coverage is strong:
- **238 tests passing (100%)**
- All main workflows tested (catalog, download, compress, upload, resume)
- All integration points tested (SharePoint, database, email, logging)
- FFmpeg auto-download tested with actual downloads
- Defensive error handling already in place throughout codebase
- Edge case errors would require disproportionate test infrastructure investment

These error paths have defensive handling in the code (try/catch with error messages) and would only trigger in rare system failures. The current test suite provides sufficient confidence in the solution's reliability.

## Completed
- ✅ Remove inappropriate default values for user-specific settings (SharePoint URL, library name, archive path, email addresses)
- ✅ Fix logger to create log directory automatically, eliminating "Failed to write to log file" warnings
- ✅ Remove obsolete tests for deleted configuration functions (Set-ConfigValue, Get-ConfigValue, Remove-ConfigValue)
- ✅ Update all function names in TODO.md to use correct naming convention (remove double hyphens)
- ✅ Achieve 100% test pass rate (238/238 tests passing, 0 failures, 0 warnings)
- ✅ Replace deprecated `Send-MailMessage` with OAuth 2.0 + MailKit (supports MFA, browser-based auth, encrypted token storage)
- ✅ Fix `$input` variable shadowing in `Read-UserInput` function (renamed to `$userInput`)
- ✅ Fix cross-platform compatibility - replaced all `$env:TEMP` with `[System.IO.Path]::GetTempPath()`
- ✅ Fix incorrect quote escaping in ffmpeg/ffprobe argument lists (removed manual quotes, using ProcessStartInfo properly)
- ✅ Implement the `$TimeoutMinutes` parameter in `Invoke-SPVidCompCompression` (with process kill on timeout)
- ✅ Add missing `-y` flag to ffmpeg to auto-confirm file overwrites
- ✅ Update module manifest to require PowerShell 7.0+
- ✅ Add platform detection and cross-platform path defaults
- ✅ Add illegal character handling for filenames
- ✅ Update DatabaseManager with IllegalCharacterHandling config
- ✅ Update main script with platform-aware setup wizard
- ✅ Integrate filename sanitization into processing workflow
- ✅ Update README for cross-platform usage
- ✅ Update file operations to use -LiteralPath to avoid conflicts with PowerShell wildcards and filenames containing square brackets
- ✅ Implement folder structure mirroring in external archive (include site/library/subfolder path to avoid filename conflicts)
- ✅ Change `Get-FileHash -Path` to `Get-FileHash -LiteralPath` for consistency (VideoCompressionModule.psm1:469-470)
- ✅ Update module manifest to export missing functions (added 7 functions: Get-SPVidCompPlatformDefaults, Get-SPVidCompIllegalCharacters, Test-SPVidCompFilenameCharacters, Repair-SPVidCompFilename, Test-SPVidCompConfigExists, Get-SPVidCompConfig, Set-SPVidCompConfig, Test-SPVidCompFFmpegAvailability)
- ✅ Add ffmpeg/ffprobe availability check before starting processing (Test-SPVidCompFFmpegAvailability function with version detection)
- ✅ Fix `Test-SPVidCompDiskSpace` to handle non-existent temp directories (creates directory or checks parent path)
- ✅ Standardize error handling pattern across all functions (all hashtable returns include Success and Error properties)
- ✅ Extract repeated directory creation pattern to helper function (New-SPVidCompDirectory)
- ✅ Add `Disconnect-SPVidCompSharePoint` cleanup function
- ✅ Fix README documentation references to non-existent `-ConfigPath` parameter (changed to `-DatabasePath`)
- ✅ Automatically download and use ffmpeg executable from official website if not found locally (Install-SPVidCompFFmpeg with platform detection, GitHub/evermeet.cx sources)
- ✅ Add comprehensive unit tests for FFmpeg auto-download feature (248 total tests, all passing)
