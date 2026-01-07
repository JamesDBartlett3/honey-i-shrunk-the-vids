#------------------------------------------------------------------------------------------------------------------
# DatabaseManager.ps1 - SQLite database operations for video catalog and status tracking
#------------------------------------------------------------------------------------------------------------------

# Module-level variable
$Script:DatabasePath = $null

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-Database
# Purpose: Create or open SQLite database and initialize schema
#------------------------------------------------------------------------------------------------------------------
function Initialize-Database {
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
            Write-LogEntry -Message "PSSQLite module not found. Installing..." -Level 'Warning'
            Install-Module -Name PSSQLite -Scope CurrentUser -Force -AllowClobber
            Write-LogEntry -Message "PSSQLite module installed successfully" -Level 'Info'
        }

        # Import module
        Import-Module PSSQLite -ErrorAction Stop

        # Create database schema
        Create-DatabaseSchema

        Write-LogEntry -Message "Database initialized successfully: $DatabasePath" -Level 'Info'
        return $true
    }
    catch {
        Write-LogEntry -Message "Failed to initialize database: $_" -Level 'Error'
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

        # Create metadata table
        $metadataQuery = @"
CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
"@

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $metadataQuery

        Write-LogEntry -Message "Database schema created successfully" -Level 'Debug'
    }
    catch {
        Write-LogEntry -Message "Failed to create database schema: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-VideoToDatabase
# Purpose: Insert a new video into the catalog
#------------------------------------------------------------------------------------------------------------------
function Add-VideoToDatabase {
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
        Write-LogEntry -Message "Failed to add video to database: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-VideosFromDatabase
# Purpose: Query videos by status or other criteria
#------------------------------------------------------------------------------------------------------------------
function Get-VideosFromDatabase {
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
        Write-LogEntry -Message "Failed to query videos from database: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Update-VideoStatus
# Purpose: Update video status and related fields
#------------------------------------------------------------------------------------------------------------------
function Update-VideoStatus {
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
        elseif ($Status -eq 'Completed' -or $Status -eq 'Failed') {
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
        Add-ProcessingLogEntry -VideoId $VideoId -Status $Status -Message "Status updated to $Status"

        return $true
    }
    catch {
        Write-LogEntry -Message "Failed to update video status: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Add-ProcessingLogEntry
# Purpose: Add entry to processing log for audit trail
#------------------------------------------------------------------------------------------------------------------
function Add-ProcessingLogEntry {
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
        Write-LogEntry -Message "Failed to add processing log entry: $_" -Level 'Warning'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-DatabaseStatistics
# Purpose: Retrieve statistics from database
#------------------------------------------------------------------------------------------------------------------
function Get-DatabaseStatistics {
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
        Write-LogEntry -Message "Failed to retrieve database statistics: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-Metadata
# Purpose: Store metadata key-value pairs
#------------------------------------------------------------------------------------------------------------------
function Set-Metadata {
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
        Write-LogEntry -Message "Failed to set metadata: $_" -Level 'Warning'
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-Metadata
# Purpose: Retrieve metadata value by key
#------------------------------------------------------------------------------------------------------------------
function Get-Metadata {
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
        Write-LogEntry -Message "Failed to get metadata: $_" -Level 'Warning'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Set-ConfigValue
# Purpose: Store configuration value in database
#------------------------------------------------------------------------------------------------------------------
function Set-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    try {
        $configKey = "config_$Key"
        Set-Metadata -Key $configKey -Value $Value
        return $true
    }
    catch {
        Write-LogEntry -Message "Failed to set config value '$Key': $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-ConfigValue
# Purpose: Retrieve configuration value from database
#------------------------------------------------------------------------------------------------------------------
function Get-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = ''
    )

    try {
        $configKey = "config_$Key"
        $value = Get-Metadata -Key $configKey

        if ($null -eq $value) {
            return $DefaultValue
        }

        return $value
    }
    catch {
        Write-LogEntry -Message "Failed to get config value '$Key': $_" -Level 'Warning'
        return $DefaultValue
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-AllConfig
# Purpose: Retrieve all configuration values from database
#------------------------------------------------------------------------------------------------------------------
function Get-AllConfig {
    [CmdletBinding()]
    param()

    try {
        $query = "SELECT key, value FROM metadata WHERE key LIKE 'config_%';"
        $results = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query

        $config = @{}
        foreach ($row in $results) {
            # Remove 'config_' prefix
            $key = $row.key -replace '^config_', ''
            $config[$key] = $row.value
        }

        return $config
    }
    catch {
        Write-LogEntry -Message "Failed to retrieve all config: $_" -Level 'Warning'
        return @{}
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-ConfigExists
# Purpose: Check if configuration exists in database
#------------------------------------------------------------------------------------------------------------------
function Test-ConfigExists {
    [CmdletBinding()]
    param()

    try {
        $query = "SELECT COUNT(*) as count FROM metadata WHERE key LIKE 'config_%';"
        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query

        return ($result.count -gt 0)
    }
    catch {
        Write-LogEntry -Message "Failed to check config existence: $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Remove-ConfigValue
# Purpose: Remove configuration value from database
#------------------------------------------------------------------------------------------------------------------
function Remove-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    try {
        $configKey = "config_$Key"
        $query = "DELETE FROM metadata WHERE key = @key;"
        $parameters = @{ key = $configKey }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters
        return $true
    }
    catch {
        Write-LogEntry -Message "Failed to remove config value '$Key': $_" -Level 'Warning'
        return $false
    }
}

# Export functions
Export-ModuleMember -Function Initialize-Database, Add-VideoToDatabase, Get-VideosFromDatabase, `
    Update-VideoStatus, Add-ProcessingLogEntry, Get-DatabaseStatistics, Set-Metadata, Get-Metadata, `
    Set-ConfigValue, Get-ConfigValue, Get-AllConfig, Test-ConfigExists, Remove-ConfigValue
