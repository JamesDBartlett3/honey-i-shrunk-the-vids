# TODO

## In Progress

## Pending (Audit Findings - Critical)
*(All critical items completed!)*

## Pending (Audit Findings - High)
*(All high priority items completed!)*

## Pending (Audit Findings - Medium)
- Standardize error handling pattern across all functions (consistent return types)
- Extract repeated directory creation pattern to helper function (DRY violation)
- Add `Disconnect-SPVidComp-SharePoint` cleanup function
- Fix README documentation references to non-existent `-ConfigPath` parameter

## Pending (Feature)
- Automatically download and use ffmpeg executable from official website if not found locally

## Completed
- ✅ Replace deprecated `Send-MailMessage` with OAuth 2.0 + MailKit (supports MFA, browser-based auth, encrypted token storage)
- ✅ Fix `$input` variable shadowing in `Read-UserInput` function (renamed to `$userInput`)
- ✅ Fix cross-platform compatibility - replaced all `$env:TEMP` with `[System.IO.Path]::GetTempPath()`
- ✅ Fix incorrect quote escaping in ffmpeg/ffprobe argument lists (removed manual quotes, using ProcessStartInfo properly)
- ✅ Implement the `$TimeoutMinutes` parameter in `Invoke-SPVidComp-Compression` (with process kill on timeout)
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
- ✅ Update module manifest to export missing functions (added 7 functions: Get-SPVidComp-PlatformDefaults, Get-SPVidComp-IllegalCharacters, Test-SPVidComp-FilenameCharacters, Repair-SPVidComp-Filename, Test-SPVidComp-ConfigExists, Get-SPVidComp-Config, Set-SPVidComp-Config, Test-SPVidComp-FFmpegAvailability)
- ✅ Add ffmpeg/ffprobe availability check before starting processing (Test-SPVidComp-FFmpegAvailability function with version detection)
- ✅ Fix `Test-SPVidComp-DiskSpace` to handle non-existent temp directories (creates directory or checks parent path)
