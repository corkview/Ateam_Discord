<#
.SYNOPSIS
    Posts today's USD economic events from Forex Factory to Discord with live countdowns.

.DESCRIPTION
    Downloads ff_calendar_thisweek.csv, filters for USD + today (ET), and posts
    a colored Discord embed via webhook. Each event line uses Discord's dynamic
    <t:UNIX:R> timestamps so every client renders a live countdown.

    Designed to run on GitHub Actions (ubuntu-latest, pwsh) with no local files.
    Works locally on Windows too.

.NOTES
    Webhook URL must be supplied via $env:DISCORD_WEBHOOK_URL (GH Actions secret).
#>

[CmdletBinding()]
param(
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL,
    [string]$CsvUrl     = 'https://nfs.faireconomy.media/ff_calendar_thisweek.csv',
    [string]$Country    = 'USD'
)

$ErrorActionPreference = 'Stop'

if (-not $WebhookUrl) {
    throw "DISCORD_WEBHOOK_URL is not set. Configure it as a GH Actions secret or local env var."
}

# --- Timezone setup --------------------------------------------------
# Forex Factory's public CSV (ff_calendar_thisweek.csv) reports times in UTC
# and dates as UTC calendar days. We display via Discord dynamic timestamps,
# which render in each viewer's local zone automatically — no server-side
# conversion needed for display. ET is used only for the "today" header and
# the workday filter (to match the user's local concept of "today").
$EtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)
$NowEt   = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $EtZone)
$TodayEt = $NowEt.Date

# --- Download CSV ----------------------------------------------------
Write-Host "Fetching $CsvUrl"
$csvText = Invoke-RestMethod -Uri $CsvUrl -Method Get
$rows    = $csvText | ConvertFrom-Csv

# --- Filter to today's USD events -----------------------------------
$todays = foreach ($r in $rows) {
    if ($r.Country -ne $Country) { continue }

    # Date is MM-DD-YYYY in the FF feed.
    $eventDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
            [string]$r.Date, [string]'MM-dd-yyyy',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$eventDate)) {
        continue
    }
    if ($eventDate.Date -ne $TodayEt) { continue }

    # Time may be "8:30am", "All Day", "Tentative", or blank. Only the first parses.
    $eventUtc      = $null
    $hasParsedTime = $false
    $parsedTime    = [datetime]::MinValue
    $timeFormats   = [string[]]@('h:mmtt','htt')
    if ([datetime]::TryParseExact(
            [string]$r.Time, $timeFormats,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedTime)) {
        # CSV times are already UTC; mark Kind=Utc so DateTimeOffset reads correctly.
        $eventUtc = [datetime]::SpecifyKind(
            $eventDate.Date.Add($parsedTime.TimeOfDay),
            [System.DateTimeKind]::Utc)
        $hasParsedTime = $true
    }

    [pscustomobject]@{
        Title     = $r.Title
        Impact    = $r.Impact
        Forecast  = $r.Forecast
        Previous  = $r.Previous
        TimeRaw   = $r.Time
        HasTime   = $hasParsedTime
        EventUtc  = $eventUtc
    }
}

# Sort: timed events by time, all-day/tentative at the end.
$todays = @($todays | Sort-Object @{Expression = { -not $_.HasTime }}, EventUtc)

# --- Build embed description (markdown) -----------------------------
# Using description instead of fields so events without Forecast/Previous
# data take a single line — no awkward empty rows.
function Get-ImpactEmoji([string]$impact) {
    switch ($impact.ToLower()) {
        'high'    { '🔴' }
        'medium'  { '🟠' }
        'low'     { '🟡' }
        'holiday' { '🏖️' }
        default   { '⚪' }
    }
}

$lines = @()
foreach ($e in $todays) {
    $emoji = Get-ImpactEmoji $e.Impact

    if ($e.HasTime) {
        $etTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($e.EventUtc, $EtZone)
        $lines += "$emoji **$($etTime.ToString('h:mm tt'))** — $($e.Title)"
    }
    else {
        $lines += "$emoji **$($e.TimeRaw)** — $($e.Title)"
    }

    $details = @()
    if ($e.Forecast) { $details += "Forecast: $($e.Forecast)" }
    if ($e.Previous) { $details += "Previous: $($e.Previous)" }
    if ($details.Count) {
        $lines += "      $($details -join ' | ')"
    }
}

# --- Embed color by highest impact ----------------------------------
$color = 8421504  # gray (default / no news)
if ($todays.Count -gt 0) {
    $impacts = $todays.Impact
    if ($impacts -contains 'High')        { $color = 15147282 }   # red
    elseif ($impacts -contains 'Medium')  { $color = 15105570 }   # orange
    elseif ($impacts -contains 'Low')     { $color = 15844367 }   # yellow
}

$dayHeader   = $NowEt.ToString('dddd, MMM. d')
$description = if ($todays.Count -eq 0) { 'No scheduled economic releases.' } else { $lines -join "`n" }

$embed = @{
    title       = "**__ $dayHeader __**"
    color       = $color
    description = $description
}

# --- Post to Discord -------------------------------------------------
$payload = @{
    embeds           = @($embed)
    allowed_mentions = @{ parse = @() }   # never ping @everyone/@here by accident
} | ConvertTo-Json -Depth 8

Invoke-RestMethod -Uri $WebhookUrl `
                  -Method Post `
                  -ContentType 'application/json; charset=utf-8' `
                  -Body $payload | Out-Null

Write-Host ("Posted {0} USD event(s) for {1}." -f $todays.Count, $TodayEt.ToString('yyyy-MM-dd'))
