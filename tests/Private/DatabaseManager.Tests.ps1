#------------------------------------------------------------------------------------------------------------------
# DatabaseManager.Tests.ps1 - Unit tests for DatabaseManager.ps1
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Import the main module
    Import-TestModule
}

Describe 'Initialize-SPVidCompDatabase' {
    It 'Should create database file with all required tables and indices' {
        $dbPath = New-TestDatabase

        Initialize-SPVidCompDatabase -DatabasePath $dbPath

        # Verify file exists
        Test-Path -LiteralPath $dbPath | Should -BeTrue

        # Verify all tables exist
        $tables = Invoke-SqliteQuery -DataSource $dbPath -Query "SELECT name FROM sqlite_master WHERE type='table'"
        $tableNames = $tables.name

        $tableNames | Should -Contain 'videos'
        $tableNames | Should -Contain 'processing_log'
        $tableNames | Should -Contain 'metadata'
        $tableNames | Should -Contain 'config'
        $tableNames | Should -Contain 'logs'

        Remove-TestDatabase -Path $dbPath
    }
}

Describe 'Add-SPVidCompVideo' {
    BeforeAll {
        $dbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $dbPath
        Initialize-SPVidCompLogger -DatabasePath $dbPath -LogLevel 'Error' -ConsoleOutput $false
    }

    AfterAll {
        Remove-TestDatabase -Path $dbPath
    }

    It 'Should add video record with all metadata' {
        $video = Get-TestVideoRecord

        $result = Add-SPVidCompVideo -SharePointUrl $video.SharePointUrl `
            -SiteUrl $video.SiteUrl `
            -LibraryName $video.LibraryName `
            -FolderPath $video.FolderPath `
            -Filename $video.Filename `
            -OriginalSize $video.OriginalSize `
            -ModifiedDate $video.ModifiedDate

        $result | Should -BeTrue

        # Verify video was added with correct data
        $stored = Get-SPVidCompVideos

        $stored | Should -Not -BeNullOrEmpty
        $stored[0].filename | Should -Be $video.Filename
        $stored[0].original_size | Should -Be $video.OriginalSize
        $stored[0].status | Should -Be 'Cataloged'
        $stored[0].retry_count | Should -Be 0
    }

    It 'Should not duplicate videos with same SharePoint URL' {
        $video = Get-TestVideoRecord -Filename "duplicate-test.mp4"

        Add-SPVidCompVideo -SharePointUrl $video.SharePointUrl `
            -SiteUrl $video.SiteUrl `
            -LibraryName $video.LibraryName `
            -FolderPath $video.FolderPath `
            -Filename $video.Filename `
            -OriginalSize $video.OriginalSize `
            -ModifiedDate $video.ModifiedDate

        Add-SPVidCompVideo -SharePointUrl $video.SharePointUrl `
            -SiteUrl $video.SiteUrl `
            -LibraryName $video.LibraryName `
            -FolderPath $video.FolderPath `
            -Filename $video.Filename `
            -OriginalSize $video.OriginalSize `
            -ModifiedDate $video.ModifiedDate

        $videos = Get-SPVidCompVideos
        ($videos | Where-Object { $_.sharepoint_url -eq $video.SharePointUrl }).Count | Should -Be 1
    }
}

Describe 'Get-SPVidCompVideos' {
    BeforeAll {
        $dbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $dbPath
        Initialize-SPVidCompLogger -DatabasePath $dbPath -LogLevel 'Error' -ConsoleOutput $false

        # Add test videos with different statuses
        1..3 | ForEach-Object {
            $video = Get-TestVideoRecord -Filename "cataloged-$_.mp4"
            Add-SPVidCompVideo -SharePointUrl $video.SharePointUrl `
                -SiteUrl $video.SiteUrl `
                -LibraryName $video.LibraryName `
                -FolderPath $video.FolderPath `
                -Filename $video.Filename `
                -OriginalSize $video.OriginalSize `
                -ModifiedDate $video.ModifiedDate
        }

        $completed = Get-TestVideoRecord -Filename "completed.mp4"
        Add-SPVidCompVideo -SharePointUrl $completed.SharePointUrl `
            -SiteUrl $completed.SiteUrl `
            -LibraryName $completed.LibraryName `
            -FolderPath $completed.FolderPath `
            -Filename $completed.Filename `
            -OriginalSize $completed.OriginalSize `
            -ModifiedDate $completed.ModifiedDate
        Update-SPVidCompStatus -VideoId 4 -Status 'Completed'

        $failed = Get-TestVideoRecord -Filename "failed.mp4"
        Add-SPVidCompVideo -SharePointUrl $failed.SharePointUrl `
            -SiteUrl $failed.SiteUrl `
            -LibraryName $failed.LibraryName `
            -FolderPath $failed.FolderPath `
            -Filename $failed.Filename `
            -OriginalSize $failed.OriginalSize `
            -ModifiedDate $failed.ModifiedDate
        Update-SPVidCompStatus -VideoId 5 -Status 'Failed'
    }

    AfterAll {
        Remove-TestDatabase -Path $dbPath
    }

    It 'Should return all videos and filter by status' {
        $all = Get-SPVidCompVideos
        $all.Count | Should -Be 5

        $cataloged = Get-SPVidCompVideos -Status 'Cataloged'
        $cataloged.Count | Should -Be 3

        $completed = Get-SPVidCompVideos -Status 'Completed'
        $completed.Count | Should -Be 1

        $failed = Get-SPVidCompVideos -Status 'Failed'
        $failed.Count | Should -Be 1
    }

    It 'Should respect Limit parameter' {
        $limited = Get-SPVidCompVideos -Limit 2
        $limited.Count | Should -Be 2
    }
}

Describe 'Update-SPVidCompStatus' {
    BeforeAll {
        $dbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $dbPath
        Initialize-SPVidCompLogger -DatabasePath $dbPath -LogLevel 'Error' -ConsoleOutput $false

        $video = Get-TestVideoRecord
        Add-SPVidCompVideo -SharePointUrl $video.SharePointUrl `
            -SiteUrl $video.SiteUrl `
            -LibraryName $video.LibraryName `
            -FolderPath $video.FolderPath `
            -Filename $video.Filename `
            -OriginalSize $video.OriginalSize `
            -ModifiedDate $video.ModifiedDate
    }

    AfterAll {
        Remove-TestDatabase -Path $dbPath
    }

    It 'Should update status and set timestamps appropriately' {
        # Update to Downloading - should set processing_started
        $result = Update-SPVidCompStatus -VideoId 1 -Status 'Downloading'
        $result | Should -BeTrue

        $video = Get-SPVidCompVideos | Where-Object { $_.id -eq 1 }
        $video.status | Should -Be 'Downloading'
        $video.processing_started | Should -Not -BeNullOrEmpty

        # Update to Completed - should set processing_completed
        Update-SPVidCompStatus -VideoId 1 -Status 'Completed'

        $video = Get-SPVidCompVideos | Where-Object { $_.id -eq 1 }
        $video.status | Should -Be 'Completed'
        $video.processing_completed | Should -Not -BeNullOrEmpty
    }

    It 'Should update additional fields' {
        $result = Update-SPVidCompStatus -VideoId 1 -Status 'Compressing' `
            -AdditionalFields @{ compressed_size = 50MB; archive_path = '/tmp/archive/test.mp4' }

        $video = Get-SPVidCompVideos | Where-Object { $_.id -eq 1 }
        $video.compressed_size | Should -Be 50MB
        $video.archive_path | Should -Be '/tmp/archive/test.mp4'
    }
}

Describe 'Get-SPVidCompStatistics' {
    BeforeAll {
        $dbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $dbPath
        Initialize-SPVidCompLogger -DatabasePath $dbPath -LogLevel 'Error' -ConsoleOutput $false

        # Add videos with different statuses and sizes
        $video1 = Get-TestVideoRecord -Filename "video1.mp4" -Size 100MB
        Add-SPVidCompVideo -SharePointUrl $video1.SharePointUrl `
            -SiteUrl $video1.SiteUrl `
            -LibraryName $video1.LibraryName `
            -FolderPath $video1.FolderPath `
            -Filename $video1.Filename `
            -OriginalSize $video1.OriginalSize `
            -ModifiedDate $video1.ModifiedDate
        Update-SPVidCompStatus -VideoId 1 -Status 'Completed' -AdditionalFields @{ compressed_size = 50MB }

        $video2 = Get-TestVideoRecord -Filename "video2.mp4" -Size 200MB
        Add-SPVidCompVideo -SharePointUrl $video2.SharePointUrl `
            -SiteUrl $video2.SiteUrl `
            -LibraryName $video2.LibraryName `
            -FolderPath $video2.FolderPath `
            -Filename $video2.Filename `
            -OriginalSize $video2.OriginalSize `
            -ModifiedDate $video2.ModifiedDate
        Update-SPVidCompStatus -VideoId 2 -Status 'Failed'
    }

    AfterAll {
        Remove-TestDatabase -Path $dbPath
    }

    It 'Should return comprehensive statistics' {
        $stats = Get-SPVidCompStatistics

        $stats | Should -Not -BeNullOrEmpty
        $stats.TotalCataloged | Should -Be 2
        $stats.TotalOriginalSize | Should -Be 300MB
        $stats.TotalCompressedSize | Should -Be 50MB
        $stats.SpaceSaved | Should -Be 50MB
        $stats.StatusBreakdown | Should -Not -BeNullOrEmpty
        $stats.StatusBreakdown.Count | Should -BeGreaterThan 0
    }
}

Describe 'Config and Metadata Functions' {
    BeforeAll {
        $dbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $dbPath
        Initialize-SPVidCompLogger -DatabasePath $dbPath -LogLevel 'Error' -ConsoleOutput $false
    }

    AfterAll {
        Remove-TestDatabase -Path $dbPath
    }

    It 'Should store and retrieve configuration' {
        $configExists = Test-SPVidCompConfigExists
        $configExists | Should -BeFalse

        $config = Get-TestConfig
        $result = Set-SPVidCompConfig -ConfigValues $config
        $result | Should -BeTrue

        $configExists = Test-SPVidCompConfigExists
        $configExists | Should -BeTrue

        $retrieved = Get-SPVidCompConfig
        $retrieved | Should -Not -BeNullOrEmpty
        $retrieved['sharepoint_site_url'] | Should -Be $config['sharepoint_site_url']
    }
}
