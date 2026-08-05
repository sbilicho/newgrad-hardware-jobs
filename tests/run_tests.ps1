[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'lib/JobMonitor.psm1') -Force -DisableNameChecking
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config/targets.json') -Raw | ConvertFrom-Json
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Message" -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    Assert-True -Condition ($Expected -eq $Actual) -Message "$Message (expected '$Expected', got '$Actual')"
}

$minisiteHtml = Get-Content -LiteralPath (Join-Path $fixtures 'minisite.html') -Raw
$searchHtml = Get-Content -LiteralPath (Join-Path $fixtures 'search.html') -Raw
$detailHtml = Get-Content -LiteralPath (Join-Path $fixtures 'detail.html') -Raw
$malformedHtml = Get-Content -LiteralPath (Join-Path $fixtures 'malformed.html') -Raw
$greenhouseJson = Get-Content -LiteralPath (Join-Path $fixtures 'greenhouse.json') -Raw
$leverJson = Get-Content -LiteralPath (Join-Path $fixtures 'lever.json') -Raw
$ashbyJson = Get-Content -LiteralPath (Join-Path $fixtures 'ashby.json') -Raw

$minisiteJobs = @(Get-MinisiteJobsFromHtml -Html $minisiteHtml -SourceId 'fixture_feed' -SourceUrl 'https://example.test/feed')
Assert-Equal 2 $minisiteJobs.Count 'Minisite parser returns all embedded jobs'
Assert-Equal 'Example Silicon' $minisiteJobs[0].Company 'Minisite parser normalizes company'
Assert-True ($minisiteJobs[0].PostedUtc -match '^2026-') 'Epoch posting date is normalized to UTC'

$searchJobs = @(Get-SearchJobsFromHtml -Html $searchHtml -SourceId 'fixture_search' -SourceUrl 'https://example.test/search')
Assert-Equal 6 $searchJobs.Count 'Search parser returns all rich jobs'
Assert-Equal 'Full-time' $searchJobs[0].EmploymentType 'Search parser captures employment type'
Assert-True ($searchJobs[0].Tags -match 'Semiconductor') 'Search parser combines company and job tags'

$unicodeHtml = '<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"jobList":[{"companyResult":{"companyName":"Unicode Silicon"},"jobResult":{"jobId":"unicode-1","jobTitle":"Mixed-Signal Engineer \u2013 New Graduate","jobLocation":"Austin, TX","employmentType":"Full-time","jobSeniority":["New Grad"]}}]}}}</script>'
$unicodeJobs = @(Get-SearchJobsFromHtml -Html $unicodeHtml -SourceId 'unicode_fixture')
Assert-True ($unicodeJobs[0].Title.Contains([char]0x2013)) 'Parser preserves Unicode job titles'

$detailJobs = @(Get-SearchJobsFromHtml -Html $detailHtml -SourceId 'fixture_detail' -SourceUrl 'https://example.test/detail' -SourceKind detail)
Assert-Equal 1 $detailJobs.Count 'Detail parser returns one job'
Assert-True ($detailJobs[0].Responsibilities -match 'clock tree synthesis') 'Detail parser keeps richer responsibility text'

$merged = @(Merge-NormalizedJobs -Jobs @($minisiteJobs + $detailJobs))
$mergedPhysical = @($merged | Where-Object { $_.Id -eq 'mini-physical-1' })[0]
Assert-Equal 2 $merged.Count 'Deduplication merges the same job ID'
Assert-Equal 'Full-time' $mergedPhysical.EmploymentType 'Deduplication retains richer detail fields'
Assert-True $mergedPhysical.RichData 'Deduplication marks enriched records as rich'

$greenhouseJobs = @(Get-GreenhouseJobsFromJson `
    -Json $greenhouseJson `
    -Company 'Example Semiconductor' `
    -BoardToken 'example' `
    -SourceId 'company_example_greenhouse' `
    -SourceUrl 'https://example.test/greenhouse' `
    -SourceTags 'semiconductor silicon ASIC')
Assert-Equal 3 $greenhouseJobs.Count 'Greenhouse parser returns all public board jobs'
Assert-Equal 'greenhouse:example:101' $greenhouseJobs[0].Id 'Greenhouse IDs include provider and board namespace'
Assert-True ($greenhouseJobs[0].Requirements -match 'timing closure') 'Greenhouse HTML content is converted to searchable text'
Assert-Equal 'Full-time' $greenhouseJobs[0].EmploymentType 'Greenhouse metadata provides explicit full-time status'
$greenhouseDetailJson = (($greenhouseJson | ConvertFrom-Json).jobs[0] | ConvertTo-Json -Depth 10)
$greenhouseDetailJobs = @(Get-GreenhouseJobsFromJson -Json $greenhouseDetailJson -Company 'Example Semiconductor' -BoardToken 'example' -SourceId 'company_example_greenhouse')
Assert-Equal 1 $greenhouseDetailJobs.Count 'Greenhouse parser accepts a single-job detail response'
Assert-True $greenhouseDetailJobs[0].RichData 'Greenhouse detail response is marked as verified rich data'

$leverJobs = @(Get-LeverJobsFromJson `
    -Json $leverJson `
    -Company 'Example FPGA' `
    -BoardToken 'example' `
    -SourceId 'company_example_lever' `
    -SourceUrl 'https://example.test/lever' `
    -SourceTags 'FPGA electrical hardware')
Assert-Equal 2 $leverJobs.Count 'Lever parser returns all public postings'
Assert-Equal 'Full-time' $leverJobs[0].EmploymentType 'Lever commitment is normalized'
Assert-Equal 'US' $leverJobs[0].Country 'Lever country is retained for geography checks'

$ashbyJobs = @(Get-AshbyJobsFromJson `
    -Json $ashbyJson `
    -Company 'Example AI Silicon' `
    -BoardToken 'example' `
    -SourceId 'company_example_ashby' `
    -SourceUrl 'https://example.test/ashby' `
    -SourceTags 'semiconductor ASIC silicon')
Assert-Equal 3 $ashbyJobs.Count 'Ashby parser returns all listed jobs'
Assert-Equal 'Full-time' $ashbyJobs[0].EmploymentType 'Ashby FullTime value is normalized'
Assert-True (Test-IsUnitedStatesLocation -Job $ashbyJobs[0]) 'Ashby U.S. postal address passes geography verification'
Assert-True (-not (Test-IsUnitedStatesLocation -Job $ashbyJobs[2])) 'Ashby Canadian address fails U.S. geography verification'

$physical = @($searchJobs | Where-Object { $_.Id -eq 'rich-physical-1' })[0]
$physicalEvaluation = Get-JobEvaluation -Job $physical -Config $config
Assert-True $physicalEvaluation.Eligible 'Physical-design new-grad role is eligible'
Assert-True ($physicalEvaluation.Score -ge 70) 'Physical-design new-grad role is a strong match'
Assert-True $physicalEvaluation.ShouldAlert 'Physical-design role crosses the configured threshold'

foreach ($representativeTitle in @('DFT Design Engineer', 'STA Engineer', 'Embedded Firmware Engineer', 'Hardware Electrical Engineer', 'P&R Engineer')) {
    $representativeJob = $physical.PSObject.Copy()
    $representativeJob.Id = 'representative-' + ($representativeTitle -replace '[^a-zA-Z0-9]', '-')
    $representativeJob.Title = $representativeTitle
    $representativeJob.Seniority = 'Entry Level'
    $representativeEvaluation = Get-JobEvaluation -Job $representativeJob -Config $config
    Assert-True $representativeEvaluation.ShouldAlert "Representative $representativeTitle role alerts"
}

$greenhouseEvaluation = Get-JobEvaluation -Job $greenhouseJobs[0] -Config $config
Assert-True $greenhouseEvaluation.ShouldAlert 'First-party Greenhouse new-grad ASIC role alerts'
$greenhouseInternEvaluation = Get-JobEvaluation -Job $greenhouseJobs[1] -Config $config
Assert-True (-not $greenhouseInternEvaluation.Eligible) 'First-party Greenhouse internship is rejected'
$greenhouseForeignEvaluation = Get-JobEvaluation -Job $greenhouseJobs[2] -Config $config
Assert-True (-not $greenhouseForeignEvaluation.Eligible) 'First-party Greenhouse non-U.S. role is rejected'
Assert-True (@($greenhouseForeignEvaluation.Warnings) -contains 'Full-time status is inferred from the first-party posting') 'Inferred Greenhouse employment is disclosed as a warning'

$leverEvaluation = Get-JobEvaluation -Job $leverJobs[0] -Config $config
Assert-True $leverEvaluation.ShouldAlert 'First-party Lever entry-level FPGA role alerts'
$leverContractEvaluation = Get-JobEvaluation -Job $leverJobs[1] -Config $config
Assert-True (-not $leverContractEvaluation.Eligible) 'First-party Lever contract role is rejected'

$ashbyEvaluation = Get-JobEvaluation -Job $ashbyJobs[0] -Config $config
Assert-True $ashbyEvaluation.ShouldAlert 'First-party Ashby digital IC role alerts'
$ashbyInternEvaluation = Get-JobEvaluation -Job $ashbyJobs[1] -Config $config
Assert-True (-not $ashbyInternEvaluation.Eligible) 'First-party Ashby internship is rejected'
$ashbyForeignEvaluation = Get-JobEvaluation -Job $ashbyJobs[2] -Config $config
Assert-True (-not $ashbyForeignEvaluation.Eligible) 'First-party Ashby Canadian role is rejected'

$electrical = @($searchJobs | Where-Object { $_.Id -eq 'electrical-1' })[0]
$electricalEvaluation = Get-JobEvaluation -Job $electrical -Config $config
Assert-True $electricalEvaluation.Eligible 'Associate electronics role is eligible'
Assert-True ($electricalEvaluation.Score -ge 30) 'Associate electronics role meets the broad electrical threshold'

$civil = @($searchJobs | Where-Object { $_.Id -eq 'civil-1' })[0]
$civilEvaluation = Get-JobEvaluation -Job $civil -Config $config
Assert-True (-not $civilEvaluation.Eligible) 'Civil-engineering role is rejected'

$senior = @($searchJobs | Where-Object { $_.Id -eq 'senior-1' })[0]
$seniorEvaluation = Get-JobEvaluation -Job $senior -Config $config
Assert-True (-not $seniorEvaluation.Eligible) 'Senior-only role is rejected'

$leaderJob = $physical.PSObject.Copy()
$leaderJob.Title = 'ASIC Design Verification Engineering Technical Leader'
$leaderJob.Seniority = 'Lead/Staff'
$leaderJob.Requirements = 'Lead the team and mentor engineers with 0-2 years of experience.'
$leaderEvaluation = Get-JobEvaluation -Job $leaderJob -Config $config
Assert-True (-not $leaderEvaluation.Eligible) 'Technical-leader role is rejected even if its description mentions entry-level work'

$midLevelJob = $electrical.PSObject.Copy()
$midLevelJob.Title = 'Mission Critical Electrical Engineer - Mid-Level'
$midLevelJob.Seniority = 'Senior Level'
$midLevelEvaluation = Get-JobEvaluation -Job $midLevelJob -Config $config
Assert-True (-not $midLevelEvaluation.Eligible) 'Explicit mid-level role is rejected'

$unknownEmploymentJob = $physical.PSObject.Copy()
$unknownEmploymentJob.EmploymentType = ''
$unknownEmploymentEvaluation = Get-JobEvaluation -Job $unknownEmploymentJob -Config $config
$preliminaryUnknownEvaluation = Get-JobEvaluation -Job $unknownEmploymentJob -Config $config -AllowUnknownEmployment
Assert-True (-not $unknownEmploymentEvaluation.Eligible) 'Unknown employment type is rejected for final alerting'
Assert-True $preliminaryUnknownEvaluation.Eligible 'Unknown employment type remains eligible for detail enrichment'

$mixedLevelJob = $physical.PSObject.Copy()
$mixedLevelJob.Title = 'ASIC Engineer - Entry Level through Senior'
$mixedLevelJob.Seniority = 'Multiple Levels'
$mixedLevelEvaluation = Get-JobEvaluation -Job $mixedLevelJob -Config $config
Assert-True $mixedLevelEvaluation.Eligible 'Mixed-level posting remains eligible when entry level is explicit'

$internshipExperienceJob = $physical.PSObject.Copy()
$internshipExperienceJob.Requirements = 'Full-time role; prior semiconductor internship experience is helpful.'
$internshipExperienceEvaluation = Get-JobEvaluation -Job $internshipExperienceJob -Config $config
Assert-True $internshipExperienceEvaluation.Eligible 'A full-time role is not rejected merely for mentioning internship experience'

$intern = @($searchJobs | Where-Object { $_.Id -eq 'intern-1' })[0]
$internEvaluation = Get-JobEvaluation -Job $intern -Config $config
Assert-True (-not $internEvaluation.Eligible) 'Internship is rejected'

$software = @($searchJobs | Where-Object { $_.Id -eq 'software-1' })[0]
$softwareEvaluation = Get-JobEvaluation -Job $software -Config $config
Assert-True (-not $softwareEvaluation.ShouldAlert) 'Generic frontend software role does not alert'

$threeYearJob = $physical.PSObject.Copy()
$threeYearJob.Id = 'three-year-1'
$threeYearJob.Requirements = 'At least 3 years of physical design and STA experience required.'
$threeYearEvaluation = Get-JobEvaluation -Job $threeYearJob -Config $config
Assert-Equal 15 $threeYearEvaluation.Breakdown.Penalty 'Explicit three-year requirement receives configured penalty'

$fourYearJob = $physical.PSObject.Copy()
$fourYearJob.Id = 'four-year-1'
$fourYearJob.Requirements = 'Minimum of 4 years of ASIC physical design experience required.'
$fourYearEvaluation = Get-JobEvaluation -Job $fourYearJob -Config $config
Assert-True (-not $fourYearEvaluation.Eligible) 'Explicit four-year minimum is rejected'

$plusYearsJob = $physical.PSObject.Copy()
$plusYearsJob.Id = 'plus-years-1'
$plusYearsJob.Requirements = '5+ years of relevant experience in ASIC implementation.'
$plusYearsEvaluation = Get-JobEvaluation -Job $plusYearsJob -Config $config
Assert-True (-not $plusYearsEvaluation.Eligible) 'Implicit five-plus-year requirement is rejected'

$rangeYearsJob = $physical.PSObject.Copy()
$rangeYearsJob.Id = 'range-years-1'
$rangeYearsJob.Requirements = '4-6 years of industry experience in physical design.'
$rangeYearsEvaluation = Get-JobEvaluation -Job $rangeYearsJob -Config $config
Assert-True (-not $rangeYearsEvaluation.Eligible) 'Four-to-six-year requirement is rejected'

$malformedRejected = $false
try {
    [void](Get-MinisiteJobsFromHtml -Html $malformedHtml)
}
catch {
    $malformedRejected = $true
}
Assert-True $malformedRejected 'Malformed page produces a visible parser failure'

$changedGreenhouseRejected = $false
try {
    [void](Get-GreenhouseJobsFromJson -Json '{"results":[]}' -Company 'Changed' -BoardToken 'changed' -SourceId 'changed')
}
catch {
    $changedGreenhouseRejected = $true
}
Assert-True $changedGreenhouseRejected 'Changed first-party schema produces a visible parser failure'

$landingValid = '<h2 data-job-path="/us/engineering_development" short-link="eng">Engineering</h2>'
Assert-True (Test-LandingPage -Html $landingValid) 'Landing-page engineering selector is validated'
Assert-True (-not (Test-LandingPage -Html '<h2>Changed</h2>')) 'Changed landing-page schema is rejected'

Assert-Equal 'healthy' (Get-MonitorStatus -LandingHealthy $true -FeedHealthy $true -SearchSuccesses 22 -SearchTotal 22 -Initialized $true -DiscoveredJobs 300) 'Complete source set is healthy'
Assert-Equal 'degraded' (Get-MonitorStatus -LandingHealthy $true -FeedHealthy $true -SearchSuccesses 20 -SearchTotal 22 -Initialized $true -DiscoveredJobs 280) 'Partial search failure is degraded'
Assert-Equal 'failed' (Get-MonitorStatus -LandingHealthy $true -FeedHealthy $false -SearchSuccesses 0 -SearchTotal 22 -Initialized $true -DiscoveredJobs 0) 'Complete discovery failure is failed'

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('job-monitor-tests-' + [guid]::NewGuid().ToString('N'))
try {
    $temporaryAlerts = Join-Path $temporaryRoot 'alerts'
    $temporaryManifest = Join-Path $temporaryAlerts 'manifest.json'
    $temporaryReport = Join-Path $temporaryRoot 'latest.md'
    [void](New-Item -ItemType Directory -Path $temporaryAlerts -Force)
    $testAlerts = @(
        [pscustomobject]@{ Sequence = 1; DiscoveredUtc = '2026-08-04T01:00:00Z'; Title = 'RTL Engineer'; Company = 'A'; Location = 'AZ'; PostedUtc = '2026-08-04T00:00:00Z'; FitScore = 70; Tier = 'Strong'; Warnings = @(); DetailUrl = 'https://example.test/1' },
        [pscustomobject]@{ Sequence = 2; DiscoveredUtc = '2026-08-04T02:00:00Z'; Title = 'FPGA Engineer'; Company = 'B'; Location = 'CA'; PostedUtc = '2026-08-04T01:00:00Z'; FitScore = 55; Tier = 'Good'; Warnings = @('Test'); DetailUrl = 'https://example.test/2' }
    )
    Add-AlertRecords -AlertsDirectory $temporaryAlerts -Alerts $testAlerts
    $manifest = Update-AlertManifest -AlertsDirectory $temporaryAlerts -ManifestPath $temporaryManifest
    Write-LatestReport -AlertsDirectory $temporaryAlerts -ReportPath $temporaryReport
    Assert-Equal 2 $manifest.LatestSequence 'Manifest preserves latest sequence'
    Assert-Equal 2 $manifest.Months[0].RecordCount 'Manifest counts monthly JSONL records'
    Assert-True (Test-Path -LiteralPath $temporaryReport) 'Readable report is generated'

    $jsonPath = Join-Path $temporaryRoot 'state.json'
    Write-JsonFile -Path $jsonPath -Value @{ initialized = $true; seenJobs = @{ abc = @{ alerted = $true } } }
    $roundTrip = Read-JsonHashtable -Path $jsonPath
    Assert-True ([bool]$roundTrip['initialized']) 'Atomic JSON state round-trips correctly'
    Assert-True ([bool]$roundTrip['seenJobs']['abc']['alerted']) 'Nested state round-trips correctly'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$publicSiteRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('job-monitor-public-site-' + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path $projectRoot 'generate_public_site.ps1') -ProjectRoot $projectRoot -OutputDirectory $publicSiteRoot
    $publicIndexPath = Join-Path $publicSiteRoot 'index.html'
    $publicJobsPath = Join-Path $publicSiteRoot 'data/jobs.json'
    $publicHealthPath = Join-Path $publicSiteRoot 'data/health.json'
    Assert-True (Test-Path -LiteralPath $publicIndexPath) 'Public site generator writes the dashboard shell'
    Assert-True (Test-Path -LiteralPath $publicJobsPath) 'Public site generator writes sanitized job data'
    Assert-True (Test-Path -LiteralPath $publicHealthPath) 'Public site generator writes sanitized health data'

    $publicJobsText = Get-Content -LiteralPath $publicJobsPath -Raw
    $publicJobsPayload = $publicJobsText | ConvertFrom-Json
    Assert-True (@($publicJobsPayload.jobs).Count -gt 0) 'Public site contains saved matching jobs'
    Assert-True (-not ($publicJobsText -match '(?i)"(?:JobId|SourceIds|SourceUrls|Breakdown|seenJobs|sourceEtags)"\s*:')) 'Public job data omits private monitor fields'
    Assert-True (-not ($publicJobsText -match '(?i)[a-z]:\\(?:users|windows|program files)\\')) 'Public job data omits local filesystem paths'
    Assert-True (-not ($publicJobsText -match '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')) 'Public job data omits email addresses'
    Assert-True (@($publicJobsPayload.jobs | Where-Object { -not ($_.reasons -is [System.Array]) -or -not ($_.warnings -is [System.Array]) }).Count -eq 0) 'Public reasons and warnings use stable array shapes'
    Assert-True (@($publicJobsPayload.jobs | Where-Object { $_.applyUrl -and $_.applyUrl -notmatch '^https?://' }).Count -eq 0) 'Public application links use only HTTP or HTTPS'
}
finally {
    if (Test-Path -LiteralPath $publicSiteRoot) {
        Remove-Item -LiteralPath $publicSiteRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Tests passed: $script:passed"
Write-Host "Tests failed: $script:failed"
if ($script:failed -gt 0) {
    exit 1
}
exit 0
