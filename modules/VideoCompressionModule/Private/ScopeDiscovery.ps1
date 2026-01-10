#------------------------------------------------------------------------------------------------------------------
# ScopeDiscovery.ps1 - SharePoint site and library discovery with interactive selection
#------------------------------------------------------------------------------------------------------------------

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompDiscoverTenantSites
# Purpose: Discover all SharePoint sites in the tenant
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompDiscoverTenantSites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdminSiteUrl,  # e.g., https://contoso-admin.sharepoint.com

        [Parameter(Mandatory = $false)]
        [switch]$IncludePersonalSites
    )

    try {
        # Ensure PnP.PowerShell module is available
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Write-Host "PnP.PowerShell module not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
        }
        if (-not (Get-Module -Name PnP.PowerShell)) {
            Import-Module PnP.PowerShell -ErrorAction Stop
        }

        Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Yellow
        Write-Host "A browser window will open for authentication..." -ForegroundColor Gray
        Write-Host ""

        # Use PnP Management Shell app (requires admin consent in tenant)
        Connect-PnPOnline -Url $AdminSiteUrl -Interactive -ClientId "d0e63221-5ead-43d0-8f3f-ad7c7b30f518" -ErrorAction Stop

        Write-Host "Discovering sites in tenant..." -ForegroundColor Yellow
        $sites = Get-PnPTenantSite -Detailed -ErrorAction Stop

        # Filter out system sites
        $systemTemplates = @('APP', 'SRCHCEN', 'APPCATALOG', 'POINTPUBLISHINGHUB', 'EDISC')
        $filteredSites = $sites | Where-Object {
            $_.Template -notin $systemTemplates -and
            (-not $_.Url.Contains('portals.ms')) -and
            (-not $_.Url.Contains('my.sharepoint.com') -or $IncludePersonalSites)
        }

        Write-Host "Found $($filteredSites.Count) sites" -ForegroundColor Green

        # Return structured array
        $result = $filteredSites | ForEach-Object {
            @{
                SiteUrl = $_.Url
                Title = $_.Title
                Template = $_.Template
                StorageUsedMB = [math]::Round($_.StorageUsage, 2)
                LastModified = $_.LastContentModifiedDate
            }
        }

        Disconnect-PnPOnline

        return $result
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to discover tenant sites: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-SPVidCompDiscoverSiteLibraries
# Purpose: Discover all document libraries in a SharePoint site
#------------------------------------------------------------------------------------------------------------------
function Get-SPVidCompDiscoverSiteLibraries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,

        [Parameter(Mandatory = $false)]
        [switch]$DocumentLibrariesOnly
    )

    try {
        # Ensure PnP.PowerShell module is available
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Write-Host "PnP.PowerShell module not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
        }
        if (-not (Get-Module -Name PnP.PowerShell)) {
            Import-Module PnP.PowerShell -ErrorAction Stop
        }

        Write-Host "Connecting to site: $SiteUrl" -ForegroundColor Yellow
        Write-Host "A browser window will open for authentication..." -ForegroundColor Gray
        Write-Host ""

        # Use PnP Management Shell app (requires admin consent in tenant)
        Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId "d0e63221-5ead-43d0-8f3f-ad7c7b30f518" -ErrorAction Stop

        Write-Host "Discovering libraries..." -ForegroundColor Yellow
        $lists = Get-PnPList -ErrorAction Stop

        # Filter for document libraries (BaseTemplate 101)
        $libraries = $lists | Where-Object {
            $_.BaseTemplate -eq 101 -and
            -not $_.Hidden -and
            $_.Title -notlike '*Form Templates' -and
            $_.Title -notlike 'Style Library'
        }

        Write-Host "Found $($libraries.Count) document libraries" -ForegroundColor Green

        # Return structured array
        $result = $libraries | ForEach-Object {
            @{
                LibraryName = $_.Title
                InternalName = $_.RootFolder.Name
                ItemCount = $_.ItemCount
                ServerRelativeUrl = $_.RootFolder.ServerRelativeUrl
                Description = $_.Description
            }
        }

        Disconnect-PnPOnline

        return $result
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed to discover site libraries: $_" -Level 'Error'
        throw
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Select-SPVidCompScopesInteractive
# Purpose: Interactive scope selection using ConsoleGuiTools
#------------------------------------------------------------------------------------------------------------------
function Select-SPVidCompScopesInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Single', 'Site', 'Multiple', 'Tenant')]
        [string]$ScopeMode,

        [Parameter(Mandatory = $false)]
        [string]$AdminSiteUrl = $null
    )

    try {
        # Ensure ConsoleGuiTools is available
        if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.ConsoleGuiTools)) {
            Write-Host "Microsoft.PowerShell.ConsoleGuiTools not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name Microsoft.PowerShell.ConsoleGuiTools -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module Microsoft.PowerShell.ConsoleGuiTools -ErrorAction Stop

        $scopes = @()

        switch ($ScopeMode) {
            'Single' {
                # Single library mode
                Write-Host "`nSingle Library Mode" -ForegroundColor Cyan
                $siteUrl = Read-Host "Enter SharePoint Site URL (e.g., https://contoso.sharepoint.com/sites/YourSite)"

                if ([string]::IsNullOrWhiteSpace($siteUrl)) {
                    throw "Site URL is required"
                }

                # Discover libraries
                $libraries = Get-SPVidCompDiscoverSiteLibraries -SiteUrl $siteUrl

                if ($libraries.Count -eq 0) {
                    throw "No document libraries found in site"
                }

                # Interactive library selection
                Write-Host "`nSelect a library:" -ForegroundColor Yellow
                $selectedLibrary = $libraries | Select-Object @{N='Library Name';E={$_.LibraryName}},
                    @{N='Items';E={$_.ItemCount}},
                    @{N='Path';E={$_.ServerRelativeUrl}} |
                    Out-ConsoleGridView -Title "Select Library" -OutputMode Single

                if ($null -eq $selectedLibrary) {
                    throw "No library selected"
                }

                # Find the original library object
                $library = $libraries | Where-Object { $_.LibraryName -eq $selectedLibrary.'Library Name' }

                # Optional folder path
                Write-Host "`nOptional: Enter folder path within library (leave blank for root)" -ForegroundColor Yellow
                $folderPath = Read-Host "Folder path (e.g., /Videos)"

                # Optional recursive setting
                $recursiveInput = Read-Host "Scan subfolders recursively? (Y/n) [default: Y]"
                $recursive = if ($recursiveInput -match '^n') { $false } else { $true }

                $scopes += @{
                    SiteUrl = $siteUrl
                    LibraryName = $library.LibraryName
                    FolderPath = if ([string]::IsNullOrWhiteSpace($folderPath)) { '' } else { $folderPath }
                    Recursive = $recursive
                    DisplayName = "$($library.LibraryName) @ $($siteUrl -replace '^https?://', '')"
                }
            }

            'Site' {
                # All libraries in one site mode
                Write-Host "`nSite-Wide Mode" -ForegroundColor Cyan
                $siteUrl = Read-Host "Enter SharePoint Site URL"

                if ([string]::IsNullOrWhiteSpace($siteUrl)) {
                    throw "Site URL is required"
                }

                # Discover libraries
                $libraries = Get-SPVidCompDiscoverSiteLibraries -SiteUrl $siteUrl

                if ($libraries.Count -eq 0) {
                    throw "No document libraries found in site"
                }

                # Interactive multi-library selection
                Write-Host "`nSelect libraries to scan (use Space to select, Enter to confirm):" -ForegroundColor Yellow
                $selectedLibraries = $libraries | Select-Object @{N='Library Name';E={$_.LibraryName}},
                    @{N='Items';E={$_.ItemCount}},
                    @{N='Path';E={$_.ServerRelativeUrl}} |
                    Out-ConsoleGridView -Title "Select Libraries" -OutputMode Multiple

                if ($null -eq $selectedLibraries -or $selectedLibraries.Count -eq 0) {
                    throw "No libraries selected"
                }

                # Recursive setting applies to all
                $recursiveInput = Read-Host "`nScan subfolders recursively in all libraries? (Y/n) [default: Y]"
                $recursive = if ($recursiveInput -match '^n') { $false } else { $true }

                # Create scope for each selected library
                foreach ($selected in $selectedLibraries) {
                    $library = $libraries | Where-Object { $_.LibraryName -eq $selected.'Library Name' }

                    $scopes += @{
                        SiteUrl = $siteUrl
                        LibraryName = $library.LibraryName
                        FolderPath = ''
                        Recursive = $recursive
                        DisplayName = "$($library.LibraryName) @ $($siteUrl -replace '^https?://', '')"
                    }
                }
            }

            'Multiple' {
                # Multiple specific sites/libraries mode
                Write-Host "`nMultiple Sites Mode" -ForegroundColor Cyan
                Write-Host "Enter site URLs one per line. Enter blank line when done." -ForegroundColor Yellow

                $siteUrls = @()
                $index = 1

                while ($true) {
                    $siteUrl = Read-Host "  Site $index (blank to finish)"

                    if ([string]::IsNullOrWhiteSpace($siteUrl)) {
                        break
                    }

                    $siteUrls += $siteUrl
                    $index++
                }

                if ($siteUrls.Count -eq 0) {
                    throw "No site URLs entered"
                }

                # Recursive setting applies to all
                $recursiveInput = Read-Host "`nScan subfolders recursively in all libraries? (Y/n) [default: Y]"
                $recursive = if ($recursiveInput -match '^n') { $false } else { $true }

                # Process each site
                foreach ($siteUrl in $siteUrls) {
                    Write-Host "`n--- Site: $siteUrl ---" -ForegroundColor Cyan

                    # Discover libraries
                    try {
                        $libraries = Get-SPVidCompDiscoverSiteLibraries -SiteUrl $siteUrl

                        if ($libraries.Count -eq 0) {
                            Write-Host "No document libraries found. Skipping..." -ForegroundColor Yellow
                            continue
                        }

                        # Interactive multi-library selection
                        Write-Host "Select libraries from this site:" -ForegroundColor Yellow
                        $selectedLibraries = $libraries | Select-Object @{N='Library Name';E={$_.LibraryName}},
                            @{N='Items';E={$_.ItemCount}},
                            @{N='Path';E={$_.ServerRelativeUrl}} |
                            Out-ConsoleGridView -Title "Select Libraries from $siteUrl" -OutputMode Multiple

                        if ($null -ne $selectedLibraries -and $selectedLibraries.Count -gt 0) {
                            foreach ($selected in $selectedLibraries) {
                                $library = $libraries | Where-Object { $_.LibraryName -eq $selected.'Library Name' }

                                $scopes += @{
                                    SiteUrl = $siteUrl
                                    LibraryName = $library.LibraryName
                                    FolderPath = ''
                                    Recursive = $recursive
                                    DisplayName = "$($library.LibraryName) @ $($siteUrl -replace '^https?://', '')"
                                }
                            }
                        }
                    }
                    catch {
                        Write-Host "Failed to process site: $_" -ForegroundColor Red
                        continue
                    }
                }
            }

            'Tenant' {
                # Entire tenant mode
                Write-Host "`nTenant-Wide Mode" -ForegroundColor Cyan

                if ([string]::IsNullOrWhiteSpace($AdminSiteUrl)) {
                    throw "Admin site URL is required for Tenant mode"
                }

                # Discover all sites
                $sites = Get-SPVidCompDiscoverTenantSites -AdminSiteUrl $AdminSiteUrl

                if ($sites.Count -eq 0) {
                    throw "No sites found in tenant"
                }

                # Interactive site selection
                Write-Host "`nSelect sites to scan (use Space to select, Enter to confirm):" -ForegroundColor Yellow
                $selectedSites = $sites | Select-Object @{N='Title';E={$_.Title}},
                    @{N='URL';E={$_.SiteUrl}},
                    @{N='Template';E={$_.Template}},
                    @{N='Storage (MB)';E={$_.StorageUsedMB}} |
                    Out-ConsoleGridView -Title "Select Sites" -OutputMode Multiple

                if ($null -eq $selectedSites -or $selectedSites.Count -eq 0) {
                    throw "No sites selected"
                }

                # Recursive setting applies to all
                $recursiveInput = Read-Host "`nScan subfolders recursively in all libraries? (Y/n) [default: Y]"
                $recursive = if ($recursiveInput -match '^n') { $false } else { $true }

                # Process each selected site
                foreach ($selected in $selectedSites) {
                    $siteUrl = $selected.URL
                    Write-Host "`n--- Site: $($selected.Title) ---" -ForegroundColor Cyan

                    # Discover libraries
                    try {
                        $libraries = Get-SPVidCompDiscoverSiteLibraries -SiteUrl $siteUrl

                        if ($libraries.Count -eq 0) {
                            Write-Host "No document libraries found. Skipping..." -ForegroundColor Yellow
                            continue
                        }

                        # Interactive multi-library selection
                        Write-Host "Select libraries from this site:" -ForegroundColor Yellow
                        $selectedLibraries = $libraries | Select-Object @{N='Library Name';E={$_.LibraryName}},
                            @{N='Items';E={$_.ItemCount}},
                            @{N='Path';E={$_.ServerRelativeUrl}} |
                            Out-ConsoleGridView -Title "Select Libraries from $($selected.Title)" -OutputMode Multiple

                        if ($null -ne $selectedLibraries -and $selectedLibraries.Count -gt 0) {
                            foreach ($selectedLib in $selectedLibraries) {
                                $library = $libraries | Where-Object { $_.LibraryName -eq $selectedLib.'Library Name' }

                                $scopes += @{
                                    SiteUrl = $siteUrl
                                    LibraryName = $library.LibraryName
                                    FolderPath = ''
                                    Recursive = $recursive
                                    DisplayName = "$($library.LibraryName) @ $($selected.Title)"
                                }
                            }
                        }
                    }
                    catch {
                        Write-Host "Failed to process site: $_" -ForegroundColor Red
                        continue
                    }
                }
            }
        }

        if ($scopes.Count -eq 0) {
            throw "No scopes were selected"
        }

        Write-Host "`nSelected $($scopes.Count) total scope(s)" -ForegroundColor Green

        return $scopes
    }
    catch {
        Write-SPVidCompLogEntry -Message "Failed during interactive scope selection: $_" -Level 'Error'
        throw
    }
}

# Export functions
Export-ModuleMember -Function Get-SPVidCompDiscoverTenantSites, Get-SPVidCompDiscoverSiteLibraries, Select-SPVidCompScopesInteractive
