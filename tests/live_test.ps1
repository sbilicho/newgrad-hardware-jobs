[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'lib/JobMonitor.psm1') -Force -DisableNameChecking
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config/targets.json') -Raw | ConvertFrom-Json
$source = [pscustomobject]@{
    Id = 'live_engineering_feed'
    Kind = 'minisite'
    Url = [string]$config.sources.embeddedUrl
    ETag = ''
}
$response = Invoke-MonitorSourceRequest -Source $source -RetryCount 3
if (-not $response.Success) {
    throw "Live source request failed: $($response.Error)"
}
$jobs = @(Get-MinisiteJobsFromHtml -Html $response.Content -SourceId $source.Id -SourceUrl $source.Url)
if ($jobs.Count -lt 1) {
    throw 'Live source returned no structured job records.'
}
if ([string]::IsNullOrWhiteSpace([string]$jobs[0].Id) -or [string]::IsNullOrWhiteSpace([string]$jobs[0].Title)) {
    throw 'Live source returned a record without an ID or title.'
}
Write-Host "Live integration passed: parsed $($jobs.Count) structured jobs."
Write-Host "Newest sample: $($jobs[0].Title) at $($jobs[0].Company)"
