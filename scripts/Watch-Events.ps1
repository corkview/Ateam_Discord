<#
.SYNOPSIS
    Posts a pre-event warning ~5 min before each USD High-impact economic event,
    then deletes that warning ~1 min after the event passes. Keeps the channel
    quiet between events.

.DESCRIPTION
    Runs on a 5-minute GitHub Actions cron during US trading hours. Persists
    state (today's events + posted message IDs) via Actions cache so each
    invocation can decide what to post/delete without re-querying anything
    except the FF CSV (which it caches in state to respect FF's rate limit).
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
$WarnWithinSec   = 360   # post a warning if event is within 6 min from now
$DeleteAfterSec  = 60    # delete the warning 1 min after event passes

# Timezone ---------------------------------------------------------
$EtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)
$nowUtc  = [datetime]::UtcNow
$nowEt   = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $EtZone)
$todayEt = $nowEt.Date.ToString('yyyy-MM-dd')

# Load state -------------------------------------------------------
function New-EmptyState {
    @{ date = $null; events = @(); warnings = @() }
}

$state = New-EmptyState
if (Test-Path $StateFile) {
    try {
        $loaded = Get-Content $StateFile -Raw | ConvertFrom-Json
        # ConvertFrom-Json auto-parses ISO date strings into DateTime — normalize back to ISO string
        # so event_utc keys are byte-identical between fresh-fetch and reload.
        $state = @{
            date     = [string]$loaded.date
            events   = @($loaded.events   | ForEach-Object {
                $utcStr = if ($_.event_utc -is [datetime]) { $_.event_utc.ToUniversalTime().ToString('o') } else { [string]$_.event_utc }
                @{ title = [string]$_.title; impact = [string]$_.impact; event_utc = $utcStr }
            })
            warnings = @($loaded.warnings | ForEach-Object {
                @{ event_key = [string]$_.event_key; message_id = [string]$_.message_id; deleted = [bool]$_.deleted }
            })
        }
        Write-Host "Loaded state: date=$($state.date), events=$($state.events.Count), warnings=$($state.warnings.Count)"
    }
    catch {
        Write-Warning "State file unreadable, resetting: $_"
        $state = New-EmptyState
    }
}

# Refresh event list on new day (or first run) ---------------------
if ($state.date -ne $todayEt) {
    Write-Host "New day ($($state.date) -> $todayEt); fetching FF CSV."
    $csvText = Invoke-RestMethod -Uri $CsvUrl
    $rows = $csvText | ConvertFrom-Csv

    $events = @()
    foreach ($r in $rows) {
        if ($r.Country -ne $Country) { continue }
        if ($r.Impact -ne 'High' -and $r.Impact -ne 'Medium') { continue }
        $impact = $r.Impact

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

        $events += @{ title = $r.Title; impact = $impact; event_utc = $eventUtc.ToString('o') }
    }

    $state.date     = $todayEt
    $state.events   = $events
    $state.warnings = @()
    Write-Host "Today has $($events.Count) USD High-impact event(s)."
}

# Walk events; decide post / delete / skip -------------------------
function Get-EventKey($title, $eventUtcIso) { "$title|$eventUtcIso" }

foreach ($e in $state.events) {
    $key      = Get-EventKey $e.title $e.event_utc
    $eventUtc = [datetime]::Parse($e.event_utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    $secsUntil = ($eventUtc - $nowUtc).TotalSeconds

    $warning = $state.warnings | Where-Object { $_.event_key -eq $key } | Select-Object -First 1

    if (-not $warning) {
        # No warning yet - post if event is within the warning window (and not past)
        if ($secsUntil -gt 0 -and $secsUntil -le $WarnWithinSec) {
            $unix = [int64]([datetimeoffset]$eventUtc).ToUnixTimeSeconds()
            $dot  = if ($e.impact -eq 'High') { ':red_circle:' } else { ':orange_circle:' }
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
            Write-Host "Posted warning for $($e.title) (msg id=$($response.id), in $([int]($secsUntil/60)) min)"
        }
        else {
            Write-Host "Skip $($e.title): secsUntil=$([int]$secsUntil), outside warning window"
        }
    }
    elseif (-not $warning.deleted) {
        # Warning exists - delete it once the event has passed
        if ($secsUntil -lt -$DeleteAfterSec) {
            $deleteUrl = "$WebhookUrl/messages/$($warning.message_id)"
            try {
                Invoke-RestMethod -Uri $deleteUrl -Method Delete | Out-Null
                Write-Host "Deleted warning for $($e.title) (msg id=$($warning.message_id))"
            }
            catch {
                Write-Warning "Delete failed for $($e.title) msg $($warning.message_id): $_"
            }
            # Mark deleted either way so we don't keep retrying
            $warning.deleted = $true
        }
    }
}

# Persist state ----------------------------------------------------
$stateDir = Split-Path $StateFile -Parent
if ($stateDir -and -not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}
$state | ConvertTo-Json -Depth 5 | Out-File -FilePath $StateFile -Encoding utf8 -Force

$activeWarnings = @($state.warnings | Where-Object { -not $_.deleted }).Count
Write-Host "Done. Active warnings: $activeWarnings / total $($state.warnings.Count)."
