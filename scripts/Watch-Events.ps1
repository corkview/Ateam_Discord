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

# Dot-source fetchers for actuals (CPI/NFP/FOMC) -------------------
. (Join-Path $PSScriptRoot 'Fetch-Actuals.ps1')
. (Join-Path $PSScriptRoot 'Market-Calendar.ps1')

# Tuning ------------------------------------------------------------
$WarnWithinSec    = 180   # post a warning if event is within 3 min from now
$DeleteAfterSec   = 60    # delete the warning 1 min after event passes
$ActualsTimeoutMin = 30   # give up on actual-fetching N min after event time

# Low-impact events you still want warnings for (case-insensitive regex, match against FF Title).
# Add more patterns here over time — e.g. 'Natural Gas Storage', 'EIA Petroleum'.
$AlwaysIncludeTitles = @(
    'Crude Oil Inventories'
)

# Timezone setup (shared across all loop iterations) ---------------
$EtZone = [System.TimeZoneInfo]::FindSystemTimeZoneById(
    $(if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Eastern Standard Time' } else { 'America/New_York' })
)

function New-EmptyState { @{ date = $null; events = @(); warnings = @(); actuals = @(); holiday_notified_date = $null } }
function Get-EventKey($title, $eventUtcIso) { "$title|$eventUtcIso" }
function Get-ImpactDot($impact, $title) {
    switch ($impact) {
        'High'   { ':red_circle:' }
        'Medium' { ':orange_circle:' }
        'MarketSession' {
            switch -Regex ($title) {
                'MOC'   { ':alarm_clock:' }
                default { ':bell:' }
            }
        }
        default { ':yellow_circle:' }
    }
}

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
                actuals     = @($loaded.actuals | ForEach-Object {
                    $feUtc = if ($_.first_event_utc -is [datetime]) { $_.first_event_utc.ToUniversalTime().ToString('o') } else { [string]$_.first_event_utc }
                    @{
                        group           = [string]$_.group
                        fetcher         = [string]$_.fetcher
                        first_event_utc = $feUtc
                        status          = [string]$_.status
                    }
                })
                holiday_notified_date = [string]$loaded.holiday_notified_date
            }
        }
        catch {
            Write-Warning "State file unreadable, resetting: $_"
            $state = New-EmptyState
        }
    }

    # --- Refresh event list on new day, filter-mode change, or forced refresh ---
    $forceRefresh = ($env:FORCE_REFRESH -eq 'true')
    if ($state.date -ne $todayEt -or $state.include_all -ne $includeAll -or $forceRefresh) {
        Write-Host "[$($nowEt.ToString('HH:mm:ss'))] New day ($($state.date) -> $todayEt); fetching FF CSV."
        $csvText = Invoke-RestMethod -Uri $CsvUrl
        $rows    = $csvText | ConvertFrom-Csv

        # Build a single regex from the whitelist for fast matching.
        $whitelistRegex = if ($AlwaysIncludeTitles.Count) { '(?i)' + ($AlwaysIncludeTitles -join '|') } else { $null }

        $events = @()
        foreach ($r in $rows) {
            if ($r.Country -ne $Country) { continue }
            $isMedHigh     = ($r.Impact -eq 'High' -or $r.Impact -eq 'Medium')
            $isWhitelisted = $whitelistRegex -and ($r.Title -match $whitelistRegex)
            if (-not $includeAll -and -not $isMedHigh -and -not $isWhitelisted) { continue }

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

        # --- Inject synthetic market session events (skipped on market holidays) ---
        function _ToUtcIso([datetime]$etTime, $zone) {
            [System.TimeZoneInfo]::ConvertTimeToUtc(
                [datetime]::SpecifyKind($etTime, [DateTimeKind]::Unspecified), $zone).ToString('o')
        }
        $holidayName = Get-MarketHoliday $nowEt.Date
        if (-not $holidayName) {
            $events += @{ title = 'US Market Open';  impact = 'MarketSession'; event_utc = (_ToUtcIso $nowEt.Date.AddHours(9).AddMinutes(30)  $EtZone) }
            $events += @{ title = 'MOC Imbalance';   impact = 'MarketSession'; event_utc = (_ToUtcIso $nowEt.Date.AddHours(15).AddMinutes(50) $EtZone) }
            $events += @{ title = 'US Market Close'; impact = 'MarketSession'; event_utc = (_ToUtcIso $nowEt.Date.AddHours(16)                $EtZone) }
        }
        else {
            Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Market holiday: $holidayName — skipping equity Open/MOC/Close."
            # If futures still trade with an early close today, inject Futures Early Close for a T-3 warning.
            $futSchedule = Get-FuturesHolidaySchedule $nowEt.Date
            if ($futSchedule -and $futSchedule.EarlyCloseEt) {
                $parts = $futSchedule.EarlyCloseEt.Split(':')
                $closeEt = $nowEt.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
                $events += @{ title = 'Futures Early Close'; impact = 'MarketSession'; event_utc = (_ToUtcIso $closeEt $EtZone) }
                Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Injected Futures Early Close at $($futSchedule.EarlyCloseEt) ET."
            }
        }

        $state.date        = $todayEt
        $state.include_all = $includeAll
        $state.events      = $events
        $state.warnings    = @()
        $state.actuals     = @()
        $mode = if ($includeAll) { 'ALL impacts' } else { 'Med/High' }
        Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Today has $($events.Count) USD event(s) ($mode)."
    }

    # Holiday closure notice is now handled by the morning post (Post-EconomicEvents.ps1).
    # Watcher only handles the Futures Early Close synthetic event injection on holidays.

    # Lookup: event_key -> event (used by the delete phase below).
    $eventByKey = @{}
    foreach ($e in $state.events) { $eventByKey[(Get-EventKey $e.title $e.event_utc)] = $e }

    # Group events by release time so simultaneous releases share ONE warning (one @here).
    $releaseGroups = @{}
    foreach ($e in $state.events) {
        $k = [string]$e.event_utc
        if ($releaseGroups.ContainsKey($k)) { $releaseGroups[$k] = $releaseGroups[$k] + ,$e }
        else { $releaseGroups[$k] = @($e) }
    }

    # --- POST phase: one combined warning per release-time group ---
    foreach ($k in @($releaseGroups.Keys)) {
        $members   = @($releaseGroups[$k])
        $eventUtc  = [datetime]::Parse($k, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $secsUntil = ($eventUtc - $nowUtc).TotalSeconds

        # Skip if any member already has a warning (group was already posted).
        $memberKeys = @($members | ForEach-Object { Get-EventKey $_.title $_.event_utc })
        if ($state.warnings | Where-Object { $memberKeys -contains $_.event_key }) { continue }

        if ($secsUntil -gt 0 -and $secsUntil -le $WarnWithinSec) {
            $unix    = [int64]([datetimeoffset]$eventUtc).ToUnixTimeSeconds()
            $hasNews = @($members | Where-Object { $_.impact -eq 'High' -or $_.impact -eq 'Medium' }).Count -gt 0
            $prefix  = if ($hasNews) { '@here ' } else { '' }

            if ($members.Count -eq 1) {
                $m   = $members[0]
                $dot = Get-ImpactDot $m.impact $m.title
                $content = if ($m.impact -eq 'MarketSession') {
                    "$dot **$($m.title)** <t:$unix`:R>"
                } else {
                    "$prefix$dot **$($m.title)** releases <t:$unix`:R>"
                }
            }
            else {
                # Multiple simultaneous releases: one @here, one timestamp, one line per event.
                $lines   = foreach ($m in $members) { "$(Get-ImpactDot $m.impact $m.title) **$($m.title)**" }
                $content = "$prefix**News releasing <t:$unix`:R>**`n" + ($lines -join "`n")
            }

            $mentions = if ($hasNews) { @{ parse = @('everyone') } } else { @{ parse = @() } }
            $payload  = @{
                content          = $content
                allowed_mentions = $mentions
            } | ConvertTo-Json -Depth 5 -Compress

            $postUrl  = "$WebhookUrl" + "?wait=true"
            $response = Invoke-RestMethod -Uri $postUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body $payload

            foreach ($m in $members) {
                $state.warnings += @{
                    event_key  = (Get-EventKey $m.title $m.event_utc)
                    message_id = $response.id
                    deleted    = $false
                }
            }
            $titles = ($members | ForEach-Object { $_.title }) -join ', '
            Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Posted warning ($($members.Count)): $titles (in $([int]$secsUntil)s)"
        }
    }

    # --- DELETE phase: remove each warning message once, after its events pass; enroll actuals per event ---
    $byMessage = @{}
    foreach ($w in $state.warnings) {
        if ($w.deleted) { continue }
        $k = [string]$w.message_id
        if ($byMessage.ContainsKey($k)) { $byMessage[$k] = $byMessage[$k] + ,$w }
        else { $byMessage[$k] = @($w) }
    }

    foreach ($msgId in @($byMessage.Keys)) {
        $warnRecs = @($byMessage[$msgId])
        $evs      = @($warnRecs | ForEach-Object { $eventByKey[$_.event_key] } | Where-Object { $_ })
        if (-not $evs.Count) { continue }

        $maxUtc = [datetime]::MinValue
        foreach ($e in $evs) {
            $t = [datetime]::Parse($e.event_utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            if ($t -gt $maxUtc) { $maxUtc = $t }
        }
        if (($maxUtc - $nowUtc).TotalSeconds -ge -$DeleteAfterSec) { continue }

        $deleteUrl = "$WebhookUrl/messages/$msgId"
        try {
            Invoke-RestMethod -Uri $deleteUrl -Method Delete | Out-Null
            Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Deleted warning: $(($evs | ForEach-Object { $_.title }) -join ', ')"
        }
        catch {
            Write-Warning "Delete failed for message $msgId`: $_"
        }
        foreach ($w in $warnRecs) { $w.deleted = $true }

        # Enroll each event for actuals follow-up if it is in the registry.
        foreach ($e in $evs) {
            $entry = Find-ActualEntry $e.title
            if ($entry) {
                $existing = $state.actuals | Where-Object { $_.group -eq $entry.Group } | Select-Object -First 1
                if (-not $existing) {
                    $state.actuals += @{
                        group           = $entry.Group
                        fetcher         = $entry.Fetcher
                        first_event_utc = $e.event_utc
                        status          = 'pending'
                    }
                    Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Enrolled $($entry.Group) for actuals follow-up."
                }
            }
        }
    }

    # --- Process pending actuals ---
    foreach ($a in $state.actuals) {
        if ($a.status -ne 'pending') { continue }

        $firstEvent  = [datetime]::Parse($a.first_event_utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $minSinceEvt = ($nowUtc - $firstEvent).TotalMinutes

        if ($minSinceEvt -gt $ActualsTimeoutMin) {
            $a.status = 'timeout'
            Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Actuals timeout for $($a.group) ($([int]$minSinceEvt) min)."
            continue
        }

        $result = $null
        try   { $result = & $a.fetcher }
        catch { Write-Warning "Actuals fetcher '$($a.fetcher)' failed: $_"; continue }

        if ($result) {
            $name    = if ($result.DisplayName) { $result.DisplayName } else { $result.Group }
            $content = "$($result.Emoji) **$name Release — $($result.PeriodLabel)**`n" + ($result.Lines -join "`n")
            $payload = @{
                content          = $content
                allowed_mentions = @{ parse = @() }
            } | ConvertTo-Json -Depth 5 -Compress

            try {
                Invoke-RestMethod -Uri $WebhookUrl -Method Post `
                    -ContentType 'application/json; charset=utf-8' -Body $payload | Out-Null
                $a.status = 'posted'
                Write-Host "[$($nowEt.ToString('HH:mm:ss'))] Posted actuals: $($a.group) — $($result.PeriodLabel)"
            }
            catch {
                Write-Warning "Failed to post actuals to Discord: $_"
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
