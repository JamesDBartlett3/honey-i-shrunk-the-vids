#------------------------------------------------------------------------------------------------------------------
# Logger.ps1 - Logging infrastructure for SharePoint Video Compression
#------------------------------------------------------------------------------------------------------------------

# Module-level variables
$Script:LogConfig = @{
    LogPath = $null
    LogLevel = 'Info'
    ConsoleOutput = $true
    FileOutput = $true
    MaxLogSizeMB = 100
    LogRetentionDays = 30
}

$Script:LogLevels = @{
    Debug = 0
    Info = 1
    Warning = 2
    Error = 3
}

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-Logger
# Purpose: Setup logging configuration
#------------------------------------------------------------------------------------------------------------------
function Initialize-Logger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$LogLevel = 'Info',

        [Parameter(Mandatory = $false)]
        [bool]$ConsoleOutput = $true,

        [Parameter(Mandatory = $false)]
        [bool]$FileOutput = $true,

        [Parameter(Mandatory = $false)]
        [int]$MaxLogSizeMB = 100,

        [Parameter(Mandatory = $false)]
        [int]$LogRetentionDays = 30
    )

    try {
        # Ensure log directory exists
        if (-not (Test-Path -LiteralPath $LogPath)) {
            New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
        }

        # Set configuration
        $Script:LogConfig.LogPath = $LogPath
        $Script:LogConfig.LogLevel = $LogLevel
        $Script:LogConfig.ConsoleOutput = $ConsoleOutput
        $Script:LogConfig.FileOutput = $FileOutput
        $Script:LogConfig.MaxLogSizeMB = $MaxLogSizeMB
        $Script:LogConfig.LogRetentionDays = $LogRetentionDays

        # Clean up old logs
        Clean-OldLogs

        Write-LogEntry -Message "Logger initialized successfully" -Level 'Info'
    }
    catch {
        Write-Error "Failed to initialize logger: $_"
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Write-LogEntry
# Purpose: Write a log entry with timestamp and level
#------------------------------------------------------------------------------------------------------------------
function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$Component = ''
    )

    # Check if this log level should be written
    if ($Script:LogLevels[$Level] -lt $Script:LogLevels[$Script:LogConfig.LogLevel]) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $componentPart = if ($Component) { " [$Component]" } else { "" }
    $logEntry = "$timestamp [$Level]$componentPart $Message"

    # Write to console
    if ($Script:LogConfig.ConsoleOutput) {
        switch ($Level) {
            'Debug' { Write-Host $logEntry -ForegroundColor Gray }
            'Info' { Write-Host $logEntry -ForegroundColor White }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Error' { Write-Host $logEntry -ForegroundColor Red }
        }
    }

    # Write to file
    if ($Script:LogConfig.FileOutput -and $Script:LogConfig.LogPath) {
        try {
            $logFile = Join-Path -Path $Script:LogConfig.LogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"

            # Check log file size and rotate if needed
            if (Test-Path -LiteralPath $logFile) {
                $fileInfo = Get-Item -LiteralPath $logFile
                $fileSizeMB = $fileInfo.Length / 1MB

                if ($fileSizeMB -ge $Script:LogConfig.MaxLogSizeMB) {
                    Rotate-LogFile -LogFile $logFile
                }
            }

            # Write log entry
            Add-Content -LiteralPath $logFile -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write to log file: $_"
        }
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Rotate-LogFile
# Purpose: Rotate log file when it exceeds size limit
#------------------------------------------------------------------------------------------------------------------
function Rotate-LogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile
    )

    try {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $rotatedFile = "$LogFile.$timestamp"

        Move-Item -Path $LogFile -Destination $rotatedFile -Force

        Write-LogEntry -Message "Log file rotated to: $rotatedFile" -Level 'Info'
    }
    catch {
        Write-Warning "Failed to rotate log file: $_"
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Clean-OldLogs
# Purpose: Remove logs older than retention period
#------------------------------------------------------------------------------------------------------------------
function Clean-OldLogs {
    [CmdletBinding()]
    param()

    try {
        if (-not $Script:LogConfig.LogPath) { return }

        $cutoffDate = (Get-Date).AddDays(-$Script:LogConfig.LogRetentionDays)
        $logFiles = Get-ChildItem -Path $Script:LogConfig.LogPath -Filter "video-compression-*.log*" -ErrorAction SilentlyContinue

        foreach ($file in $logFiles) {
            if ($file.LastWriteTime -lt $cutoffDate) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                Write-LogEntry -Message "Removed old log file: $($file.Name)" -Level 'Debug'
            }
        }
    }
    catch {
        Write-Warning "Failed to clean old logs: $_"
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-LogHistory
# Purpose: Retrieve log entries (for debugging/reporting)
#------------------------------------------------------------------------------------------------------------------
function Get-LogHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Last = 100,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level
    )

    try {
        if (-not $Script:LogConfig.LogPath) {
            Write-Warning "Logger not initialized"
            return
        }

        $logFile = Join-Path -Path $Script:LogConfig.LogPath -ChildPath "video-compression-$(Get-Date -Format 'yyyyMMdd').log"

        if (-not (Test-Path -LiteralPath $logFile)) {
            Write-Warning "Log file not found: $logFile"
            return
        }

        $entries = Get-Content -LiteralPath $logFile -Tail $Last

        if ($Level) {
            $entries = $entries | Where-Object { $_ -match "\[$Level\]" }
        }

        return $entries
    }
    catch {
        Write-Error "Failed to retrieve log history: $_"
        return $null
    }
}

# Export functions
Export-ModuleMember -Function Initialize-Logger, Write-LogEntry, Get-LogHistory
