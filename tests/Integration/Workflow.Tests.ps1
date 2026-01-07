#------------------------------------------------------------------------------------------------------------------
# Workflow.Tests.ps1 - Integration tests for the video compression workflow
# Tests the complete processing pipeline with mocked external dependencies
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Ensure PSSQLite is available
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Install-Module -Name PSSQLite -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module PSSQLite -Force

    # Create test directories FIRST (before importing module)
    $Script:TestTempDir = Join-Path -Path $env:TEMP -ChildPath "workflow-test-$(Get-Random)"
    $Script:TestArchiveDir = Join-Path -Path $Script:TestTempDir -ChildPath 'archive'
    $Script:TestLogDir = Join-Path -Path $Script:TestTempDir -ChildPath 'logs'

    New-Item -ItemType Directory -Path $Script:TestTempDir -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:TestArchiveDir -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:TestLogDir -Force | Out-Null

    # Import the module
    Import-TestModule

    # Initialize logger
    Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
}

AfterAll {
    # Cleanup
    if (Test-Path -LiteralPath $Script:TestTempDir) {
        Remove-Item -LiteralPath $Script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Mock Definitions for External Dependencies
#------------------------------------------------------------------------------------------------------------------

# Mock ffprobe response for video duration
function Get-MockFfprobeOutput {
    param(
        [double]$Duration = 120.5  # Default 2 minutes
    )
    return $Duration.ToString()
}

# Mock ffmpeg compression result
function New-MockCompressedFile {
    param(
        [string]$OutputPath,
        [long]$OriginalSize,
        [double]$CompressionRatio = 0.5
    )

    $compressedSize = [long]($OriginalSize * $CompressionRatio)
    $bytes = New-Object byte[] $compressedSize
    [System.Random]::new().NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($OutputPath, $bytes)

    return $compressedSize
}

#------------------------------------------------------------------------------------------------------------------
# Catalog Phase Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Catalog Phase Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should initialize empty catalog' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalCataloged | Should -Be 0
    }

    It 'Should add multiple videos to catalog' {
        $videos = @(
            Get-TestVideoRecord -Filename 'video1.mp4' -Size 100000000
            Get-TestVideoRecord -Filename 'video2.mp4' -Size 200000000
            Get-TestVideoRecord -Filename 'video3.mp4' -Size 150000000
        )

        foreach ($video in $videos) {
            Add-SPVidComp-Video @video
        }

        $stats = Get-SPVidComp-Statistics
        $stats.TotalCataloged | Should -Be 3
    }

    It 'Should track total original size' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalOriginalSize | Should -Be 450000000  # 100 + 200 + 150 MB
    }

    It 'Should set all videos to Cataloged status' {
        $videos = Get-SPVidComp-Videos -Status 'Cataloged'

        $videos.Count | Should -Be 3
    }
}

#------------------------------------------------------------------------------------------------------------------
# Processing Phase Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Processing Phase Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        # Add a test video
        $video = Get-TestVideoRecord -Filename 'process-test.mp4' -Size 100000000
        Add-SPVidComp-Video @video

        $Script:TestVideo = (Get-SPVidComp-Videos)[0]

        # Create a mock original file
        $Script:MockOriginalFile = Join-Path -Path $Script:TestTempDir -ChildPath 'original.mp4'
        New-MockVideoFile -Path $Script:MockOriginalFile -SizeKB 1000
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
        if (Test-Path -LiteralPath $Script:MockOriginalFile) {
            Remove-Item -LiteralPath $Script:MockOriginalFile -Force
        }
    }

    Describe 'Status Progression' {
        It 'Should progress from Cataloged to Downloading' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Downloading'

            $video = (Get-SPVidComp-Videos -Status 'Downloading')[0]
            $video.status | Should -Be 'Downloading'
        }

        It 'Should set processing_started timestamp on Downloading' {
            $video = (Get-SPVidComp-Videos -Status 'Downloading')[0]

            $video.processing_started | Should -Not -BeNullOrEmpty
        }

        It 'Should progress to Archiving' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Archiving'

            $video = (Get-SPVidComp-Videos -Status 'Archiving')[0]
            $video.status | Should -Be 'Archiving'
        }

        It 'Should progress to Compressing' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Compressing'

            $video = (Get-SPVidComp-Videos -Status 'Compressing')[0]
            $video.status | Should -Be 'Compressing'
        }

        It 'Should progress to Verifying' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Verifying'

            $video = (Get-SPVidComp-Videos -Status 'Verifying')[0]
            $video.status | Should -Be 'Verifying'
        }

        It 'Should progress to Uploading' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Uploading'

            $video = (Get-SPVidComp-Videos -Status 'Uploading')[0]
            $video.status | Should -Be 'Uploading'
        }

        It 'Should progress to Completed' {
            Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Completed'

            $video = (Get-SPVidComp-Videos -Status 'Completed')[0]
            $video.status | Should -Be 'Completed'
        }

        It 'Should set processing_completed timestamp on Completed' {
            $video = (Get-SPVidComp-Videos -Status 'Completed')[0]

            $video.processing_completed | Should -Not -BeNullOrEmpty
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Archive Workflow Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Archive Workflow' {
    BeforeAll {
        # Create a source file
        $Script:SourceFile = Join-Path -Path $Script:TestTempDir -ChildPath 'archive-source.mp4'
        New-MockVideoFile -Path $Script:SourceFile -SizeKB 500
    }

    AfterAll {
        if (Test-Path -LiteralPath $Script:SourceFile) {
            Remove-Item -LiteralPath $Script:SourceFile -Force
        }
    }

    It 'Should create archive with mirrored folder structure' {
        $archivePath = Join-Path -Path $Script:TestArchiveDir -ChildPath 'sites\TestSite\Documents\Videos\test.mp4'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:SourceFile -ArchivePath $archivePath

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $archivePath | Should -BeTrue
    }

    It 'Should verify archive integrity with hash' {
        $archivePath = Join-Path -Path $Script:TestArchiveDir -ChildPath 'verified\test.mp4'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:SourceFile -ArchivePath $archivePath

        $result.SourceHash | Should -Be $result.DestinationHash
    }

    It 'Should handle deep nested paths' {
        $deepPath = Join-Path -Path $Script:TestArchiveDir -ChildPath 'a\b\c\d\e\f\g\deep.mp4'

        $result = Copy-SPVidComp-Archive -SourcePath $Script:SourceFile -ArchivePath $deepPath

        $result.Success | Should -BeTrue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Filename Sanitization Workflow Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Filename Sanitization Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should handle valid filenames without modification' {
        $result = Repair-SPVidComp-Filename -Filename 'normal-video-2024.mp4'

        $result.Success | Should -BeTrue
        $result.Changed | Should -BeFalse
        $result.SanitizedFilename | Should -Be 'normal-video-2024.mp4'
    }

    It 'Should sanitize filenames with spaces' {
        # Spaces are valid, should not change
        $result = Repair-SPVidComp-Filename -Filename 'video with spaces.mp4'

        $result.Success | Should -BeTrue
        $result.SanitizedFilename | Should -Be 'video with spaces.mp4'
    }

    It 'Should sanitize filenames with special characters' {
        # Null character is invalid everywhere
        $invalidName = "video`0name.mp4"

        $result = Repair-SPVidComp-Filename -Filename $invalidName -Strategy 'Replace' -ReplacementChar '_'

        $result.Success | Should -BeTrue
        $result.Changed | Should -BeTrue
        $result.SanitizedFilename | Should -Not -Match "`0"
    }

    It 'Should preserve file extension' {
        $invalidName = "bad`0name.mp4"

        $result = Repair-SPVidComp-Filename -Filename $invalidName -Strategy 'Replace'

        $result.SanitizedFilename | Should -Match '\.mp4$'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Error Handling Workflow Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Error Handling Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        # Add test video
        $video = Get-TestVideoRecord -Filename 'error-test.mp4'
        Add-SPVidComp-Video @video

        $Script:TestVideo = (Get-SPVidComp-Videos)[0]
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should mark video as Failed on error' {
        Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Failed' -AdditionalFields @{
            last_error = 'Download timeout'
            retry_count = 1
        }

        $video = (Get-SPVidComp-Videos -Status 'Failed')[0]
        $video.status | Should -Be 'Failed'
    }

    It 'Should store error message' {
        $video = (Get-SPVidComp-Videos -Status 'Failed')[0]

        $video.last_error | Should -Be 'Download timeout'
    }

    It 'Should increment retry count' {
        $video = (Get-SPVidComp-Videos -Status 'Failed')[0]

        $video.retry_count | Should -Be 1
    }

    It 'Should filter by MaxRetryCount' {
        # Update retry count to exceed limit
        Update-SPVidComp-Status -VideoId $Script:TestVideo.id -Status 'Failed' -AdditionalFields @{
            retry_count = 5
        }

        $videos = Get-SPVidComp-Videos -Status 'Failed' -MaxRetryCount 3

        $videos | Should -BeNullOrEmpty
    }
}

#------------------------------------------------------------------------------------------------------------------
# Statistics Workflow Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Statistics Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        # Add multiple videos with different statuses
        $videos = @(
            @{ Filename = 'stat1.mp4'; Size = 100000000; Status = 'Completed'; CompressedSize = 50000000 }
            @{ Filename = 'stat2.mp4'; Size = 200000000; Status = 'Completed'; CompressedSize = 80000000 }
            @{ Filename = 'stat3.mp4'; Size = 150000000; Status = 'Cataloged'; CompressedSize = $null }
            @{ Filename = 'stat4.mp4'; Size = 100000000; Status = 'Failed'; CompressedSize = $null }
        )

        foreach ($v in $videos) {
            $record = Get-TestVideoRecord -Filename $v.Filename -Size $v.Size
            Add-SPVidComp-Video @record

            $id = (Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query "SELECT id FROM videos WHERE filename = '$($v.Filename)'").id

            if ($v.Status -ne 'Cataloged') {
                $updateQuery = "UPDATE videos SET status = '$($v.Status)'"
                if ($v.CompressedSize) {
                    $updateQuery += ", compressed_size = $($v.CompressedSize)"
                }
                $updateQuery += " WHERE id = $id"
                Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query $updateQuery
            }
        }
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should calculate total cataloged count' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalCataloged | Should -Be 4
    }

    It 'Should calculate total original size' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalOriginalSize | Should -Be 550000000  # 100 + 200 + 150 + 100
    }

    It 'Should calculate total compressed size' {
        $stats = Get-SPVidComp-Statistics

        $stats.TotalCompressedSize | Should -Be 130000000  # 50 + 80
    }

    It 'Should calculate space saved' {
        $stats = Get-SPVidComp-Statistics

        # Original completed = 300 MB, Compressed = 130 MB, Saved = 170 MB
        $stats.SpaceSaved | Should -Be 170000000
    }

    It 'Should include status breakdown' {
        $stats = Get-SPVidComp-Statistics

        $completed = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Completed' }
        $failed = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Failed' }
        $cataloged = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Cataloged' }

        $completed.count | Should -Be 2
        $failed.count | Should -Be 1
        $cataloged.count | Should -Be 1
    }
}

#------------------------------------------------------------------------------------------------------------------
# Resume Capability Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Resume Capability' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        # Add videos in various states to simulate interrupted run
        $videos = @(
            @{ Filename = 'completed.mp4'; Status = 'Completed' }
            @{ Filename = 'downloading.mp4'; Status = 'Downloading' }
            @{ Filename = 'compressing.mp4'; Status = 'Compressing' }
            @{ Filename = 'cataloged1.mp4'; Status = 'Cataloged' }
            @{ Filename = 'cataloged2.mp4'; Status = 'Cataloged' }
        )

        foreach ($v in $videos) {
            $record = Get-TestVideoRecord -Filename $v.Filename
            Add-SPVidComp-Video @record

            if ($v.Status -ne 'Cataloged') {
                $id = (Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query "SELECT id FROM videos WHERE filename = '$($v.Filename)'").id
                Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query "UPDATE videos SET status = '$($v.Status)' WHERE id = $id"
            }
        }
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should find videos to process (Cataloged status)' {
        $toProcess = Get-SPVidComp-Videos -Status 'Cataloged'

        $toProcess.Count | Should -Be 2
    }

    It 'Should find interrupted videos (Downloading status)' {
        $interrupted = Get-SPVidComp-Videos -Status 'Downloading'

        $interrupted.Count | Should -Be 1
        $interrupted[0].filename | Should -Be 'downloading.mp4'
    }

    It 'Should find interrupted videos (Compressing status)' {
        $interrupted = Get-SPVidComp-Videos -Status 'Compressing'

        $interrupted.Count | Should -Be 1
        $interrupted[0].filename | Should -Be 'compressing.mp4'
    }

    It 'Should not include completed videos in processing queue' {
        $cataloged = Get-SPVidComp-Videos -Status 'Cataloged'
        $filenames = $cataloged | ForEach-Object { $_.filename }

        $filenames | Should -Not -Contain 'completed.mp4'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Configuration Persistence Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Configuration Persistence' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should persist configuration across reinitializations' {
        $config = @{
            'sharepoint_site_url' = 'https://test.sharepoint.com'
            'compression_frame_rate' = '15'
            'paths_temp_download' = 'C:\Temp\Test'
        }

        Set-SPVidComp-Config -ConfigValues $config

        # Simulate script restart by reinitializing catalog
        Initialize-SPVidComp-Catalog -DatabasePath $Script:TestDbPath

        $retrieved = Get-SPVidComp-Config

        $retrieved['sharepoint_site_url'] | Should -Be 'https://test.sharepoint.com'
        $retrieved['compression_frame_rate'] | Should -Be '15'
    }

    It 'Should indicate config exists after saving' {
        $result = Test-SPVidComp-ConfigExists

        $result | Should -BeTrue
    }
}
