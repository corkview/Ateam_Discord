<#
.SYNOPSIS
    Sunday evening post: this week's USD Med/High events grouped by day,
    plus upcoming-closure notices, plus an ephemeral "Futures Open" warning
    that auto-deletes ~1 min after 6:00 PM ET.
#>

[CmdletBinding()]
param(
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL,
    [string]$CsvUrl     = 'https://nfs.faireconomy.media/ff_calendar_thisweek.csv',
    [string]$Country    = 'USD'
)

$ErrorActionPreference = 'Stop'
if (-not $WebhookUrl) { throw "DISCORD_WEBHOOK_URL is not set." }

. (Join-Path $PSScriptRoot 'Market-Calendar.ps1')

$EtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)
$nowEt = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $EtZone)
$today = $nowEt.Date

# Week starts Sunday. Anchor on current week's Sunday → today..today+6 when run Sunday.
$dow       = [int]$today.DayOfWeek   # 0=Sun, 6=Sat
$weekStart = $today.AddDays(-$dow)
$weekEnd   = $weekStart.AddDays(6)
$weekLabel = $weekStart.ToString('MMM d')

# --- Fetch + parse FF CSV (USD, Med/High, this week) ---------------
Write-Host "Fetching $CsvUrl"
$csvText = Invoke-RestMethod -Uri $CsvUrl
$rows    = $csvText | ConvertFrom-Csv

$events = @()
foreach ($r in $rows) {
    if ($r.Country -ne $Country) { continue }
    if ($r.Impact -ne 'High' -and $r.Impact -ne 'Medium') { continue }

    $eventDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$r.Date, [string]'MM-dd-yyyy',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$eventDate)) { continue }
    if ($eventDate -lt $weekStart -or $eventDate -gt $weekEnd) { continue }

    $parsedTime  = [datetime]::MinValue
    $timeFormats = [string[]]@('h:mmtt','htt')
    $hasTime     = [datetime]::TryParseExact([string]$r.Time, $timeFormats,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref]$parsedTime)

    if ($hasTime) {
        $utcDt = [datetime]::SpecifyKind($eventDate.Date.Add($parsedTime.TimeOfDay), [System.DateTimeKind]::Utc)
        $etDt  = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcDt, $EtZone)
    } else {
        $etDt = $eventDate
    }

    $events += [pscustomobject]@{
        DateEt  = $etDt.Date
        TimeEt  = $etDt
        HasTime = $hasTime
        Impact  = $r.Impact
        Title   = $r.Title
    }
}

# --- Build week-ahead summary ---
$lines = @()
$lines += ":calendar_spiral: **Week of $weekLabel — Key Events**"

# Upcoming closures this week
$closureBlocks = @()
for ($i = 0; $i -le 6; $i++) {
    $checkDate = $weekStart.AddDays($i)
    $h = Get-MarketHoliday $checkDate
    if (-not $h) { continue }
    $f = Get-FuturesHolidaySchedule $checkDate
    $futStatus = if ($f -and $f.EarlyCloseEt) {
        $fh, $fm = $f.EarlyCloseEt.Split(':')
        $cT = (Get-Date 0).AddHours([int]$fh).AddMinutes([int]$fm)
        "Futures early close $($cT.ToString('h:mm tt')) ET"
    } elseif ($f -and $f.Note) { $f.Note } else { 'Futures status unknown' }
    $closureBlocks += ":warning: **$($checkDate.ToString('ddd MMM d')) — $h**`n   Equity closed | $futStatus"
}
if ($closureBlocks.Count) {
    $lines += ''
    $lines += ($closureBlocks -join "`n")
}

# Events grouped by day
$grouped = $events | Group-Object { $_.DateEt.ToString('yyyy-MM-dd') } | Sort-Object Name
if ($grouped.Count -gt 0) {
    foreach ($g in $grouped) {
        $dt = [datetime]$g.Name
        $lines += ''
        $lines += "**$($dt.ToString('ddd MMM d'))**"
        foreach ($e in $g.Group | Sort-Object @{Expression = { -not $_.HasTime }}, TimeEt) {
            $dot = if ($e.Impact -eq 'High') { ':red_circle:' } else { ':orange_circle:' }
            $timeStr = if ($e.HasTime) { $e.TimeEt.ToString('h:mm tt') } else { 'All Day' }
            $lines += "  $dot $timeStr — $($e.Title)"
        }
    }
} else {
    $lines += ''
    $lines += '_No Med/High USD events scheduled this week._'
}

$summaryContent = $lines -join "`n"
$summaryPayload = @{
    content          = $summaryContent
    allowed_mentions = @{ parse = @() }
} | ConvertTo-Json -Depth 5 -Compress

Invoke-RestMethod -Uri $WebhookUrl -Method Post `
    -ContentType 'application/json; charset=utf-8' -Body $summaryPayload | Out-Null
Write-Host "Posted week-ahead summary."

# --- Ephemeral futures-open warning -------------------------------
$openEt   = $today.AddHours(18)   # 6:00 PM ET tonight
$openUtc  = [System.TimeZoneInfo]::ConvertTimeToUtc(
    [datetime]::SpecifyKind($openEt, [DateTimeKind]::Unspecified), $EtZone)
$unix     = [int64]([datetimeoffset]$openUtc).ToUnixTimeSeconds()

$warningContent = ":bell: **US Futures Open** <t:$unix`:R>"
$warningPayload = @{
    content          = $warningContent
    allowed_mentions = @{ parse = @() }
} | ConvertTo-Json -Depth 5 -Compress

$postUrl = "$WebhookUrl" + "?wait=true"
$resp    = Invoke-RestMethod -Uri $postUrl -Method Post `
    -ContentType 'application/json; charset=utf-8' -Body $warningPayload
$msgId   = $resp.id
Write-Host "Posted futures-open warning (msg id=$msgId)."

# Sleep until ~1 min after 6:00 PM ET, then delete.
$deleteEt  = $openEt.AddMinutes(1)
$deleteUtc = [System.TimeZoneInfo]::ConvertTimeToUtc(
    [datetime]::SpecifyKind($deleteEt, [DateTimeKind]::Unspecified), $EtZone)
$sleepSec  = ($deleteUtc - [datetime]::UtcNow).TotalSeconds
if ($sleepSec -gt 0) {
    Write-Host "Sleeping $([int]$sleepSec) sec until $($deleteEt.ToString('HH:mm:ss')) ET..."
    Start-Sleep -Seconds ([int]$sleepSec)
}

try {
    Invoke-RestMethod -Uri "$WebhookUrl/messages/$msgId" -Method Delete | Out-Null
    Write-Host "Deleted futures-open warning."
} catch {
    Write-Warning "Failed to delete futures-open warning: $_"
}
