# TODO

## In Progress

## Pending (Audit Findings - Critical)
- Replace deprecated `Send-MailMessage` with Microsoft Graph API or modern alternative (PowerShell 7+ deprecation)
- Fix `$input` variable shadowing in `Read-UserInput` function (conflicts with PowerShell automatic variable)
- Fix incorrect quote escaping in ffmpeg/ffprobe argument lists (change "`"$path`"" to "$path")
- Implement the `$TimeoutMinutes` parameter in `Invoke-SPVidComp-Compression` (currently ignored)

## Pending (Audit Findings - High)
- Change `Get-FileHash -Path` to `Get-FileHash -LiteralPath` for consistency
- Update module manifest to export missing functions (config, platform, filename functions)
- Add ffmpeg/ffprobe availability check before starting processing
- Add missing `-y` flag to ffmpeg to auto-confirm file overwrites
- Fix `Test-SPVidComp-DiskSpace` to handle non-existent temp directories

## Pending (Audit Findings - Medium)
- Standardize error handling pattern across all functions (consistent return types)
- Extract repeated directory creation pattern to helper function (DRY violation)
- Add `Disconnect-SPVidComp-SharePoint` cleanup function
- Fix README documentation references to non-existent `-ConfigPath` parameter

## Pending (Feature)
- Automatically download and use ffmpeg executable from official website if not found locally

## Completed
- ✅ Update module manifest to require PowerShell 7.0+
- ✅ Add platform detection and cross-platform path defaults
- ✅ Add illegal character handling for filenames
- ✅ Update DatabaseManager with IllegalCharacterHandling config
- ✅ Update main script with platform-aware setup wizard
- ✅ Integrate filename sanitization into processing workflow
- ✅ Update README for cross-platform usage
- ✅ Update file operations to use -LiteralPath to avoid conflicts with PowerShell wildcards and filenames containing square brackets
- ✅ Implement folder structure mirroring in external archive (include site/library/subfolder path to avoid filename conflicts)
