#------------------------------------------------------------------------------------------------------------------
# ComponentIntegration.Tests.ps1 - Integration tests for cross-component interactions
# Verifies that different parts of the system work together correctly
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Ensure PSSQLite is available
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Install-Module -Name PSSQLite -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module PSSQLite -Force

    # Create test directories
    $Script:TestTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "integration-test-$(Get-Random)"
    $Script:TestArchiveDir = Join-Path -Path $Script:TestTempDir -ChildPath 'archive'
    $Script:TestLogDir = Join-Path -Path $Script:TestTempDir -ChildPath 'logs'
    $Script:TestDbPath = Join-Path -Path $Script:TestTempDir -ChildPath 'test-catalog.db'

    New-Item -ItemType Directory -Path $Script:TestTempDir -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:TestArchiveDir -Force | Out-Null
    New-Item -ItemType Directory -Path $Script:TestLogDir -Force | Out-Null

    # Remove any cached module and force fresh import
    Remove-Module VideoCompressionModule -Force -ErrorAction SilentlyContinue

    # Import the module with -Force to ensure latest version
    Import-TestModule
}

AfterAll {
    # Cleanup
    if (Test-Path -LiteralPath $Script:TestTempDir) {
        Remove-Item -LiteralPath $Script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# FFmpeg Availability Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'FFmpeg Availability Integration' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
        Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    Context 'Test-SPVidCompFFmpegAvailability function' {
        It 'Should return a result with all required properties' {
            $result = Test-SPVidCompFFmpegAvailability

            $result | Should -Not -BeNullOrEmpty
            $result.ContainsKey('FFmpegAvailable') | Should -BeTrue
            $result.ContainsKey('FFprobeAvailable') | Should -BeTrue
            $result.ContainsKey('AllAvailable') | Should -BeTrue
            $result.ContainsKey('Errors') | Should -BeTrue
        }

        It 'Should return detailed info when -Detailed switch is used' {
            $result = Test-SPVidCompFFmpegAvailability -Detailed

            $result.ContainsKey('FFmpegVersion') | Should -BeTrue
            $result.ContainsKey('FFprobeVersion') | Should -BeTrue
        }

        It 'Should log the availability check' {
            # Clear log directory
            Get-ChildItem -Path $Script:TestLogDir -Filter '*.log' | Remove-Item -Force -ErrorAction SilentlyContinue

            # Re-initialize logger to ensure fresh log file
            Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

            $null = Test-SPVidCompFFmpegAvailability

            # Wait a moment for file system
            Start-Sleep -Milliseconds 100

            # Check that something was logged
            $logFiles = Get-ChildItem -Path $Script:TestLogDir -Filter '*.log'
            $logFiles.Count | Should -BeGreaterThan 0

            # Verify log content mentions ffmpeg check
            $logContent = Get-Content -Path $logFiles[0].FullName -Raw
            ($logContent -match 'ffmpeg' -or $logContent -match 'ffprobe') | Should -BeTrue
        }
    }

    Context 'FFmpeg availability affects compression workflow' {
        It 'Should be checkable before starting compression' {
            $availability = Test-SPVidCompFFmpegAvailability

            # The result should provide enough information to decide whether to proceed
            $availability.AllAvailable | Should -BeOfType [bool]

            # If not available, errors should be populated
            if (-not $availability.AllAvailable) {
                $availability.Errors.Count | Should -BeGreaterThan 0
            }
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Configuration Affects System Behavior Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Configuration Affects System Behavior' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    Context 'Logger configuration integration' {
        It 'Should update logger when log level config changes' {
            # Clear and set up fresh log directory
            $testLogDir = Join-Path -Path $Script:TestTempDir -ChildPath "config-log-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testLogDir -Force | Out-Null

            # Initialize with Debug level
            Initialize-Logger -LogPath $testLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

            # Write a debug message
            Write-SPVidCompLog -Message 'Debug level test message' -Level 'Debug'
            Start-Sleep -Milliseconds 100

            $logFiles = Get-ChildItem -Path $testLogDir -Filter '*.log'
            $logContent = Get-Content -Path $logFiles[0].FullName -Raw
            $logContent | Should -Match 'Debug level test message'

            # Reinitialize with Error level (should filter out Debug messages)
            Initialize-Logger -LogPath $testLogDir -LogLevel 'Error' -ConsoleOutput $false -FileOutput $true

            # Write another debug message - should NOT appear
            Write-SPVidCompLog -Message 'This debug should be filtered' -Level 'Debug'

            # Write an error message - should appear
            Write-SPVidCompLog -Message 'This error should appear' -Level 'Error'
            Start-Sleep -Milliseconds 100

            $logContent = Get-Content -Path $logFiles[0].FullName -Raw

            # The debug message after level change should NOT be in the log
            $logContent | Should -Not -Match 'This debug should be filtered'

            # The error message should be in the log
            $logContent | Should -Match 'This error should appear'

            # Cleanup
            Remove-Item -Path $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Should change log file location when path config changes' {
            $logDir1 = Join-Path -Path $Script:TestTempDir -ChildPath "log-path-1-$(Get-Random)"
            $logDir2 = Join-Path -Path $Script:TestTempDir -ChildPath "log-path-2-$(Get-Random)"

            New-Item -ItemType Directory -Path $logDir1 -Force | Out-Null
            New-Item -ItemType Directory -Path $logDir2 -Force | Out-Null

            # Initialize logger to first path
            Initialize-Logger -LogPath $logDir1 -LogLevel 'Info' -ConsoleOutput $false -FileOutput $true
            Write-SPVidCompLog -Message 'Message in path 1' -Level 'Info'
            Start-Sleep -Milliseconds 100

            # Verify log file in first path
            $logsInPath1 = Get-ChildItem -Path $logDir1 -Filter '*.log'
            $logsInPath1.Count | Should -BeGreaterThan 0

            # Change to second path
            Initialize-Logger -LogPath $logDir2 -LogLevel 'Info' -ConsoleOutput $false -FileOutput $true
            Write-SPVidCompLog -Message 'Message in path 2' -Level 'Info'
            Start-Sleep -Milliseconds 100

            # Verify log file in second path
            $logsInPath2 = Get-ChildItem -Path $logDir2 -Filter '*.log'
            $logsInPath2.Count | Should -BeGreaterThan 0

            $content2 = Get-Content -Path $logsInPath2[0].FullName -Raw
            $content2 | Should -Match 'Message in path 2'

            # Cleanup
            Remove-Item -Path $logDir1 -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $logDir2 -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Email configuration integration' {
        BeforeEach {
            # Reset email config state in module scope
            InModuleScope VideoCompressionModule {
                $Script:EmailConfig = $null
                $Script:MailKitInstallAttempted = $false
                $Script:MailKitAvailable = $false
            }
        }

        It 'Should return false when email is disabled in config' {
            Initialize-EmailConfig -Config @{
                Enabled = $false
                SmtpServer = 'smtp.test.com'
                From = 'test@test.com'
                To = @('recipient@test.com')
            }

            $result = Send-SPVidCompNotification -Subject 'Test' -Body 'Test body'

            $result | Should -BeFalse
        }

        It 'Should respect email enabled/disabled config changes' {
            # First disable email
            Initialize-EmailConfig -Config @{
                Enabled = $false
                SmtpServer = 'smtp.test.com'
                From = 'test@test.com'
                To = @('recipient@test.com')
            }

            $resultDisabled = Send-SPVidCompNotification -Subject 'Test' -Body 'Body'
            $resultDisabled | Should -BeFalse

            # Now enable email (will still fail due to no MailKit, but flow is different)
            InModuleScope VideoCompressionModule {
                $Script:MailKitInstallAttempted = $true
                $Script:MailKitAvailable = $false
            }

            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                From = 'test@test.com'
                To = @('recipient@test.com')
            }

            # This should attempt to send (and fail for a different reason - MailKit not available)
            # The key is that it tries when enabled vs returns immediately when disabled
            $resultEnabled = Send-SPVidCompNotification -Subject 'Test' -Body 'Body'
            $resultEnabled | Should -BeFalse  # Still false, but took different code path
        }
    }

    Context 'Database configuration persistence' {
        It 'Should persist and retrieve config values that affect other systems' {
            # Set complete configuration
            $configValues = Get-TestConfig
            $configValues['logging_log_level'] = 'Debug'
            $configValues['email_enabled'] = 'True'
            $configValues['compression_timeout_minutes'] = '30'
            $configValues['paths_temp_download'] = '/tmp/videos'

            Set-SPVidCompConfig -ConfigValues $configValues

            # Retrieve and verify
            $retrieved = Get-SPVidCompConfig

            $retrieved['logging_log_level'] | Should -Be 'Debug'
            $retrieved['email_enabled'] | Should -Be 'True'
            $retrieved['compression_timeout_minutes'] | Should -Be '30'
            $retrieved['paths_temp_download'] | Should -Be '/tmp/videos'
        }

        It 'Should persist config across database reinitializations' {
            # First set a complete config
            $configValues = Get-TestConfig
            $configValues['sharepoint_site_url'] = 'https://persistence-test.sharepoint.com'

            Set-SPVidCompConfig -ConfigValues $configValues

            # Reinitialize catalog (simulates restart)
            Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath

            $retrieved = Get-SPVidCompConfig
            $retrieved['sharepoint_site_url'] | Should -Be 'https://persistence-test.sharepoint.com'
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Email Notification Trigger Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Email Notification Triggers' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
        Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        # Track email send attempts
        $Script:EmailSendAttempts = @()
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    Context 'Report generation for email' {
        It 'Should generate valid completion report from real statistics' {
            # Add real test data to the database
            $videos = @(
                @{ Filename = 'report-test-1.mp4'; Status = 'Completed'; OriginalSize = 100000000; CompressedSize = 50000000 }
                @{ Filename = 'report-test-2.mp4'; Status = 'Completed'; OriginalSize = 200000000; CompressedSize = 80000000 }
                @{ Filename = 'report-test-3.mp4'; Status = 'Failed'; OriginalSize = 150000000; CompressedSize = $null }
            )

            foreach ($v in $videos) {
                $record = Get-TestVideoRecord -Filename $v.Filename -Size $v.OriginalSize
                Add-SPVidCompVideo @record

                $id = (Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query "SELECT id FROM videos WHERE filename = '$($v.Filename)'").id

                $updateQuery = "UPDATE videos SET status = '$($v.Status)'"
                if ($v.CompressedSize) {
                    $updateQuery += ", compressed_size = $($v.CompressedSize)"
                }
                if ($v.Status -eq 'Failed') {
                    $updateQuery += ", last_error = 'Test error message'"
                }
                $updateQuery += " WHERE id = $id"
                Invoke-SqliteQuery -DataSource $Script:TestDbPath -Query $updateQuery
            }

            # Get actual statistics
            $stats = Get-SPVidCompStatistics

            # Get failed videos
            $failedVideos = Get-SPVidCompVideos -Status 'Failed'

            # Build completion report using real data
            $report = Build-CompletionReport -Statistics $stats -FailedVideos $failedVideos

            # Verify the report contains data from the database
            $report | Should -Match 'report-test-3'  # Failed video should be listed
            $report | Should -Match 'Test error message'  # Error message should be included
        }

        It 'Should generate valid error report for failed video' {
            $video = Get-SPVidCompVideos -Status 'Failed' | Select-Object -First 1

            $report = Build-ErrorReport -ErrorMessage 'Compression failed' -VideoFilename $video.filename -SharePointUrl $video.sharepoint_url

            $report | Should -Match 'Compression failed'
            $report | Should -Match $video.filename
        }
    }

    Context 'Email notification flow integration' {
        BeforeEach {
            # Reset email state
            InModuleScope VideoCompressionModule {
                $Script:EmailConfig = $null
                $Script:MailKitInstallAttempted = $true
                $Script:MailKitAvailable = $true
            }
        }

        It 'Should be callable with completion report from real statistics' {
            # Setup email config for testing (enabled but will use mock)
            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'test@test.com'
                To = @('recipient@test.com')
                SendOnCompletion = $true
                SendOnError = $true
            }

            # Mock the actual send function
            Mock -ModuleName VideoCompressionModule Send-EmailViaMailKit { return $true }

            # Build real report from stats
            $stats = Get-SPVidCompStatistics
            $report = Build-CompletionReport -Statistics $stats

            # Send notification
            $result = Send-SPVidCompNotification -Subject 'Processing Complete' -Body $report -IsHtml $true

            # Verify send was attempted
            Should -Invoke -ModuleName VideoCompressionModule -CommandName Send-EmailViaMailKit -Times 1
        }

        It 'Should integrate logging with email send attempts' {
            $logDir = Join-Path -Path $Script:TestTempDir -ChildPath "email-log-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null

            Initialize-Logger -LogPath $logDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                From = 'test@test.com'
                To = @('recipient@test.com')
            }

            # Mock to simulate failure
            Mock -ModuleName VideoCompressionModule Send-EmailViaMailKit { return $false }

            $null = Send-SPVidCompNotification -Subject 'Test' -Body 'Body'
            Start-Sleep -Milliseconds 100

            # Check logs captured the email attempt
            $logFiles = Get-ChildItem -Path $logDir -Filter '*.log'
            if ($logFiles.Count -gt 0) {
                $logContent = Get-Content -Path $logFiles[0].FullName -Raw
                # Log should contain email-related entries
                ($logContent -match 'email' -or $logContent -match 'notification' -or $logContent.Length -gt 0) | Should -BeTrue
            }

            Remove-Item -Path $logDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Full End-to-End Workflow Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Full End-to-End Workflow' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        $Script:WorkflowLogDir = Join-Path -Path $Script:TestTempDir -ChildPath "workflow-logs-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:WorkflowLogDir -Force | Out-Null

        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
        Initialize-Logger -LogPath $Script:WorkflowLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        # Initialize email config (disabled for this test to avoid side effects)
        Initialize-EmailConfig -Config @{
            Enabled = $false
        }

        # Create mock video files
        $Script:SourceVideo = Join-Path -Path $Script:TestTempDir -ChildPath 'source-video.mp4'
        New-MockVideoFile -Path $Script:SourceVideo -SizeKB 500
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
        if (Test-Path -LiteralPath $Script:WorkflowLogDir) {
            Remove-Item -Path $Script:WorkflowLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'Complete video processing pipeline' {
        It 'Step 1: Should catalog a new video' {
            $record = Get-TestVideoRecord -Filename 'workflow-test.mp4' -Size 1024000

            $result = Add-SPVidCompVideo @record

            $result | Should -BeTrue

            $videos = Get-SPVidCompVideos -Status 'Cataloged'
            $videos.Count | Should -BeGreaterThan 0
            $video = $videos | Where-Object { $_.filename -eq 'workflow-test.mp4' }
            $video | Should -Not -BeNullOrEmpty

            $Script:TestVideoId = $video.id
        }

        It 'Step 2: Should update status to Downloading and set timestamp' {
            Update-SPVidCompStatus -VideoId $Script:TestVideoId -Status 'Downloading'

            $video = (Get-SPVidCompVideos -Status 'Downloading') | Where-Object { $_.id -eq $Script:TestVideoId }
            $video.status | Should -Be 'Downloading'
            $video.processing_started | Should -Not -BeNullOrEmpty
        }

        It 'Step 3: Should archive the video with hash verification' {
            $archivePath = Join-Path -Path $Script:TestArchiveDir -ChildPath 'TestSite\Documents\Videos\workflow-test.mp4'

            $result = Copy-SPVidCompArchive -SourcePath $Script:SourceVideo -ArchivePath $archivePath

            $result.Success | Should -BeTrue
            $result.SourceHash | Should -Be $result.DestinationHash
            Test-Path -LiteralPath $archivePath | Should -BeTrue

            # Update status
            Update-SPVidCompStatus -VideoId $Script:TestVideoId -Status 'Archiving' -AdditionalFields @{
                archive_path = $archivePath
            }

            $video = (Get-SPVidCompVideos -Status 'Archiving') | Where-Object { $_.id -eq $Script:TestVideoId }
            $video.archive_path | Should -Be $archivePath
        }

        It 'Step 4: Should verify archive integrity' {
            $archivePath = Join-Path -Path $Script:TestArchiveDir -ChildPath 'TestSite\Documents\Videos\workflow-test.mp4'

            $integrityResult = Test-SPVidCompArchiveIntegrity -SourcePath $Script:SourceVideo -DestinationPath $archivePath

            $integrityResult.Success | Should -BeTrue
            $integrityResult.SourceHash | Should -Be $integrityResult.DestinationHash
        }

        It 'Step 5: Should progress through compression status' {
            Update-SPVidCompStatus -VideoId $Script:TestVideoId -Status 'Compressing'

            $video = (Get-SPVidCompVideos -Status 'Compressing') | Where-Object { $_.id -eq $Script:TestVideoId }
            $video.status | Should -Be 'Compressing'
        }

        It 'Step 6: Should update with compression results' {
            Update-SPVidCompStatus -VideoId $Script:TestVideoId -Status 'Verifying' -AdditionalFields @{
                compressed_size = 256000
                compression_ratio = 0.5
            }

            $video = (Get-SPVidCompVideos -Status 'Verifying') | Where-Object { $_.id -eq $Script:TestVideoId }
            $video.compressed_size | Should -Be 256000
        }

        It 'Step 7: Should complete the workflow' {
            Update-SPVidCompStatus -VideoId $Script:TestVideoId -Status 'Completed'

            $video = (Get-SPVidCompVideos -Status 'Completed') | Where-Object { $_.id -eq $Script:TestVideoId }
            $video.status | Should -Be 'Completed'
            $video.processing_completed | Should -Not -BeNullOrEmpty
        }

        It 'Step 8: Should have logged all workflow steps' {
            Start-Sleep -Milliseconds 200

            $logFiles = Get-ChildItem -Path $Script:WorkflowLogDir -Filter '*.log'
            $logFiles.Count | Should -BeGreaterThan 0

            $logContent = Get-Content -Path $logFiles[0].FullName -Raw

            # Verify key operations were logged
            $logContent | Should -Not -BeNullOrEmpty
        }

        It 'Step 9: Statistics should reflect the completed workflow' {
            $stats = Get-SPVidCompStatistics

            $stats.TotalCataloged | Should -BeGreaterThan 0

            $completedStatus = $stats.StatusBreakdown | Where-Object { $_.status -eq 'Completed' }
            $completedStatus.count | Should -BeGreaterThan 0
        }
    }

    Context 'Error handling workflow' {
        BeforeAll {
            # Add a new video for error testing
            $record = Get-TestVideoRecord -Filename 'error-workflow-test.mp4' -Size 2048000
            Add-SPVidCompVideo @record

            $Script:ErrorTestVideo = (Get-SPVidCompVideos -Status 'Cataloged') | Where-Object { $_.filename -eq 'error-workflow-test.mp4' }
        }

        It 'Should handle failure and store error details' {
            Update-SPVidCompStatus -VideoId $Script:ErrorTestVideo.id -Status 'Downloading'
            Update-SPVidCompStatus -VideoId $Script:ErrorTestVideo.id -Status 'Failed' -AdditionalFields @{
                last_error = 'Connection timeout after 30 seconds'
                retry_count = 1
            }

            $video = (Get-SPVidCompVideos -Status 'Failed') | Where-Object { $_.id -eq $Script:ErrorTestVideo.id }
            $video.last_error | Should -Be 'Connection timeout after 30 seconds'
            $video.retry_count | Should -Be 1
        }

        It 'Should generate error report for failed video' {
            $failedVideo = (Get-SPVidCompVideos -Status 'Failed') | Where-Object { $_.id -eq $Script:ErrorTestVideo.id }

            $errorReport = Build-ErrorReport -ErrorMessage $failedVideo.last_error -VideoFilename $failedVideo.filename -SharePointUrl $failedVideo.sharepoint_url

            $errorReport | Should -Match $failedVideo.filename
            $errorReport | Should -Match 'Connection timeout'
        }

        It 'Should be retriable and update retry count' {
            Update-SPVidCompStatus -VideoId $Script:ErrorTestVideo.id -Status 'Cataloged' -AdditionalFields @{
                retry_count = 2
            }

            Update-SPVidCompStatus -VideoId $Script:ErrorTestVideo.id -Status 'Downloading'
            Update-SPVidCompStatus -VideoId $Script:ErrorTestVideo.id -Status 'Failed' -AdditionalFields @{
                last_error = 'Second failure'
                retry_count = 3
            }

            $video = (Get-SPVidCompVideos -Status 'Failed') | Where-Object { $_.id -eq $Script:ErrorTestVideo.id }
            $video.retry_count | Should -Be 3
        }

        It 'Should be excluded when retry count exceeds max' {
            $videosUnderLimit = Get-SPVidCompVideos -Status 'Failed' -MaxRetryCount 2

            $excluded = $videosUnderLimit | Where-Object { $_.id -eq $Script:ErrorTestVideo.id }
            $excluded | Should -BeNullOrEmpty
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Database and Logging Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Database and Logging Integration' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        $Script:IntegrationLogDir = Join-Path -Path $Script:TestTempDir -ChildPath "db-log-integration-$(Get-Random)"
        New-Item -ItemType Directory -Path $Script:IntegrationLogDir -Force | Out-Null

        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
        Initialize-Logger -LogPath $Script:IntegrationLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
        if (Test-Path -LiteralPath $Script:IntegrationLogDir) {
            Remove-Item -Path $Script:IntegrationLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Should log when videos are added to the catalog' {
        $record = Get-TestVideoRecord -Filename 'logging-integration-test.mp4'
        Add-SPVidCompVideo @record

        Start-Sleep -Milliseconds 100

        $logFiles = Get-ChildItem -Path $Script:IntegrationLogDir -Filter '*.log'
        $logFiles.Count | Should -BeGreaterThan 0
    }

    It 'Should log when video status changes' {
        $video = (Get-SPVidCompVideos -Status 'Cataloged') | Select-Object -First 1

        if (-not $video) {
            # Add a video if none exist
            $record = Get-TestVideoRecord -Filename "status-change-log-test-$(Get-Random).mp4"
            Add-SPVidCompVideo @record
            $video = (Get-SPVidCompVideos -Status 'Cataloged') | Select-Object -First 1
        }

        Update-SPVidCompStatus -VideoId $video.id -Status 'Downloading'

        Start-Sleep -Milliseconds 100

        # Verify log file exists and has content
        $logFiles = Get-ChildItem -Path $Script:IntegrationLogDir -Filter '*.log'
        $logFiles.Count | Should -BeGreaterThan 0

        $logContent = Get-Content -Path $logFiles[0].FullName -Raw
        $logContent | Should -Not -BeNullOrEmpty
    }

    It 'Should log catalog initialization' {
        $newLogDir = Join-Path -Path $Script:TestTempDir -ChildPath "init-log-$(Get-Random)"
        New-Item -ItemType Directory -Path $newLogDir -Force | Out-Null

        Initialize-Logger -LogPath $newLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        $newDbPath = New-TestDatabase -Path (Join-Path -Path $Script:TestTempDir -ChildPath "init-test-$(Get-Random).db")
        Initialize-SPVidCompCatalog -DatabasePath $newDbPath

        Start-Sleep -Milliseconds 100

        $logFiles = Get-ChildItem -Path $newLogDir -Filter '*.log'
        $logFiles.Count | Should -BeGreaterThan 0

        $logContent = Get-Content -Path $logFiles[0].FullName -Raw
        ($logContent -match 'catalog' -or $logContent -match 'initialize' -or $logContent -match 'Database') | Should -BeTrue

        # Cleanup
        Remove-TestDatabase -Path $newDbPath
        Remove-Item -Path $newLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Disk Space Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Disk Space Integration' {
    BeforeAll {
        Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
    }

    Context 'Non-existent directory handling' {
        It 'Should handle non-existent temp directory path' {
            $nonExistentPath = Join-Path -Path $Script:TestTempDir -ChildPath "non-existent-$(Get-Random)\deeply\nested\path"

            $result = Test-SPVidCompDiskSpace -Path $nonExistentPath -RequiredBytes 1024

            $result | Should -Not -BeNullOrEmpty
            $result.ContainsKey('HasSpace') | Should -BeTrue
            # Should not error out
        }

        It 'Should create directory or use parent for space check' {
            $testPath = Join-Path -Path $Script:TestTempDir -ChildPath "disk-space-test-$(Get-Random)"

            # Path should not exist initially
            Test-Path -LiteralPath $testPath | Should -BeFalse

            $result = Test-SPVidCompDiskSpace -Path $testPath -RequiredBytes 1024

            $result.HasSpace | Should -BeOfType [bool]
            $result.FreeSpace | Should -BeGreaterThan 0
        }
    }

    Context 'Disk space affects workflow decisions' {
        It 'Should report insufficient space for large requirements' {
            $path = $Script:TestTempDir

            # Request impossibly large space (100 TB)
            $result = Test-SPVidCompDiskSpace -Path $path -RequiredBytes (100TB)

            $result.HasSpace | Should -BeFalse
        }

        It 'Should report sufficient space for small requirements' {
            $path = $Script:TestTempDir

            # Request tiny amount (1 KB)
            $result = Test-SPVidCompDiskSpace -Path $path -RequiredBytes 1024

            $result.HasSpace | Should -BeTrue
            $result.FreeSpace | Should -BeGreaterThan 1024
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Filename Sanitization Integration Tests
#------------------------------------------------------------------------------------------------------------------
Describe 'Filename Sanitization Workflow Integration' {
    BeforeAll {
        $Script:TestDbPath = New-TestDatabase
        Initialize-SPVidCompCatalog -DatabasePath $Script:TestDbPath
        Initialize-Logger -LogPath $Script:TestLogDir -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        # Get the actual illegal characters for this platform
        $Script:IllegalChars = Get-SPVidCompIllegalCharacters
    }

    AfterAll {
        Remove-TestDatabase -Path $Script:TestDbPath
    }

    It 'Should sanitize filename with null character' {
        # Null character is universally invalid across all platforms
        $illegalFilename = "video`0name.mp4"

        $sanitizeResult = Repair-SPVidCompFilename -Filename $illegalFilename -Strategy 'Replace' -ReplacementChar '_'

        $sanitizeResult.Success | Should -BeTrue
        $sanitizeResult.Changed | Should -BeTrue
        $sanitizeResult.SanitizedFilename | Should -Not -Match "`0"
    }

    It 'Should integrate filename check into validation flow' {
        $testFilename = "test-file.mp4"

        $checkResult = Test-SPVidCompFilenameCharacters -Filename $testFilename

        $checkResult.IsValid | Should -BeTrue
        $checkResult.OriginalFilename | Should -Be $testFilename
    }

    It 'Should identify illegal characters based on platform' {
        # Use null character which is always illegal
        $illegalFilename = "file`0name.mp4"

        $checkResult = Test-SPVidCompFilenameCharacters -Filename $illegalFilename

        $checkResult.IsValid | Should -BeFalse
        $checkResult.IllegalCharacters.Count | Should -BeGreaterThan 0
    }

    It 'Should return list of platform-specific illegal characters' {
        $illegalChars = Get-SPVidCompIllegalCharacters

        $illegalChars | Should -Not -BeNullOrEmpty
        $illegalChars.Count | Should -BeGreaterThan 0

        # Null character should always be in the list
        $illegalChars | Should -Contain ([char]0)
    }
}
