[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot,
    [string]$OutputDirectory,
    [ValidateRange(1, 5000)]
    [int]$MaximumJobs = 1000
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $ProjectRoot 'public'
}

$alertsDirectory = Join-Path $ProjectRoot 'alerts'
$healthPath = Join-Path $ProjectRoot 'health/status.json'
$siteSourceDirectory = Join-Path $ProjectRoot 'site'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
Import-Module (Join-Path $ProjectRoot 'lib/JobMonitor.psm1') -Force -DisableNameChecking

foreach ($requiredPath in @($alertsDirectory, $healthPath, $siteSourceDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required public-site input is missing: $requiredPath"
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-SafePublicUrl {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if (@('http', 'https') -notcontains $uri.Scheme.ToLowerInvariant()) { return $null }
    return $uri.AbsoluteUri
}

function Get-DateSortValue {
    param($Alert)
    foreach ($candidate in @([string]$Alert.PostedUtc, [string]$Alert.DiscoveredUtc)) {
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($candidate, [ref]$parsed)) {
            return $parsed.UtcTicks
        }
    }
    return 0
}

function Test-FirstPartyAlert {
    param($Alert)
    $sourceKinds = if ($Alert.PSObject.Properties['SourceKinds']) { @($Alert.SourceKinds) } else { @() }
    $sourceIds = if ($Alert.PSObject.Properties['SourceIds']) { @($Alert.SourceIds) } else { @() }
    return (
        @($sourceKinds | Where-Object { @('greenhouse', 'lever', 'ashby', 'workday', 'eightfold') -contains ([string]$_).ToLowerInvariant() }).Count -gt 0 -or
        @($sourceIds | Where-Object { [string]$_ -like 'company_*' }).Count -gt 0
    )
}

$allAlerts = New-Object System.Collections.Generic.List[object]
foreach ($file in @(Get-ChildItem -LiteralPath $alertsDirectory -Filter '*.jsonl' -File | Sort-Object Name)) {
    foreach ($line in @(Get-Content -LiteralPath $file.FullName)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $allAlerts.Add(($line | ConvertFrom-Json))
        }
        catch {
            throw "Invalid alert JSON in $($file.Name): $($_.Exception.Message)"
        }
    }
}

$deduplicated = @{}
foreach ($alert in @($allAlerts | Sort-Object Sequence)) {
    $key = if ($alert.PSObject.Properties['JobId'] -and -not [string]::IsNullOrWhiteSpace([string]$alert.JobId)) {
        [string]$alert.JobId
    }
    else {
        ([string]$alert.Company + '|' + [string]$alert.Title + '|' + [string]$alert.Location).ToLowerInvariant()
    }
    $deduplicated[$key] = $alert
}

$sortedAlerts = @(
    $deduplicated.Values |
        Sort-Object @{ Expression = { Get-DateSortValue $_ }; Descending = $true }, @{ Expression = { [int]$_.Sequence }; Descending = $true } |
        Select-Object -First $MaximumJobs
)

$publicJobs = New-Object System.Collections.Generic.List[object]
foreach ($alert in $sortedAlerts) {
    $geography = [pscustomobject]@{ Location = [string]$alert.Location; Country = '' }
    if (-not (Test-IsUnitedStatesLocation -Job $geography)) { continue }
    $isFirstParty = Test-FirstPartyAlert $alert
    $detailUrl = Get-SafePublicUrl ([string]$alert.DetailUrl)
    $applyUrl = if ($alert.PSObject.Properties['ApplyUrl']) { Get-SafePublicUrl ([string]$alert.ApplyUrl) } else { $null }
    if ($null -eq $applyUrl) { $applyUrl = $detailUrl }

    $reasons = @()
    if ($alert.PSObject.Properties['Reasons']) {
        $reasons = @($alert.Reasons | ForEach-Object { [string]$_ })
    }
    $warnings = @()
    if ($alert.PSObject.Properties['Warnings']) {
        $warnings = @($alert.Warnings | ForEach-Object { [string]$_ })
    }
    $publicJobs.Add([pscustomobject][ordered]@{
        sequence       = [int]$alert.Sequence
        title          = [string]$alert.Title
        company        = [string]$alert.Company
        location       = [string]$alert.Location
        employmentType = [string]$alert.EmploymentType
        seniority      = [string]$alert.Seniority
        postedUtc      = [string]$alert.PostedUtc
        discoveredUtc  = [string]$alert.DiscoveredUtc
        salary         = [string]$alert.Salary
        workModel      = [string]$alert.WorkModel
        sponsorship    = [string]$alert.Sponsorship
        fitScore       = [int]$alert.FitScore
        tier           = [string]$alert.Tier
        reasons        = $reasons
        warnings       = $warnings
        sourceType     = if ($isFirstParty) { 'first-party' } else { 'broad-search' }
        sourceLabel    = if ($isFirstParty) { 'First-party' } else { 'Broad search' }
        detailUrl      = $detailUrl
        applyUrl       = $applyUrl
    })
}

$health = Get-Content -LiteralPath $healthPath -Raw | ConvertFrom-Json
$directKinds = @('greenhouse', 'lever', 'ashby', 'workday', 'eightfold')
$companyBoards = New-Object System.Collections.Generic.List[object]
if ($health.PSObject.Properties['Sources']) {
    $directSources = @($health.Sources | Where-Object { $directKinds -contains ([string]$_.Kind).ToLowerInvariant() })
    foreach ($group in @($directSources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Company) } | Group-Object Company | Sort-Object Name)) {
        $members = @($group.Group)
        $sourceWithUrl = @($members | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.CareersUrl) } | Select-Object -First 1)
        $careersUrl = if ($sourceWithUrl.Count -gt 0) { Get-SafePublicUrl ([string]$sourceWithUrl[0].CareersUrl) } else { $null }
        $companyBoards.Add([pscustomobject][ordered]@{
            company    = [string]$group.Name
            healthy    = @($members | Where-Object { [bool]$_.Success }).Count -eq $members.Count
            careersUrl = $careersUrl
            issue      = (@($members | ForEach-Object {
                if ($_.PSObject.Properties['Error'] -and $_.Error) { [string]$_.Error }
                if ($_.PSObject.Properties['Warning'] -and $_.Warning) { [string]$_.Warning }
            }) -join '; ')
        })
    }
}

$coverage = $health.Coverage
$publicHealth = [pscustomobject][ordered]@{
    version               = 1
    generatedUtc          = [DateTime]::UtcNow.ToString('o')
    status                = [string]$health.Status
    lastSuccessfulScanUtc = [string]$health.LastSuccessfulScanUtc
    discoveredJobs        = [int]$health.DiscoveredJobs
    publishedMatches      = [int]$publicJobs.Count
    focusedRoleSearches   = [int]$coverage.FocusedRoleSearches
    directCompanyBoards   = [int]$coverage.DirectCompanyBoards
    healthyDirectBoards   = [int]$coverage.HealthyDirectCompanyBoards
    directHealthyPercent  = [double]$coverage.DirectHealthyPercent
    detailChecksRequested = if ($coverage.PSObject.Properties['CompanyDetailsRequested']) { [int]$coverage.CompanyDetailsRequested } else { 0 }
    detailChecksSucceeded = if ($coverage.PSObject.Properties['CompanyDetailsSucceeded']) { [int]$coverage.CompanyDetailsSucceeded } else { 0 }
    companyBoards         = $companyBoards.ToArray()
    broadCoverageCompanies = @($coverage.BroadCoverageCompanies | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

$publicPayload = [pscustomobject][ordered]@{
    version      = 1
    generatedUtc = $publicHealth.generatedUtc
    description  = 'U.S. full-time early-career electrical, semiconductor, and hardware matches scoring 30 or higher.'
    scoreNotice  = 'Relevance scores reflect an ASIC, digital, semiconductor, and electrical new-grad profile. They are not hiring probabilities.'
    count        = [int]$publicJobs.Count
    jobs         = $publicJobs.ToArray()
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
}
$dataDirectory = Join-Path $OutputDirectory 'data'
if (-not (Test-Path -LiteralPath $dataDirectory)) {
    [void](New-Item -ItemType Directory -Path $dataDirectory -Force)
}

foreach ($assetName in @('index.html', 'styles.css', 'app.js', 'site.webmanifest', 'robots.txt', 'outreach.html', 'outreach.js')) {
    $sourcePath = Join-Path $siteSourceDirectory $assetName
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required site asset is missing: $sourcePath"
    }
    Write-Utf8File -Path (Join-Path $OutputDirectory $assetName) -Content (Get-Content -LiteralPath $sourcePath -Raw)
}

$jobsJson = ConvertTo-Json -InputObject $publicPayload -Depth 8
$healthJson = ConvertTo-Json -InputObject $publicHealth -Depth 8
Write-Utf8File -Path (Join-Path $dataDirectory 'jobs.json') -Content ($jobsJson + [Environment]::NewLine)
Write-Utf8File -Path (Join-Path $dataDirectory 'health.json') -Content ($healthJson + [Environment]::NewLine)
Write-Utf8File -Path (Join-Path $OutputDirectory '.nojekyll') -Content ''

$outreachPath = Join-Path $ProjectRoot 'config/outreach.json'
if (Test-Path -LiteralPath $outreachPath) {
    $outreach = Get-Content -LiteralPath $outreachPath -Raw | ConvertFrom-Json
    $companyConfig = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/company_sources.json') -Raw | ConvertFrom-Json
    $names = @(@($companyConfig.directBoards | ForEach-Object { [string]$_.company }) + @($companyConfig.broadRoleCoverageCompanies) | Sort-Object -Unique)
    $directory = foreach ($name in $names) {
        $board = @($companyConfig.directBoards | Where-Object { $_.company -eq $name } | Select-Object -First 1)
        $sourceHealth = @($companyBoards | Where-Object { $_.company -eq $name } | Select-Object -First 1)
        $coverageText = 'Aggregator role searches + manual company searches; no direct feed configured.'
        if ($board.Count -gt 0) {
            $coverageText = if ($sourceHealth.Count -eq 0) { 'Direct feed configured; awaiting first scan.' }
                elseif ($sourceHealth[0].healthy) { 'Automatic direct company feed: healthy.' }
                else { 'Direct feed needs attention. Use company careers or web search while it recovers.' }
            if ($sourceHealth.Count -gt 0 -and $sourceHealth[0].issue) { $coverageText += ' ' + $sourceHealth[0].issue }
        }
        $jobQuery = '"' + $name + '" (ASIC OR RTL OR semiconductor OR EDA OR hardware) ("new grad" OR "entry level" OR "engineer I") (USA OR "United States")'
        $postQuery = $name + ' hiring (ASIC OR RTL OR physical design OR EDA) (United States OR USA)'
        [pscustomobject]@{
            company = $name; coverage = $coverageText
            careersUrl = if ($board.Count -gt 0) { Get-SafePublicUrl $board[0].careersUrl } else { $null }
            jobSearchUrl = 'https://www.google.com/search?q=' + [Uri]::EscapeDataString($jobQuery)
            postSearchUrl = 'https://www.linkedin.com/search/results/content/?keywords=' + [Uri]::EscapeDataString($postQuery) + '&sortBy=%22date_posted%22'
            webPostSearchUrl = 'https://www.google.com/search?q=' + [Uri]::EscapeDataString('site:linkedin.com/posts/ ' + $postQuery) + '&tbs=qdr:m'
        }
    }
    $outreach | Add-Member -NotePropertyName companies -NotePropertyValue @($directory) -Force
    Write-Utf8File -Path (Join-Path $dataDirectory 'outreach.json') -Content ($outreach | ConvertTo-Json -Depth 10)
}

$generatedText = (Get-Content -LiteralPath (Join-Path $OutputDirectory 'index.html') -Raw) + $jobsJson + $healthJson
$forbiddenPatterns = @(
    '(?i)[a-z]:\\(?:users|windows|program files)\\',
    '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
    '(?i)"(?:JobId|SourceIds|SourceUrls|Breakdown|seenJobs|sourceEtags)"\s*:'
)
foreach ($pattern in $forbiddenPatterns) {
    if ($generatedText -match $pattern) {
        throw "Public-site privacy check failed for pattern: $pattern"
    }
}

Write-Host "Generated public site with $($publicJobs.Count) sanitized job match(es): $OutputDirectory"
