#------------------------------------------------------------------------------------------------------------------
# EmailHelper.ps1 - Email notification functionality
#------------------------------------------------------------------------------------------------------------------

# Module-level variables
$Script:EmailConfig = $null
$Script:MailKitInstallAttempted = $false
$Script:MailKitAvailable = $false
$Script:MSALInstallAttempted = $false
$Script:MSALAvailable = $false
$Script:CachedAccessToken = $null
$Script:TokenExpiry = $null

#------------------------------------------------------------------------------------------------------------------
# Function: Initialize-EmailConfig
# Purpose: Setup email configuration
#------------------------------------------------------------------------------------------------------------------
function Initialize-EmailConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $Script:EmailConfig = $Config
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-MailKitAvailability
# Purpose: Check if MailKit is available for sending emails
#------------------------------------------------------------------------------------------------------------------
function Test-MailKitAvailability {
    [CmdletBinding()]
    param()

    try {
        # Try to load MailKit assembly
        $null = [System.Reflection.Assembly]::LoadWithPartialName('MailKit')
        $null = [System.Reflection.Assembly]::LoadWithPartialName('MimeKit')

        # Verify we can access the required types
        $mailKitType = [MailKit.Net.Smtp.SmtpClient] -as [Type]
        $mimeKitType = [MimeKit.MimeMessage] -as [Type]

        if ($mailKitType -and $mimeKitType) {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Install-MailKit
# Purpose: Install MailKit package on-demand
#------------------------------------------------------------------------------------------------------------------
function Install-MailKit {
    [CmdletBinding()]
    param()

    try {
        Write-LogEntry -Message "MailKit not found. Attempting to install MailKit package..." -Level 'Info'

        # Check if PackageManagement is available
        if (-not (Get-Module -ListAvailable -Name PackageManagement)) {
            Write-LogEntry -Message "PackageManagement module not available. Cannot auto-install MailKit." -Level 'Error'
            return $false
        }

        # Register NuGet provider if not already registered
        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-LogEntry -Message "Installing NuGet package provider..." -Level 'Info'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }

        # Install MailKit and MimeKit packages
        Write-LogEntry -Message "Installing MailKit package (this may take a moment)..." -Level 'Info'
        Install-Package -Name MailKit -Source nuget.org -Force -Scope CurrentUser -SkipDependencies:$false -ErrorAction Stop | Out-Null

        # Verify installation
        $installed = Test-MailKitAvailability
        if ($installed) {
            Write-LogEntry -Message "MailKit installed successfully" -Level 'Info'
            $Script:MailKitAvailable = $true
            return $true
        }
        else {
            Write-LogEntry -Message "MailKit installation completed but library not accessible" -Level 'Warning'
            return $false
        }
    }
    catch {
        Write-LogEntry -Message "Failed to install MailKit: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Test-MSALAvailability
# Purpose: Check if Microsoft.Identity.Client (MSAL) is available for OAuth
#------------------------------------------------------------------------------------------------------------------
function Test-MSALAvailability {
    [CmdletBinding()]
    param()

    try {
        # Try to load MSAL assembly
        $null = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.Identity.Client')

        # Verify we can access the required types
        $msalType = [Microsoft.Identity.Client.PublicClientApplicationBuilder] -as [Type]

        if ($msalType) {
            return $true
        }

        return $false
    }
    catch {
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Install-MSAL
# Purpose: Install Microsoft.Identity.Client package on-demand
#------------------------------------------------------------------------------------------------------------------
function Install-MSAL {
    [CmdletBinding()]
    param()

    try {
        Write-LogEntry -Message "MSAL not found. Attempting to install Microsoft.Identity.Client package..." -Level 'Info'

        # Check if PackageManagement is available
        if (-not (Get-Module -ListAvailable -Name PackageManagement)) {
            Write-LogEntry -Message "PackageManagement module not available. Cannot auto-install MSAL." -Level 'Error'
            return $false
        }

        # Register NuGet provider if not already registered
        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-LogEntry -Message "Installing NuGet package provider..." -Level 'Info'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }

        # Install MSAL package
        Write-LogEntry -Message "Installing Microsoft.Identity.Client package (this may take a moment)..." -Level 'Info'
        Install-Package -Name Microsoft.Identity.Client -Source nuget.org -Force -Scope CurrentUser -SkipDependencies:$false -ErrorAction Stop | Out-Null

        # Verify installation
        $installed = Test-MSALAvailability
        if ($installed) {
            Write-LogEntry -Message "Microsoft.Identity.Client installed successfully" -Level 'Info'
            $Script:MSALAvailable = $true
            return $true
        }
        else {
            Write-LogEntry -Message "Microsoft.Identity.Client installation completed but library not accessible" -Level 'Warning'
            return $false
        }
    }
    catch {
        Write-LogEntry -Message "Failed to install Microsoft.Identity.Client: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Get-OAuthAccessToken
# Purpose: Acquire OAuth 2.0 access token using MSAL with browser authentication
#------------------------------------------------------------------------------------------------------------------
function Get-OAuthAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$EmailAddress,

        [Parameter(Mandatory = $false)]
        [string]$TokenCacheFile
    )

    try {
        # Check if we have a cached valid token
        if ($Script:CachedAccessToken -and $Script:TokenExpiry -and ((Get-Date) -lt $Script:TokenExpiry)) {
            Write-LogEntry -Message "Using cached access token (expires: $($Script:TokenExpiry))" -Level 'Debug'
            return $Script:CachedAccessToken
        }

        Write-LogEntry -Message "Acquiring OAuth access token via browser authentication..." -Level 'Info'

        # Build MSAL public client application
        $authority = "https://login.microsoftonline.com/$TenantId"
        $scopes = @('https://outlook.office365.com/SMTP.Send', 'offline_access')
        $redirectUri = 'http://localhost'

        $app = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)
        $app = $app.WithAuthority($authority)
        $app = $app.WithRedirectUri($redirectUri)

        # Configure token cache if file specified
        if ($TokenCacheFile) {
            $app = $app.WithCacheOptions([Microsoft.Identity.Client.CacheOptions]::new($true))
        }

        $clientApp = $app.Build()

        # Load token cache from file if it exists
        if ($TokenCacheFile -and (Test-Path -LiteralPath $TokenCacheFile)) {
            try {
                $cacheData = Get-Content -LiteralPath $TokenCacheFile -Raw -ErrorAction Stop
                $decryptedData = ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $cacheData) -AsPlainText
                $clientApp.UserTokenCache.DeserializeMsalV3($decryptedData)
                Write-LogEntry -Message "Loaded token cache from: $TokenCacheFile" -Level 'Debug'
            }
            catch {
                Write-LogEntry -Message "Could not load token cache, will acquire new token: $_" -Level 'Warning'
            }
        }

        # Try to acquire token silently first (using refresh token)
        $accounts = $clientApp.GetAccountsAsync().GetAwaiter().GetResult()
        if ($accounts.Count -gt 0) {
            try {
                Write-LogEntry -Message "Attempting silent token acquisition..." -Level 'Debug'
                $silentRequest = $clientApp.AcquireTokenSilent($scopes, $accounts[0])
                $result = $silentRequest.ExecuteAsync().GetAwaiter().GetResult()
                Write-LogEntry -Message "Successfully acquired token silently" -Level 'Info'
            }
            catch {
                Write-LogEntry -Message "Silent acquisition failed, will use interactive flow: $_" -Level 'Debug'
                $result = $null
            }
        }

        # If silent acquisition failed, use interactive browser flow
        if (-not $result) {
            Write-LogEntry -Message "Opening browser for authentication (MFA supported)..." -Level 'Info'
            $interactiveRequest = $clientApp.AcquireTokenInteractive($scopes).WithLoginHint($EmailAddress).WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
            $result = $interactiveRequest.ExecuteAsync().GetAwaiter().GetResult()
            Write-LogEntry -Message "Successfully acquired token interactively" -Level 'Info'
        }

        # Save token cache to file
        if ($TokenCacheFile) {
            try {
                $cacheBytes = $clientApp.UserTokenCache.SerializeMsalV3()
                $encryptedData = ConvertTo-SecureString -String $cacheBytes -AsPlainText -Force | ConvertFrom-SecureString

                # Ensure directory exists
                $cacheDir = Split-Path -Path $TokenCacheFile -Parent
                if ($cacheDir -and -not (Test-Path -LiteralPath $cacheDir)) {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                }

                Set-Content -LiteralPath $TokenCacheFile -Value $encryptedData -Force
                Write-LogEntry -Message "Saved token cache to: $TokenCacheFile" -Level 'Debug'
            }
            catch {
                Write-LogEntry -Message "Could not save token cache: $_" -Level 'Warning'
            }
        }

        # Cache the token in memory
        $Script:CachedAccessToken = $result.AccessToken
        $Script:TokenExpiry = $result.ExpiresOn.DateTime

        Write-LogEntry -Message "Access token acquired successfully (expires: $($Script:TokenExpiry))" -Level 'Info'
        return $result.AccessToken
    }
    catch {
        Write-LogEntry -Message "Failed to acquire OAuth access token: $_" -Level 'Error'
        return $null
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Send-EmailNotification
# Purpose: Send email notification with report
#------------------------------------------------------------------------------------------------------------------
function Send-EmailNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [bool]$IsHtml = $true,

        [Parameter(Mandatory = $false)]
        [string[]]$Attachments = @()
    )

    try {
        if (-not $Script:EmailConfig -or -not $Script:EmailConfig.Enabled) {
            Write-LogEntry -Message "Email notifications are disabled" -Level 'Debug'
            return $false
        }

        # Check if MailKit is available, install if needed
        if (-not $Script:MailKitAvailable -and -not $Script:MailKitInstallAttempted) {
            $Script:MailKitInstallAttempted = $true
            $Script:MailKitAvailable = Test-MailKitAvailability

            if (-not $Script:MailKitAvailable) {
                Write-LogEntry -Message "MailKit not available. Email functionality requires MailKit package." -Level 'Warning'
                $installed = Install-MailKit
                if (-not $installed) {
                    Write-LogEntry -Message "Cannot send email: MailKit package not available and installation failed" -Level 'Error'
                    return $false
                }
            }
        }

        if (-not $Script:MailKitAvailable) {
            Write-LogEntry -Message "Cannot send email: MailKit package not available" -Level 'Error'
            return $false
        }

        # Check if OAuth is configured - if so, ensure MSAL is available
        $useOAuth = $Script:EmailConfig.ClientId -and $Script:EmailConfig.TenantId
        if ($useOAuth) {
            if (-not $Script:MSALAvailable -and -not $Script:MSALInstallAttempted) {
                $Script:MSALInstallAttempted = $true
                $Script:MSALAvailable = Test-MSALAvailability

                if (-not $Script:MSALAvailable) {
                    Write-LogEntry -Message "MSAL not available. OAuth authentication requires Microsoft.Identity.Client package." -Level 'Warning'
                    $installed = Install-MSAL
                    if (-not $installed) {
                        Write-LogEntry -Message "Cannot send email with OAuth: MSAL package not available and installation failed" -Level 'Error'
                        return $false
                    }
                }
            }

            if (-not $Script:MSALAvailable) {
                Write-LogEntry -Message "Cannot send email with OAuth: MSAL package not available" -Level 'Error'
                return $false
            }
        }

        # Send email using MailKit
        $result = Send-EmailViaMailKit -Subject $Subject -Body $Body -IsHtml $IsHtml -Attachments $Attachments
        return $result
    }
    catch {
        Write-LogEntry -Message "Failed to send email notification: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Send-EmailViaMailKit
# Purpose: Send email using MailKit library
#------------------------------------------------------------------------------------------------------------------
function Send-EmailViaMailKit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [bool]$IsHtml = $true,

        [Parameter(Mandatory = $false)]
        [string[]]$Attachments = @()
    )

    try {
        # Create message
        $message = New-Object MimeKit.MimeMessage

        # Set From address
        $message.From.Add([MimeKit.MailboxAddress]::new('', $Script:EmailConfig.From))

        # Set To addresses
        foreach ($recipient in $Script:EmailConfig.To) {
            $message.To.Add([MimeKit.MailboxAddress]::new('', $recipient))
        }

        # Set Subject
        $message.Subject = $Subject

        # Build body
        $bodyBuilder = New-Object MimeKit.BodyBuilder
        if ($IsHtml) {
            $bodyBuilder.HtmlBody = $Body
        }
        else {
            $bodyBuilder.TextBody = $Body
        }

        # Add attachments
        foreach ($attachment in $Attachments) {
            if (Test-Path -LiteralPath $attachment) {
                $null = $bodyBuilder.Attachments.Add($attachment)
            }
            else {
                Write-LogEntry -Message "Attachment not found, skipping: $attachment" -Level 'Warning'
            }
        }

        $message.Body = $bodyBuilder.ToMessageBody()

        # Create SMTP client and send
        $smtpClient = New-Object MailKit.Net.Smtp.SmtpClient

        try {
            # Connect to SMTP server
            $secureSocketOptions = if ($Script:EmailConfig.UseSSL) {
                [MailKit.Security.SecureSocketOptions]::StartTls
            }
            else {
                [MailKit.Security.SecureSocketOptions]::None
            }

            $smtpClient.Connect($Script:EmailConfig.SmtpServer, $Script:EmailConfig.SmtpPort, $secureSocketOptions)

            # Authenticate using OAuth or username/password
            if ($Script:EmailConfig.ClientId -and $Script:EmailConfig.TenantId) {
                # OAuth 2.0 authentication
                Write-LogEntry -Message "Using OAuth 2.0 authentication" -Level 'Debug'

                $accessToken = Get-OAuthAccessToken `
                    -ClientId $Script:EmailConfig.ClientId `
                    -TenantId $Script:EmailConfig.TenantId `
                    -EmailAddress $Script:EmailConfig.From `
                    -TokenCacheFile $Script:EmailConfig.TokenCacheFile

                if (-not $accessToken) {
                    throw "Failed to acquire OAuth access token"
                }

                # Create OAuth2 SASL mechanism
                $oauth2 = New-Object MailKit.Security.SaslMechanismOAuth2($Script:EmailConfig.From, $accessToken)
                $smtpClient.Authenticate($oauth2)
                Write-LogEntry -Message "Authenticated via OAuth 2.0" -Level 'Debug'
            }
            elseif ($Script:EmailConfig.Username -and $Script:EmailConfig.Password) {
                # Username/password authentication
                Write-LogEntry -Message "Using username/password authentication" -Level 'Debug'
                $smtpClient.Authenticate($Script:EmailConfig.Username, $Script:EmailConfig.Password)
            }
            else {
                Write-LogEntry -Message "No authentication configured - attempting to send without auth" -Level 'Warning'
            }

            # Send message
            $null = $smtpClient.Send($message)

            Write-LogEntry -Message "Email notification sent successfully to: $($Script:EmailConfig.To -join ', ')" -Level 'Info'
            return $true
        }
        finally {
            if ($smtpClient.IsConnected) {
                $smtpClient.Disconnect($true)
            }
            $smtpClient.Dispose()
        }
    }
    catch {
        Write-LogEntry -Message "Failed to send email via MailKit: $_" -Level 'Error'
        return $false
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Build-CompletionReport
# Purpose: Generate HTML report for completion notification
#------------------------------------------------------------------------------------------------------------------
function Build-CompletionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Statistics,

        [Parameter(Mandatory = $false)]
        [array]$FailedVideos = @()
    )

    try {
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #0078d4; }
        h2 { color: #333; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th { background-color: #0078d4; color: white; padding: 10px; text-align: left; }
        td { padding: 8px; border-bottom: 1px solid #ddd; }
        tr:hover { background-color: #f5f5f5; }
        .summary { background-color: #e8f4f8; padding: 15px; border-radius: 5px; margin: 20px 0; }
        .stat { font-size: 24px; font-weight: bold; color: #0078d4; }
        .failed { color: #d13438; }
        .success { color: #107c10; }
    </style>
</head>
<body>
    <h1>SharePoint Video Compression Report</h1>
    <p><strong>Run Date:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>

    <div class="summary">
        <h2>Summary</h2>
        <p><span class="stat success">$($Statistics['StatusBreakdown'] | Where-Object { $_.status -eq 'Completed' } | Select-Object -ExpandProperty count)</span> videos processed successfully</p>
        <p><span class="stat failed">$($Statistics['StatusBreakdown'] | Where-Object { $_.status -eq 'Failed' } | Select-Object -ExpandProperty count)</span> videos failed</p>
        <p><strong>Total Videos Cataloged:</strong> $($Statistics['TotalCataloged'])</p>
        <p><strong>Original Size:</strong> $([math]::Round($Statistics['TotalOriginalSize'] / 1GB, 2)) GB</p>
        <p><strong>Compressed Size:</strong> $([math]::Round($Statistics['TotalCompressedSize'] / 1GB, 2)) GB</p>
        <p><strong>Space Saved:</strong> $([math]::Round($Statistics['SpaceSaved'] / 1GB, 2)) GB</p>
        <p><strong>Average Compression Ratio:</strong> $($Statistics['AverageCompressionRatio'])</p>
    </div>

    <h2>Status Breakdown</h2>
    <table>
        <tr>
            <th>Status</th>
            <th>Count</th>
        </tr>
"@

        foreach ($status in $Statistics['StatusBreakdown']) {
            $html += @"
        <tr>
            <td>$($status.status)</td>
            <td>$($status.count)</td>
        </tr>
"@
        }

        $html += @"
    </table>
"@

        if ($FailedVideos.Count -gt 0) {
            $html += @"

    <h2 class="failed">Failed Videos</h2>
    <table>
        <tr>
            <th>Filename</th>
            <th>SharePoint URL</th>
            <th>Error</th>
        </tr>
"@

            foreach ($video in $FailedVideos) {
                $html += @"
        <tr>
            <td>$($video.filename)</td>
            <td><a href="$($video.sharepoint_url)">$($video.sharepoint_url)</a></td>
            <td>$($video.last_error)</td>
        </tr>
"@
            }

            $html += @"
    </table>
"@
        }

        $html += @"

    <hr>
    <p style="color: #666; font-size: 12px;">Generated by SharePoint Video Compression Automation</p>
</body>
</html>
"@

        return $html
    }
    catch {
        Write-LogEntry -Message "Failed to build completion report: $_" -Level 'Error'
        return "<html><body><h1>Error generating report</h1></body></html>"
    }
}

#------------------------------------------------------------------------------------------------------------------
# Function: Build-ErrorReport
# Purpose: Generate HTML report for error notification
#------------------------------------------------------------------------------------------------------------------
function Build-ErrorReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,

        [Parameter(Mandatory = $false)]
        [string]$VideoFilename = '',

        [Parameter(Mandatory = $false)]
        [string]$SharePointUrl = ''
    )

    try {
        $html = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #d13438; }
        .error-box { background-color: #fef0f0; border-left: 4px solid #d13438; padding: 15px; margin: 20px 0; }
        .details { background-color: #f5f5f5; padding: 10px; margin-top: 10px; }
    </style>
</head>
<body>
    <h1>Video Compression Error</h1>
    <p><strong>Time:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>

    <div class="error-box">
        <h2>Error Details</h2>
        <p><strong>Error:</strong> $ErrorMessage</p>
"@

        if ($VideoFilename) {
            $html += "<p><strong>Video:</strong> $VideoFilename</p>"
        }

        if ($SharePointUrl) {
            $html += "<p><strong>SharePoint URL:</strong> <a href='$SharePointUrl'>$SharePointUrl</a></p>"
        }

        $html += @"
    </div>

    <p>Please check the logs for more details.</p>

    <hr>
    <p style="color: #666; font-size: 12px;">Generated by SharePoint Video Compression Automation</p>
</body>
</html>
"@

        return $html
    }
    catch {
        Write-LogEntry -Message "Failed to build error report: $_" -Level 'Error'
        return "<html><body><h1>Error generating error report</h1></body></html>"
    }
}

# Export functions
Export-ModuleMember -Function Initialize-EmailConfig, Send-EmailNotification, `
    Build-CompletionReport, Build-ErrorReport, Test-MailKitAvailability, Install-MailKit, `
    Test-MSALAvailability, Install-MSAL, Get-OAuthAccessToken
