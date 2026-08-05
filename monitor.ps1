[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Test')]
    [string]$Mode = 'Scan',
    [string]$ProjectRoot = $PSScriptRoot,
    [switch]$NoParallel
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$modulePath = Join-Path $ProjectRoot 'lib/JobMonitor.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Mode -eq 'Test') {
    & (Join-Path $ProjectRoot 'tests/run_tests.ps1')
    exit $LASTEXITCODE
}

$configPath = Join-Path $ProjectRoot 'config/targets.json'
$companyConfigPath = Join-Path $ProjectRoot 'config/company_sources.json'
$statePath = Join-Path $ProjectRoot 'state/monitor_state.json'
$alertsDirectory = Join-Path $ProjectRoot 'alerts'
$manifestPath = Join-Path $alertsDirectory 'manifest.json'
$healthPath = Join-Path $ProjectRoot 'health/status.json'
$reportPath = Join-Path $ProjectRoot 'reports/latest.md'

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$companyConfig = Get-Content -LiteralPath $companyConfigPath -Raw | ConvertFrom-Json
$state = Read-JsonHashtable -Path $statePath

$directTitleTerms = @($config.scoring.titlePhrases | ForEach-Object { @($_.terms) } | ForEach-Object { [string]$_ } | Sort-Object Length -Descending -Unique)
$directTitleParts = @($directTitleTerms | ForEach-Object {
    ([regex]::Escape($_) -replace '\\ ', '\s+')
})
$directTitleRegex = [regex]::new(
    '(?<![\p{L}\p{Nd}])(?:' + ($directTitleParts -join '|') + ')(?![\p{L}\p{Nd}])',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function Test-DirectTitleCandidate {
    param([Parameter(Mandatory = $true)]$Job)
    return $directTitleRegex.IsMatch([string]$Job.Title)
}

foreach ($requiredKey in @('sourceEtags', 'seenJobs', 'initializedSources')) {
    if (-not $state.ContainsKey($requiredKey) -or $null -eq $state[$requiredKey]) {
        $state[$requiredKey] = @{}
    }
}
if (-not $state.ContainsKey('nextSequence')) { $state['nextSequence'] = 1 }
if (-not $state.ContainsKey('initialized')) { $state['initialized'] = $false }
if (-not $state.ContainsKey('lastSuccessfulScanUtc')) { $state['lastSuccessfulScanUtc'] = $null }

$now = [DateTime]::UtcNow
$nowIso = $now.ToString('o')
$state['lastAttemptUtc'] = $nowIso

function Get-SourceEtag {
    param([string]$Id)
    if ($state['sourceEtags'].ContainsKey($Id)) {
        return [string]$state['sourceEtags'][$Id]
    }
    return ''
}

$sources = New-Object System.Collections.Generic.List[object]
$boardsBySourceId = @{}
$sources.Add([pscustomobject]@{
    Id = 'landing'
    Kind = 'landing'
    Url = [string]$config.sources.landingUrl
    ETag = Get-SourceEtag 'landing'
})
$sources.Add([pscustomobject]@{
    Id = 'engineering_feed'
    Kind = 'minisite'
    Url = [string]$config.sources.embeddedUrl
    ETag = Get-SourceEtag 'engineering_feed'
})
foreach ($searchPage in @($config.sources.searchPages)) {
    $sourceId = 'search_' + [string]$searchPage.id
    $sources.Add([pscustomobject]@{
        Id = $sourceId
        Kind = 'search'
        Url = ([string]$config.sources.searchBaseUrl + [string]$searchPage.path)
        ETag = Get-SourceEtag $sourceId
    })
}
foreach ($board in @($companyConfig.directBoards)) {
    $sourceId = 'company_' + [string]$board.id
    $boardsBySourceId[$sourceId] = $board
    $sources.Add([pscustomobject]@{
        Id          = $sourceId
        Kind        = [string]$board.provider
        Url         = [string]$board.url
        ETag        = Get-SourceEtag $sourceId
        Company     = [string]$board.company
        BoardToken  = [string]$board.board
        SourceTags  = [string]$board.tags
        CareersUrl  = [string]$board.careersUrl
        TimeoutSec  = 35
    })
}

$responses = @()
if ($PSVersionTable.PSVersion.Major -ge 7 -and -not $NoParallel) {
    $responses = @($sources | ForEach-Object -Parallel {
        Import-Module $using:modulePath -Force -DisableNameChecking
        Invoke-MonitorSourceRequest -Source $_ -RetryCount 3
    } -ThrottleLimit 12)
}
else {
    foreach ($source in $sources) {
        $responses += Invoke-MonitorSourceRequest -Source $source -RetryCount 3
    }
}

$allJobs = New-Object System.Collections.Generic.List[object]
$sourceHealth = New-Object System.Collections.Generic.List[object]
$landingHealthy = $false
$feedHealthy = $false
$searchSuccesses = 0
$searchTotal = @($config.sources.searchPages).Count
$directKinds = @('greenhouse', 'lever', 'ashby')
$directSuccesses = 0
$directTotal = @($companyConfig.directBoards).Count
$successfulDirectSourceIds = New-Object System.Collections.Generic.List[string]

foreach ($response in $responses) {
    $jobCount = 0
    $sourceError = [string]$response.Error
    $sourceSuccess = [bool]$response.Success

    if ($sourceSuccess -and -not $response.NotModified) {
        try {
            switch ($response.Kind) {
                'landing' {
                    if (-not (Test-LandingPage -Html $response.Content)) {
                        throw 'The engineering selector is missing or changed.'
                    }
                    $landingHealthy = $true
                }
                'minisite' {
                    $parsedJobs = @(Get-MinisiteJobsFromHtml -Html $response.Content -SourceId $response.Id -SourceUrl $response.Url)
                    foreach ($job in $parsedJobs) { $allJobs.Add($job) }
                    $jobCount = $parsedJobs.Count
                    $feedHealthy = ($jobCount -gt 0)
                }
                'search' {
                    $parsedJobs = @(Get-SearchJobsFromHtml -Html $response.Content -SourceId $response.Id -SourceUrl $response.Url)
                    foreach ($job in $parsedJobs) { $allJobs.Add($job) }
                    $jobCount = $parsedJobs.Count
                    if ($jobCount -gt 0) { $searchSuccesses++ }
                }
                'greenhouse' {
                    $parsedJobs = @(Get-GreenhouseJobsFromJson `
                        -Json $response.Content `
                        -Company $response.Company `
                        -BoardToken $response.BoardToken `
                        -SourceId $response.Id `
                        -SourceUrl $response.Url `
                        -SourceTags $response.SourceTags)
                    foreach ($job in $parsedJobs) {
                        if (Test-DirectTitleCandidate -Job $job) { $allJobs.Add($job) }
                    }
                    $jobCount = $parsedJobs.Count
                    $directSuccesses++
                    $successfulDirectSourceIds.Add([string]$response.Id)
                }
                'lever' {
                    $parsedJobs = @(Get-LeverJobsFromJson `
                        -Json $response.Content `
                        -Company $response.Company `
                        -BoardToken $response.BoardToken `
                        -SourceId $response.Id `
                        -SourceUrl $response.Url `
                        -SourceTags $response.SourceTags)
                    foreach ($job in $parsedJobs) {
                        if (Test-DirectTitleCandidate -Job $job) { $allJobs.Add($job) }
                    }
                    $jobCount = $parsedJobs.Count
                    $directSuccesses++
                    $successfulDirectSourceIds.Add([string]$response.Id)
                }
                'ashby' {
                    $parsedJobs = @(Get-AshbyJobsFromJson `
                        -Json $response.Content `
                        -Company $response.Company `
                        -BoardToken $response.BoardToken `
                        -SourceId $response.Id `
                        -SourceUrl $response.Url `
                        -SourceTags $response.SourceTags)
                    foreach ($job in $parsedJobs) {
                        if (Test-DirectTitleCandidate -Job $job) { $allJobs.Add($job) }
                    }
                    $jobCount = $parsedJobs.Count
                    $directSuccesses++
                    $successfulDirectSourceIds.Add([string]$response.Id)
                }
            }
        }
        catch {
            $sourceSuccess = $false
            $sourceError = $_.Exception.Message
        }
    }
    elseif ($sourceSuccess -and $response.NotModified) {
        if ($response.Kind -eq 'landing') { $landingHealthy = $true }
        if ($response.Kind -eq 'minisite') { $feedHealthy = $true }
        if ($response.Kind -eq 'search') { $searchSuccesses++ }
        if ($directKinds -contains [string]$response.Kind) {
            $directSuccesses++
            $successfulDirectSourceIds.Add([string]$response.Id)
        }
    }

    if ($sourceSuccess -and -not [string]::IsNullOrWhiteSpace([string]$response.ETag)) {
        $state['sourceEtags'][$response.Id] = [string]$response.ETag
    }

    $sourceHealth.Add([pscustomobject][ordered]@{
        Id          = $response.Id
        Kind        = $response.Kind
        Company     = if ([string]::IsNullOrWhiteSpace([string]$response.Company)) { $null } else { [string]$response.Company }
        CareersUrl  = if ([string]::IsNullOrWhiteSpace([string]$response.CareersUrl)) { $null } else { [string]$response.CareersUrl }
        Success     = $sourceSuccess
        NotModified = [bool]$response.NotModified
        StatusCode  = [int]$response.StatusCode
        Jobs        = [int]$jobCount
        DurationMs  = [int]$response.DurationMs
        Error       = if ($sourceSuccess) { $null } else { $sourceError }
    })
}

$mergedJobs = @(Merge-NormalizedJobs -Jobs $allJobs)

# The compact engineering feed omits employment type. Enrich only likely matches
# through the allowed public job-detail page, keeping the hourly run lightweight.
$detailCandidates = New-Object System.Collections.Generic.List[object]
foreach ($job in $mergedJobs) {
    if ($job.RichData -or -not [string]::IsNullOrWhiteSpace([string]$job.EmploymentType)) {
        continue
    }
    $preliminary = Get-JobEvaluation -Job $job -Config $config -AllowUnknownEmployment
    if ($preliminary.Score -ge [int]$config.fitThreshold -and $preliminary.Eligible) {
        $detailCandidates.Add($job)
    }
}

$detailJobs = New-Object System.Collections.Generic.List[object]
foreach ($job in @($detailCandidates | Select-Object -First ([int]$config.maxDetailFetches))) {
    $detailSource = [pscustomobject]@{
        Id = 'detail_' + $job.Id
        Kind = 'detail'
        Url = $job.DetailUrl
        ETag = ''
    }
    $detailResponse = Invoke-MonitorSourceRequest -Source $detailSource -RetryCount 2
    $detailCount = 0
    $detailError = [string]$detailResponse.Error
    if ($detailResponse.Success) {
        try {
            $parsed = @(Get-SearchJobsFromHtml -Html $detailResponse.Content -SourceId $detailSource.Id -SourceUrl $detailSource.Url -SourceKind detail)
            foreach ($detailJob in $parsed) { $detailJobs.Add($detailJob) }
            $detailCount = $parsed.Count
        }
        catch {
            $detailResponse.Success = $false
            $detailError = $_.Exception.Message
        }
    }
    $sourceHealth.Add([pscustomobject][ordered]@{
        Id          = $detailSource.Id
        Kind        = 'detail'
        Success     = [bool]$detailResponse.Success
        NotModified = $false
        StatusCode  = [int]$detailResponse.StatusCode
        Jobs        = [int]$detailCount
        DurationMs  = [int]$detailResponse.DurationMs
        Error       = if ($detailResponse.Success) { $null } else { $detailError }
    })
}
if ($detailJobs.Count -gt 0) {
    $mergedJobs = @(Merge-NormalizedJobs -Jobs @($mergedJobs + $detailJobs.ToArray()))
}

# Large Greenhouse boards are fetched in compact form. Pull descriptions only for
# relevant, unsuppressed candidates so experience requirements remain enforceable.
$companyDetailCandidates = New-Object System.Collections.Generic.List[object]
foreach ($job in $mergedJobs) {
    if ($job.RichData -or -not (@($job.SourceKinds) -contains 'greenhouse')) {
        continue
    }

    $originalSourceId = [string](@($job.SourceIds | Where-Object { [string]$_ -like 'company_*' } | Select-Object -First 1))
    if ([string]::IsNullOrWhiteSpace($originalSourceId) -or -not $boardsBySourceId.ContainsKey($originalSourceId)) {
        continue
    }

    $existing = if ($state['seenJobs'].ContainsKey($job.Id)) { $state['seenJobs'][$job.Id] } else { $null }
    if ($null -ne $existing) {
        if ([bool]$existing['suppressed']) { continue }
        if ($existing.ContainsKey('richDataVerified') -and [bool]$existing['richDataVerified']) { continue }
    }

    if (-not $state['initializedSources'].ContainsKey($originalSourceId)) {
        $posted = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace([string]$job.PostedUtc) -or
            -not [DateTimeOffset]::TryParse([string]$job.PostedUtc, [ref]$posted) -or
            $posted.UtcDateTime -lt $now.AddDays(-1 * [int]$config.initialLookbackDays)) {
            continue
        }
    }

    $preliminary = Get-JobEvaluation -Job $job -Config $config
    if ($preliminary.ShouldAlert) {
        $companyDetailCandidates.Add([pscustomobject]@{
            Job              = $job
            Score            = [int]$preliminary.Score
            OriginalSourceId = $originalSourceId
            Board            = $boardsBySourceId[$originalSourceId]
        })
    }
}

$companyDetailSources = New-Object System.Collections.Generic.List[object]
foreach ($candidate in @($companyDetailCandidates | Sort-Object Score -Descending | Select-Object -First ([int]$config.maxCompanyDetailFetches))) {
    $idParts = @([string]$candidate.Job.Id -split ':', 3)
    if ($idParts.Count -lt 3) { continue }
    $externalId = $idParts[2]
    $board = $candidate.Board
    $companyDetailSources.Add([pscustomobject]@{
        Id               = "company_detail_$([string]$board.id)_$externalId"
        Kind             = 'greenhouse_detail'
        Url              = "https://boards-api.greenhouse.io/v1/boards/$([string]$board.board)/jobs/$externalId"
        ETag             = ''
        Company          = [string]$board.company
        BoardToken       = [string]$board.board
        SourceTags       = [string]$board.tags
        CareersUrl       = [string]$board.careersUrl
        OriginalSourceId = [string]$candidate.OriginalSourceId
        TimeoutSec       = 25
    })
}

$companyDetailResponses = @()
if ($companyDetailSources.Count -gt 0) {
    if ($PSVersionTable.PSVersion.Major -ge 7 -and -not $NoParallel) {
        $companyDetailResponses = @($companyDetailSources | ForEach-Object -Parallel {
            Import-Module $using:modulePath -Force -DisableNameChecking
            Invoke-MonitorSourceRequest -Source $_ -RetryCount 2
        } -ThrottleLimit 12)
    }
    else {
        foreach ($source in $companyDetailSources) {
            $companyDetailResponses += Invoke-MonitorSourceRequest -Source $source -RetryCount 2
        }
    }
}

$companyDetailJobs = New-Object System.Collections.Generic.List[object]
$companyDetailSucceeded = 0
foreach ($response in $companyDetailResponses) {
    $detailCount = 0
    $detailSuccess = [bool]$response.Success
    $detailError = [string]$response.Error
    if ($detailSuccess) {
        try {
            $parsedJobs = @(Get-GreenhouseJobsFromJson `
                -Json $response.Content `
                -Company $response.Company `
                -BoardToken $response.BoardToken `
                -SourceId $response.OriginalSourceId `
                -SourceUrl $response.Url `
                -SourceTags $response.SourceTags)
            foreach ($job in $parsedJobs) { $companyDetailJobs.Add($job) }
            $detailCount = $parsedJobs.Count
            if ($detailCount -gt 0) { $companyDetailSucceeded++ }
        }
        catch {
            $detailSuccess = $false
            $detailError = $_.Exception.Message
        }
    }
    $sourceHealth.Add([pscustomobject][ordered]@{
        Id          = $response.Id
        Kind        = 'greenhouse_detail'
        Company     = $response.Company
        CareersUrl  = $response.CareersUrl
        Success     = $detailSuccess
        NotModified = $false
        StatusCode  = [int]$response.StatusCode
        Jobs        = [int]$detailCount
        DurationMs  = [int]$response.DurationMs
        Error       = if ($detailSuccess) { $null } else { $detailError }
    })
}
if ($companyDetailJobs.Count -gt 0) {
    $mergedJobs = @(Merge-NormalizedJobs -Jobs @($mergedJobs + $companyDetailJobs.ToArray()))
}

$status = Get-MonitorStatus `
    -LandingHealthy $landingHealthy `
    -FeedHealthy $feedHealthy `
    -SearchSuccesses $searchSuccesses `
    -SearchTotal $searchTotal `
    -Initialized ([bool]$state['initialized']) `
    -DiscoveredJobs $mergedJobs.Count

$directHealthyPercent = if ($directTotal -gt 0) {
    [Math]::Round(($directSuccesses * 100.0) / $directTotal, 1)
}
else {
    100.0
}
if ($status -ne 'failed' -and $directHealthyPercent -lt [double]$companyConfig.minimumHealthyPercent) {
    $status = 'degraded'
}

$newAlerts = New-Object System.Collections.Generic.List[object]
$isInitialRun = -not [bool]$state['initialized']
$lookbackCutoff = $now.AddDays(-1 * [int]$config.initialLookbackDays)

if ($status -ne 'failed') {
    foreach ($job in $mergedJobs) {
        $existing = $null
        if ($state['seenJobs'].ContainsKey($job.Id)) {
            $existing = $state['seenJobs'][$job.Id]
        }

        $isNew = ($null -eq $existing)
        $suppressed = if ($isNew) { $false } else { [bool]$existing['suppressed'] }
        $alerted = if ($isNew) { $false } else { [bool]$existing['alerted'] }
        $firstSeenUtc = if ($isNew) { $nowIso } else { [string]$existing['firstSeenUtc'] }

        $isFirstSourceRun = $false
        foreach ($sourceId in @($job.SourceIds)) {
            if ([string]$sourceId -like 'company_*' -and -not $state['initializedSources'].ContainsKey([string]$sourceId)) {
                $isFirstSourceRun = $true
            }
        }
        if (($isInitialRun -or $isFirstSourceRun) -and $isNew) {
            if ([string]::IsNullOrWhiteSpace([string]$job.PostedUtc)) {
                $suppressed = $true
            }
            else {
                $posted = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$job.PostedUtc, [ref]$posted) -and $posted.UtcDateTime -lt $lookbackCutoff) {
                    $suppressed = $true
                }
            }
        }

        $evaluation = Get-JobEvaluation -Job $job -Config $config
        $awaitingCompanyDetail = (-not $job.RichData -and @($job.SourceKinds) -contains 'greenhouse')
        if (-not $suppressed -and -not $alerted -and -not $awaitingCompanyDetail -and $evaluation.ShouldAlert) {
            $sequence = [int]$state['nextSequence']
            $state['nextSequence'] = $sequence + 1
            $alert = [pscustomobject][ordered]@{
                Sequence       = $sequence
                DiscoveredUtc  = $nowIso
                JobId          = $job.Id
                Title          = $job.Title
                Company        = $job.Company
                Location       = $job.Location
                EmploymentType = $job.EmploymentType
                Seniority      = $job.Seniority
                PostedUtc      = $job.PostedUtc
                Salary         = $job.Salary
                WorkModel      = $job.WorkModel
                Sponsorship    = $job.Sponsorship
                FitScore       = [int]$evaluation.Score
                Tier           = $evaluation.Tier
                Breakdown      = $evaluation.Breakdown
                Reasons        = @($evaluation.Reasons)
                Warnings       = @($evaluation.Warnings)
                DetailUrl      = $job.DetailUrl
                ApplyUrl       = $job.ApplyUrl
                SourceIds      = @($job.SourceIds)
                SourceKinds    = @($job.SourceKinds)
                SourceUrls     = @($job.SourceUrls)
            }
            $newAlerts.Add($alert)
            $alerted = $true
        }

        $bestScore = [int]$evaluation.Score
        if (-not $isNew -and $existing.ContainsKey('bestScore')) {
            $bestScore = [Math]::Max($bestScore, [int]$existing['bestScore'])
        }
        $state['seenJobs'][$job.Id] = @{
            firstSeenUtc = $firstSeenUtc
            lastSeenUtc  = $nowIso
            postedUtc    = $job.PostedUtc
            title        = $job.Title
            company      = $job.Company
            location     = $job.Location
            alerted      = $alerted
            suppressed   = $suppressed
            bestScore    = $bestScore
            sourceIds    = @($job.SourceIds)
            richDataVerified = [bool]$job.RichData
        }
    }

    $retentionCutoff = $now.AddDays(-1 * [int]$config.stateRetentionDays)
    foreach ($jobId in @($state['seenJobs'].Keys)) {
        $record = $state['seenJobs'][$jobId]
        $lastSeen = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$record['lastSeenUtc'], [ref]$lastSeen) -and $lastSeen.UtcDateTime -lt $retentionCutoff) {
            $state['seenJobs'].Remove($jobId)
        }
    }

    $state['initialized'] = $true
    foreach ($sourceId in @($successfulDirectSourceIds | Select-Object -Unique)) {
        $state['initializedSources'][$sourceId] = $nowIso
    }
    $state['lastSuccessfulScanUtc'] = $nowIso
}

if ($newAlerts.Count -gt 0) {
    Add-AlertRecords -AlertsDirectory $alertsDirectory -Alerts $newAlerts.ToArray()
}
$manifest = Update-AlertManifest -AlertsDirectory $alertsDirectory -ManifestPath $manifestPath
Write-LatestReport -AlertsDirectory $alertsDirectory -ReportPath $reportPath
Write-JsonFile -Path $statePath -Value $state

$health = [pscustomobject][ordered]@{
    Version               = 2
    Status                = $status
    LastAttemptUtc        = $nowIso
    LastSuccessfulScanUtc = $state['lastSuccessfulScanUtc']
    DiscoveredJobs        = [int]$mergedJobs.Count
    NewAlerts             = [int]$newAlerts.Count
    LatestSequence        = [int]$manifest.LatestSequence
    Coverage              = [pscustomobject][ordered]@{
        AggregatorFeed             = 'NewGrad Jobs / Jobright U.S. Engineering'
        FocusedRoleSearches         = [int]$searchTotal
        DirectCompanyBoards        = [int]$directTotal
        HealthyDirectCompanyBoards = [int]$directSuccesses
        DirectHealthyPercent       = [double]$directHealthyPercent
        CompanyDetailsRequested    = [int]$companyDetailSources.Count
        CompanyDetailsSucceeded    = [int]$companyDetailSucceeded
        DirectCompanies            = @($companyConfig.directBoards | ForEach-Object { [string]$_.company } | Select-Object -Unique)
        BroadCoverageCompanies     = @($companyConfig.broadRoleCoverageCompanies)
    }
    Sources               = $sourceHealth.ToArray()
}
Write-JsonFile -Path $healthPath -Value $health

Write-Host "Status: $status"
Write-Host "Unique jobs discovered: $($mergedJobs.Count)"
Write-Host "Direct company boards: $directSuccesses/$directTotal healthy ($directHealthyPercent%)"
Write-Host "First-party detail checks: $companyDetailSucceeded/$($companyDetailSources.Count)"
Write-Host "New alerts: $($newAlerts.Count)"
if ($newAlerts.Count -gt 0) {
    $newAlerts | Sort-Object FitScore -Descending | Select-Object FitScore, Tier, Title, Company, Location | Format-Table -AutoSize
}

if ($status -eq 'failed') {
    Write-Error 'All primary discovery sources failed or returned an invalid schema. State was not advanced.'
    exit 1
}
