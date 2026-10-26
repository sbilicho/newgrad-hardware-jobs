[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'refresh_hiring_posts.ps1'
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powerShell -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
$triggers = @((New-ScheduledTaskTrigger -Daily -At '08:00'), (New-ScheduledTaskTrigger -Daily -At '20:00'), (New-ScheduledTaskTrigger -AtLogOn -User $user))
$phoenixDate = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'US Mountain Standard Time').ToString('yyyy-MM-dd')
$triggers[0].StartBoundary = "${phoenixDate}T08:00:00-07:00"
$triggers[1].StartBoundary = "${phoenixDate}T20:00:00-07:00"
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'Samarth-Hardware-Hiring-Post-Research' -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
    -Description 'Research public U.S. hardware hiring posts with the existing ChatGPT sign-in and publish validated leads. Runs at 08:00 and 20:00 Phoenix time and after login when due.' -Force | Out-Null
Write-Host 'Installed twice-daily public hiring-post research at 08:00 and 20:00 America/Phoenix.'
