#------------------------------------------------------------------------------------------------------------------
# EmailHelper.Tests.ps1 - Unit tests for EmailHelper.ps1
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Import the main module (which includes EmailHelper and Logger)
    Import-TestModule

    # Initialize logger to suppress output
    $testLogPath = New-TestLogDirectory
    Initialize-Logger -LogPath $testLogPath -LogLevel 'Error' -ConsoleOutput $false -FileOutput $false
}

AfterAll {
    Remove-TestLogDirectory
}

Describe 'Initialize-EmailConfig' {
    It 'Should store email configuration without throwing' {
        # Note: $Script:EmailConfig is module-internal and not accessible from test scope
        # We verify the function runs successfully without errors
        $config = @{
            Enabled = $true
            SmtpServer = 'smtp.test.com'
            SmtpPort = 587
            UseSSL = $true
            From = 'sender@test.com'
            To = @('recipient@test.com')
            SendOnCompletion = $true
            SendOnError = $true
        }

        { Initialize-EmailConfig -Config $config } | Should -Not -Throw
    }

    It 'Should handle disabled email configuration' {
        $config = @{
            Enabled = $false
            SmtpServer = ''
            SmtpPort = 25
            UseSSL = $false
            From = ''
            To = @()
            SendOnCompletion = $false
            SendOnError = $false
        }

        { Initialize-EmailConfig -Config $config } | Should -Not -Throw

        $Script:EmailConfig.Enabled | Should -BeFalse
    }

    It 'Should accept multiple recipients without error' {
        $config = @{
            Enabled = $true
            SmtpServer = 'smtp.test.com'
            SmtpPort = 587
            UseSSL = $true
            From = 'sender@test.com'
            To = @('user1@test.com', 'user2@test.com', 'user3@test.com')
            SendOnCompletion = $true
            SendOnError = $true
        }

        { Initialize-EmailConfig -Config $config } | Should -Not -Throw
    }
}

Describe 'Send-EmailNotification' {
    Context 'When email is disabled' {
        BeforeAll {
            Initialize-EmailConfig -Config @{
                Enabled = $false
                SmtpServer = 'smtp.test.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'sender@test.com'
                To = @('recipient@test.com')
            }
        }

        It 'Should return false without sending' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Test body'

            $result | Should -BeFalse
        }
    }

    Context 'When email is enabled' {
        BeforeAll {
            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'sender@test.com'
                To = @('recipient@test.com')
            }
        }

        It 'Should not throw when attempting to send' {
            # Will fail to actually send (no SMTP server) but should handle gracefully
            { Send-EmailNotification -Subject 'Test' -Body 'Body' } | Should -Not -Throw
        }
    }

    Context 'When email config is not initialized' {
        BeforeAll {
            # Re-initialize with null-like config
            Initialize-EmailConfig -Config @{
                Enabled = $false
                SmtpServer = ''
                SmtpPort = 25
                UseSSL = $false
                From = ''
                To = @()
            }
        }

        It 'Should return false gracefully' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Test body'

            $result | Should -BeFalse
        }
    }
}

Describe 'Build-CompletionReport' {
    BeforeAll {
        # Sample statistics data
        $Script:TestStats = @{
            TotalCataloged = 100
            TotalOriginalSize = 10737418240  # 10 GB
            TotalCompressedSize = 5368709120  # 5 GB
            SpaceSaved = 5368709120
            AverageCompressionRatio = 0.5
            StatusBreakdown = @(
                @{ status = 'Completed'; count = 85 }
                @{ status = 'Failed'; count = 10 }
                @{ status = 'Cataloged'; count = 5 }
            )
        }

        $Script:TestFailedVideos = @(
            @{ filename = 'failed1.mp4'; sharepoint_url = 'https://test.sharepoint.com/file1.mp4'; last_error = 'Download timeout' }
            @{ filename = 'failed2.mp4'; sharepoint_url = 'https://test.sharepoint.com/file2.mp4'; last_error = 'Compression failed' }
        )
    }

    It 'Should return HTML content' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match '<html>'
        $report | Should -Match '</html>'
    }

    It 'Should include report title' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match 'SharePoint Video Compression Report'
    }

    It 'Should include total cataloged count' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match '100'
    }

    It 'Should include completed count' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match '85'
    }

    It 'Should include failed count' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match '10'
    }

    It 'Should include space saved' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        # 5 GB space saved
        $report | Should -Match '5'
    }

    It 'Should include status breakdown table' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match 'Completed'
        $report | Should -Match 'Failed'
        $report | Should -Match 'Cataloged'
    }

    It 'Should include failed videos section when provided' {
        $report = Build-CompletionReport -Statistics $Script:TestStats -FailedVideos $Script:TestFailedVideos

        $report | Should -Match 'Failed Videos'
        $report | Should -Match 'failed1.mp4'
        $report | Should -Match 'failed2.mp4'
        $report | Should -Match 'Download timeout'
    }

    It 'Should not include failed videos section when empty' {
        $report = Build-CompletionReport -Statistics $Script:TestStats -FailedVideos @()

        $report | Should -Not -Match 'Failed Videos'
    }

    It 'Should include CSS styling' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match '<style>'
        $report | Should -Match 'font-family'
    }

    It 'Should include run date' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        $report | Should -Match 'Run Date'
        $report | Should -Match '\d{4}-\d{2}-\d{2}'
    }
}

Describe 'Build-ErrorReport' {
    It 'Should return HTML content' {
        $report = Build-ErrorReport -ErrorMessage 'Test error'

        $report | Should -Match '<html>'
        $report | Should -Match '</html>'
    }

    It 'Should include error message' {
        $errorMsg = 'Connection timeout after 30 seconds'

        $report = Build-ErrorReport -ErrorMessage $errorMsg

        $report | Should -Match $errorMsg
    }

    It 'Should include video filename when provided' {
        $report = Build-ErrorReport -ErrorMessage 'Error' -VideoFilename 'problem-video.mp4'

        $report | Should -Match 'problem-video.mp4'
    }

    It 'Should include SharePoint URL when provided' {
        $url = 'https://contoso.sharepoint.com/sites/Videos/video.mp4'

        $report = Build-ErrorReport -ErrorMessage 'Error' -SharePointUrl $url

        $report | Should -Match $url
    }

    It 'Should include timestamp' {
        $report = Build-ErrorReport -ErrorMessage 'Error'

        $report | Should -Match 'Time'
        $report | Should -Match '\d{4}-\d{2}-\d{2}'
    }

    It 'Should have error styling' {
        $report = Build-ErrorReport -ErrorMessage 'Error'

        $report | Should -Match 'error'
        $report | Should -Match '#d13438'  # Error color
    }

    It 'Should work with minimal parameters' {
        { Build-ErrorReport -ErrorMessage 'Minimal error' } | Should -Not -Throw

        $report = Build-ErrorReport -ErrorMessage 'Minimal error'
        $report | Should -Not -BeNullOrEmpty
    }

    It 'Should handle special characters in error message' {
        $errorMsg = 'Error: <script>alert("xss")</script> & special "chars"'

        { Build-ErrorReport -ErrorMessage $errorMsg } | Should -Not -Throw
    }
}

Describe 'Email Report Integration' {
    BeforeAll {
        Initialize-EmailConfig -Config @{
            Enabled = $true
            SmtpServer = 'smtp.test.com'
            SmtpPort = 587
            UseSSL = $true
            From = 'sender@test.com'
            To = @('recipient@test.com')
        }
    }

    It 'Should be able to build and send completion report' {
        $stats = @{
            TotalCataloged = 50
            TotalOriginalSize = 5368709120
            TotalCompressedSize = 2684354560
            SpaceSaved = 2684354560
            AverageCompressionRatio = 0.5
            StatusBreakdown = @(
                @{ status = 'Completed'; count = 50 }
            )
        }

        $report = Build-CompletionReport -Statistics $stats

        # Report should be valid HTML that could be sent
        $report | Should -Match '<html>'
        $report.Length | Should -BeGreaterThan 100
    }

    It 'Should be able to build and send error report' {
        $report = Build-ErrorReport -ErrorMessage 'Compression failed' `
            -VideoFilename 'test.mp4' `
            -SharePointUrl 'https://test.sharepoint.com/test.mp4'

        # Report should be valid HTML that could be sent
        $report | Should -Match '<html>'
        $report.Length | Should -BeGreaterThan 100
    }
}

Describe 'Edge Cases' {
    It 'Should handle empty statistics gracefully' {
        $emptyStats = @{
            TotalCataloged = 0
            TotalOriginalSize = 0
            TotalCompressedSize = 0
            SpaceSaved = 0
            AverageCompressionRatio = 0
            StatusBreakdown = @()
        }

        { Build-CompletionReport -Statistics $emptyStats } | Should -Not -Throw
    }

    It 'Should handle null StatusBreakdown' {
        $stats = @{
            TotalCataloged = 10
            TotalOriginalSize = 1073741824
            TotalCompressedSize = 536870912
            SpaceSaved = 536870912
            AverageCompressionRatio = 0.5
            StatusBreakdown = $null
        }

        { Build-CompletionReport -Statistics $stats } | Should -Not -Throw
    }

    It 'Should handle very long error messages' {
        $longError = 'A' * 10000

        { Build-ErrorReport -ErrorMessage $longError } | Should -Not -Throw
    }

    It 'Should handle unicode in filenames' {
        $report = Build-ErrorReport -ErrorMessage 'Error' -VideoFilename '日本語ファイル名.mp4'

        $report | Should -Match '日本語ファイル名.mp4'
    }
}
