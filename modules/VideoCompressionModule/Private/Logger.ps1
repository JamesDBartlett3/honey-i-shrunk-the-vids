#------------------------------------------------------------------------------------------------------------------
# Logger.ps1 - Database-based logging infrastructure for SharePoint Video Compression
#------------------------------------------------------------------------------------------------------------------

# Module-level variables
$Script:LogConfig = @{
    DatabasePath = $null
    ErrorLogPath = $null
    LogLevel = 'Info'
    ConsoleOutput = $false
    LogRetentionDays = 30
}

$Script:LogLevels = @{
    Debug = 0
    Info = 1
    Warning = 2
    Error = 3
}

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-SPVidCompLogger # Purpose: Setup logging configuration
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidCompLogger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$LogLevel = 'Info',

        [Parameter(Mandatory = $false)]
        [bool]$ConsoleOutput = $false,

        [Parameter(Mandatory = $false)]
        [int]$LogRetentionDays = 30,

        [Parameter(Mandatory = $false)]
        [string]$ErrorLogPath = $null
    )

    try {
        # Set configuration
        $Script:LogConfig.DatabasePath = $DatabasePath
        $Script:LogConfig.LogLevel = $LogLevel
        $Script:LogConfig.ConsoleOutput = $ConsoleOutput
        $Script:LogConfig.LogRetentionDays = $LogRetentionDays

        # Set error log path (for database failures only)
        if (-not $ErrorLogPath) {
            $ErrorLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'VideoCompressionErrors'
        }
        $Script:LogConfig.ErrorLogPath = $ErrorLogPath

        # Ensure error log directory exists
        if (-not (Test-Path -LiteralPath $ErrorLogPath)) {
            New-Item -ItemType Directory -Path $ErrorLogPath -Force -ErrorAction SilentlyContinue | Out-Null
        }

        Write-SPVidCompLogEntry -Message "Logger initialized successfully (database-based logging)" -Level 'Info'
    }
    catch {
        # If logger initialization fails, write to error file
        Write-SPVidCompErrorLogFile -Message "Failed to initialize logger: $_"
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Write-SPVidCompLogEntry # Purpose: Write a log entry to the database (with file fallback for database errors)
#------------------------------------------------------------------------------------------------------------------
function Write-SPVidCompLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$Component = '',

        [Parameter(Mandatory = $false)]
        [string]$Context = $null
    )

    # Check if this log level should be written
    if ($Script:LogLevels[$Level] -lt $Script:LogLevels[$Script:LogConfig.LogLevel]) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $componentPart = if ($Component) { " [$Component]" } else { "" }
    $logEntry = "$timestamp [$Level]$componentPart $Message"

    # Write to console if enabled
    if ($Script:LogConfig.ConsoleOutput) {
        switch ($Level) {
            'Debug' { Write-Host $logEntry -ForegroundColor Gray }
            'Info' { Write-Host $logEntry -ForegroundColor White }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Error' { Write-Host $logEntry -ForegroundColor Red }
        }
    }

    # Write to database
    if ($Script:LogConfig.DatabasePath) {
        try {
            $success = Add-SPVidCompLogEntry -Message $Message -Level $Level -Component $Component -Context $Context

            if (-not $success) {
                # Database write failed, fallback to error log file
                Write-SPVidCompErrorLogFile -Message $logEntry
            }
        }
        catch {
            # Database write failed, fallback to error log file
            Write-SPVidCompErrorLogFile -Message "$logEntry`nDatabase error: $_"
        }
    }
    else {
        # Logger not initialized with database path, write to error log
        Write-SPVidCompErrorLogFile -Message $logEntry
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Write-SPVidCompErrorLogFile # Purpose: Write to error log file (only used when database logging fails)
#------------------------------------------------------------------------------------------------------------------
function Write-SPVidCompErrorLogFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        if (-not $Script:LogConfig.ErrorLogPath) {
            # No error log path configured, output to console as last resort
            Write-Warning "DATABASE LOGGING FAILED - No error log path configured. Message: $Message"
            return
        }

        # Ensure error log directory exists
        if (-not (Test-Path -LiteralPath $Script:LogConfig.ErrorLogPath)) {
            New-Item -ItemType Directory -Path $Script:LogConfig.ErrorLogPath -Force -ErrorAction Stop | Out-Null
        }

        $errorLogFile = Join-Path -Path $Script:LogConfig.ErrorLogPath -ChildPath "database-errors-$(Get-Date -Format 'yyyyMMdd').log"
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $entry = "$timestamp [DATABASE_ERROR] $Message"

        Add-Content -LiteralPath $errorLogFile -Value $entry -ErrorAction Stop

        # Notify user where to find error log
        Write-Warning "DATABASE LOGGING FAILED - Error logged to: $errorLogFile"
    }
    catch {
        # Ultimate fallback - can't even write to error log file
        Write-Warning "CRITICAL: Cannot write to database OR error log file. Message: $Message. Error: $_"
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompLogHistory # Purpose: Retrieve log entries from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompLogHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Last = 100,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $false)]
        [string]$Component,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$StartDate,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$EndDate
    )

    try {
        if (-not $Script:LogConfig.DatabasePath) {
            Write-Warning "Logger not initialized with database path"
            return @()
        }

        $params = @{
            Limit = $Last
        }

        if ($Level) { $params['Level'] = $Level }
        if ($Component) { $params['Component'] = $Component }
        if ($PSBoundParameters.ContainsKey('StartDate')) { $params['StartDate'] = $StartDate }
        if ($PSBoundParameters.ContainsKey('EndDate')) { $params['EndDate'] = $EndDate }

        return Get-SPVidCompLogEntries @params
    }
    catch {
        Write-Error "Failed to retrieve log history from database: $_"
        return @()
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Clear-SPVidCompOldLogs # Purpose: Remove database log entries older than retention period
#------------------------------------------------------------------------------------------------------------------
function Clear-SPVidCompOldLogs {
    [CmdletBinding()]
    param()

    try {
        if (-not $Script:LogConfig.DatabasePath) {
            return
        }

        $result = Clear-SPVidCompOldLogEntries -RetentionDays $Script:LogConfig.LogRetentionDays

        if ($result) {
            Write-SPVidCompLogEntry -Message "Successfully cleaned up old log entries" -Level 'Debug'
        }
    }
    catch {
        Write-Warning "Failed to clean old database logs: $_"
    }
}

# Export functions
Export-ModuleMember -Function Initialize-SPVidCompLogger, Write-SPVidCompLogEntry, Get-SPVidCompLogHistory, Clear-SPVidCompOldLogs
