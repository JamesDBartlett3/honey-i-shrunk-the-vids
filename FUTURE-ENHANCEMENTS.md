# Future Enhancements

This document outlines the top 5 potential enhancements for the SharePoint Video Compression & Archival solution, prioritized by impact and feasibility.

---

## 1. Parallel Video Processing

**Priority**: High
**Complexity**: Medium
**Impact**: Dramatically reduced total processing time for large video catalogs

### Description
Currently, videos are processed sequentially (one at a time). For organizations with hundreds or thousands of videos, this creates a significant bottleneck. Implementing parallel processing would allow multiple videos to be compressed simultaneously.

### Implementation Approach
- Add `MaxParallelJobs` configuration option (default: 2-4 based on CPU cores)
- Use PowerShell's `ForEach-Object -Parallel` (PowerShell 7.0+) or runspace pools
- Implement job queue management with status tracking per worker
- Add per-job temp folders to avoid file conflicts (`temp/{jobId}/{videoId}_*.mp4`)
- Throttle based on:
  - CPU utilization (prevent system overload)
  - Available disk space (each job needs ~2x video size)
  - Network bandwidth for uploads/downloads

### Considerations
- Database writes must be thread-safe (SQLite handles this natively)
- ffmpeg is CPU/GPU intensive - may need to limit concurrent compressions
- Memory usage monitoring for large files
- Progress reporting across parallel jobs

---

## 2. Intelligent Codec Auto-Detection with Hardware Acceleration

**Priority**: High
**Complexity**: Medium
**Impact**: 3-10x faster compression on systems with GPU support

### Description
Currently, users must manually specify the video codec. The solution could automatically detect available hardware encoders (NVIDIA NVENC, AMD AMF, Intel Quick Sync) and use them when available, falling back to software encoding gracefully.

### Implementation Approach
```powershell
function Get-SPVidComp-OptimalCodec {
    # Check NVIDIA GPU
    $nvencAvailable = & ffmpeg -hide_banner -encoders 2>&1 | Select-String 'h264_nvenc'

    # Check AMD GPU
    $amfAvailable = & ffmpeg -hide_banner -encoders 2>&1 | Select-String 'h264_amf'

    # Check Intel Quick Sync
    $qsvAvailable = & ffmpeg -hide_banner -encoders 2>&1 | Select-String 'h264_qsv'

    # Return optimal codec with fallback chain
    if ($nvencAvailable) { return 'hevc_nvenc' }
    elseif ($amfAvailable) { return 'hevc_amf' }
    elseif ($qsvAvailable) { return 'hevc_qsv' }
    else { return 'libx265' }  # Software fallback
}
```

### Additional Features
- Benchmark mode to test encoding speed with sample video
- Automatic fallback if hardware encoder fails
- Codec comparison report showing speed vs quality trade-offs
- GPU memory monitoring to prevent encoder crashes

---

## 3. Tenant-Wide SharePoint Discovery

**Priority**: Medium-High
**Complexity**: Medium
**Impact**: Automatic discovery of all videos across entire SharePoint tenant

### Description
Currently, users must specify which site/library to scan. This enhancement would automatically enumerate all SharePoint sites, document libraries, and subsites across the entire tenant, building a comprehensive video inventory without manual configuration.

### Implementation Approach
```powershell
function Get-SPVidComp-TenantVideos {
    param([string]$AdminUrl)  # e.g., "https://contoso-admin.sharepoint.com"

    # Connect to SharePoint Admin Center
    Connect-PnPOnline -Url $AdminUrl -Interactive

    # Get all site collections
    $sites = Get-PnPTenantSite -Detailed

    foreach ($site in $sites) {
        # Connect to each site
        Connect-PnPOnline -Url $site.Url -Interactive

        # Get all document libraries
        $libraries = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 }

        foreach ($library in $libraries) {
            # Scan for MP4 files
            Get-SPVidComp-Files -SiteUrl $site.Url -LibraryName $library.Title
        }
    }
}
```

### Features
- Site filtering (include/exclude patterns)
- Incremental scanning (only check modified libraries since last scan)
- Site collection statistics dashboard
- Permission-aware scanning (skip sites without access)
- Progress tracking across large tenants

---

## 4. Compression Profile Presets

**Priority**: Medium
**Complexity**: Low
**Impact**: Simplified configuration and optimized results for different use cases

### Description
Replace the current manual codec/framerate configuration with predefined profiles optimized for different scenarios. Users select a profile, and the system applies the optimal settings automatically.

### Proposed Profiles

| Profile | Frame Rate | Codec | Audio | Use Case |
|---------|------------|-------|-------|----------|
| **Webinar** | 10 fps | libx265 | Mono 22kHz | Screen recordings, presentations with minimal motion |
| **Training** | 15 fps | libx265 | Mono 32kHz | Training videos with moderate motion |
| **Marketing** | 24 fps | libx264 | Stereo 44.1kHz | Marketing content requiring quality |
| **Archive** | 30 fps | libx265 | Original | Long-term storage, preserve quality |
| **Aggressive** | 5 fps | libx265 | Mono 16kHz | Maximum compression, acceptable quality loss |
| **Custom** | User-defined | User-defined | User-defined | Full control over all parameters |

### Implementation
```powershell
$CompressionProfiles = @{
    'Webinar' = @{
        FrameRate = 10
        VideoCodec = 'libx265'
        AudioChannels = 1
        AudioRate = 22050
        CRF = 28
        Preset = 'medium'
    }
    'Training' = @{
        FrameRate = 15
        VideoCodec = 'libx265'
        AudioChannels = 1
        AudioRate = 32000
        CRF = 26
        Preset = 'medium'
    }
    # ... additional profiles
}
```

### Additional Features
- Profile preview showing estimated compression ratio
- A/B comparison tool to test profiles on sample video
- Custom profile creation and saving
- Per-library profile assignment (different profiles for different content types)

---

## 5. Real-Time Progress Dashboard and Webhook Notifications

**Priority**: Medium
**Complexity**: Medium
**Impact**: Better visibility and integration with enterprise workflows

### Description
Replace the current email-only notifications with a comprehensive progress system including real-time status updates, Microsoft Teams/Slack webhooks, and an optional web-based dashboard for monitoring long-running batch operations.

### Components

#### A. Webhook Notifications (Teams, Slack, Generic)
```powershell
function Send-SPVidComp-WebhookNotification {
    param(
        [string]$WebhookUrl,
        [string]$MessageType,  # 'Started', 'Progress', 'Completed', 'Error'
        [hashtable]$Data
    )

    $payload = @{
        '@type' = 'MessageCard'
        summary = "Video Compression: $MessageType"
        sections = @(
            @{
                facts = @(
                    @{ name = 'Status'; value = $MessageType }
                    @{ name = 'Processed'; value = "$($Data.Processed) / $($Data.Total)" }
                    @{ name = 'Space Saved'; value = "$($Data.SpaceSavedGB) GB" }
                )
            }
        )
    }

    Invoke-RestMethod -Uri $WebhookUrl -Method POST -Body ($payload | ConvertTo-Json -Depth 10)
}
```

#### B. Progress Events
- Batch started (total videos, estimated time)
- Individual video progress (download %, compression %, upload %)
- Batch completion summary
- Error alerts with details

#### C. Optional Web Dashboard (Future)
- Real-time WebSocket updates
- Historical processing charts
- Per-site statistics visualization
- Error analysis and trending

### Integration Points
- Microsoft Teams incoming webhooks
- Slack incoming webhooks
- Microsoft Power Automate triggers
- Azure Logic Apps
- Generic REST API endpoints

---

## 6. Interactive Video Selection with ConsoleGuiTools

**Priority**: Medium
**Complexity**: Low
**Impact**: Improved user experience for selective video processing

### Description
Add an optional interactive mode using the [ConsoleGuiTools](https://github.com/PowerShell/ConsoleGuiTools) PowerShell module to allow users to filter, sort, and select specific videos from the catalog before processing. This provides a terminal-based GUI experience without leaving the command line.

### Implementation Approach
```powershell
function Select-SPVidComp-VideosInteractive {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Status = 'Cataloged'
    )

    # Check for ConsoleGuiTools module
    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.ConsoleGuiTools)) {
        Write-Host "Installing ConsoleGuiTools for interactive selection..." -ForegroundColor Yellow
        Install-Module -Name Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser -Force
    }

    Import-Module Microsoft.PowerShell.ConsoleGuiTools

    # Get videos from catalog
    $videos = Get-SPVidComp-Videos -Status $Status

    # Present interactive selection with Out-ConsoleGridView
    $selectedVideos = $videos |
        Select-Object id, filename,
            @{N='Size (MB)';E={[math]::Round($_.original_size / 1MB, 2)}},
            site_url, library_name, folder_path, status, modified_date |
        Out-ConsoleGridView -Title "Select Videos to Process" -OutputMode Multiple

    return $selectedVideos
}
```

### Features
- **Table View**: Display video catalog in sortable, filterable grid
- **Multi-Select**: Choose specific videos to process (Ctrl+Click or Space)
- **Column Sorting**: Click headers to sort by filename, size, date, status
- **Search/Filter**: Quick filter to find specific videos by name or path
- **Tree View Option**: Hierarchical view by Site → Library → Folder → File

### Use Cases
- Process only videos from a specific site or library
- Select large files first for maximum space savings
- Re-process specific failed videos without retrying all
- Preview catalog before committing to full processing run

### Integration Points
```powershell
# Add -Interactive switch to main script
.\Compress-SharePointVideos.ps1 -Phase Process -Interactive

# Or use standalone selection
$selected = Select-SPVidComp-VideosInteractive -Status 'Cataloged'
# Then process only selected videos
```

### Module Reference
- **GitHub**: https://github.com/PowerShell/ConsoleGuiTools
- **Install**: `Install-Module Microsoft.PowerShell.ConsoleGuiTools`
- **Key Cmdlet**: `Out-ConsoleGridView` (cross-platform replacement for `Out-GridView`)

---

## Honorable Mentions

These enhancements didn't make the top 6 but are worth considering:

7. **Automatic ffmpeg Installation** - Already in TODO.md. Download and configure ffmpeg automatically if not found.

8. **Video Preview Generation** - Create thumbnail images or short preview clips before processing for verification.

9. **File Exclusion Patterns** - Skip files matching certain patterns (e.g., `*_compressed.mp4`, files under certain size).

10. **Bandwidth Throttling** - Limit upload/download speeds during business hours to avoid network congestion.

11. **Compression History Analytics** - Track compression ratios over time, identify videos that compress poorly, suggest optimal profiles.

---

## Implementation Priority Matrix

| Enhancement | Impact | Effort | Dependencies | Recommended Phase |
|------------|--------|--------|--------------|-------------------|
| Parallel Processing | High | Medium | None | Phase 1 |
| Hardware Codec Detection | High | Low | None | Phase 1 |
| Compression Profiles | Medium | Low | None | Phase 1 |
| Interactive Selection (ConsoleGuiTools) | Medium | Low | ConsoleGuiTools module | Phase 1 |
| Webhook Notifications | Medium | Medium | None | Phase 2 |
| Tenant-Wide Discovery | Medium-High | Medium | Admin permissions | Phase 2 |

---

*Last updated: 2026-01-07*
