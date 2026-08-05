[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'lib/JobMonitor.psm1') -Force -DisableNameChecking
$sourceConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'config/company_sources.json') -Raw | ConvertFrom-Json

$sampleIds = @('astera_labs', 'etched', 'e_space')
foreach ($sourceId in $sampleIds) {
    $board = @($sourceConfig.directBoards | Where-Object { [string]$_.id -eq $sourceId })[0]
    $source = [pscustomobject]@{
        Id          = 'live_' + [string]$board.id
        Kind        = [string]$board.provider
        Url         = [string]$board.url
        ETag        = ''
        Company     = [string]$board.company
        BoardToken  = [string]$board.board
        SourceTags  = [string]$board.tags
        CareersUrl  = [string]$board.careersUrl
        TimeoutSec  = 35
    }
    $response = Invoke-MonitorSourceRequest -Source $source -RetryCount 2
    if (-not $response.Success) {
        throw "$($source.Company) live request failed: $($response.Error)"
    }

    $jobs = switch ($source.Kind) {
        'greenhouse' {
            @(Get-GreenhouseJobsFromJson -Json $response.Content -Company $source.Company -BoardToken $source.BoardToken -SourceId $source.Id -SourceUrl $source.Url -SourceTags $source.SourceTags)
        }
        'ashby' {
            @(Get-AshbyJobsFromJson -Json $response.Content -Company $source.Company -BoardToken $source.BoardToken -SourceId $source.Id -SourceUrl $source.Url -SourceTags $source.SourceTags)
        }
        'lever' {
            @(Get-LeverJobsFromJson -Json $response.Content -Company $source.Company -BoardToken $source.BoardToken -SourceId $source.Id -SourceUrl $source.Url -SourceTags $source.SourceTags)
        }
    }
    if (@($jobs).Count -eq 0) {
        throw "$($source.Company) returned no structured jobs. Check for an upstream schema change."
    }
    $first = @($jobs)[0]
    if ([string]::IsNullOrWhiteSpace([string]$first.Id) -or [string]::IsNullOrWhiteSpace([string]$first.Title)) {
        throw "$($source.Company) did not produce a valid normalized record."
    }
    if ($source.Kind -eq 'greenhouse') {
        $externalId = @([string]$first.Id -split ':', 3)[2]
        $detailSource = [pscustomobject]@{
            Id = 'live_detail'; Kind = 'greenhouse_detail'
            Url = "https://boards-api.greenhouse.io/v1/boards/$($source.BoardToken)/jobs/$externalId"
            ETag = ''; Company = $source.Company; BoardToken = $source.BoardToken
            SourceTags = $source.SourceTags; CareersUrl = $source.CareersUrl
            OriginalSourceId = $source.Id; TimeoutSec = 25
        }
        $detailResponse = Invoke-MonitorSourceRequest -Source $detailSource -RetryCount 2
        if (-not $detailResponse.Success) {
            throw "$($source.Company) detail request failed: $($detailResponse.Error)"
        }
        $detailJobs = @(Get-GreenhouseJobsFromJson -Json $detailResponse.Content -Company $source.Company -BoardToken $source.BoardToken -SourceId $source.Id -SourceUrl $detailSource.Url -SourceTags $source.SourceTags)
        if ($detailJobs.Count -ne 1 -or -not $detailJobs[0].RichData) {
            throw "$($source.Company) detail endpoint did not produce one rich record."
        }
    }
    Write-Host "$($source.Company): $(@($jobs).Count) structured jobs ($($response.DurationMs) ms)"
}

Write-Host 'First-party live integration check passed.'
