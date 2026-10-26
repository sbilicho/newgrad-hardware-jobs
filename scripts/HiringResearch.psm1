Set-StrictMode -Version 2.0

function Get-HiringResearchPlan {
    param([Parameter(Mandatory = $true)]$Config, [string[]]$CompanyNames, [int]$RunNumber = 0)
    $queries = New-Object System.Collections.Generic.List[string]
    $suffix = ' -internship -"open to work" -"seeking opportunities"'
    foreach ($role in @($Config.roleQueries)) { $queries.Add('site:linkedin.com/posts/ ' + $role + $suffix) }
    foreach ($group in @($Config.priorityCompanyGroups)) {
        $names = (@($group) | ForEach-Object { '"' + $_ + '"' }) -join ' OR '
        $queries.Add('site:linkedin.com/posts/ (' + $names + ') hiring (hardware OR semiconductor OR ASIC OR RTL)' + $suffix)
    }
    $companies = @($CompanyNames | Sort-Object -Unique)
    if ($companies.Count -gt 0) {
        for ($groupIndex = 0; $groupIndex -lt 2; $groupIndex++) {
            $group = @(for ($i = 0; $i -lt 3; $i++) { '"' + $companies[(($RunNumber * 6) + ($groupIndex * 3) + $i) % $companies.Count] + '"' })
            $queries.Add('site:linkedin.com/posts/ (' + ($group -join ' OR ') + ') hiring (engineer OR hardware)' + $suffix)
        }
    }
    $startups = @($Config.startupCompanies)
    $group = @(for ($i = 0; $i -lt 4; $i++) { '"' + $startups[(($RunNumber * 4) + $i) % $startups.Count] + '"' })
    $queries.Add('site:linkedin.com/posts/ (' + ($group -join ' OR ') + ') (hiring OR "join our team") (hardware OR silicon OR semiconductor)' + $suffix)
    $queries.Add('(semiconductor OR ASIC OR RTL OR "electrical hardware") startup "hiring" ("new grad" OR "early career") ("United States" OR USA) -site:linkedin.com/jobs -internship')
    return @($queries | Select-Object -First ([int]$Config.queriesPerRun))
}

function Test-HiringResearchPayload {
    param([Parameter(Mandatory = $true)]$Payload)
    if (-not $Payload.PSObject.Properties['leads'] -or -not $Payload.PSObject.Properties['queries']) { throw 'Research must contain leads and search queries.' }
    if (@($Payload.queries).Count -lt 1) { throw 'Research returned no record of its public search queries.' }
    if (@($Payload.queries).Count -gt 24) { throw 'Research exceeds the search-query safety limit.' }
    foreach ($query in @($Payload.queries)) {
        if (-not ($query -is [string]) -or $query.Length -gt 1500 -or $query -match '(?i)[a-z]:\\(?:users|windows)\\|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b') { throw 'Research query contains invalid or private content.' }
    }
    if (@($Payload.leads).Count -gt 24) { throw 'Research exceeds the 24-lead safety limit.' }
    foreach ($lead in @($Payload.leads)) {
        foreach ($field in @('person', 'company', 'role', 'location', 'url', 'evidence', 'observedAge', 'verification', 'caution', 'message')) {
            if (-not $lead.PSObject.Properties[$field] -or -not ($lead.$field -is [string])) { throw "Lead is missing text field $field." }
            if ($lead.$field.Length -gt 2500) { throw "Lead field $field is too long." }
        }
        $uri = $null
        if (-not [Uri]::TryCreate($lead.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'Hiring lead has an unsafe URL.' }
        if ($uri.Host -match '^(localhost|127\.|0\.)' -or $uri.Host -match '^\d+\.\d+\.\d+\.\d+$') { throw 'Hiring lead may not link to a local address.' }
        if ($lead.location -notmatch '(?i)United States|\bUSA\b|\bUS\b|,\s*(CA|TX|AZ|OR|WA|MA|NY|NC|CO|ID|UT|FL|MI|VA|MD|PA|NJ|CT|MN|OH|IL|WI)\b') { throw 'Hiring lead needs explicit U.S. geography.' }
        if ($lead.role -match '(?i)\b(internship|intern|co-op)\b' -and $lead.role -notmatch '(?i)graduate|full.time') { throw 'Internship-only leads are outside scope.' }
        $publicText = ($lead.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '
        if ($publicText -match '(?i)[a-z]:\\(?:users|windows)\\|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b') { throw 'Public lead contains a local path or email address.' }
    }
    return $true
}

function Merge-HiringResearch {
    param([Parameter(Mandatory = $true)]$Existing, [Parameter(Mandatory = $true)]$Incoming, [DateTime]$Now = [DateTime]::UtcNow)
    [void](Test-HiringResearchPayload $Incoming)
    $byUrl = @{}
    foreach ($lead in @($Existing.leads)) {
        if (-not $lead.PSObject.Properties['lastCheckedUtc']) {
            $seedDate = [DateTime]::MinValue
            $seed = if ([DateTime]::TryParse([string]$Existing.researchedOn, [ref]$seedDate)) { $seedDate.ToString('yyyy-MM-dd') + 'T00:00:00Z' } else { '' }
            $lead | Add-Member -NotePropertyName lastCheckedUtc -NotePropertyValue $seed
        }
        $byUrl[[string]$lead.url] = $lead
    }
    foreach ($lead in @($Incoming.leads)) {
        $kind = if ($lead.url -match '^https://(?:www\.)?linkedin\.com/posts/') { 'linkedin_post' }
            elseif ($lead.url -match '^https://(?:www\.)?linkedin\.com/in/') { 'indexed_profile' }
            elseif ($lead.url -match '^https://(?:www\.)?linkedin\.com/jobs/') { 'job_listing' }
            else { 'public_hiring_page' }
        $lead | Add-Member -NotePropertyName sourceKind -NotePropertyValue $kind -Force
        $lead | Add-Member -NotePropertyName lastCheckedUtc -NotePropertyValue $Now.ToUniversalTime().ToString('o') -Force
        $byUrl[[string]$lead.url] = $lead
    }
    $Existing.leads = @($byUrl.Values | Sort-Object lastCheckedUtc -Descending | Select-Object -First 60)
    $Existing.researchedOn = $Now.ToUniversalTime().ToString('yyyy-MM-dd')
    $Existing.scope = 'Public hiring posts and indexed recruiter activity researched twice daily from this Windows computer using the existing ChatGPT sign-in. Private messages are not accessed. Older leads retain their own last-checked date.'
    $Existing | Add-Member -NotePropertyName automation -NotePropertyValue ([pscustomobject]@{
        status = 'active'; schedule = '08:00 and 20:00 America/Phoenix'; requiresComputer = $true
        lastSuccessfulResearchUtc = $Now.ToUniversalTime().ToString('o'); latestLeadCount = @($Incoming.leads).Count
        note = 'Uses the existing ChatGPT allowance; runs after missed schedules when the computer is available.'
    }) -Force
    return $Existing
}

Export-ModuleMember -Function Get-HiringResearchPlan, Test-HiringResearchPayload, Merge-HiringResearch
