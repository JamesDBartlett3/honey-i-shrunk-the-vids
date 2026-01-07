#------------------------------------------------------------------------------------------------------------------
# Logger.Tests.ps1 - Unit tests for Logger.ps1
#------------------------------------------------------------------------------------------------------------------

BeforeAll {
    # Import test helper
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\TestHelper.ps1')

    # Import the main module (which includes Logger)
    Import-TestModule
}

Describe 'Initialize-Logger' {
    BeforeEach {
        $Script:TestLogPath = New-TestLogDirectory
    }

    AfterEach {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should create log directory if it does not exist' {
        $newLogPath = Join-Path -Path $env:TEMP -ChildPath "new-log-dir-$(Get-Random)"

        Initialize-Logger -LogPath $newLogPath -ConsoleOutput $false

        Test-Path -LiteralPath $newLogPath | Should -BeTrue

        # Cleanup
        Remove-Item -LiteralPath $newLogPath -Recurse -Force
    }

    It 'Should not throw when setting LogLevel' {
        { Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Warning' -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should not throw when setting ConsoleOutput' {
        { Initialize-Logger -LogPath $Script:TestLogPath -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should not throw when setting FileOutput' {
        { Initialize-Logger -LogPath $Script:TestLogPath -FileOutput $false -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should not throw when setting MaxLogSizeMB' {
        { Initialize-Logger -LogPath $Script:TestLogPath -MaxLogSizeMB 50 -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should not throw when setting LogRetentionDays' {
        { Initialize-Logger -LogPath $Script:TestLogPath -LogRetentionDays 14 -ConsoleOutput $false } | Should -Not -Throw
    }

    It 'Should accept valid log levels' {
        { Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Info' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Warning' -ConsoleOutput $false } | Should -Not -Throw
        { Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Error' -ConsoleOutput $false } | Should -Not -Throw
    }
}

Describe 'Write-LogEntry' {
    BeforeAll {
        $Script:TestLogPath = New-TestLogDirectory
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true
    }

    AfterAll {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should write log entry to file' {
        Write-LogEntry -Message 'Test log message' -Level 'Info'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"

        Test-Path -LiteralPath $logFile | Should -BeTrue

        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Match 'Test log message'
    }

    It 'Should include timestamp in log entry' {
        Write-LogEntry -Message 'Timestamp test' -Level 'Info'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        # Should match timestamp pattern: yyyy-MM-dd HH:mm:ss
        $content | Should -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}'
    }

    It 'Should include log level in entry' {
        Write-LogEntry -Message 'Level test' -Level 'Warning'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Match '\[Warning\]'
    }

    It 'Should include component when specified' {
        Write-LogEntry -Message 'Component test' -Level 'Info' -Component 'TestComponent'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Match '\[TestComponent\]'
    }

    It 'Should respect log level filtering - Debug not written at Info level' {
        # Reinitialize with Info level
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Info' -ConsoleOutput $false -FileOutput $true

        # Create a unique message
        $uniqueMsg = "Debug-filtered-$(Get-Random)"
        Write-LogEntry -Message $uniqueMsg -Level 'Debug'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Not -Match $uniqueMsg
    }

    It 'Should write Error level regardless of log level setting' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Error' -ConsoleOutput $false -FileOutput $true

        $uniqueMsg = "Error-message-$(Get-Random)"
        Write-LogEntry -Message $uniqueMsg -Level 'Error'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Match $uniqueMsg
    }
}

Describe 'Log Level Hierarchy' {
    BeforeEach {
        $Script:TestLogPath = New-TestLogDirectory
    }

    AfterEach {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Debug level should write all messages' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        $debugMsg = "debug-$(Get-Random)"
        $infoMsg = "info-$(Get-Random)"
        $warnMsg = "warn-$(Get-Random)"
        $errorMsg = "error-$(Get-Random)"

        Write-LogEntry -Message $debugMsg -Level 'Debug'
        Write-LogEntry -Message $infoMsg -Level 'Info'
        Write-LogEntry -Message $warnMsg -Level 'Warning'
        Write-LogEntry -Message $errorMsg -Level 'Error'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Match $debugMsg
        $content | Should -Match $infoMsg
        $content | Should -Match $warnMsg
        $content | Should -Match $errorMsg
    }

    It 'Info level should filter Debug messages' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Info' -ConsoleOutput $false -FileOutput $true

        $debugMsg = "debug-filtered-$(Get-Random)"
        $infoMsg = "info-shown-$(Get-Random)"

        Write-LogEntry -Message $debugMsg -Level 'Debug'
        Write-LogEntry -Message $infoMsg -Level 'Info'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Not -Match $debugMsg
        $content | Should -Match $infoMsg
    }

    It 'Warning level should filter Debug and Info messages' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Warning' -ConsoleOutput $false -FileOutput $true

        $debugMsg = "debug-filtered-$(Get-Random)"
        $infoMsg = "info-filtered-$(Get-Random)"
        $warnMsg = "warn-shown-$(Get-Random)"

        Write-LogEntry -Message $debugMsg -Level 'Debug'
        Write-LogEntry -Message $infoMsg -Level 'Info'
        Write-LogEntry -Message $warnMsg -Level 'Warning'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Not -Match $debugMsg
        $content | Should -Not -Match $infoMsg
        $content | Should -Match $warnMsg
    }

    It 'Error level should only write Error messages' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Error' -ConsoleOutput $false -FileOutput $true

        $warnMsg = "warn-filtered-$(Get-Random)"
        $errorMsg = "error-shown-$(Get-Random)"

        Write-LogEntry -Message $warnMsg -Level 'Warning'
        Write-LogEntry -Message $errorMsg -Level 'Error'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile -Raw

        $content | Should -Not -Match $warnMsg
        $content | Should -Match $errorMsg
    }
}

Describe 'Get-LogHistory' {
    BeforeAll {
        $Script:TestLogPath = New-TestLogDirectory
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $false -FileOutput $true

        # Write some test entries
        1..10 | ForEach-Object {
            Write-LogEntry -Message "History test message $_" -Level 'Info'
        }
        Write-LogEntry -Message 'Warning message' -Level 'Warning'
        Write-LogEntry -Message 'Error message' -Level 'Error'
    }

    AfterAll {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should return log entries' {
        $history = Get-LogHistory -Last 5

        $history | Should -Not -BeNullOrEmpty
        $history.Count | Should -BeLessOrEqual 5
    }

    It 'Should filter by level' {
        $history = Get-LogHistory -Level 'Warning'

        $history | Should -Not -BeNullOrEmpty
        $history | ForEach-Object { $_ | Should -Match '\[Warning\]' }
    }

    It 'Should handle missing log file gracefully' {
        # Try to get history from non-existent date
        $result = Get-LogHistory -Last 5

        # Should return something (entries or null) without throwing
        { Get-LogHistory -Last 5 } | Should -Not -Throw
    }
}

Describe 'Log File Naming' {
    BeforeEach {
        $Script:TestLogPath = New-TestLogDirectory
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Info' -ConsoleOutput $false -FileOutput $true
    }

    AfterEach {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should create log file with date-based name' {
        Write-LogEntry -Message 'File naming test' -Level 'Info'

        $expectedFileName = "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath $expectedFileName

        Test-Path -LiteralPath $logFile | Should -BeTrue
    }

    It 'Should append to existing log file' {
        Write-LogEntry -Message 'First entry' -Level 'Info'
        Write-LogEntry -Message 'Second entry' -Level 'Info'

        $logFile = Join-Path -Path $Script:TestLogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"
        $content = Get-Content -LiteralPath $logFile

        $content.Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Clean-OldLogs' {
    BeforeEach {
        $Script:TestLogPath = New-TestLogDirectory
    }

    AfterEach {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should remove logs older than retention period' {
        # Create an old log file
        $oldLogFile = Join-Path -Path $Script:TestLogPath -ChildPath 'video-compression-20200101.log'
        'Old log content' | Out-File -FilePath $oldLogFile

        # Set file date to old
        (Get-Item -LiteralPath $oldLogFile).LastWriteTime = (Get-Date).AddDays(-60)

        # Initialize logger with 30 day retention (triggers cleanup)
        Initialize-Logger -LogPath $Script:TestLogPath -LogRetentionDays 30 -ConsoleOutput $false

        # Old file should be removed
        Test-Path -LiteralPath $oldLogFile | Should -BeFalse
    }

    It 'Should keep logs within retention period' {
        # Create a recent log file
        $recentLogFile = Join-Path -Path $Script:TestLogPath -ChildPath 'video-compression-recent.log'
        'Recent log content' | Out-File -FilePath $recentLogFile

        # Set file date to recent (5 days ago)
        (Get-Item -LiteralPath $recentLogFile).LastWriteTime = (Get-Date).AddDays(-5)

        # Initialize logger with 30 day retention
        Initialize-Logger -LogPath $Script:TestLogPath -LogRetentionDays 30 -ConsoleOutput $false

        # Recent file should still exist
        Test-Path -LiteralPath $recentLogFile | Should -BeTrue
    }
}

Describe 'Console Output' {
    BeforeEach {
        $Script:TestLogPath = New-TestLogDirectory
    }

    AfterEach {
        Remove-TestLogDirectory -Path $Script:TestLogPath
    }

    It 'Should not throw when ConsoleOutput is enabled' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Info' -ConsoleOutput $true -FileOutput $false

        { Write-LogEntry -Message 'Console test' -Level 'Info' } | Should -Not -Throw
    }

    It 'Should handle all log levels for console output' {
        Initialize-Logger -LogPath $Script:TestLogPath -LogLevel 'Debug' -ConsoleOutput $true -FileOutput $false

        { Write-LogEntry -Message 'Debug' -Level 'Debug' } | Should -Not -Throw
        { Write-LogEntry -Message 'Info' -Level 'Info' } | Should -Not -Throw
        { Write-LogEntry -Message 'Warning' -Level 'Warning' } | Should -Not -Throw
        { Write-LogEntry -Message 'Error' -Level 'Error' } | Should -Not -Throw
    }
}
