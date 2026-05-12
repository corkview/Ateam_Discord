<#
.SYNOPSIS
    Posts a pre-event warning ~3 min before each USD Medium/High-impact economic
    event, then deletes that warning ~1 min after the event passes. Keeps the
    channel quiet between events.

.DESCRIPTION
    By default runs a single check. If $env:LOOP_DURATION_MINUTES is set, runs
    a long-lived loop that checks once per minute for that many minutes — used
    by the GitHub Actions watcher workflow on a public repo with unlimited
    Actions minutes.

    State (today's events + posted message IDs) persists between job runs via
    the Actions cache so warnings posted in the morning shift can be deleted
    by the afternoon shift.
#>

[CmdletBinding()]
param(
    [string]$WebhookUrl = $env:DISCORD_WEBHOOK_URL,
    [string]$CsvUrl     = 'https://nfs.faireconomy.media/ff_calendar_thisweek.csv',
    [string]$Country    = 'USD',
    [string]$StateFile  = $(if ($env:STATE_FILE) { $env:STATE_FILE } else { './state/watcher.json' })
)

$ErrorActionPreference = 'Stop'

if (-not $WebhookUrl) { throw "DISCORD_WEBHOOK_URL is not set." }

# Tuning ------------------------------------------------------------
$WarnWithinSec   = 180   # post a warning if event is within 3 min from now
$DeleteAfterSec  = 60    # delete the warning 1 min after event passes

# Timezone setup (shared across all loop iterations) ---------------
$EtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)

function New-EmptyState { @{ date = $null; events = @(); warnings = @() } }
function Get-EventKey($title, $eventUtcIso) { "$title|$eventUtcIso" }

function Invoke-WatcherTick {
    $nowUtc  = [datetime]::UtcNow
    $nowEt   = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $EtZone)
    $todayEt = $nowEt.Date.ToString('yyyy-MM-dd')

    $includeAll = ($env:INCLUDE_ALL_IMPACTS -eq 'true')

    # --- Load state ---
    $state = New-EmptyState
    if (Test-Path $StateFile) {
        try {
            $loaded = Get-Content $StateFile -Raw | ConvertFrom-Json
            $state = @{
                date        = [string]$loaded.date
                include_all = [bool]$loaded.include_all
                events      = @($loaded.events   | ForEach-Object {
                    $utcStr = if ($_.event_utc -is [datetime]) { $_.event_utc.ToUniversalTime().ToString('o') } else { [string]$_.event_utc }
                    @{ title = [string]$_.title; impact = [string]$_.impact; event_utc = $utcStr }
                })
                warnings    = @($loaded.warnings | ForEach-Object {
                    @{ event_key = [string]$_.event_key; message_id = [string]$_.message_id; deleted = [bool]$_.deleted }
                })
            }
        }
        catch {
            Write-Warning "State file unreadable, resetting: $_"
            $state = New-EmptyState
        }
    }

    # --- Refresh event list on new day or when filter mode changes ---
    if ($state.date -ne $todayEt -or $state.include_all -ne $includeAll) {
        Write-Host "[$($nowEt.ToString('HH:mm:ss'))] New day ($($state.date) -> $todayEt); fetching FF CSV."
        $csvText = Invoke-RestMethod -Uri $CsvUrl
        $rows    = $csvText | ConvertFrom-Csv

        $events = @()
        foreach ($r in $rows) {
            if ($r.Country -ne $Country) { continue }
            if (-not $includeAll -and $r.Impact -ne 'High' -and $r.Impact -ne 'Medium') { continue }

            $eventDate = [datetime]::MinValue
            if (-not [datetime]::TryParseExact(
                    [string]$r.Date, [string]'MM-dd-yyyy',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$eventDate)) { continue }

            $parsedTime  = [datetime]::MinValue
            $timeFormats = [string[]]@('h:mmtt','htt')
            if (-not [datetime]::TryParseExact(
                    [string]$r.Time, $timeFormats,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsedTime)) { continue }

            $eventUtc = [datetime]::SpecifyKind(
                $eventDate.Date.Add($parsedTime.TimeOfDay),
                [System.DateTimeKind]::Utc)

            $eventEt = [System.TimeZoneInfo]::ConvertTimeFromUtc($eventUtc, $EtZone)
            if ($eventEt.Date.ToString('yyyy-MM-dd') -ne $todayEt) { continue }

            $events += @{ title = $r.Title; impact = $r.Impact; event_utc = $eventUtc.ToString('o') }
        }

        $state.date        = $todayEt
        $state.include_all = $includeAll
        $state.events      = $events
        $state.warnings    = @()
        $mode = if ($includeAll) { 'ALL impacts' } else { 'Med/High' }
        Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Today has $($events.Count) USD event(s) ($mode)."
    }

    # --- Walk events; decide post / delete / skip ---
    foreach ($e in $state.events) {
        $key       = Get-EventKey $e.title $e.event_utc
        $eventUtc  = [datetime]::Parse($e.event_utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $secsUntil = ($eventUtc - $nowUtc).TotalSeconds
        $warning   = $state.warnings | Where-Object { $_.event_key -eq $key } | Select-Object -First 1

        if (-not $warning) {
            if ($secsUntil -gt 0 -and $secsUntil -le $WarnWithinSec) {
                $unix    = [int64]([datetimeoffset]$eventUtc).ToUnixTimeSeconds()
                $dot     = if ($e.impact -eq 'High') { ':red_circle:' } else { ':orange_circle:' }
                $content = "$dot **$($e.title)** releases <t:$unix`:R>"

                $payload = @{
                    content          = $content
                    allowed_mentions = @{ parse = @() }
                } | ConvertTo-Json -Depth 5 -Compress

                $postUrl  = "$WebhookUrl" + "?wait=true"
                $response = Invoke-RestMethod -Uri $postUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $payload

                $state.warnings += @{
                    event_key  = $key
                    message_id = $response.id
                    deleted    = $false
                }
                Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Posted warning: $($e.title) (in $([int]$secsUntil)s)"
            }
        }
        elseif (-not $warning.deleted) {
            if ($secsUntil -lt -$DeleteAfterSec) {
                $deleteUrl = "$WebhookUrl/messages/$($warning.message_id)"
                try {
                    Invoke-RestMethod -Uri $deleteUrl -Method Delete | Out-Null
                    Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Deleted warning: $($e.title)"
                }
                catch {
                    Write-Warning "Delete failed for $($e.title): $_"
                }
                $warning.deleted = $true
            }
        }
    }

    # --- Persist state ---
    $stateDir = Split-Path $StateFile -Parent
    if ($stateDir -and -not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8 -Force
}

# Entry point: single-shot or loop ---------------------------------
$loopMinutes = if ($env:LOOP_DURATION_MINUTES) { [int]$env:LOOP_DURATION_MINUTES } else { 0 }

if ($loopMinutes -le 0) {
    Invoke-WatcherTick
}
else {
    $endTime = (Get-Date).AddMinutes($loopMinutes)
    Write-Host "Loop mode: ticking every minute until $($endTime.ToString('HH:mm:ss'))"
    $tickCount = 0
    while ((Get-Date) -lt $endTime) {
        try { Invoke-WatcherTick }
        catch { Write-Warning "Tick failed: $_" }
        $tickCount++
        # Sleep to the next minute boundary so ticks align nicely.
        $sleepSec = 60 - (Get-Date).Second
        if ($sleepSec -lt 1) { $sleepSec = 1 }
        Start-Sleep -Seconds $sleepSec
    }
    Write-Host "Loop completed after $tickCount tick(s)."
}
