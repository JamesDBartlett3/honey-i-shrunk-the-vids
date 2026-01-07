#------------------------------------------------------------------------------------------------------------------
# Run-Tests.ps1 - Execute Pester test suite for VideoCompressionModule
#------------------------------------------------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'Unit', 'Integration')]
    [string]$TestType = 'All',

    [Parameter(Mandatory = $false)]
    [string]$TestName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Normal',

    [Parameter(Mandatory = $false)]
    [switch]$CodeCoverage,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Check for Pester module
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
    Write-Host "Pester 5.0+ is required. Installing..." -ForegroundColor Yellow
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
}

Import-Module Pester -MinimumVersion 5.0.0

# Determine test paths based on TestType
$testPaths = @()

switch ($TestType) {
    'Unit' {
        $testPaths += Join-Path -Path $PSScriptRoot -ChildPath 'Private'
        $testPaths += Join-Path -Path $PSScriptRoot -ChildPath 'VideoCompressionModule.Tests.ps1'
    }
    'Integration' {
        $testPaths += Join-Path -Path $PSScriptRoot -ChildPath 'Integration'
    }
    'All' {
        $testPaths += $PSScriptRoot
    }
}

# Build Pester configuration
$config = New-PesterConfiguration

# Test discovery
$config.Run.Path = $testPaths
$config.Run.Exit = $true
$config.Run.PassThru = $true

# Filter by test name if specified
if ($TestName) {
    $config.Filter.FullName = "*$TestName*"
}

# Output configuration
$config.Output.Verbosity = $Output

# Test results output
if ($OutputPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $OutputPath
    $config.TestResult.OutputFormat = 'NUnitXml'
}

# Code coverage configuration
if ($CodeCoverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(
        (Join-Path -Path $PSScriptRoot -ChildPath '..\modules\VideoCompressionModule\VideoCompressionModule.psm1'),
        (Join-Path -Path $PSScriptRoot -ChildPath '..\modules\VideoCompressionModule\Private\*.ps1')
    )
    $config.CodeCoverage.OutputPath = Join-Path -Path $PSScriptRoot -ChildPath 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}

# Display test run information
Write-Host "`n" -NoNewline
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VideoCompressionModule Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Type    : $TestType" -ForegroundColor White
Write-Host "Output Level : $Output" -ForegroundColor White
if ($TestName) {
    Write-Host "Filter       : $TestName" -ForegroundColor White
}
if ($CodeCoverage) {
    Write-Host "Code Coverage: Enabled" -ForegroundColor White
}
Write-Host "========================================`n" -ForegroundColor Cyan

# Run tests
$results = Invoke-Pester -Configuration $config

# Display summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Tests  : $($results.TotalCount)" -ForegroundColor White
Write-Host "Passed       : $($results.PassedCount)" -ForegroundColor Green
Write-Host "Failed       : $($results.FailedCount)" -ForegroundColor $(if ($results.FailedCount -gt 0) { 'Red' } else { 'White' })
Write-Host "Skipped      : $($results.SkippedCount)" -ForegroundColor Yellow
Write-Host "Duration     : $([math]::Round($results.Duration.TotalSeconds, 2)) seconds" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Return exit code based on test results
if ($results.FailedCount -gt 0) {
    exit 1
}
exit 0
