#------------------------------------------------------------------------------------------------------------------
# ScopeManager.ps1 - CRUD operations for scopes table
#------------------------------------------------------------------------------------------------------------------

#------------------------------------------------------------------------------------------------------------------
# Function: Add-SPVidCompScope
# Purpose: Add a new scope to the scopes table
#------------------------------------------------------------------------------------------------------------------
function Add-SPVidCompScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true)]
        [string]$LibraryName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Single', 'Site', 'Multiple', 'Tenant')]
        [string]$ScopeMode,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$FolderPath = '',

        [Parameter(Mandatory = $false)]
        [bool]$Recursive = $true
    )

    try {
        $query = @"
INSERT INTO scopes
(scope_mode, site_url, library_name, folder_path, recursive, display_name, enabled, created_date)
VALUES
(@scope_mode, @site_url, @library_name, @folder_path, @recursive, @display_name, 1, @created_date);
SELECT last_insert_rowid() as id;
"@

        $parameters = @{
            scope_mode = $ScopeMode
            site_url = $SiteUrl
            library_name = $LibraryName
            folder_path = $FolderPath
            recursive = if ($Recursive) { 1 } else { 0 }
            display_name = $DisplayName
            created_date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        $result = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        Write-SPVidCompLogEntry -Message "Scope added: $DisplayName (ID: $($result.id))" -Level 'Info'

        return $result.id
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to add scope: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompScopes
# Purpose: Retrieve scopes from database
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompScopes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [switch]$EnabledOnly
    )

    try {
        $query = if ($EnabledOnly) {
            "SELECT * FROM scopes WHERE enabled = 1 ORDER BY created_date ASC;"
        } else {
            "SELECT * FROM scopes ORDER BY created_date ASC;"
        }

        $results = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query

        return $results
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to retrieve scopes: $_" -Level 'Error'
        return @()
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Update-SPVidCompScopeStats
# Purpose: Update video_count and total_size statistics for a scope
#------------------------------------------------------------------------------------------------------------------
function Update-SPVidCompScopeStats {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ScopeId
    )

    try {
        # Get video count and total size for this scope
        $statsQuery = @"
SELECT
    COUNT(*) as video_count,
    COALESCE(SUM(original_size), 0) as total_size
FROM videos
WHERE scope_id = @scope_id;
"@

        $statsParams = @{ scope_id = $ScopeId }
        $stats = Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $statsQuery -SqlParameters $statsParams

        # Update scope record
        $updateQuery = @"
UPDATE scopes
SET video_count = @video_count,
    total_size = @total_size,
    last_scanned_date = @last_scanned
WHERE id = @scope_id;
"@

        $updateParams = @{
            scope_id = $ScopeId
            video_count = $stats.video_count
            total_size = $stats.total_size
            last_scanned = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $updateQuery -SqlParameters $updateParams

        Write-SPVidCompLogEntry -Message "Updated stats for scope ID ${ScopeId}: $($stats.video_count) videos, $([math]::Round($stats.total_size / 1MB, 2)) MB" -Level 'Debug'

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to update scope stats: $_" -Level 'Warning'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Remove-SPVidCompScope
# Purpose: Remove a scope from the database
#------------------------------------------------------------------------------------------------------------------
function Remove-SPVidCompScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ScopeId,

        [Parameter(Mandatory = $false)]
        [switch]$DeleteVideos
    )

    try {
        # Optionally delete associated videos
        if ($DeleteVideos) {
            $deleteVideosQuery = "DELETE FROM videos WHERE scope_id = @scope_id;"
            $deleteParams = @{ scope_id = $ScopeId }
            Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $deleteVideosQuery -SqlParameters $deleteParams
            Write-SPVidCompLogEntry -Message "Deleted videos for scope ID $ScopeId" -Level 'Info'
        }

        # Delete scope
        $deleteScopeQuery = "DELETE FROM scopes WHERE id = @scope_id;"
        $scopeParams = @{ scope_id = $ScopeId }
        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $deleteScopeQuery -SqlParameters $scopeParams

        Write-SPVidCompLogEntry -Message "Removed scope ID $ScopeId" -Level 'Info'

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to remove scope: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Enable-SPVidCompScope
# Purpose: Enable a scope
#------------------------------------------------------------------------------------------------------------------
function Enable-SPVidCompScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ScopeId
    )

    try {
        $query = "UPDATE scopes SET enabled = 1 WHERE id = @scope_id;"
        $parameters = @{ scope_id = $ScopeId }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        Write-SPVidCompLogEntry -Message "Enabled scope ID $ScopeId" -Level 'Info'

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to enable scope: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Disable-SPVidCompScope
# Purpose: Disable a scope
#------------------------------------------------------------------------------------------------------------------
function Disable-SPVidCompScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ScopeId
    )

    try {
        $query = "UPDATE scopes SET enabled = 0 WHERE id = @scope_id;"
        $parameters = @{ scope_id = $ScopeId }

        Invoke-SqliteQuery -DataSource $Script:DatabasePath -Query $query -SqlParameters $parameters

        Write-SPVidCompLogEntry -Message "Disabled scope ID $ScopeId" -Level 'Info'

        return $true
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to disable scope: $_" -Level 'Error'
        return $false
    }
}

# Export functions
Export-ModuleMember -Function Add-SPVidCompScope, Get-SPVidCompScopes, Update-SPVidCompScopeStats, Remove-SPVidCompScope, Enable-SPVidCompScope, Disable-SPVidCompScope
