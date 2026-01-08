#------------------------------------------------------------------------------------------------------------------
# DatabaseManager.ps1 - SQLite database operations for video catalog and status tracking
#------------------------------------------------------------------------------------------------------------------

# Module-level variable
$Script:DatabasePath = $null

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-SPVidCompDatabase # Purpose: Create or open SQLite database and initialize schema
#------------------------------------------------------------------------------------------------------------------
function Initialize-SPVidCompDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )

    try {
        $Script:DatabasePath = $DatabasePath

        # Ensure directory exists
        $dbDir = Split-Path -Path $DatabasePath -Parent
        if (-not (Test-Path -LiteralPath $dbDir)) {
            New-Item -ItemType Directory -Path $dbDir -Force | Out-Null
        }

        # Check if PSSQLite module is available
        if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
            Write-SPVidCompLogEntry -Message "PSSQLite module not found. Installing..." -Level 'Warning'
            Install-Module -Name PSSQLite -Scope CurrentUser -Force -AllowClobber
            Write-SPVidCompLogEntry -Message "PSSQLite module installed successfully" -Level 'Info'
        }

        # Import module
        Import-Module PSSQLite -ErrorAction Stop

        # Create database schema
        Create-DatabaseSchema

        Write-SPVidCompLogEntry -Message "Database initialized successfully: $DatabasePath" -Level 'Info'
        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to initialize database: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Create-DatabaseSchema
# Purpose: Create database tables if they don't exist
#------------------------------------------------------------------------------------------------------------------
function Create-DatabaseSchema {
    [CmdletBinding()]
    param()

    try {
        # Create videos table
        $videosTableQuery = @"
CREATE TABLE IF NOT EXISTS videos (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sharepoint_url TEXT NOT NULL UNIQUE,
    site_url TEXT NOT NULL,
    library_name TEXT NOT NULL,
    folder_path TEXT,
    filename TEXT NOT NULL,
    original_size INTEGER NOT NULL,
    modified_date TEXT NOT NULL,
    cataloged_date TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'Cataloged',
    processing_started TEXT,
    processing_completed TEXT,
    compressed_size INTEGER,
    compression_ratio REAL,
    archive_path TEXT,
    archive_hash TEXT,
    original_hash TEXT,
    hash_verified INTEGER DEFAULT 0,
    original_duration REAL,
    compressed_duration REAL,
    integrity_verified INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    last_error TEXT
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $videosTableQuery

        # Create indices for videos table
        $indexQueries = @(
            "CREATE INDEX IF NOT EXISTS idx_status ON videos(status);",
            "CREATE INDEX IF NOT EXISTS idx_site_url ON videos(site_url);",
            "CREATE INDEX IF NOT EXISTS idx_cataloged_date ON videos(cataloged_date);"
        )

        foreach ($query in $indexQueries) {
            Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query
        }

        # Create processing_log table
        $processingLogQuery = @"
CREATE TABLE IF NOT EXISTS processing_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id INTEGER NOT NULL,
    timestamp TEXT NOT NULL,
    status TEXT NOT NULL,
    message TEXT,
    FOREIGN KEY (video_id) REFERENCES videos(id)
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $processingLogQuery

        # Create config table (single-row table with typed columns)
        $configQuery = @"
CREATE TABLE IF NOT EXISTS config (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    -- SharePoint settings
    sharepoint_site_url TEXT NOT NULL,
    sharepoint_library_name TEXT NOT NULL,
    sharepoint_folder_path TEXT,
    sharepoint_recursive INTEGER NOT NULL DEFAULT 1,
    -- Path settings
    paths_temp_download TEXT NOT NULL,
    paths_external_archive TEXT NOT NULL,
    -- Compression settings
    compression_frame_rate INTEGER NOT NULL DEFAULT 10,
    compression_video_codec TEXT NOT NULL DEFAULT 'libx265',
    compression_timeout_minutes INTEGER NOT NULL DEFAULT 60,
    -- Processing settings
    processing_retry_attempts INTEGER NOT NULL DEFAULT 3,
    processing_required_disk_space_gb INTEGER NOT NULL DEFAULT 50,
    processing_duration_tolerance_seconds INTEGER NOT NULL DEFAULT 1,
    -- Resume settings
    resume_enable INTEGER NOT NULL DEFAULT 1,
    resume_skip_processed INTEGER NOT NULL DEFAULT 1,
    resume_reprocess_failed INTEGER NOT NULL DEFAULT 1,
    -- Email settings
    email_enabled INTEGER NOT NULL DEFAULT 0,
    email_smtp_server TEXT,
    email_smtp_port INTEGER DEFAULT 587,
    email_use_ssl INTEGER DEFAULT 1,
    email_from TEXT,
    email_to TEXT,
    email_send_on_completion INTEGER DEFAULT 1,
    email_send_on_error INTEGER DEFAULT 1,
    -- Logging settings
    logging_log_level TEXT NOT NULL DEFAULT 'Info',
    logging_console_output INTEGER NOT NULL DEFAULT 0,
    logging_retention_days INTEGER NOT NULL DEFAULT 30,
    -- Advanced settings
    advanced_cleanup_temp_files INTEGER NOT NULL DEFAULT 1,
    advanced_verify_checksums INTEGER NOT NULL DEFAULT 1,
    advanced_dry_run INTEGER NOT NULL DEFAULT 0,
    -- Illegal character handling
    illegal_char_strategy TEXT NOT NULL DEFAULT 'Replace',
    illegal_char_replacement TEXT DEFAULT '_'
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $configQuery

        # Create metadata table (for runtime metadata like last_catalog_run, etc.)
        $metadataQuery = @"
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $metadataQuery

        # Create logs table (for application-wide logging)
        $logsQuery = @"
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    level TEXT NOT NULL,
    component TEXT,
    message TEXT NOT NULL,
    context TEXT
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $logsQuery

        # Create index on logs table for performance
        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query "CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp);"
        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query "CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);"

        Write-SPVidCompLogEntry -Message "Database schema created successfully" -Level 'Debug'
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to create database schema: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-SPVidCompVideoToDatabase # Purpose: Insert a new video into the catalog
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidCompVideoToDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl,

        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$LibraryName,

        [Parameter(Mandatory = $false)]
        [string]$FolderPath = '',

        [Parameter(Mandatory = $true)]
        [string]$Filename,

        [Parameter(Mandatory = $true)]
        [long]$OriginalSize,

        [Parameter(Mandatory = $true)]
        [DateTime]$ModifiedDate
    )

    try {
        $query = @"
INSERT OR IGNORE INTO videos
(sharepoint_url, site_url, library_name, folder_path, filename, original_size, modified_date, cataloged_date, status)
VALUES
(@sharepoint_url, @site_url, @library_name, @folder_path, @filename, @original_size, @modified_date, @cataloged_date, 'Cataloged');
"@

        $parameters = @{
            sharepoint_url = $SharePointUrl
            site_url = $SiteUrl
            library_name = $LibraryName
            folder_path = $FolderPath
            filename = $Filename
            original_size = $OriginalSize
            modified_date = $ModifiedDate.ToString('yyyy-MM-dd HH:mm:ss')
            cataloged_date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to add video to database: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompVideosFromDatabase # Purpose: Query videos by status or other criteria
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompVideosFromDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetryCount = 999,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 0
    )

    try {
        $query = "SELECT * FROM videos WHERE 1=1"

        $parameters = @{}

        if ($Status) {
            $query += " AND status = @status"
            $parameters['status'] = $Status
        }

        $query += " AND retry_count <= @max_retry"
        $parameters['max_retry'] = $MaxRetryCount

        $query += " ORDER BY cataloged_date ASC"

        if ($Limit -gt 0) {
            $query += " LIMIT @limit"
            $parameters['limit'] = $Limit
        }

        $results = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        return $results
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to query videos from database: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Update-SPVidCompVideoStatus # Purpose: Update video status and related fields
#------------------------------------------------------------------------------------------------------------------
function Update-SPVidCompVideoStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VideoId,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [hashtable]$AdditionalFields = @{}
    )

    try {
        # Build update query dynamically
        $updateFields = @("status = @status")
        $parameters = @{
            video_id = $VideoId
            status = $Status
        }

        # Add processing timestamps
        if ($Status -eq 'Downloading') {
            $updateFields += "processing_started = @processing_started"
            $parameters['processing_started'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        elseif ($Status -in @('Completed', 'Failed')) {
            $updateFields += "processing_completed = @processing_completed"
            $parameters['processing_completed'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        # Add additional fields
        foreach ($key in $AdditionalFields.Keys) {
            $paramName = $key.ToLower().Replace('_', '')
            $updateFields += "$key = @$paramName"
            $parameters[$paramName] = $AdditionalFields[$key]
        }

        $query = "UPDATE videos SET $($updateFields -join ', ') WHERE id = @video_id;"

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        # Log status change
        Add-SPVidCompProcessingLogEntry -VideoId $VideoId -Status $Status -Message "Status updated to $Status"

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to update video status: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-SPVidCompProcessingLogEntry # Purpose: Add entry to processing log for audit trail
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidCompProcessingLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$VideoId,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$Message = ''
    )

    try {
        $query = @"
INSERT INTO processing_log (video_id, timestamp, status, message)
VALUES (@video_id, @timestamp, @status, @message);
"@

        $parameters = @{
            video_id = $VideoId
            timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            status = $Status
            message = $Message
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to add processing log entry: $_" -Level 'Warning'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompDatabaseStatistics # Purpose: Retrieve statistics from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompDatabaseStatistics {
    [CmdletBinding()]
    param()

    try {
        $stats = @{}

        # Total videos cataloged
        $totalQuery = "SELECT COUNT(*) as total FROM videos;"
        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $totalQuery
        $stats['TotalCataloged'] = $result.total

        # Status breakdown
        $statusQuery = "SELECT status, COUNT(*) as count FROM videos GROUP BY status;"
        $statusResults = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $statusQuery
        $stats['StatusBreakdown'] = $statusResults

        # Total original size
        $sizeQuery = "SELECT SUM(original_size) as total_size FROM videos;"
        $sizeResult = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $sizeQuery
        $stats['TotalOriginalSize'] = [long]$sizeResult.total_size

        # Total compressed size (completed videos only)
        $compressedQuery = "SELECT SUM(compressed_size) as total_compressed FROM videos WHERE status = 'Completed';"
        $compressedResult = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $compressedQuery
        $stats['TotalCompressedSize'] = [long]$compressedResult.total_compressed

        # Space saved (only for completed videos - original vs compressed)
        $completedOriginalQuery = "SELECT SUM(original_size) as completed_original FROM videos WHERE status = 'Completed';"
        $completedOriginalResult = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $completedOriginalQuery
        $completedOriginalSize = [long]$completedOriginalResult.completed_original

        if ($stats['TotalCompressedSize'] -gt 0 -and $completedOriginalSize -gt 0) {
            $stats['SpaceSaved'] = $completedOriginalSize - $stats['TotalCompressedSize']
            $stats['AverageCompressionRatio'] = [math]::Round(($stats['TotalCompressedSize'] / $completedOriginalSize), 2)
        }

        return $stats
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to retrieve database statistics: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-SPVidCompMetadata # Purpose: Store metadata key-value pairs
#------------------------------------------------------------------------------------------------------------------
function Set-SPVidCompMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    try {
        $query = "INSERT OR REPLACE INTO metadata (key, value) VALUES (@key, @value);"
        $parameters = @{
            key = $Key
            value = $Value
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to set metadata: $_" -Level 'Warning'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompMetadata # Purpose: Retrieve metadata value by key
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    try {
        $query = "SELECT value FROM metadata WHERE key = @key;"
        $parameters = @{ key = $Key }

        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        if ($result) {
            return $result.value
        }
        return $null
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to get metadata: $_" -Level 'Warning'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-SPVidCompAllConfig (Internal)
# Purpose: Store complete configuration in database
#------------------------------------------------------------------------------------------------------------------
function Set-SPVidCompAllConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigValues
    )

    try {
        # Convert string booleans to integers for database
        $boolFields = @(
            'sharepoint_recursive', 'resume_enable', 'resume_skip_processed', 'resume_reprocess_failed',
            'email_enabled', 'email_use_ssl', 'email_send_on_completion', 'email_send_on_error',
            'logging_console_output',
            'advanced_cleanup_temp_files', 'advanced_verify_checksums', 'advanced_dry_run'
        )

        foreach ($field in $boolFields) {
            if ($ConfigValues.ContainsKey($field)) {
                $value = $ConfigValues[$field]
                if ($value -is [string]) {
                    $ConfigValues[$field] = if ($value -in @('True', 'true', '1')) { 1 } else { 0 }
                } elseif ($value -is [bool]) {
                    $ConfigValues[$field] = if ($value) { 1 } else { 0 }
                }
            }
        }

        # Check if config already exists
        $existsQuery = "SELECT COUNT(*) as count FROM config WHERE id = 1;"
        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $existsQuery
        $exists = ($result.count -gt 0)

        if ($exists) {
            # Build UPDATE statement dynamically
            $setClauses = @()
            $parameters = @{ id = 1 }

            foreach ($key in $ConfigValues.Keys) {
                $setClauses += "$key = @$key"
                $parameters[$key] = $ConfigValues[$key]
            }

            $setClause = $setClauses -join ', '
            $query = "UPDATE config SET $setClause WHERE id = @id;"
        }
        else {
            # Build INSERT statement
            $ConfigValues['id'] = 1
            $columns = $ConfigValues.Keys -join ', '
            $placeholders = ($ConfigValues.Keys | ForEach-Object { "@$_" }) -join ', '
            $query = "INSERT INTO config ($columns) VALUES ($placeholders);"
            $parameters = $ConfigValues
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters
        Write-SPVidCompLogEntry -Message "Configuration saved successfully" -Level 'Debug'
        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to save configuration: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompAllConfig (Internal)
# Purpose: Retrieve all configuration values from database with proper types
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompAllConfig {
    [CmdletBinding()]
    param()

    try {
        $query = "SELECT * FROM config WHERE id = 1;"
        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query

        if ($null -eq $result -or $result.Count -eq 0) {
            return @{}
        }

        # Convert result to hashtable with proper types
        $config = @{}
        $row = $result[0]

        # Get all column names (excluding 'id')
        $properties = $row.PSObject.Properties | Where-Object { $_.Name -ne 'id' }

        foreach ($prop in $properties) {
            $name = $prop.Name
            $value = $prop.Value

            # Convert INTEGER booleans (0/1) back to strings for compatibility
            $boolFields = @(
                'sharepoint_recursive', 'resume_enable', 'resume_skip_processed', 'resume_reprocess_failed',
                'email_enabled', 'email_use_ssl', 'email_send_on_completion', 'email_send_on_error',
                'logging_console_output',
                'advanced_cleanup_temp_files', 'advanced_verify_checksums', 'advanced_dry_run'
            )

            if ($name -in $boolFields) {
                $config[$name] = if ($value -eq 1) { 'True' } else { 'False' }
            }
            else {
                $config[$name] = $value
            }
        }

        return $config
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to retrieve configuration: $_" -Level 'Error'
        return @{}
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-SPVidCompConfigExists (Internal)
# Purpose: Check if configuration exists in database
#------------------------------------------------------------------------------------------------------------------
function Test-SPVidCompConfigExists {
    [CmdletBinding()]
    param()

    try {
        $query = "SELECT COUNT(*) as count FROM config WHERE id = 1;"
        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query

        return ($result.count -gt 0)
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to check config existence: $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-LogEntry (Internal)
# Purpose: Write a log entry to the database
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidCompLogEntry {
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

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'

        $query = @"
INSERT INTO logs (timestamp, level, component, message, context)
VALUES (@timestamp, @level, @component, @message, @context);
"@

        $parameters = @{
            timestamp = $timestamp
            level = $Level
            component = $Component
            message = $Message
            context = $Context
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters | Out-Null

        return $true
    }
    catch {
        # Cannot log to database, this error needs to go to fallback file logging
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-LogEntries (Internal)
# Purpose: Retrieve log entries from the database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompLogEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = $null,

        [Parameter(Mandatory = $false)]
        [string]$Component = $null,

        [Parameter(Mandatory = $false)]
        [int]$Limit = 100,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$StartDate = $null,

        [Parameter(Mandatory = $false)]
        [Nullable[datetime]]$EndDate = $null
    )

    try {
        $whereConditions = @()
        $parameters = @{}

        if ($Level) {
            $whereConditions += "level = @level"
            $parameters['level'] = $Level
        }

        if ($Component) {
            $whereConditions += "component = @component"
            $parameters['component'] = $Component
        }

        if ($PSBoundParameters.ContainsKey('StartDate')) {
            $whereConditions += "timestamp >= @startdate"
            $parameters['startdate'] = $StartDate.ToString('yyyy-MM-dd HH:mm:ss')
        }

        if ($PSBoundParameters.ContainsKey('EndDate')) {
            $whereConditions += "timestamp <= @enddate"
            $parameters['enddate'] = $EndDate.ToString('yyyy-MM-dd HH:mm:ss')
        }

        $whereClause = if ($whereConditions.Count -gt 0) {
            "WHERE " + ($whereConditions -join " AND ")
        } else {
            ""
        }

        $query = @"
SELECT id, timestamp, level, component, message, context
FROM logs
$whereClause
ORDER BY timestamp DESC
LIMIT $Limit;
"@

        if ($parameters.Count -gt 0) {
            return Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters
        } else {
            return Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query
        }
    }
    catch {
        Write-Error "Failed to retrieve log entries: $_"
        return @()
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Clear-OldLogEntries (Internal)
# Purpose: Remove log entries older than specified retention period
#------------------------------------------------------------------------------------------------------------------
function Clear-SPVidCompOldLogEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$RetentionDays
    )

    try {
        $cutoffDate = (Get-Date).AddDays(-$RetentionDays).ToString('yyyy-MM-dd HH:mm:ss')

        $query = "DELETE FROM logs WHERE timestamp < @cutoffdate;"
        $parameters = @{ cutoffdate = $cutoffDate }

        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        Write-SPVidCompLogEntry -Message "Cleaned up log entries older than $RetentionDays days (cutoff: $cutoffDate)" -Level 'Debug'

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to clean up old log entries: $_" -Level 'Warning'
        return $false
    }
}

# Export functions
Export-ModuleMember -Function Initialize-SPVidCompDatabase, Add-SPVidCompVideoToDatabase, Get-SPVidCompVideosFromDatabase, `
    Update-SPVidCompVideoStatus, Add-SPVidCompProcessingLogEntry, Get-SPVidCompDatabaseStatistics, Set-SPVidCompMetadata, Get-SPVidCompMetadata, `
    Set-SPVidCompAllConfig, Get-SPVidCompAllConfig, Add-SPVidCompLogEntry, Get-SPVidCompLogEntries, Clear-SPVidCompOldLogEntries
