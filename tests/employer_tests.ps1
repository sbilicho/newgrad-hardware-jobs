param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ProjectRoot 'lib/JobMonitor.psm1') -Force -DisableNameChecking
$config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config/targets.json') -Raw | ConvertFrom-Json
function Assert-Employer($Condition, $Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$fixtures = @{
    records = @(
        @{ jobPostingInfo = @{ id = 'a'; jobReqId = 'R1'; title = 'ASIC Verification Engineer'; location = 'USA-CA-San-Jose'; country = @{ descriptor = 'United States of America' }; timeType = 'Full time'; startDate = '2026-10-20'; jobDescription = '<p>New Grad MSEE/CS OR BSEE/CS with 5+ years of experience. SystemVerilog and ASIC simulation.</p>'; externalUrl = 'https://example.test/job/R1' } },
        @{ jobPostingInfo = @{ id = 'b'; jobReqId = 'R2'; title = 'IC Design Engineer'; location = 'Bengaluru, India'; country = @{ descriptor = 'India' }; timeType = 'Full time'; startDate = '2026-10-20'; jobDescription = '<p>Entry-level CMOS circuit design.</p>'; externalUrl = 'https://example.test/job/R2' } },
        @{ jobPostingInfo = @{ id = 'c'; jobReqId = 'R3'; title = 'EDA Software Engineer'; location = 'Austin, TX'; country = @{ descriptor = 'United States' }; timeType = 'Full time'; startDate = '2026-10-20'; jobDescription = '<p>Python STA prototype and NLDM interpolation.</p>'; externalUrl = 'https://example.test/job/R3' } }
    )
} | ConvertTo-Json -Depth 10
$jobs = @(Get-WorkdayJobsFromJson -Json $fixtures -Company 'Example Semiconductor' -BoardToken 'example' -SourceId 'company_example' -SourceUrl 'https://example.test/jobs' -SourceTags 'ASIC semiconductor')
Assert-Employer ($jobs.Count -eq 3) 'Workday parser retains all detail records'
Assert-Employer ($jobs[0].Id -eq 'workday:example:R1') 'Workday requisition IDs remain stable'
Assert-Employer ((Get-JobEvaluation -Job $jobs[0] -Config $config).ShouldAlert) 'New-grad masters alternative is eligible despite five-year bachelor requirement'
Assert-Employer (-not (Get-JobEvaluation -Job $jobs[1] -Config $config).ShouldAlert) 'Workday non-U.S. jobs are rejected'
$costaRica = $jobs[0].PSObject.Copy(); $costaRica.Location = 'Costa Rica, San Jose'; $costaRica.Country = 'Costa Rica'
Assert-Employer (-not (Get-JobEvaluation -Job $costaRica -Config $config).ShouldAlert) 'San Jose in Costa Rica is not mistaken for California'
Assert-Employer (-not (Test-IsUnitedStatesLocation -Job ([pscustomobject]@{Location='Costa Rica, San Jose';Country=''}))) 'Explicit non-U.S. geography overrides city-only fallback'
Assert-Employer ((Get-JobEvaluation -Job $jobs[2] -Config $config).ShouldAlert) 'Resume-supported EDA software role crosses threshold'
$civilCad = $jobs[2].PSObject.Copy(); $civilCad.Title = 'CAD Engineer - Entry Level'; $civilCad.Requirements = 'Civil drafting of track geometry and construction drawings.'
Assert-Employer (-not (Get-JobEvaluation -Job $civilCad -Config $config).Eligible) 'Civil CAD roles do not enter the expanded EDA search'
$mastersJob = $jobs[0].PSObject.Copy()
$mastersJob.Requirements = "Bachelor's with 5 years OR Master's with 2 years of experience."
Assert-Employer ((Get-JobEvaluation -Job $mastersJob -Config $config).Eligible) 'Masters two-year alternative is retained'
$senior = $jobs[0].PSObject.Copy(); $senior.Title = 'Senior ASIC Verification Engineer'
Assert-Employer (-not (Get-JobEvaluation -Job $senior -Config $config).Eligible) 'Senior-only title still rejected'
$malformed = $false
try { [void](Get-WorkdayJobsFromJson -Json '{"jobPostings":[]}' -Company Test -BoardToken test -SourceId test) } catch { $malformed = $true }
Assert-Employer $malformed 'Workday schema drift fails visibly'
$eightfold = '{"data":{"positions":[{"id":"e1","name":"EDA Applications Engineer","location":"San Diego, CA","employment_type":"Full-time","description":"ASIC Python characterization automation and circuit simulation."},{"id":"e2","name":"ASIC Engineer","location":"San Diego, CA"}]}}'
$ef = @(Get-EightfoldJobsFromJson -Json $eightfold -Company Qualcomm -BoardToken 'qualcomm.com' -SourceId company_qualcomm -SourceTags 'ASIC semiconductor')
Assert-Employer ($ef.Count -eq 1) 'Eightfold summary-only listings cannot produce unverified alerts'
Assert-Employer ((Get-JobEvaluation -Job $ef[0] -Config $config).ShouldAlert) 'Verified Eightfold detail can alert'
$unknownType = $ef[0].PSObject.Copy(); $unknownType.EmploymentType = ''
Assert-Employer (-not (Get-JobEvaluation -Job $unknownType -Config $config).ShouldAlert) 'Unknown employment is rejected rather than assumed full-time'
$preferredJob = $jobs[0].PSObject.Copy(); $preferredJob.Requirements = 'Minimum Qualifications: MSEE. Preferred Qualifications: 5+ years of experience.'
Assert-Employer ((Get-JobEvaluation -Job $preferredJob -Config $config).Eligible) 'Preferred experience does not become a required minimum'
$metadata = Get-PublicJobPostingMetadata -Html '<script type="application/ld+json">{"@type":"JobPosting","employmentType":"FULL_TIME"}</script>'
Assert-Employer ($metadata.employmentType -eq 'FULL_TIME') 'Official job-page metadata verifies full-time status'

& (Get-Module JobMonitor) {
    $original = (Get-Item Function:Invoke-EmployerJsonRequest).ScriptBlock
    try {
        Set-Item Function:script:Invoke-EmployerJsonRequest -Value {
            param($Url, $Method = 'Get', $Body)
            if ($Method -eq 'Post') {
                if ($Body.offset -eq 0) {
                    $items = @(1..19 | ForEach-Object { [pscustomobject]@{ title = 'EDA Engineer'; externalPath = "/job/US-CA/EDA_R$_"; locationsText = 'Austin, TX' } })
                    $items += [pscustomobject]@{ bulletFields = @('deleted') }
                    return [pscustomobject]@{ total = 21; facets = @(); jobPostings = $items }
                }
                return [pscustomobject]@{ total = 0; facets = @(); jobPostings = @([pscustomobject]@{ title = 'EDA Engineer'; externalPath = '/job/US-CA/EDA_R20'; locationsText = 'Austin, TX' }) }
            }
            return [pscustomobject]@{ jobPostingInfo = [pscustomobject]@{ id = $Url; title = 'EDA Engineer'; location = 'Austin, TX'; timeType = 'Full time' } }
        }
        $source = [pscustomobject]@{ Id = 'fixture'; Kind = 'workday'; Company = 'Fixture'; BoardToken = 'fixture'; SourceTags = ''; CareersUrl = 'https://example.test/'; Url = 'https://example.test/jobs'; Queries = @(''); MaxPages = 3; MaxDetails = 30; TitlePattern = 'EDA'; VerifiedIds = @() }
        $response = Invoke-WorkdaySourceRequest -Source $source
        if (-not $response.Success) { throw $response.Error }
        $records = ($response.Content | ConvertFrom-Json).records
        if (@($records).Count -ne 20) { throw 'Workday pagination skipped valid later-page records.' }
        if (-not $response.Warning) { throw 'Retired listing placeholder was not disclosed.' }
        Write-Host 'PASS: Later-page zero totals and retired placeholders preserve all valid jobs'
    }
    finally { Set-Item Function:script:Invoke-EmployerJsonRequest -Value $original }
}
Write-Host 'All employer adapter checks passed.'
