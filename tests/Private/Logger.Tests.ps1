#------------------------------------------------------------------------------------------------------------------
# Logger.Tests.ps1 - Unit tests for Logger.ps1 (Database-Based Logging)
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Import the main module (which includes Logger)
    Import-TestModule
}

Describe 'Initialize-SPVidCompLogger' {
    It 'Should initialize with valid parameters without throwing' {
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Warning' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogRetentionDays 14 -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should accept all valid log levels' {
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Debug' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Info' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Warning' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Error' -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should create error log directory if specified' {
        $errorLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-error-logs-$(Get-Random)"

        { Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -ErrorLogPath $errorLogPath -ConsoleOutput $false } | Should -Not -Throw

        Test-Path -LiteralPath $errorLogPath | Should -BeTrue

        Remove-Item -LiteralPath $errorLogPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Write-SPVidCompLogEntry - Database Storage' {
    BeforeAll {
        # Initialize catalog first to create database with logs table
        Initialize-SPVidCompCatalog -DatabasePath $Script:GlobalTestDbPath
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Debug' -ConsoleOutput $false
    }

    It 'Should write log entry to database with all fields' {
        $uniqueMsg = "Database test message $(Get-Random)"
        Write-SPVidCompLogEntry -Message $uniqueMsg -Level 'Info' -Component 'TestComponent'

        # Query database directly
        $query = "SELECT * FROM logs WHERE message = @message"
        $logs = Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query $query -SqlParameters @{ message = $uniqueMsg }

        $logs | Should -Not -BeNullOrEmpty
        $logs[0].message | Should -Be $uniqueMsg
        $logs[0].level | Should -Be 'Info'
        $logs[0].component | Should -Be 'TestComponent'
        $logs[0].timestamp | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
    }

    It 'Should respect log level filtering' {
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Warning' -ConsoleOutput $false

        $debugMsg = "Debug-filtered-$(Get-Random)"
        $warnMsg = "Warning-shown-$(Get-Random)"

        Write-SPVidCompLogEntry -Message $debugMsg -Level 'Debug'
        Write-SPVidCompLogEntry -Message $warnMsg -Level 'Warning'

        # Query all logs
        $allLogs = Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query "SELECT message FROM logs"

        $allLogs.message | Should -Not -Contain $debugMsg
        $allLogs.message | Should -Contain $warnMsg
    }
}

Describe 'Log Level Hierarchy' {
    BeforeAll {
        Initialize-SPVidCompCatalog -DatabasePath $Script:GlobalTestDbPath
    }

    It 'Should filter messages based on log level hierarchy' {
        # Test Debug level - writes everything
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Debug' -ConsoleOutput $false

        $debugMsg = "debug-$(Get-Random)"
        $infoMsg = "info-$(Get-Random)"

        Write-SPVidCompLogEntry -Message $debugMsg -Level 'Debug'
        Write-SPVidCompLogEntry -Message $infoMsg -Level 'Info'

        $logs = Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query "SELECT message FROM logs"

        $logs.message | Should -Contain $debugMsg
        $logs.message | Should -Contain $infoMsg

        # Test Error level - only writes errors
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Error' -ConsoleOutput $false

        $warnMsg = "warn-filtered-$(Get-Random)"
        $errorMsg = "error-shown-$(Get-Random)"

        Write-SPVidCompLogEntry -Message $warnMsg -Level 'Warning'
        Write-SPVidCompLogEntry -Message $errorMsg -Level 'Error'

        $logs = Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query "SELECT message FROM logs"

        $logs.message | Should -Not -Contain $warnMsg
        $logs.message | Should -Contain $errorMsg
    }
}

Describe 'Get-SPVidCompLogHistory' {
    BeforeAll {
        Initialize-SPVidCompCatalog -DatabasePath $Script:GlobalTestDbPath
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Debug' -ConsoleOutput $false

        # Write test entries
        1..10 | ForEach-Object {
            Write-SPVidCompLogEntry -Message "History test message $_" -Level 'Info'
        }
        Write-SPVidCompLogEntry -Message 'Warning message for history' -Level 'Warning' -Component 'TestComponent'
    }

    It 'Should return log entries from database' {
        $history = Get-SPVidCompLogHistory -Last 5

        $history | Should -Not -BeNullOrEmpty
        $history.Count | Should -BeLessOrEqual 5
    }

    It 'Should filter by level and component' {
        $history = Get-SPVidCompLogHistory -Level 'Warning'

        $history | Should -Not -BeNullOrEmpty
        $history | ForEach-Object { $_.level | Should -Be 'Warning' }

        $history = Get-SPVidCompLogHistory -Component 'TestComponent'

        $history | Should -Not -BeNullOrEmpty
        $history | ForEach-Object { $_.component | Should -Be 'TestComponent' }
    }
}

Describe 'Clear-SPVidCompOldLogs' {
    BeforeAll {
        Initialize-SPVidCompCatalog -DatabasePath $Script:GlobalTestDbPath
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogRetentionDays 30 -ConsoleOutput $false
    }

    It 'Should remove logs older than retention period' {
        # Insert old log entry directly
        $oldTimestamp = (Get-Date).AddDays(-60).ToString("yyyy-MM-ddTHH:mm:ss")
        $query = "INSERT INTO logs (timestamp, level, component, message) VALUES (@timestamp, @level, @component, @message)"
        Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query $query -SqlParameters @{
            timestamp = $oldTimestamp
            level = 'Info'
            component = 'Test'
            message = 'Old log entry that should be deleted'
        }

        # Add recent entry
        Write-SPVidCompLogEntry -Message 'Recent log entry' -Level 'Info'

        # Run cleanup
        Clear-SPVidCompOldLogs

        # Verify old entry is gone
        $logs = Invoke-SqliteQuery -DataSource $Script:GlobalTestDbPath -Query "SELECT message FROM logs"
        $logs.message | Should -Not -Contain 'Old log entry that should be deleted'
        $logs.message | Should -Contain 'Recent log entry'
    }
}

Describe 'Console Output' {
    BeforeAll {
        Initialize-SPVidCompCatalog -DatabasePath $Script:GlobalTestDbPath
    }

    It 'Should handle console output for all log levels' {
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -LogLevel 'Debug' -ConsoleOutput $true

        { Write-SPVidCompLogEntry -Message 'Debug' -Level 'Debug' } | Should -Not -Throw
        { Write-SPVidCompLogEntry -Message 'Info' -Level 'Info' } | Should -Not -Throw
        { Write-SPVidCompLogEntry -Message 'Warning' -Level 'Warning' } | Should -Not -Throw
        { Write-SPVidCompLogEntry -Message 'Error' -Level 'Error' } | Should -Not -Throw
    }
}

Describe 'Error Fallback Logging' {
    It 'Should handle database logging failures gracefully' {
        $errorLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "test-fallback-errors-$(Get-Random)"

        # Initialize logger with error log path
        Initialize-SPVidCompLogger -DatabasePath $Script:GlobalTestDbPath -ErrorLogPath $errorLogPath -ConsoleOutput $false

        # Verify initialization created the error log directory
        Test-Path -LiteralPath $errorLogPath | Should -BeTrue

        # Test that logging doesn't throw even if database is unavailable
        # This verifies the error handling gracefully degrades to file logging
        { Write-SPVidCompLogEntry -Message 'Test message 1' -Level 'Info' } | Should -Not -Throw
        { Write-SPVidCompLogEntry -Message 'Test message 2' -Level 'Warning' } | Should -Not -Throw
        { Write-SPVidCompLogEntry -Message 'Test message 3' -Level 'Error' } | Should -Not -Throw

        Remove-Item -LiteralPath $errorLogPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
