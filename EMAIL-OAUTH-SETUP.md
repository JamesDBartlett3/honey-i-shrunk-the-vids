# Email OAuth 2.0 Setup Guide

This guide explains how to configure OAuth 2.0 authentication for email notifications using Microsoft 365 with MFA support.

## Overview

The solution uses **OAuth 2.0 with Microsoft Identity Platform** (Azure AD) for email authentication. This approach:
- ✅ **Supports MFA** - Works with multi-factor authentication
- ✅ **Secure** - No passwords stored, uses encrypted refresh tokens
- ✅ **Browser-based** - First-time authentication opens browser for consent
- ✅ **Silent refresh** - Subsequent runs don't require browser interaction

## Prerequisites

- Microsoft 365 tenant (Office 365)
- Global Administrator or Application Administrator role in Azure AD
- PowerShell 7.0+

## Step 1: Register Azure AD Application

### Option A: Using Azure Portal (Recommended for beginners)

1. **Navigate to Azure Portal**
   - Go to [Azure Portal](https://portal.azure.com)
   - Sign in with your Microsoft 365 admin account

2. **Register New Application**
   - Search for and select **"Azure Active Directory"**
   - Click **"App registrations"** in the left menu
   - Click **"+ New registration"**

3. **Configure Application**
   - **Name**: `SharePoint Video Compression - Email`
   - **Supported account types**: Select **"Accounts in this organizational directory only (Single tenant)"**
   - **Redirect URI**: Select **"Public client/native (mobile & desktop)"** and enter: `http://localhost`
   - Click **"Register"**

4. **Configure API Permissions**
   - In your new app, click **"API permissions"** in the left menu
   - Click **"+ Add a permission"**
   - Select **"Microsoft Graph"** (not required for SMTP, but click on it then go back)
   - Click **"APIs my organization uses"**
   - Search for and select **"Office 365 Exchange Online"**
   - Select **"Delegated permissions"**
   - Check **"SMTP.Send"** permission
   - Click **"Add permissions"**
   - *Optional*: Click **"Grant admin consent for [Your Organization]"** (requires admin)

5. **Enable Public Client Flow**
   - Click **"Authentication"** in the left menu
   - Scroll down to **"Advanced settings"**
   - Under **"Allow public client flows"**, set **"Enable the following mobile and desktop flows"** to **"Yes"**
   - Click **"Save"**

6. **Copy Application Details**
   - Go to **"Overview"** in the left menu
   - **Copy** the **"Application (client) ID"** - you'll need this for `ClientId`
   - **Copy** the **"Directory (tenant) ID"** - you'll need this for `TenantId`

### Option B: Using PowerShell (Advanced)

```powershell
# Install Azure AD module if not already installed
Install-Module -Name AzureAD -Scope CurrentUser

# Connect to Azure AD
Connect-AzureAD

# Create app registration
$app = New-AzureADApplication `
    -DisplayName "SharePoint Video Compression - Email" `
    -PublicClient $true `
    -ReplyUrls @("http://localhost")

# Add SMTP.Send permission (Office 365 Exchange Online API)
$exchangeOnlineAppId = "00000002-0000-0ff1-ce00-000000000000" # Exchange Online
$smtpSendPermission = "ff91d191-45a0-43fd-b837-bd682c4a0b0f"   # SMTP.Send

$resourceAccess = New-Object Microsoft.Open.AzureAD.Model.ResourceAccess
$resourceAccess.Id = $smtpSendPermission
$resourceAccess.Type = "Scope"

$requiredResourceAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
$requiredResourceAccess.ResourceAppId = $exchangeOnlineAppId
$requiredResourceAccess.ResourceAccess = $resourceAccess

Set-AzureADApplication -ObjectId $app.ObjectId -RequiredResourceAccess $requiredResourceAccess

# Display IDs
Write-Host "Application (Client) ID: $($app.AppId)"
Write-Host "Tenant ID: $((Get-AzureADTenantDetail).ObjectId)"
```

## Step 2: Configure Email Settings in Database

Update your configuration in the SQLite database with the OAuth parameters:

```powershell
# Load the module
Import-Module ./modules/VideoCompressionModule/VideoCompressionModule.psm1

# Initialize configuration (if not already done)
Initialize-SPVidComp-Config -DatabasePath ./video-catalog.db

# Get current email config
$emailConfig = Get-SPVidComp-Config -Key 'Email'

# Update with OAuth parameters
$emailConfig.ClientId = '<YOUR_CLIENT_ID>'           # From Azure AD App Registration
$emailConfig.TenantId = '<YOUR_TENANT_ID>'           # From Azure AD
$emailConfig.TokenCacheFile = './config/.token-cache' # Path to store encrypted tokens
$emailConfig.SmtpServer = 'smtp.office365.com'       # Office 365 SMTP
$emailConfig.SmtpPort = 587                           # Office 365 SMTP port
$emailConfig.UseSSL = $true                           # Required for Office 365
$emailConfig.From = 'your-email@yourdomain.com'       # Your M365 email address
$emailConfig.To = @('recipient@domain.com')           # Recipients
$emailConfig.Enabled = $true                          # Enable email notifications

# Remove username/password (OAuth doesn't need them)
$emailConfig.Username = ''
$emailConfig.Password = ''

# Save updated config
Set-SPVidComp-Config -Key 'Email' -Value $emailConfig
```

### Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ClientId` | Application (client) ID from Azure AD | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` |
| `TenantId` | Directory (tenant) ID from Azure AD | `12345678-90ab-cdef-1234-567890abcdef` |
| `TokenCacheFile` | Path to store encrypted refresh tokens | `./config/.token-cache` |
| `SmtpServer` | Office 365 SMTP server | `smtp.office365.com` |
| `SmtpPort` | SMTP port (587 for STARTTLS) | `587` |
| `UseSSL` | Enable SSL/TLS | `$true` |
| `From` | Sender email address (your M365 account) | `automation@contoso.com` |
| `To` | Recipient email addresses (array) | `@('admin@contoso.com')` |

## Step 3: First-Time Authentication

When you run the script for the first time with email enabled:

1. **Browser opens automatically** - You'll see a Microsoft login page
2. **Sign in with MFA** - Enter your credentials and complete MFA
3. **Consent prompt** - Click "Accept" to grant SMTP.Send permission
4. **Token saved** - Encrypted refresh token saved to `TokenCacheFile`
5. **Email sent** - Your email notification is sent

### What Happens:
```
[Info] MailKit not found. Attempting to install MailKit package...
[Info] MailKit installed successfully
[Info] MSAL not found. Attempting to install Microsoft.Identity.Client package...
[Info] Microsoft.Identity.Client installed successfully
[Info] Opening browser for authentication (MFA supported)...
[Browser opens for login]
[Info] Successfully acquired token interactively
[Info] Saved token cache to: ./config/.token-cache
[Info] Access token acquired successfully (expires: 2026-01-07 18:30:00)
[Info] Using OAuth 2.0 authentication
[Info] Authenticated via OAuth 2.0
[Info] Email notification sent successfully to: admin@contoso.com
```

## Step 4: Subsequent Runs (Silent Token Refresh)

After the first authentication, subsequent runs will:
- ✅ Load encrypted refresh token from cache file
- ✅ Silently acquire new access token (no browser)
- ✅ Send email without user interaction

```
[Info] Loaded token cache from: ./config/.token-cache
[Info] Attempting silent token acquisition...
[Info] Successfully acquired token silently
[Info] Access token acquired successfully (expires: 2026-01-07 19:45:00)
[Info] Email notification sent successfully
```

## Troubleshooting

### Browser Doesn't Open
- **Check redirect URI**: Ensure `http://localhost` is configured in Azure AD
- **Firewall**: Ensure PowerShell can open browser
- **Run manually**: The browser should open automatically, but you can manually navigate to the auth URL if needed

### "AADSTS65001: The user or administrator has not consented"
- **Solution**: Admin needs to grant consent in Azure AD portal
- **Or**: User needs to accept consent prompt during first login

### "Failed to acquire OAuth access token"
- **Check ClientId/TenantId**: Ensure they're correct in your config
- **Check API permissions**: Ensure SMTP.Send permission is added
- **Check public client**: Ensure "Allow public client flows" is enabled

### "Authentication failed: 535 5.7.3 Authentication unsuccessful"
- **Token expired**: Delete token cache file and re-authenticate
- **Wrong scope**: Ensure using `https://outlook.office365.com/SMTP.Send`
- **Account issue**: Ensure the From address matches the authenticated account

### Token Cache Issues
- **Location**: Check that `TokenCacheFile` path exists and is writable
- **Encryption**: Token cache is encrypted using Windows DPAPI (user-specific)
- **Reset**: Delete the token cache file to force re-authentication

## Security Considerations

### Token Storage
- **Encrypted**: Tokens are encrypted using `ConvertTo-SecureString` (Windows DPAPI)
- **User-specific**: Tokens are tied to the user account that encrypted them
- **Not portable**: Token cache cannot be copied to another machine/user
- **Secure location**: Store token cache in a secure directory with appropriate permissions

### Best Practices
1. **Least privilege**: Only grant SMTP.Send permission (not full mailbox access)
2. **Dedicated account**: Consider using a dedicated service account for emails
3. **Secure storage**: Store token cache file in a protected directory
4. **Regular rotation**: Tokens automatically refresh, but consider periodic re-authentication
5. **Audit logs**: Monitor Azure AD sign-in logs for the application

## Additional Resources

- [Microsoft Identity Platform documentation](https://docs.microsoft.com/en-us/azure/active-directory/develop/)
- [Register an application with Microsoft identity platform](https://docs.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)
- [OAuth 2.0 and OpenID Connect protocols](https://docs.microsoft.com/en-us/azure/active-directory/develop/active-directory-v2-protocols)
- [Microsoft Authentication Library (MSAL) for .NET](https://docs.microsoft.com/en-us/azure/active-directory/develop/msal-overview)
- [MailKit OAuth 2.0 documentation](https://github.com/jstedfast/MailKit/blob/master/GettingStarted.md#oauth20)

## Fallback: Username/Password (Not Recommended)

If you cannot use OAuth (e.g., on-premises Exchange), you can still use username/password authentication:

```powershell
$emailConfig.ClientId = ''  # Leave empty
$emailConfig.TenantId = ''  # Leave empty
$emailConfig.Username = 'your-email@yourdomain.com'
$emailConfig.Password = 'your-app-password'  # Use app-specific password if MFA enabled
```

**Note**: This requires [App Passwords](https://support.microsoft.com/en-us/account-billing/manage-app-passwords-for-two-step-verification-d6dc8c6d-4bf7-4851-ad95-6d07799387e9) if MFA is enabled on your account.
