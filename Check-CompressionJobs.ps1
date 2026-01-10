#------------------------------------------------------------------------------------------------------------------
# Check-CompressionJobs.ps1
# Diagnostic script to monitor compression job status
#------------------------------------------------------------------------------------------------------------------

Write-Host "`n=== PowerShell Background Jobs Status ===" -ForegroundColor Cyan

# Get all jobs
$allJobs = Get-Job

if ($allJobs.Count -eq 0) {
    Write-Host "No background jobs found." -ForegroundColor Yellow
    exit
}

Write-Host "`nTotal Jobs: $($allJobs.Count)`n" -ForegroundColor White

# Group by state
$allJobs | Group-Object State | ForEach-Object {
    Write-Host "$($_.Name): $($_.Count)" -ForegroundColor White
}

Write-Host "`n--- Job Details ---`n" -ForegroundColor Cyan

foreach ($job in $allJobs) {
    Write-Host "Job ID: $($job.Id) | State: $($job.State) | HasMoreData: $($job.HasMoreData)" -ForegroundColor White

    # Show any errors or output
    if ($job.State -eq 'Failed') {
        Write-Host "  ERROR: " -NoNewline -ForegroundColor Red
        $jobErrors = Receive-Job -Job $job -ErrorAction SilentlyContinue
        Write-Host $jobErrors -ForegroundColor Red
    }
    elseif ($job.HasMoreData) {
        Write-Host "  Output available (use Receive-Job -Id $($job.Id) to see)" -ForegroundColor Gray
    }
}

Write-Host "`n--- Temp Files ---`n" -ForegroundColor Cyan

# Check temp folder for files
$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'modules\VideoCompressionModule\VideoCompressionModule.psm1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue

$dbPath = Join-Path -Path $PSScriptRoot -ChildPath 'data\video-catalog.db'
$null = Initialize-SPVidCompCatalog -DatabasePath $dbPath

$tempPath = Get-SPVidCompConfigValue -Key 'paths_temp_download'

if (Test-Path $tempPath) {
    $tempFiles = Get-ChildItem -Path $tempPath -File

    if ($tempFiles.Count -gt 0) {
        Write-Host "Files in $tempPath`:" -ForegroundColor White
        foreach ($file in $tempFiles) {
            $sizeMB = [math]::Round($file.Length / 1MB, 2)
            Write-Host "  $($file.Name) - $sizeMB MB" -ForegroundColor White
        }
    }
    else {
        Write-Host "No files in temp folder: $tempPath" -ForegroundColor Yellow
    }
}
else {
    Write-Host "Temp folder not found: $tempPath" -ForegroundColor Red
}

Write-Host ""
