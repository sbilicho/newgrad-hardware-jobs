$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts/HiringResearch.psm1') -Force
function Assert-Research($Condition, $Message) { if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$existing = Get-Content -LiteralPath (Join-Path $root 'config/outreach.json') -Raw | ConvertFrom-Json
$lead = [pscustomobject]@{ person='Hiring team';company='Example Silicon';role='RTL engineer';location='Austin, TX';url='https://example.test/jobs/1';evidence='Public hiring announcement';observedAge='Date unconfirmed';verification='Public page reviewed';caution='Confirm January start';message='Hello, is the team considering new graduates?' }
$incoming = [pscustomobject]@{ queries=@('public ASIC hiring USA');leads=@($lead) }
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
