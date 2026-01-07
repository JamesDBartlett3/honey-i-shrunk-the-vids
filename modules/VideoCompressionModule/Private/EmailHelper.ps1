#------------------------------------------------------------------------------------------------------------------
# EmailHelper.ps1 - Email notification functionality
#------------------------------------------------------------------------------------------------------------------

# Module-level variable
$Script:EmailConfig = $null

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

        # Prepare email parameters
        $mailParams = @{
            From = $Script:EmailConfig.From
            To = $Script:EmailConfig.To
            Subject = $Subject
            Body = $Body
            SmtpServer = $Script:EmailConfig.SmtpServer
            Port = $Script:EmailConfig.SmtpPort
        }

        if ($IsHtml) {
            $mailParams['BodyAsHtml'] = $true
        }

        if ($Script:EmailConfig.UseSSL) {
            $mailParams['UseSsl'] = $true
        }

        if ($Attachments.Count -gt 0) {
            $mailParams['Attachments'] = $Attachments
        }

        # Send email
        Send-MailMessage @mailParams -ErrorAction Stop

        Write-LogEntry -Message "Email notification sent successfully to: $($Script:EmailConfig.To -join ', ')" -Level 'Info'
        return $true
    }
    catch {
        Write-LogEntry -Message "Failed to send email notification: $_" -Level 'Error'
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
    Build-CompletionReport, Build-ErrorReport
