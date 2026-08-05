Set-StrictMode -Version 2.0

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:NormalizedTermCache = @{}

function Get-ObjectValue {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        $Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    foreach ($name in $Names) {
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($name)) {
                return $InputObject[$name]
            }
        }
        else {
            $property = $InputObject.PSObject.Properties[$name]
            if ($null -ne $property) {
                return $property.Value
            }
        }
    }

    return $Default
}

function ConvertTo-FlatText {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return (($Value.Values | ForEach-Object { ConvertTo-FlatText $_ }) -join ' ')
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return (($Value | ForEach-Object { ConvertTo-FlatText $_ }) -join ' ')
    }

    return [string]$Value
}

function Normalize-MatchText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Text).ToLowerInvariant()
    $decoded = $decoded -replace '&', ' and '
    $decoded = $decoded -replace '[^\p{L}\p{Nd}\+\#]+', ' '
    return (($decoded -replace '\s+', ' ').Trim())
}

function Test-TextContainsTerm {
    param(
        [Parameter(Mandatory = $true)][string]$NormalizedText,
        [Parameter(Mandatory = $true)][string]$Term
    )

    if ($script:NormalizedTermCache.ContainsKey($Term)) {
        $normalizedTerm = $script:NormalizedTermCache[$Term]
    }
    else {
        $normalizedTerm = Normalize-MatchText $Term
        $script:NormalizedTermCache[$Term] = $normalizedTerm
    }
    if ([string]::IsNullOrWhiteSpace($normalizedTerm)) {
        return $false
    }

    return (' ' + $NormalizedText + ' ').Contains(' ' + $normalizedTerm + ' ')
}

function Test-AnyTerm {
    param(
        [Parameter(Mandatory = $true)][string]$NormalizedText,
        [Parameter(Mandatory = $false)]$Terms
    )

    foreach ($term in $Terms) {
        if (Test-TextContainsTerm -NormalizedText $NormalizedText -Term ([string]$term)) {
            return $true
        }
    }
    return $false
}

function ConvertTo-UtcIso {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    $number = 0L
    if ([long]::TryParse([string]$Value, [ref]$number)) {
        try {
            if ($number -gt 99999999999) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($number).UtcDateTime.ToString('o')
            }
            if ($number -gt 999999999) {
                return [DateTimeOffset]::FromUnixTimeSeconds($number).UtcDateTime.ToString('o')
            }
        }
        catch {
            return $null
        }
    }

    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.ToUniversalTime().ToString('o')
    }

    return $null
}

function Get-NextDataPageProps {
    param([Parameter(Mandatory = $true)][string]$Html)

    $match = [regex]::Match(
        $Html,
        '<script[^>]*id=["'']__NEXT_DATA__["''][^>]*>(.*?)</script>',
        [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        throw 'The page does not contain a __NEXT_DATA__ payload.'
    }

    try {
        $payload = $match.Groups[1].Value | ConvertFrom-Json
    }
    catch {
        throw "The __NEXT_DATA__ payload is not valid JSON: $($_.Exception.Message)"
    }

    $props = Get-ObjectValue -InputObject $payload -Names @('props')
    $pageProps = Get-ObjectValue -InputObject $props -Names @('pageProps')
    if ($null -eq $pageProps) {
        throw 'The __NEXT_DATA__ payload does not contain props.pageProps.'
    }
    return $pageProps
}

function New-NormalizedJob {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Company,
        [string]$Location,
        [string]$Country,
        [string]$EmploymentType,
        [string]$Seniority,
        [string]$Requirements,
        [string]$Summary,
        [string]$Responsibilities,
        [string]$Tags,
        [string]$PostedUtc,
        [string]$Salary,
        [string]$WorkModel,
        [string]$Sponsorship,
        [string]$ApplyUrl,
        [string]$DetailUrl,
        [string]$SourceId,
        [string]$SourceKind,
        [string]$SourceUrl,
        [Nullable[bool]]$RichData = $null
    )

    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($DetailUrl)) {
        $DetailUrl = "https://jobright.ai/jobs/info/$Id"
    }
    if ([string]::IsNullOrWhiteSpace($ApplyUrl)) {
        $ApplyUrl = $DetailUrl
    }
    if ($null -eq $RichData) {
        $RichData = ($SourceKind -eq 'search' -or $SourceKind -eq 'detail')
    }

    return [pscustomobject][ordered]@{
        Id               = $Id.Trim()
        Title            = $Title.Trim()
        Company          = $Company.Trim()
        Location         = $Location.Trim()
        Country          = $Country.Trim()
        EmploymentType   = $EmploymentType.Trim()
        Seniority        = $Seniority.Trim()
        Requirements     = $Requirements.Trim()
        Summary          = $Summary.Trim()
        Responsibilities = $Responsibilities.Trim()
        Tags             = $Tags.Trim()
        PostedUtc        = $PostedUtc
        Salary           = $Salary.Trim()
        WorkModel        = $WorkModel.Trim()
        Sponsorship      = $Sponsorship.Trim()
        ApplyUrl         = $ApplyUrl.Trim()
        DetailUrl        = $DetailUrl.Trim()
        SourceIds        = @($SourceId)
        SourceKinds      = @($SourceKind)
        SourceUrls       = @($SourceUrl)
        RichData         = [bool]$RichData
    }
}

function ConvertFrom-HtmlFragment {
    param([AllowNull()][string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return ''
    }

    $text = $Html -replace '(?i)<\s*br\s*/?\s*>', "`n"
    $text = $text -replace '(?i)</\s*(p|li|div|h[1-6])\s*>', "`n"
    $text = $text -replace '<[^>]+>', ' '
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return (($text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim())
}

function ConvertTo-NormalizedEmploymentType {
    param(
        [AllowNull()][string]$Value,
        [AllowNull()][string]$Title,
        [AllowNull()][string]$Description,
        [switch]$InferFullTime
    )

    $provided = Normalize-MatchText $Value
    $titleText = Normalize-MatchText $Title
    $descriptionText = Normalize-MatchText $Description
    $scope = "$provided $titleText"

    if ($scope -match '\b(co op|coop)\b') { return 'Co-op' }
    if ($scope -match '\b(intern|internship)\b') { return 'Internship' }
    if ($scope -match '\b(part time|parttime)\b') { return 'Part-time' }
    if ($scope -match '\b(contract|contractor)\b') { return 'Contract' }
    if ($scope -match '\b(temporary|seasonal)\b') { return 'Temporary' }
    if ($provided -match '\b(full time|fulltime|regular|permanent)\b') { return 'Full-time' }
    if ($descriptionText -match '\b(employment type|job type|commitment)\b.{0,30}\bfull time\b') { return 'Full-time' }

    if ($InferFullTime) {
        return 'Full-time (inferred)'
    }
    return [string]$Value
}

function Get-LastUrlSegment {
    param([AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }
    try {
        return ([uri]$Url).Segments[-1].Trim('/')
    }
    catch {
        return (($Url -split '/')[-1] -split '\?')[0]
    }
}

function Get-GreenhouseJobsFromJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Company,
        [Parameter(Mandatory = $true)][string]$BoardToken,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [string]$SourceUrl = '',
        [string]$SourceTags = ''
    )

    try {
        $payload = $Json | ConvertFrom-Json
    }
    catch {
        throw "The Greenhouse payload is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $payload) {
        throw 'The Greenhouse payload is empty.'
    }
    if ($null -ne $payload.PSObject.Properties['jobs']) {
        $records = @($payload.jobs)
    }
    elseif ($null -ne $payload.PSObject.Properties['id'] -and $null -ne $payload.PSObject.Properties['title']) {
        $records = @($payload)
    }
    else {
        throw 'The Greenhouse payload contains neither a jobs collection nor a job detail record.'
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $externalId = [string](Get-ObjectValue $record @('id'))
        $title = [string](Get-ObjectValue $record @('title'))
        if ([string]::IsNullOrWhiteSpace($externalId) -or [string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $description = ConvertFrom-HtmlFragment ([string](Get-ObjectValue $record @('content')))
        $metadataText = New-Object System.Collections.Generic.List[string]
        $employmentValue = ''
        foreach ($metadata in @(Get-ObjectValue $record @('metadata') @())) {
            $name = [string](Get-ObjectValue $metadata @('name'))
            $value = ConvertTo-FlatText (Get-ObjectValue $metadata @('value'))
            if (-not [string]::IsNullOrWhiteSpace("$name $value")) {
                $metadataText.Add("$name $value")
            }
            if ($name -match '(?i)employment|job\s*type|commitment|time\s*type') {
                $employmentValue = $value
            }
        }

        $locations = New-Object System.Collections.Generic.List[string]
        $primaryLocation = [string](Get-ObjectValue (Get-ObjectValue $record @('location')) @('name'))
        if (-not [string]::IsNullOrWhiteSpace($primaryLocation)) { $locations.Add($primaryLocation) }
        foreach ($office in @(Get-ObjectValue $record @('offices') @())) {
            $officeLocation = [string](Get-ObjectValue $office @('location', 'name'))
            if (-not [string]::IsNullOrWhiteSpace($officeLocation)) { $locations.Add($officeLocation) }
        }
        $location = (@($locations | Select-Object -Unique) -join '; ')

        $departments = @(Get-ObjectValue $record @('departments') @() | ForEach-Object {
            [string](Get-ObjectValue $_ @('name'))
        })
        $offices = @(Get-ObjectValue $record @('offices') @() | ForEach-Object {
            [string](Get-ObjectValue $_ @('name'))
        })
        $tags = @($SourceTags, ($departments -join ' '), ($offices -join ' '), ($metadataText -join ' ')) -join ' '
        $detailUrl = [string](Get-ObjectValue $record @('absolute_url'))
        $employment = ConvertTo-NormalizedEmploymentType `
            -Value $employmentValue `
            -Title $title `
            -Description $description `
            -InferFullTime

        $job = New-NormalizedJob `
            -Id "greenhouse:$BoardToken`:$externalId" `
            -Title $title `
            -Company $Company `
            -Location $location `
            -Country $location `
            -EmploymentType $employment `
            -Seniority $title `
            -Requirements $description `
            -Summary $description `
            -Responsibilities '' `
            -Tags $tags `
            -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $record @('updated_at'))) `
            -Salary '' `
            -WorkModel '' `
            -Sponsorship '' `
            -ApplyUrl $detailUrl `
            -DetailUrl $detailUrl `
            -SourceId $SourceId `
            -SourceKind 'greenhouse' `
            -SourceUrl $SourceUrl `
            -RichData (-not [string]::IsNullOrWhiteSpace($description))
        if ($null -ne $job) { $jobs.Add($job) }
    }
    return $jobs.ToArray()
}

function Get-LeverJobsFromJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Company,
        [Parameter(Mandatory = $true)][string]$BoardToken,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [string]$SourceUrl = '',
        [string]$SourceTags = ''
    )

    $trimmed = $Json.TrimStart()
    if (-not $trimmed.StartsWith('[')) {
        throw 'The Lever payload is not a JSON array.'
    }
    try {
        $payload = $Json | ConvertFrom-Json
        $records = @($payload)
    }
    catch {
        throw "The Lever payload is not valid JSON: $($_.Exception.Message)"
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $externalId = [string](Get-ObjectValue $record @('id'))
        $title = [string](Get-ObjectValue $record @('text'))
        if ([string]::IsNullOrWhiteSpace($externalId) -or [string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $categories = Get-ObjectValue $record @('categories')
        $listText = New-Object System.Collections.Generic.List[string]
        foreach ($list in @(Get-ObjectValue $record @('lists') @())) {
            $listText.Add((ConvertFrom-HtmlFragment ([string](Get-ObjectValue $list @('content')))))
        }
        $description = @(
            [string](Get-ObjectValue $record @('descriptionPlain'))
            [string](Get-ObjectValue $record @('additionalPlain'))
            ($listText -join ' ')
        ) -join ' '
        $allLocations = @(
            ConvertTo-FlatText (Get-ObjectValue $categories @('location'))
            ConvertTo-FlatText (Get-ObjectValue $record @('allLocations'))
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $location = (@($allLocations | Select-Object -Unique) -join '; ')
        $country = ConvertTo-FlatText (Get-ObjectValue $categories @('country'))
        $commitment = ConvertTo-FlatText (Get-ObjectValue $categories @('commitment'))
        $employment = ConvertTo-NormalizedEmploymentType -Value $commitment -Title $title -Description $description
        $detailUrl = [string](Get-ObjectValue $record @('hostedUrl'))
        $applyUrl = [string](Get-ObjectValue $record @('applyUrl'))
        $tags = @(
            $SourceTags,
            (ConvertTo-FlatText (Get-ObjectValue $categories @('department'))),
            (ConvertTo-FlatText (Get-ObjectValue $categories @('team')))
        ) -join ' '

        $job = New-NormalizedJob `
            -Id "lever:$BoardToken`:$externalId" `
            -Title $title `
            -Company $Company `
            -Location $location `
            -Country $country `
            -EmploymentType $employment `
            -Seniority $title `
            -Requirements $description `
            -Summary ([string](Get-ObjectValue $record @('descriptionPlain'))) `
            -Responsibilities ($listText -join ' ') `
            -Tags $tags `
            -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $record @('createdAt'))) `
            -Salary (ConvertTo-FlatText (Get-ObjectValue $record @('salaryDescriptionPlain', 'salaryRange'))) `
            -WorkModel ([string](Get-ObjectValue $record @('workplaceType'))) `
            -Sponsorship '' `
            -ApplyUrl $applyUrl `
            -DetailUrl $detailUrl `
            -SourceId $SourceId `
            -SourceKind 'lever' `
            -SourceUrl $SourceUrl `
            -RichData $true
        if ($null -ne $job) { $jobs.Add($job) }
    }
    return $jobs.ToArray()
}

function Get-AshbyJobsFromJson {
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$Company,
        [Parameter(Mandatory = $true)][string]$BoardToken,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [string]$SourceUrl = '',
        [string]$SourceTags = ''
    )

    try {
        $payload = $Json | ConvertFrom-Json
    }
    catch {
        throw "The Ashby payload is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $payload -or $null -eq $payload.PSObject.Properties['jobs']) {
        throw 'The Ashby payload does not contain a jobs collection.'
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($payload.jobs)) {
        $isListed = Get-ObjectValue $record @('isListed') $true
        if ($null -ne $isListed -and -not [bool]$isListed) { continue }

        $title = [string](Get-ObjectValue $record @('title'))
        $detailUrl = [string](Get-ObjectValue $record @('jobUrl'))
        $externalId = [string](Get-ObjectValue $record @('id'))
        if ([string]::IsNullOrWhiteSpace($externalId)) {
            $externalId = Get-LastUrlSegment $detailUrl
        }
        if ([string]::IsNullOrWhiteSpace($externalId) -or [string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $secondaryLocations = @(Get-ObjectValue $record @('secondaryLocations') @() | ForEach-Object {
            ConvertTo-FlatText (Get-ObjectValue $_ @('location', 'name', 'address'))
        })
        $location = @(
            [string](Get-ObjectValue $record @('location'))
            ($secondaryLocations -join '; ')
        ) -join '; '
        $country = @(
            ConvertTo-FlatText (Get-ObjectValue (Get-ObjectValue $record @('address')) @('postalAddress', 'addressCountry'))
            ConvertTo-FlatText (Get-ObjectValue $record @('secondaryLocations'))
        ) -join ' '
        $description = [string](Get-ObjectValue $record @('descriptionPlain'))
        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = ConvertFrom-HtmlFragment ([string](Get-ObjectValue $record @('descriptionHtml')))
        }
        $employment = ConvertTo-NormalizedEmploymentType `
            -Value ([string](Get-ObjectValue $record @('employmentType'))) `
            -Title $title `
            -Description $description
        $tags = @(
            $SourceTags,
            (ConvertTo-FlatText (Get-ObjectValue $record @('department'))),
            (ConvertTo-FlatText (Get-ObjectValue $record @('team')))
        ) -join ' '

        $job = New-NormalizedJob `
            -Id "ashby:$BoardToken`:$externalId" `
            -Title $title `
            -Company $Company `
            -Location $location.Trim(' ', ';') `
            -Country $country `
            -EmploymentType $employment `
            -Seniority $title `
            -Requirements $description `
            -Summary $description `
            -Responsibilities '' `
            -Tags $tags `
            -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $record @('publishedAt'))) `
            -Salary (ConvertTo-FlatText (Get-ObjectValue $record @('compensation'))) `
            -WorkModel ([string](Get-ObjectValue $record @('workplaceType'))) `
            -Sponsorship '' `
            -ApplyUrl ([string](Get-ObjectValue $record @('applyUrl'))) `
            -DetailUrl $detailUrl `
            -SourceId $SourceId `
            -SourceKind 'ashby' `
            -SourceUrl $SourceUrl `
            -RichData $true
        if ($null -ne $job) { $jobs.Add($job) }
    }
    return $jobs.ToArray()
}

function ConvertFrom-MinisiteJob {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SourceUrl
    )

    $id = [string](Get-ObjectValue $Record @('id', 'jobId'))
    $title = [string](Get-ObjectValue $Record @('title', 'jobTitle'))
    return New-NormalizedJob `
        -Id $id `
        -Title $title `
        -Company ([string](Get-ObjectValue $Record @('company', 'companyName'))) `
        -Location ([string](Get-ObjectValue $Record @('location', 'jobLocation'))) `
        -EmploymentType ([string](Get-ObjectValue $Record @('employmentType'))) `
        -Seniority (ConvertTo-FlatText (Get-ObjectValue $Record @('expLevel', 'jobSeniority'))) `
        -Requirements (ConvertTo-FlatText (Get-ObjectValue $Record @('qualifications', 'requirements'))) `
        -Summary (ConvertTo-FlatText (Get-ObjectValue $Record @('summary', 'jobSummary'))) `
        -Responsibilities (ConvertTo-FlatText (Get-ObjectValue $Record @('responsibilities'))) `
        -Tags (ConvertTo-FlatText (Get-ObjectValue $Record @('industry', 'jobTags'))) `
        -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $Record @('postedDate', 'postedAt', 'publishTime'))) `
        -Salary ([string](Get-ObjectValue $Record @('salary', 'salaryDesc'))) `
        -WorkModel ([string](Get-ObjectValue $Record @('workModel'))) `
        -Sponsorship ([string](Get-ObjectValue $Record @('h1bSponsored', 'h1BStatus'))) `
        -ApplyUrl ([string](Get-ObjectValue $Record @('applyUrl', 'applyLink', 'url'))) `
        -SourceId $SourceId `
        -SourceKind 'minisite' `
        -SourceUrl $SourceUrl
}

function ConvertFrom-RichJob {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$SourceKind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SourceUrl
    )

    $jobResult = Get-ObjectValue $Record @('jobResult')
    if ($null -eq $jobResult) {
        $jobResult = $Record
    }
    $companyResult = Get-ObjectValue $Record @('companyResult')

    $company = [string](Get-ObjectValue $companyResult @('companyName', 'name', 'company'))
    if ([string]::IsNullOrWhiteSpace($company)) {
        $company = [string](Get-ObjectValue $jobResult @('companyName', 'company'))
    }

    $location = ConvertTo-FlatText (Get-ObjectValue $jobResult @('jobLocation', 'jobLocations', 'location'))
    $requirements = ConvertTo-FlatText (Get-ObjectValue $jobResult @('requirements', 'qualifications'))
    $responsibilities = ConvertTo-FlatText (Get-ObjectValue $jobResult @('coreResponsibilities', 'responsibilities'))
    $detailResponsibilities = ConvertTo-FlatText (Get-ObjectValue $Record @('jdResponsibilitySummary'))
    if ($detailResponsibilities.Length -gt $responsibilities.Length) {
        $responsibilities = $detailResponsibilities
    }

    $tags = @(
        ConvertTo-FlatText (Get-ObjectValue $jobResult @('jobTags'))
        ConvertTo-FlatText (Get-ObjectValue $companyResult @('companyCategory', 'industries', 'industry'))
    ) -join ' '

    return New-NormalizedJob `
        -Id ([string](Get-ObjectValue $jobResult @('jobId', 'id'))) `
        -Title ([string](Get-ObjectValue $jobResult @('jobTitle', 'title'))) `
        -Company $company `
        -Location $location `
        -EmploymentType (ConvertTo-FlatText (Get-ObjectValue $jobResult @('employmentType', 'jobType'))) `
        -Seniority (ConvertTo-FlatText (Get-ObjectValue $jobResult @('jobSeniority', 'seniority', 'expLevel'))) `
        -Requirements $requirements `
        -Summary (ConvertTo-FlatText (Get-ObjectValue $jobResult @('jobSummary', 'summary'))) `
        -Responsibilities $responsibilities `
        -Tags $tags `
        -PostedUtc (ConvertTo-UtcIso (Get-ObjectValue $jobResult @('publishTime', 'postedAt', 'postedDate'))) `
        -Salary ([string](Get-ObjectValue $jobResult @('salaryDesc', 'salary'))) `
        -WorkModel ([string](Get-ObjectValue $jobResult @('workModel'))) `
        -Sponsorship ([string](Get-ObjectValue $jobResult @('h1BStatus', 'h1bSponsored'))) `
        -ApplyUrl ([string](Get-ObjectValue $jobResult @('applyLink', 'url', 'originalUrl'))) `
        -SourceId $SourceId `
        -SourceKind $SourceKind `
        -SourceUrl $SourceUrl
}

function Get-MinisiteJobsFromHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [string]$SourceId = 'engineering_feed',
        [string]$SourceUrl = ''
    )

    $pageProps = Get-NextDataPageProps $Html
    $records = @(Get-ObjectValue -InputObject $pageProps -Names @('initialJobs') -Default @())
    if ($records.Count -eq 0) {
        throw 'The minisite payload contains no initialJobs records.'
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $job = ConvertFrom-MinisiteJob -Record $record -SourceId $SourceId -SourceUrl $SourceUrl
        if ($null -ne $job) {
            $jobs.Add($job)
        }
    }
    return $jobs.ToArray()
}

function Get-SearchJobsFromHtml {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [string]$SourceId = 'search',
        [string]$SourceUrl = '',
        [ValidateSet('search', 'detail')][string]$SourceKind = 'search'
    )

    $pageProps = Get-NextDataPageProps $Html
    if ($SourceKind -eq 'detail') {
        $record = Get-ObjectValue -InputObject $pageProps -Names @('dataSource')
        if ($null -eq $record) {
            throw 'The detail payload contains no dataSource record.'
        }
        $job = ConvertFrom-RichJob -Record $record -SourceId $SourceId -SourceKind 'detail' -SourceUrl $SourceUrl
        if ($null -eq $job) {
            throw 'The detail payload did not produce a valid job.'
        }
        return @($job)
    }

    $records = @(Get-ObjectValue -InputObject $pageProps -Names @('jobList') -Default @())
    if ($records.Count -eq 0) {
        throw 'The search payload contains no jobList records.'
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($record in $records) {
        $job = ConvertFrom-RichJob -Record $record -SourceId $SourceId -SourceKind 'search' -SourceUrl $SourceUrl
        if ($null -ne $job) {
            $jobs.Add($job)
        }
    }
    return $jobs.ToArray()
}

function Merge-NormalizedJobs {
    param([Parameter(Mandatory = $true)]$Jobs)

    $byId = [ordered]@{}
    $textFields = @(
        'Title', 'Company', 'Location', 'Country', 'EmploymentType', 'Seniority', 'Requirements',
        'Summary', 'Responsibilities', 'Tags', 'Salary', 'WorkModel', 'Sponsorship', 'ApplyUrl', 'DetailUrl'
    )

    foreach ($job in $Jobs) {
        if ($null -eq $job -or [string]::IsNullOrWhiteSpace([string]$job.Id)) {
            continue
        }

        if (-not $byId.Contains($job.Id)) {
            $byId[$job.Id] = $job
            continue
        }

        $existing = $byId[$job.Id]
        foreach ($field in $textFields) {
            $oldValue = [string](Get-ObjectValue $existing @($field) '')
            $newValue = [string](Get-ObjectValue $job @($field) '')
            if ($newValue.Length -gt $oldValue.Length) {
                $existing.$field = $newValue
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$existing.PostedUtc) -and -not [string]::IsNullOrWhiteSpace([string]$job.PostedUtc)) {
            $existing.PostedUtc = $job.PostedUtc
        }
        $existing.RichData = [bool]($existing.RichData -or $job.RichData)
        $existing.SourceIds = @($existing.SourceIds + $job.SourceIds | Select-Object -Unique)
        $existing.SourceKinds = @($existing.SourceKinds + $job.SourceKinds | Select-Object -Unique)
        $existing.SourceUrls = @($existing.SourceUrls + $job.SourceUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    return @($byId.Values | ForEach-Object { $_ })
}

function Get-RequiredExperience {
    param([Parameter(Mandatory = $true)]$Job)

    $text = @($Job.Title, $Job.Requirements, $Job.Summary) -join ' '
    $requiredValues = New-Object System.Collections.Generic.List[int]
    $patterns = @(
        '(?i)(?:minimum(?:\s+of)?|at\s+least|required|requires|must\s+have)\D{0,16}(\d+)\+?\s*(?:years|yrs)',
        '(?i)(\d+)\+?\s*(?:years|yrs)(?:\s+of[^.;]{0,40})?\s+(?:required|minimum)',
        '(?i)(\d+)\s*(?:-|to)\s*\d+\s*(?:years|yrs)\s+(?:required|minimum)',
        '(?i)\b(\d+)\+\s*(?:years|yrs)(?:\s+of)?\s+(?:relevant\s+|professional\s+|industry\s+|hands-on\s+)?experience\b',
        '(?i)\b(\d+)\s*(?:-|to)\s*\d+\s*(?:years|yrs)(?:\s+of)?\s+(?:relevant\s+|professional\s+|industry\s+|hands-on\s+)?experience\b'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $value = 0
            if ([int]::TryParse($match.Groups[1].Value, [ref]$value)) {
                $requiredValues.Add($value)
            }
        }
    }

    $minimum = $null
    if ($requiredValues.Count -gt 0) {
        $minimum = ($requiredValues | Measure-Object -Maximum).Maximum
    }
    return [pscustomobject]@{ RequiredMinimumYears = $minimum }
}

function Test-IsUnitedStatesLocation {
    param([Parameter(Mandatory = $true)]$Job)

    $location = [string](Get-ObjectValue $Job @('Location') '')
    $country = [string](Get-ObjectValue $Job @('Country') '')
    $geo = "$location $country"

    if ($geo -match '(?i)\b(united states(?: of america)?|u\.?s\.?a\.?|us remote|remote[ ,/-]+us)\b') {
        return $true
    }

    $stateCodes = 'AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC'
    if ($geo -match "(?i)(?:,\s*|\bUS[ ,/-]+)($stateCodes)(?:\b|$)") {
        return $true
    }

    $stateNames = @(
        'alabama', 'alaska', 'arizona', 'arkansas', 'california', 'colorado', 'connecticut',
        'delaware', 'florida', 'georgia', 'hawaii', 'idaho', 'illinois', 'indiana', 'iowa',
        'kansas', 'kentucky', 'louisiana', 'maine', 'maryland', 'massachusetts', 'michigan',
        'minnesota', 'mississippi', 'missouri', 'montana', 'nebraska', 'nevada', 'new hampshire',
        'new jersey', 'new mexico', 'new york', 'north carolina', 'north dakota', 'ohio',
        'oklahoma', 'oregon', 'pennsylvania', 'rhode island', 'south carolina', 'south dakota',
        'tennessee', 'texas', 'utah', 'vermont', 'virginia', 'washington', 'west virginia',
        'wisconsin', 'wyoming', 'district of columbia'
    )
    $normalizedGeo = Normalize-MatchText $geo
    if (Test-AnyTerm -NormalizedText $normalizedGeo -Terms $stateNames) {
        return $true
    }

    # Some startup boards publish only a city, so retain a conservative U.S. tech-hub list.
    $usCities = @(
        'austin', 'boston', 'chicago', 'cupertino', 'denver', 'fort collins', 'irvine',
        'los angeles', 'milpitas', 'mountain view', 'new york', 'palo alto', 'phoenix',
        'raleigh', 'redwood city', 'san diego', 'san francisco', 'san jose', 'santa clara',
        'seattle', 'sunnyvale'
    )
    return (Test-AnyTerm -NormalizedText $normalizedGeo -Terms $usCities)
}

function Test-JobEligibility {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Config,
        [switch]$AllowUnknownEmployment
    )

    $title = Normalize-MatchText $Job.Title
    $location = Normalize-MatchText $Job.Location
    $employment = Normalize-MatchText $Job.EmploymentType
    $seniority = Normalize-MatchText $Job.Seniority
    $allText = Normalize-MatchText (@(
        $Job.Title, $Job.Company, $Job.Location, $Job.EmploymentType, $Job.Seniority,
        $Job.Requirements, $Job.Summary, $Job.Responsibilities, $Job.Tags
    ) -join ' ')

    $rejections = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $employmentScope = Normalize-MatchText "$title $employment"
    if (Test-AnyTerm $employmentScope $Config.eligibility.excludedEmploymentTerms) {
        $rejections.Add('Not a full-time role')
    }
    elseif ([string]::IsNullOrWhiteSpace($employment)) {
        if ($AllowUnknownEmployment) {
            $warnings.Add('Full-time status is pending detail verification')
        }
        else {
            $rejections.Add('Full-time status could not be verified')
        }
    }
    elseif ($employment -notmatch 'full\s*time') {
        $rejections.Add("Employment type is $($Job.EmploymentType); full-time is required")
    }

    $levelScope = Normalize-MatchText "$title $seniority"
    $hasSeniorSignal = Test-AnyTerm $levelScope $Config.eligibility.seniorTerms
    $hasEntrySignal = Test-AnyTerm $levelScope $Config.eligibility.entryTerms
    if ($hasSeniorSignal -and -not $hasEntrySignal) {
        $rejections.Add('Senior-only title')
    }

    $hasUnrelatedTitle = Test-AnyTerm $title $Config.eligibility.unrelatedTitleTerms
    $hasTargetRescue = Test-AnyTerm $title $Config.eligibility.targetRescueTerms
    if ($hasUnrelatedTitle -and -not $hasTargetRescue) {
        $rejections.Add('Unrelated engineering discipline')
    }

    $sourceKinds = @((Get-ObjectValue $Job @('SourceKinds') @()))
    $directKinds = @('greenhouse', 'lever', 'ashby')
    $aggregatorKinds = @('landing', 'minisite', 'search', 'detail')
    $isDirectJob = @($sourceKinds | Where-Object { $directKinds -contains [string]$_ }).Count -gt 0
    $hasAggregatorSource = @($sourceKinds | Where-Object { $aggregatorKinds -contains [string]$_ }).Count -gt 0
    if ($isDirectJob -and -not $hasAggregatorSource) {
        if (-not (Test-IsUnitedStatesLocation -Job $Job)) {
            $rejections.Add('A United States location could not be verified')
        }
    }
    else {
        $hasExplicitNonUs = Test-AnyTerm $location $Config.eligibility.explicitNonUsTerms
        $hasUsSignal = Test-AnyTerm $location $Config.eligibility.usTerms
        if ($hasExplicitNonUs -and -not $hasUsSignal) {
            $rejections.Add('Location is outside the United States')
        }
    }

    $experience = Get-RequiredExperience $Job
    if ($null -ne $experience.RequiredMinimumYears -and $experience.RequiredMinimumYears -ge 4) {
        $rejections.Add("Requires at least $($experience.RequiredMinimumYears) years of experience")
    }

    if ($allText -match 'u\.?s\.?\s+citizen|us\s+citizen|citizenship\s+required') {
        $warnings.Add('U.S. citizenship language is present')
    }
    if ($allText -match 'security\s+clearance|active\s+clearance') {
        $warnings.Add('Security clearance language is present')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Job.Sponsorship)) {
        $warnings.Add("Sponsorship: $($Job.Sponsorship)")
    }
    elseif ($allText -match '\b(visa sponsorship|employment sponsorship|sponsor(?:ship)? for)\b') {
        $warnings.Add('Sponsorship language is present')
    }
    if ($employment -match '\binferred\b') {
        $warnings.Add('Full-time status is inferred from the first-party posting')
    }
    return [pscustomobject][ordered]@{
        Eligible             = ($rejections.Count -eq 0)
        Rejections           = $rejections.ToArray()
        Warnings             = @($warnings | Select-Object -Unique)
        RequiredMinimumYears = $experience.RequiredMinimumYears
    }
}

function Get-JobFitScore {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Config
    )

    $titleText = Normalize-MatchText $Job.Title
    $allText = Normalize-MatchText (@(
        $Job.Title, $Job.Company, $Job.Requirements, $Job.Summary,
        $Job.Responsibilities, $Job.Tags, $Job.Seniority
    ) -join ' ')

    $titlePoints = 0
    $families = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($Config.scoring.titlePhrases)) {
        if (Test-AnyTerm $titleText $group.terms) {
            $titlePoints = [Math]::Max($titlePoints, [int]$group.points)
            $families.Add([string]$group.family)
        }
    }
    $titlePoints = [Math]::Min($titlePoints, [int]$Config.scoring.titleMaximum)

    $skillPoints = 0
    $skills = New-Object System.Collections.Generic.List[string]
    foreach ($cluster in @($Config.scoring.skillClusters)) {
        if (Test-AnyTerm $allText $cluster.terms) {
            $skillPoints += [int]$cluster.points
            $skills.Add([string]$cluster.name)
        }
    }
    $skillPoints = [Math]::Min($skillPoints, [int]$Config.scoring.skillMaximum)

    $domainPoints = 0
    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($cluster in @($Config.scoring.domainClusters)) {
        if (Test-AnyTerm $allText $cluster.terms) {
            $domainPoints += [int]$cluster.points
            $domains.Add([string]$cluster.name)
        }
    }
    $domainPoints = [Math]::Min($domainPoints, [int]$Config.scoring.domainMaximum)

    $earlyCareerPoints = 0
    if (Test-AnyTerm $allText $Config.scoring.earlyCareerTerms) {
        $earlyCareerPoints = 7
    }
    elseif (@($Job.SourceKinds) -contains 'minisite') {
        $earlyCareerPoints = 4
    }
    if (Test-AnyTerm $allText $Config.scoring.graduationTerms) {
        $earlyCareerPoints += 3
    }
    $earlyCareerPoints = [Math]::Min($earlyCareerPoints, [int]$Config.scoring.earlyCareerMaximum)

    $experience = Get-RequiredExperience $Job
    $penalty = 0
    if ($experience.RequiredMinimumYears -eq 3) {
        $penalty = [int]$Config.scoring.threeYearPenalty
    }

    $score = [Math]::Max(0, [Math]::Min(100, $titlePoints + $skillPoints + $domainPoints + $earlyCareerPoints - $penalty))
    $tier = if ($score -ge 70) { 'Strong' } elseif ($score -ge 50) { 'Good' } elseif ($score -ge 30) { 'Possible' } else { 'Below threshold' }

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($families.Count -gt 0) {
        $reasons.Add('Role: ' + (($families | Select-Object -Unique) -join ', '))
    }
    if ($skills.Count -gt 0) {
        $reasons.Add('Skills: ' + (($skills | Select-Object -Unique) -join ', '))
    }
    if ($domains.Count -gt 0) {
        $reasons.Add('Domain: ' + (($domains | Select-Object -Unique) -join ', '))
    }
    if ($earlyCareerPoints -gt 0) {
        $reasons.Add('Early-career alignment')
    }
    if ($penalty -gt 0) {
        $reasons.Add("Penalty: explicit 3-year requirement (-$penalty)")
    }

    return [pscustomobject][ordered]@{
        Score     = [int]$score
        Tier      = $tier
        Breakdown = [pscustomobject][ordered]@{
            TitleRole   = [int]$titlePoints
            Skills      = [int]$skillPoints
            Domain      = [int]$domainPoints
            EarlyCareer = [int]$earlyCareerPoints
            Penalty     = [int]$penalty
        }
        Reasons   = $reasons.ToArray()
    }
}

function Get-JobEvaluation {
    param(
        [Parameter(Mandatory = $true)]$Job,
        [Parameter(Mandatory = $true)]$Config,
        [switch]$AllowUnknownEmployment
    )

    $eligibility = Test-JobEligibility -Job $Job -Config $Config -AllowUnknownEmployment:$AllowUnknownEmployment
    $fit = Get-JobFitScore -Job $Job -Config $Config
    return [pscustomobject][ordered]@{
        Eligible             = $eligibility.Eligible
        Rejections           = $eligibility.Rejections
        Warnings             = $eligibility.Warnings
        RequiredMinimumYears = $eligibility.RequiredMinimumYears
        Score                = $fit.Score
        Tier                 = $fit.Tier
        Breakdown            = $fit.Breakdown
        Reasons              = $fit.Reasons
        ShouldAlert          = ($eligibility.Eligible -and $fit.Score -ge [int]$Config.fitThreshold)
    }
}

function ConvertTo-HashtableRecursive {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[[string]$key] = ConvertTo-HashtableRecursive $InputObject[$key]
        }
        return $hash
    }
    if ($InputObject -is [pscustomobject]) {
        $hash = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $hash[$property.Name] = ConvertTo-HashtableRecursive $property.Value
        }
        return $hash
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-HashtableRecursive $_ })
    }
    return $InputObject
}

function Read-JsonHashtable {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }
    return ConvertTo-HashtableRecursive ($raw | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 20
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $json = $Value | ConvertTo-Json -Depth $Depth
    $temporary = "$Path.tmp"
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, $script:Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-MonitorSourceRequest {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [int]$RetryCount = 3
    )

    $started = [DateTime]::UtcNow
    $isJsonSource = @('greenhouse', 'greenhouse_detail', 'lever', 'ashby') -contains [string]$Source.Kind
    $headers = @{
        'Accept'          = if ($isJsonSource) { 'application/json' } else { 'text/html,application/xhtml+xml' }
        'Accept-Language' = 'en-US,en;q=0.8'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Source.ETag)) {
        $headers['If-None-Match'] = [string]$Source.ETag
    }

    $lastError = $null
    $lastStatusCode = 0
    $timeoutSeconds = [int](Get-ObjectValue $Source @('TimeoutSec') 25)
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $Source.Url `
                -Headers $headers `
                -UserAgent 'SignalPathJobMonitor/1.0 (+public hardware job alerts; respectful hourly polling)' `
                -TimeoutSec $timeoutSeconds `
                -UseBasicParsing
            return [pscustomobject][ordered]@{
                Id          = $Source.Id
                Kind        = $Source.Kind
                Company     = [string](Get-ObjectValue $Source @('Company') '')
                BoardToken  = [string](Get-ObjectValue $Source @('BoardToken') '')
                SourceTags  = [string](Get-ObjectValue $Source @('SourceTags') '')
                CareersUrl  = [string](Get-ObjectValue $Source @('CareersUrl') '')
                OriginalSourceId = [string](Get-ObjectValue $Source @('OriginalSourceId') '')
                Url         = $Source.Url
                Success     = $true
                NotModified = $false
                StatusCode  = [int]$response.StatusCode
                ETag        = [string]$response.Headers['ETag']
                Content     = [string]$response.Content
                Error       = $null
                DurationMs  = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
            }
        }
        catch {
            $statusCode = 0
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = 0
            }
            $lastStatusCode = $statusCode
            if ($statusCode -eq 304) {
                return [pscustomobject][ordered]@{
                    Id          = $Source.Id
                    Kind        = $Source.Kind
                    Company     = [string](Get-ObjectValue $Source @('Company') '')
                    BoardToken  = [string](Get-ObjectValue $Source @('BoardToken') '')
                    SourceTags  = [string](Get-ObjectValue $Source @('SourceTags') '')
                    CareersUrl  = [string](Get-ObjectValue $Source @('CareersUrl') '')
                    OriginalSourceId = [string](Get-ObjectValue $Source @('OriginalSourceId') '')
                    Url         = $Source.Url
                    Success     = $true
                    NotModified = $true
                    StatusCode  = 304
                    ETag        = [string]$Source.ETag
                    Content     = ''
                    Error       = $null
                    DurationMs  = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
                }
            }
            $lastError = $_.Exception.Message
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $attempt
            }
        }
    }

    return [pscustomobject][ordered]@{
        Id          = $Source.Id
        Kind        = $Source.Kind
        Company     = [string](Get-ObjectValue $Source @('Company') '')
        BoardToken  = [string](Get-ObjectValue $Source @('BoardToken') '')
        SourceTags  = [string](Get-ObjectValue $Source @('SourceTags') '')
        CareersUrl  = [string](Get-ObjectValue $Source @('CareersUrl') '')
        OriginalSourceId = [string](Get-ObjectValue $Source @('OriginalSourceId') '')
        Url         = $Source.Url
        Success     = $false
        NotModified = $false
        StatusCode  = $lastStatusCode
        ETag        = [string]$Source.ETag
        Content     = ''
        Error       = $lastError
        DurationMs  = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
    }
}

function Test-LandingPage {
    param([Parameter(Mandatory = $true)][string]$Html)

    return (
        $Html -match 'data-job-path=["'']/us/engineering_development["'']' -and
        $Html -match 'short-link=["'']eng["'']'
    )
}

function Get-MonitorStatus {
    param(
        [Parameter(Mandatory = $true)][bool]$LandingHealthy,
        [Parameter(Mandatory = $true)][bool]$FeedHealthy,
        [Parameter(Mandatory = $true)][int]$SearchSuccesses,
        [Parameter(Mandatory = $true)][int]$SearchTotal,
        [Parameter(Mandatory = $true)][bool]$Initialized,
        [Parameter(Mandatory = $true)][int]$DiscoveredJobs
    )

    if ((-not $FeedHealthy) -and $SearchSuccesses -eq 0) {
        return 'failed'
    }
    if ((-not $Initialized) -and $DiscoveredJobs -eq 0) {
        return 'failed'
    }
    if (-not $LandingHealthy -or -not $FeedHealthy -or $SearchSuccesses -lt $SearchTotal) {
        return 'degraded'
    }
    return 'healthy'
}

function Add-AlertRecords {
    param(
        [Parameter(Mandatory = $true)][string]$AlertsDirectory,
        [Parameter(Mandatory = $true)]$Alerts
    )

    if (-not (Test-Path -LiteralPath $AlertsDirectory)) {
        [void](New-Item -ItemType Directory -Path $AlertsDirectory -Force)
    }
    foreach ($alert in $Alerts) {
        $timestamp = [DateTimeOffset]::Parse($alert.DiscoveredUtc)
        $fileName = $timestamp.UtcDateTime.ToString('yyyy-MM') + '.jsonl'
        $path = Join-Path $AlertsDirectory $fileName
        $line = $alert | ConvertTo-Json -Depth 15 -Compress
        [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, $script:Utf8NoBom)
    }
}

function Update-AlertManifest {
    param(
        [Parameter(Mandatory = $true)][string]$AlertsDirectory,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $months = New-Object System.Collections.Generic.List[object]
    $latestSequence = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $AlertsDirectory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $sequences = New-Object System.Collections.Generic.List[int]
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $record = $line | ConvertFrom-Json
                $sequences.Add([int]$record.Sequence)
            }
            catch {
                throw "Invalid JSONL in $($file.FullName): $($_.Exception.Message)"
            }
        }
        if ($sequences.Count -gt 0) {
            $minimum = ($sequences | Measure-Object -Minimum).Minimum
            $maximum = ($sequences | Measure-Object -Maximum).Maximum
            $latestSequence = [Math]::Max($latestSequence, $maximum)
            $months.Add([pscustomobject][ordered]@{
                File        = $file.Name
                Minimum     = [int]$minimum
                Maximum     = [int]$maximum
                RecordCount = [int]$sequences.Count
            })
        }
    }

    $manifest = [pscustomobject][ordered]@{
        Version        = 1
        UpdatedUtc     = [DateTime]::UtcNow.ToString('o')
        LatestSequence = [int]$latestSequence
        Months         = $months.ToArray()
    }
    Write-JsonFile -Path $ManifestPath -Value $manifest
    return $manifest
}

function Escape-MarkdownCell {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return ''
    }
    return (($Value -replace '\|', '\|') -replace "`r?`n", ' ')
}

function Write-LatestReport {
    param(
        [Parameter(Mandatory = $true)][string]$AlertsDirectory,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [int]$Limit = 100
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $AlertsDirectory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 3)) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $records.Add(($line | ConvertFrom-Json))
            }
            catch {
                continue
            }
        }
    }

    $latest = @($records | Sort-Object Sequence -Descending | Select-Object -First $Limit)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Full-Time Hardware Job Matches')
    $lines.Add('')
    $lines.Add("Updated: $([DateTime]::UtcNow.ToString('u')) UTC")
    $lines.Add('')
    if ($latest.Count -eq 0) {
        $lines.Add('No jobs have met the configured 30-point threshold yet.')
    }
    else {
        $lines.Add('| Score | Role | Company | Location | Posted | Warnings |')
        $lines.Add('|---:|---|---|---|---|---|')
        foreach ($record in $latest) {
            $title = Escape-MarkdownCell $record.Title
            $company = Escape-MarkdownCell $record.Company
            $location = Escape-MarkdownCell $record.Location
            $warnings = Escape-MarkdownCell ((@($record.Warnings) -join '; '))
            $posted = Escape-MarkdownCell $record.PostedUtc
            $lines.Add("| $($record.FitScore) ($($record.Tier)) | [$title]($($record.DetailUrl)) | $company | $location | $posted | $warnings |")
        }
    }

    $directory = Split-Path -Parent $ReportPath
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    [System.IO.File]::WriteAllLines($ReportPath, $lines, $script:Utf8NoBom)
}

Export-ModuleMember -Function @(
    'Add-AlertRecords',
    'ConvertTo-HashtableRecursive',
    'Get-AshbyJobsFromJson',
    'Get-GreenhouseJobsFromJson',
    'Get-JobEvaluation',
    'Get-JobFitScore',
    'Get-LeverJobsFromJson',
    'Get-MinisiteJobsFromHtml',
    'Get-MonitorStatus',
    'Get-NextDataPageProps',
    'Get-ObjectValue',
    'Get-SearchJobsFromHtml',
    'Invoke-MonitorSourceRequest',
    'Merge-NormalizedJobs',
    'Normalize-MatchText',
    'Read-JsonHashtable',
    'Test-IsUnitedStatesLocation',
    'Test-JobEligibility',
    'Test-LandingPage',
    'Update-AlertManifest',
    'Write-JsonFile',
    'Write-LatestReport'
)
