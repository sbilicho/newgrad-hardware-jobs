# Loaded in the JobMonitor module so employer adapters share the normalizer and eligibility rules.
function Get-WorkdayJobsFromJson {
    param([string]$Json, [string]$Company, [string]$BoardToken, [string]$SourceId, [string]$SourceUrl, [string]$SourceTags)
    $payload = $Json | ConvertFrom-Json
    if (-not $payload.PSObject.Properties['records']) { throw 'Workday records schema changed.' }
    foreach ($record in @($payload.records)) {
        $info = Get-ObjectValue $record @('jobPostingInfo') $null
        if ($null -eq $info) { throw 'Workday job detail is missing jobPostingInfo.' }
        $externalId = [string](Get-ObjectValue $info @('jobReqId') '')
        if (-not $externalId) { $externalId = [string](Get-ObjectValue $info @('id') '') }
        $country = [string](Get-ObjectValue (Get-ObjectValue $info @('country') $null) @('descriptor') '')
        $location = [string](Get-ObjectValue $info @('location') '')
        $extra = @(Get-ObjectValue $info @('additionalLocations') @())
        if ($extra.Count -gt 0) { $location += '; ' + ($extra -join '; ') }
        $description = ConvertFrom-HtmlFragment ([string](Get-ObjectValue $info @('jobDescription') ''))
        $url = [string](Get-ObjectValue $info @('externalUrl') '')
        $timeType = ConvertTo-NormalizedEmploymentType ([string](Get-ObjectValue $info @('timeType') ''))
        New-NormalizedJob -Id "workday:$BoardToken`:$externalId" -Title ([string]$info.title) -Company $Company `
            -Location $location -Country $country -EmploymentType $timeType -Requirements $description `
            -Tags $SourceTags -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $info @('startDate') '')) `
            -ApplyUrl $url -DetailUrl $url -SourceId $SourceId -SourceKind 'workday' -SourceUrl $SourceUrl -RichData $true
    }
}

function Invoke-EmployerJsonRequest {
    param([string]$Url, [string]$Method = 'Get', $Body = $null)
    $arguments = @{
        Uri = $Url; Method = $Method; TimeoutSec = 15
        Headers = @{ Accept = 'application/json'; 'User-Agent' = 'SignalPathJobMonitor/2.0' }
    }
    if ($null -ne $Body) {
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 12 -Compress
    }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try { return Invoke-RestMethod @arguments }
        catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if ($code -in @(401, 403, 404, 429) -or $attempt -eq 1) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-WorkdaySourceRequest {
    param([Parameter(Mandatory = $true)]$Source)
    $started = [DateTime]::UtcNow
    $records = New-Object System.Collections.Generic.List[object]
    $candidates = @{}
    $warning = ''
    $success = $true
    $errorText = ''
    try {
        foreach ($query in @($Source.Queries)) {
            $body = @{ limit = 20; offset = 0; searchText = [string]$query; appliedFacets = @{} }
            $page = Invoke-EmployerJsonRequest -Url $Source.Url -Method Post -Body $body
            if (-not $page.PSObject.Properties['jobPostings'] -or -not $page.PSObject.Properties['total']) { throw 'Workday list schema changed.' }

            # Use each tenant's published country facet instead of hard-coded country IDs.
            $locationGroup = @($page.facets | Where-Object { $_.facetParameter -eq 'locationMainGroup' })
            $facets = @($page.facets) + @($locationGroup | ForEach-Object { $_.values })
            $countryFacet = @($facets | Where-Object {
                @($_.values | Where-Object { $_.descriptor -match '^(United States(?: of America)?|USA)$' }).Count -gt 0
            } | Select-Object -First 1)
            if ($countryFacet.Count -gt 0) {
                $us = @($countryFacet[0].values | Where-Object { $_.descriptor -match '^(United States(?: of America)?|USA)$' })
                $body.appliedFacets[[string]$countryFacet[0].facetParameter] = @($us | ForEach-Object { [string]$_.id })
                $page = Invoke-EmployerJsonRequest -Url $Source.Url -Method Post -Body $body
            }
            # Workday reports total=0 on later pages even when jobPostings is nonempty.
            $total = [int]$page.total
            $pages = 0
            while ($true) {
                $items = @($page.jobPostings | Where-Object { $null -ne $_ })
                $validItems = 0
                foreach ($item in $items) {
                    # Some tenants retain deleted-job placeholders containing only bulletFields.
                    if (-not $item.PSObject.Properties['title']) { $warning = 'Some retired listing placeholders were skipped.'; continue }
                    $validItems++
                    $title = [string]$item.title
                    if ($title -notmatch [string]$Source.TitlePattern) { continue }
                    if ($title -match '(?i)\b(senior|sr\.?|staff|principal|director|manager|intern|internship)\b' -and $title -notmatch '(?i)new (?:college |university )?grad|entry.level') { continue }
                    $location = [string]$item.locationsText
                    $hasMultipleLocations = $location -match '^\d+ Locations?$'
                    if (-not $hasMultipleLocations -and -not (Test-IsUnitedStatesLocation -Job ([pscustomobject]@{ Location = $location; Country = '' }))) { continue }
                    $path = [string]$item.externalPath
                    if (-not $path.StartsWith('/job/')) { throw 'Unexpected Workday job path.' }
                    $candidates[$path] = $item
                }
                if ($items.Count -gt 0 -and $validItems -eq 0) { throw 'Workday returned no valid listing records on a nonempty page.' }
                $pages++
                $body.offset += $items.Count
                if ($body.offset -ge $total -or $items.Count -eq 0) { break }
                if ($pages -ge [int]$Source.MaxPages) { $warning = 'Listing pagination reached the configured limit; some older jobs await discovery.'; break }
                $page = Invoke-EmployerJsonRequest -Url $Source.Url -Method Post -Body $body
            }
        }
        $verified = @($Source.VerifiedIds)
        $pending = 0
        foreach ($path in @($candidates.Keys | Sort-Object)) {
            $item = $candidates[$path]
            $req = [regex]::Match($path, '_([^_/]+?)(?:-\d+)?$').Groups[1].Value
            if ($verified -contains "workday:$($Source.BoardToken):$req") { continue }
            if ($records.Count -ge [int]$Source.MaxDetails) { $pending++; continue }
            try {
                $detail = Invoke-EmployerJsonRequest -Url (($Source.Url -replace '/jobs$', '') + $path)
                if (-not $detail.PSObject.Properties['jobPostingInfo']) { throw 'Workday detail schema changed.' }
                $records.Add($detail)
            }
            catch {
                $pending++
                $warning = 'Some job details could not be verified: ' + $_.Exception.Message
                if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 429) { break }
            }
        }
        if ($pending -gt 0 -and -not $warning) { $warning = "$pending job detail(s) await a later scan because of the per-run limit." }
    }
    catch { $success = $false; $errorText = $_.Exception.Message }
    return [pscustomobject]@{
        Id = $Source.Id; Kind = 'workday'; Company = $Source.Company; BoardToken = $Source.BoardToken
        SourceTags = $Source.SourceTags; CareersUrl = $Source.CareersUrl; Url = $Source.Url
        Success = $success; NotModified = $false; StatusCode = if ($success) { 200 } else { 0 }
        ETag = ''; Content = (@{ records = $records.ToArray() } | ConvertTo-Json -Depth 30 -Compress)
        Error = $errorText; Warning = $warning; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
    }
}

function Invoke-EightfoldSourceRequest {
    param([Parameter(Mandatory = $true)]$Source)
    $started = [DateTime]::UtcNow
    $records = New-Object System.Collections.Generic.List[object]
    $positions = @{}
    $success = $true
    $errorText = ''
    $warning = ''
    $base = ([Uri]$Source.Url).GetLeftPart([UriPartial]::Authority)
    try {
        foreach ($query in @($Source.Queries)) {
            $offset = 0
            for ($pageIndex = 0; $pageIndex -lt [int]$Source.MaxPages; $pageIndex++) {
                $url = "$base/api/pcsx/search?domain=$([Uri]::EscapeDataString($Source.BoardToken))&query=$([Uri]::EscapeDataString($query))&location=United%20States&start=$offset"
                $response = Invoke-EmployerJsonRequest -Url $url
                $data = Get-ObjectValue $response @('data') $response
                if (-not $data.PSObject.Properties['positions']) { throw 'Eightfold search schema changed.' }
                $batch = @($data.positions)
                foreach ($position in $batch) {
                    $title = [string](Get-ObjectValue $position @('name', 'title') '')
                    $id = [string](Get-ObjectValue $position @('id', 'positionId') '')
                    if ($id -and $title -match [string]$Source.TitlePattern -and $title -notmatch '(?i)\b(staff|principal|director|manager|senior|intern)\b') { $positions[$id] = $position }
                }
                $offset += $batch.Count
                if ($batch.Count -eq 0 -or $offset -ge [int](Get-ObjectValue $data @('count') 0)) { break }
                if ($pageIndex -eq ([int]$Source.MaxPages - 1)) { $warning = 'Search pagination reached its configured limit.' }
            }
        }
        foreach ($id in @($positions.Keys | Sort-Object)) {
            if (@($Source.VerifiedIds) -contains "eightfold:$($Source.BoardToken):$id") { continue }
            if ($records.Count -ge [int]$Source.MaxDetails) { $warning = 'Additional job details await the next scan.'; break }
            $publicUrl = "$base/careers/job/$([Uri]::EscapeDataString($id))?domain=$([Uri]::EscapeDataString($Source.BoardToken))"
            $page = Invoke-WebRequest -Uri $publicUrl -UseBasicParsing -TimeoutSec 15
            $metadata = Get-PublicJobPostingMetadata -Html ([string]$page.Content)
            if ($null -eq $metadata) { $warning = 'Some official pages did not expose job-posting metadata.'; continue }
            $detail = $positions[$id].PSObject.Copy()
            $detail | Add-Member -NotePropertyName employmentType -NotePropertyValue ([string](Get-ObjectValue $metadata @('employmentType') '')) -Force
            $detail | Add-Member -NotePropertyName jobDescription -NotePropertyValue ([string](Get-ObjectValue $metadata @('description') '')) -Force
            $detail | Add-Member -NotePropertyName posted_date -NotePropertyValue ([string](Get-ObjectValue $metadata @('datePosted') '')) -Force
            $records.Add($detail)
        }
    }
    catch { $success = $false; $errorText = $_.Exception.Message }
    return [pscustomobject]@{
        Id = $Source.Id; Kind = 'eightfold'; Company = $Source.Company; BoardToken = $Source.BoardToken
        SourceTags = $Source.SourceTags; CareersUrl = $Source.CareersUrl; Url = $Source.Url
        Success = $success; NotModified = $false; StatusCode = if ($success) { 200 } else { 0 }
        ETag = ''; Content = (@{ positions = $records.ToArray() } | ConvertTo-Json -Depth 30 -Compress)
        Error = $errorText; Warning = $warning; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
    }
}

function Get-PublicJobPostingMetadata {
    param([string]$Html)
    foreach ($match in [regex]::Matches($Html, '(?is)<script\b[^>]*type=["\x27]application/ld\+json["\x27][^>]*>(.*?)</script>')) {
        try { $data = $match.Groups[1].Value | ConvertFrom-Json } catch { continue }
        $objects = @($data) + @(Get-ObjectValue $data @('@graph') @())
        foreach ($object in $objects) {
            if (@(Get-ObjectValue $object @('@type') @()) -contains 'JobPosting') { return $object }
        }
    }
    return $null
}

function Get-EightfoldJobsFromJson {
    param([string]$Json, [string]$Company, [string]$BoardToken, [string]$SourceId, [string]$SourceUrl, [string]$SourceTags)
    $payload = $Json | ConvertFrom-Json
    $data = Get-ObjectValue $payload @('data') $payload
    if (-not $data.PSObject.Properties['positions']) { throw 'Eightfold positions schema changed.' }
    foreach ($position in @($data.positions)) {
        $id = [string](Get-ObjectValue $position @('id', 'positionId') '')
        $title = [string](Get-ObjectValue $position @('name', 'title') '')
        $locations = @(Get-ObjectValue $position @('locations') @())
        $location = (@($locations | ForEach-Object {
            if ($_ -is [string]) { $_ } else { [string](Get-ObjectValue $_ @('name', 'location', 'displayName') '') }
        }) -join '; ')
        if (-not $location) { $location = [string](Get-ObjectValue $position @('location') '') }
        $description = ConvertFrom-HtmlFragment ([string](Get-ObjectValue $position @('job_description', 'jobDescription', 'description') ''))
        # Summary search results do not prove employment type or experience; never alert on them alone.
        if (-not $description) { continue }
        $url = 'https://careers.qualcomm.com/careers/job/' + [Uri]::EscapeDataString($id) + '?domain=qualcomm.com'
        $employment = [string](Get-ObjectValue $position @('employment_type', 'employmentType', 'type') '')
        New-NormalizedJob -Id "eightfold:$BoardToken`:$id" -Title $title -Company $Company -Location $location `
            -Requirements $description -EmploymentType (ConvertTo-NormalizedEmploymentType $employment) `
            -Tags $SourceTags -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $position @('t_create', 'postedTs', 'posted_date') '')) `
            -ApplyUrl $url -DetailUrl $url -SourceId $SourceId -SourceKind 'eightfold' -SourceUrl $SourceUrl -RichData $true
    }
}
