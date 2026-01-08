#------------------------------------------------------------------------------------------------------------------
# EmailHelper.Tests.ps1 - Unit tests for EmailHelper.ps1
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Import the main module (which includes EmailHelper and Logger)
    Import-TestModule

    # Initialize logger to suppress output
    Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Error' -ConsoleOutput $false
}

AfterAll {
    Remove-TestLogDirectory
}

Describe 'Initialize-EmailConfig' {
    It 'Should store email configuration without throwing' {
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
                Username = ''
                Password = ''
            }
        }

        BeforeEach {
            InModuleScope VideoCompressionModule {
                $Script:MailKitInstallAttempted = $false
                $Script:MailKitAvailable = $false
            }
        }

        It 'Should return false without sending' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Test body'

            $result | Should -BeFalse
        }
    }

    Context 'When email is enabled but MailKit not available' {
        BeforeAll {
            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'sender@test.com'
                To = @('recipient@test.com')
                Username = 'testuser'
                Password = 'testpass'
            }

            Mock -ModuleName VideoCompressionModule Test-MailKitAvailability { return $false }
            Mock -ModuleName VideoCompressionModule Install-MailKit { return $false }
        }

        BeforeEach {
            InModuleScope VideoCompressionModule {
                $Script:MailKitInstallAttempted = $false
                $Script:MailKitAvailable = $false
            }
        }

        It 'Should attempt to install MailKit and return false if unavailable' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Body'

            Should -Invoke -ModuleName VideoCompressionModule -CommandName Install-MailKit -Times 1
            $result | Should -BeFalse
        }
    }

    Context 'When email is enabled and MailKit is available' {
        BeforeAll {
            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.test.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'sender@test.com'
                To = @('recipient@test.com')
                Username = 'testuser'
                Password = 'testpass'
            }

            Mock -ModuleName VideoCompressionModule Send-EmailViaMailKit { return $true }
        }

        BeforeEach {
            InModuleScope VideoCompressionModule {
                $Script:MailKitInstallAttempted = $true
                $Script:MailKitAvailable = $true
            }
        }

        It 'Should call Send-EmailViaMailKit and return true' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Body'

            Should -Invoke -ModuleName VideoCompressionModule -CommandName Send-EmailViaMailKit -Times 1
            $result | Should -BeTrue
        }
    }

    Context 'When OAuth is configured' {
        BeforeAll {
            Initialize-EmailConfig -Config @{
                Enabled = $true
                SmtpServer = 'smtp.office365.com'
                SmtpPort = 587
                UseSSL = $true
                From = 'sender@contoso.com'
                To = @('recipient@contoso.com')
                ClientId = 'test-client-id'
                TenantId = 'test-tenant-id'
                TokenCacheFile = '/tmp/test-token-cache'
                Username = ''
                Password = ''
            }

            Mock -ModuleName VideoCompressionModule Send-EmailViaMailKit { return $true }
            Mock -ModuleName VideoCompressionModule Test-MSALAvailability { return $true }
            Mock -ModuleName VideoCompressionModule Install-MSAL { return $true }
        }

        BeforeEach {
            InModuleScope VideoCompressionModule {
                $Script:MailKitInstallAttempted = $true
                $Script:MailKitAvailable = $true
                $Script:MSALInstallAttempted = $true
                $Script:MSALAvailable = $true
            }
        }

        It 'Should send email with OAuth configuration' {
            $result = Send-EmailNotification -Subject 'Test' -Body 'Body'

            Should -Invoke -ModuleName VideoCompressionModule -CommandName Send-EmailViaMailKit -Times 1
            $result | Should -BeTrue
        }
    }
}

Describe 'Build-CompletionReport' {
    BeforeAll {
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

    It 'Should return valid HTML report with all required data' {
        $report = Build-CompletionReport -Statistics $Script:TestStats

        # Verify it's HTML
        $report | Should -Match '<html>'
        $report | Should -Match '</html>'

        # Verify key data is included
        $report | Should -Match 'SharePoint Video Compression Report'
        $report | Should -Match '100'  # Total cataloged
        $report | Should -Match '85'   # Completed count
        $report | Should -Match '10'   # Failed count
        $report | Should -Match 'Completed'
        $report | Should -Match 'Failed'
        $report | Should -Match 'Cataloged'
        $report | Should -Match '<style>'  # Has CSS
        $report | Should -Match '\d{4}-\d{2}-\d{2}'  # Has date
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
}

Describe 'Build-ErrorReport' {
    It 'Should return valid HTML error report with message' {
        $errorMsg = 'Connection timeout after 30 seconds'
        $report = Build-ErrorReport -ErrorMessage $errorMsg

        $report | Should -Match '<html>'
        $report | Should -Match '</html>'
        $report | Should -Match $errorMsg
        $report | Should -Match 'error'
        $report | Should -Match '#d13438'  # Error color
        $report | Should -Match '\d{4}-\d{2}-\d{2}'  # Has timestamp
    }

    It 'Should include optional video information when provided' {
        $url = 'https://contoso.sharepoint.com/sites/Videos/video.mp4'
        $report = Build-ErrorReport -ErrorMessage 'Error' -VideoFilename 'problem-video.mp4' -SharePointUrl $url

        $report | Should -Match 'problem-video.mp4'
        $report | Should -Match $url
    }

    It 'Should handle special characters in error message' {
        $errorMsg = 'Error: <script>alert("xss")</script> & special "chars"'

        { Build-ErrorReport -ErrorMessage $errorMsg } | Should -Not -Throw
        $report = Build-ErrorReport -ErrorMessage $errorMsg
        $report | Should -Not -BeNullOrEmpty
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
            Username = 'testuser'
            Password = 'testpass'
        }
    }

    It 'Should build valid completion report that can be sent' {
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

        $report | Should -Match '<html>'
        $report.Length | Should -BeGreaterThan 100
    }

    It 'Should build valid error report that can be sent' {
        $report = Build-ErrorReport -ErrorMessage 'Compression failed' `
            -VideoFilename 'test.mp4' `
            -SharePointUrl 'https://test.sharepoint.com/test.mp4'

        $report | Should -Match '<html>'
        $report.Length | Should -BeGreaterThan 100
    }
}
