$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/HiringResearch.psm1') -Force
function Assert-Research($Condition, $Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$existing = Get-Content -LiteralPath (Join-Path $root 'config/outreach.json') -Raw | ConvertFrom-Json
$lead = [pscustomobject]@{ person='Hiring team';company='Example Silicon';role='RTL engineer';location='Austin, TX';url='https://example.test/jobs/1';evidence='Public hiring announcement';observedAge='Date unconfirmed';verification='Public page reviewed';caution='Confirm January start';message='Hello, is the team considering new graduates?' }
$incoming = [pscustomobject]@{ queries=@('public ASIC hiring USA');leads=@($lead) }
$researchConfig = Get-Content -LiteralPath (Join-Path $root 'config/hiring_research.json') -Raw | ConvertFrom-Json
$names = @(1..20 | ForEach-Object { 'SiliconCompany' + $_ })
$plan = @(Get-HiringResearchPlan -Config $researchConfig -CompanyNames $names -RunNumber 0)
$nextPlan = @(Get-HiringResearchPlan -Config $researchConfig -CompanyNames $names -RunNumber 1)
Assert-Research ($plan.Count -eq 16) 'Expanded research plans 16 bounded queries'
Assert-Research (@($plan | Where-Object { $_ -match '^site:linkedin.com/posts/' }).Count -ge 12) 'Research prioritizes public LinkedIn posts rather than job listings'
Assert-Research (($plan -join ' ') -match 'Broadcom.*Intel.*Qualcomm') 'Major semiconductor employers remain in every research run'
Assert-Research (($plan -join ' ') -ne ($nextPlan -join ' ')) 'Company and startup cohorts rotate between successful runs'
Assert-Research (Test-HiringResearchPayload $incoming) 'Valid public U.S. hiring lead is accepted'
$bad = $lead.PSObject.Copy(); $bad.url = 'file:///C:/private.txt'
$rejected = $false; try { Test-HiringResearchPayload ([pscustomobject]@{queries=@('q');leads=@($bad)})|Out-Null } catch { $rejected=$true }
Assert-Research $rejected 'Non-HTTPS lead URL is rejected'
$bad = $lead.PSObject.Copy(); $bad.location = 'Bengaluru, India'
$rejected = $false; try { Test-HiringResearchPayload ([pscustomobject]@{queries=@('q');leads=@($bad)})|Out-Null } catch { $rejected=$true }
Assert-Research $rejected 'Lead without U.S. geography is rejected'
$bad = $lead.PSObject.Copy(); $bad.message = 'Send mail to private@example.com'
$rejected = $false; try { Test-HiringResearchPayload ([pscustomobject]@{queries=@('q');leads=@($bad)})|Out-Null } catch { $rejected=$true }
Assert-Research $rejected 'Email addresses are kept out of published research'
$rejected = $false; try { Test-HiringResearchPayload ([pscustomobject]@{queries=@('private@example.com');leads=@()}) | Out-Null } catch { $rejected=$true }
Assert-Research $rejected 'Search-query history cannot publish private email addresses'
$rejected = $false; try { Test-HiringResearchPayload ([pscustomobject]@{queries=@('q');leads=@(1..25 | ForEach-Object { $lead.PSObject.Copy() })}) | Out-Null } catch { $rejected=$true }
Assert-Research $rejected 'Research output stays within the 24-lead limit'
$people = Get-Content -LiteralPath (Join-Path $root 'outreach/manual-people-2026-10-26.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Research (Test-HiringResearchPayload $people) 'Reviewed people leads pass the geography and public-data guardrails'
$kindSample = Merge-HiringResearch -Existing ([pscustomobject]@{leads=@();researchedOn='2026-10-26';scope=''}) -Incoming $people
Assert-Research (@($kindSample.leads | Where-Object { $_.sourceKind -eq 'linkedin_post' }).Count -eq 1) 'A direct LinkedIn post is labeled separately from profiles'
Assert-Research (@($kindSample.leads | Where-Object { $_.sourceKind -eq 'indexed_profile' }).Count -eq 3) 'Indexed profile activity is not mislabeled as original posts'
$now = [DateTime]::Parse('2026-10-26T12:00:00Z').ToUniversalTime()
$originalCount = @($existing.leads).Count
$merged = Merge-HiringResearch -Existing $existing -Incoming $incoming -Now $now
Assert-Research (@($merged.leads).Count -eq $originalCount+1) 'Earlier leads are preserved when new research arrives'
$again = Merge-HiringResearch -Existing $merged -Incoming $incoming -Now $now.AddHours(12)
Assert-Research (@($again.leads).Count -eq $originalCount+1) 'Repeated lead URLs do not create duplicates'
Assert-Research ($again.automation.lastSuccessfulResearchUtc -eq $now.AddHours(12).ToString('o')) 'Research freshness advances only after validated research'
$empty = [pscustomobject]@{queries=@('No supported leads found');leads=@()}
$noNew = Merge-HiringResearch -Existing $again -Incoming $empty -Now $now.AddDays(1)
Assert-Research (@($noNew.leads).Count -eq $originalCount+1) 'An empty search preserves the existing outreach list'
