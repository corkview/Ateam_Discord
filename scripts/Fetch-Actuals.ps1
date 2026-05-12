<#
.SYNOPSIS
    Fetches real release values from official agency sources (BLS, Federal
    Reserve) and returns structured results for posting to Discord.

.DESCRIPTION
    Dot-source this file from Watch-Events.ps1. It exposes:
      - Get-CpiActual   (BLS)
      - Get-NfpActual   (BLS)
      - Get-FomcActual  (Federal Reserve RSS)
      - Find-ActualEntry  — maps an FF event title to a registry entry

    Each fetcher returns:
      - $null  if the source hasn't published the new release yet
      - A hashtable @{ Group; PeriodLabel; Emoji; Lines = @(string) } on success
#>

# --- BLS helpers --------------------------------------------------
$script:BlsEndpoint = 'https://api.bls.gov/publicAPI/v2/timeseries/data/'

function Invoke-BlsSeries {
    param(
        [Parameter(Mandatory)][string[]]$SeriesIds,
        [int]$StartYear = ((Get-Date).Year - 1),
        [int]$EndYear   = (Get-Date).Year,
        [string]$ApiKey = $env:BLS_API_KEY
    )

    $body = @{ seriesid = $SeriesIds; startyear = "$StartYear"; endyear = "$EndYear" }
    if ($ApiKey) { $body.registrationkey = $ApiKey }

    $r = Invoke-RestMethod -Uri $script:BlsEndpoint `
        -Method Post -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Compress)

    if ($r.status -ne 'REQUEST_SUCCEEDED') {
        throw "BLS API error: $($r.message -join '; ')"
    }
    $r.Results.series
}

function Get-SeriesSorted($series) {
    $series.data | Sort-Object @{Expression = { [int]$_.year }; Descending = $true},
                                @{Expression = { [int]($_.period -replace 'M','') }; Descending = $true}
}

function Get-ExpectedPriorMonth {
    # Returns @{ Year; Period(='M04') } for the previous calendar month relative to now.
    $now = Get-Date
    $y = $now.Year
    $m = $now.Month - 1
    if ($m -lt 1) { $m = 12; $y-- }
    @{ Year = "$y"; Period = "M{0:D2}" -f $m; Label = (Get-Culture).DateTimeFormat.GetMonthName($m) + " $y" }
}

function Format-Pct([double]$current, [double]$base) {
    if ($base -eq 0) { return 'n/a' }
    "{0:+0.0;-0.0;0.0}%" -f ((($current / $base) - 1.0) * 100.0)
}

# --- CPI ----------------------------------------------------------
function Get-CpiActual {
    [CmdletBinding()] param()
    $expected = Get-ExpectedPriorMonth
    $series   = Invoke-BlsSeries -SeriesIds @('CUUR0000SA0','CUUR0000SA0L1E')

    $headline = $series | Where-Object { $_.seriesID -eq 'CUUR0000SA0'    } | Select-Object -First 1
    $core     = $series | Where-Object { $_.seriesID -eq 'CUUR0000SA0L1E' } | Select-Object -First 1
    $hSorted  = Get-SeriesSorted $headline
    $cSorted  = Get-SeriesSorted $core

    # Freshness check: BLS hasn't yet published this month's release.
    if ($hSorted[0].year -ne $expected.Year -or $hSorted[0].period -ne $expected.Period) {
        return $null
    }

    $hYearAgo = $hSorted | Where-Object { [int]$_.year -eq ([int]$hSorted[0].year - 1) -and $_.period -eq $hSorted[0].period } | Select-Object -First 1
    $cYearAgo = $cSorted | Where-Object { [int]$_.year -eq ([int]$cSorted[0].year - 1) -and $_.period -eq $cSorted[0].period } | Select-Object -First 1

    $hMom = Format-Pct ([double]$hSorted[0].value) ([double]$hSorted[1].value)
    $hYoy = if ($hYearAgo) { Format-Pct ([double]$hSorted[0].value) ([double]$hYearAgo.value) } else { 'n/a' }
    $cMom = Format-Pct ([double]$cSorted[0].value) ([double]$cSorted[1].value)
    $cYoy = if ($cYearAgo) { Format-Pct ([double]$cSorted[0].value) ([double]$cYearAgo.value) } else { 'n/a' }

    @{
        Group       = 'CPI'
        Emoji       = ':bar_chart:'
        PeriodLabel = "$($hSorted[0].periodName) $($hSorted[0].year)"
        Lines       = @(
            "**Headline**   m/m $hMom    y/y $hYoy"
            "**Core**       m/m $cMom    y/y $cYoy"
        )
    }
}

# --- NFP ----------------------------------------------------------
function Get-NfpActual {
    [CmdletBinding()] param()
    $expected = Get-ExpectedPriorMonth
    # CES0000000001 = Total nonfarm payrolls (thousands, SA, monthly)
    # LNS14000000   = Unemployment rate (%, SA, monthly)
    # CES0500000003 = Avg hourly earnings, total private ($, SA, monthly)
    $series  = Invoke-BlsSeries -SeriesIds @('CES0000000001','LNS14000000','CES0500000003')

    $nfp  = $series | Where-Object { $_.seriesID -eq 'CES0000000001' } | Select-Object -First 1
    $une  = $series | Where-Object { $_.seriesID -eq 'LNS14000000'   } | Select-Object -First 1
    $ahe  = $series | Where-Object { $_.seriesID -eq 'CES0500000003' } | Select-Object -First 1

    $nfpS = Get-SeriesSorted $nfp
    $uneS = Get-SeriesSorted $une
    $aheS = Get-SeriesSorted $ahe

    if ($nfpS[0].year -ne $expected.Year -or $nfpS[0].period -ne $expected.Period) {
        return $null
    }

    # NFP change in thousands of jobs.
    $nfpChange  = [double]$nfpS[0].value - [double]$nfpS[1].value
    $nfpChangeK = "{0:+0;-0;0}K" -f $nfpChange
    $uneRate    = "{0:0.0}%" -f ([double]$uneS[0].value)
    $aheMom     = Format-Pct ([double]$aheS[0].value) ([double]$aheS[1].value)

    @{
        Group       = 'NFP'
        Emoji       = ':necktie:'
        PeriodLabel = "$($nfpS[0].periodName) $($nfpS[0].year)"
        Lines       = @(
            "**Non-Farm Payrolls**     $nfpChangeK"
            "**Unemployment Rate**     $uneRate"
            "**Avg Hourly Earnings**   m/m $aheMom"
        )
    }
}

# --- FOMC ---------------------------------------------------------
function Get-FomcActual {
    [CmdletBinding()] param([int]$RecencyMinutes = 90)
    # The Fed publishes monetary press releases via RSS. Invoke-RestMethod
    # flattens the feed to an array of <item> elements directly.
    $items = @(Invoke-RestMethod -Uri 'https://www.federalreserve.gov/feeds/press_monetary.xml')
    if ($items.Count -eq 0) { return $null }

    # The RSS includes minutes, discount-rate meetings, projections, etc.
    # The rate decision is titled exactly "Federal Reserve issues FOMC statement".
    $statement = $items | Where-Object { $_.title -like '*FOMC statement*' } | Select-Object -First 1
    if (-not $statement) { return $null }

    # CDATA-wrapped fields come back as XmlElement; pull .InnerText.
    function _Text($node) {
        if ($null -eq $node) { return $null }
        if ($node -is [string]) { return $node }
        return [string]$node.InnerText
    }

    $pubDateStr = _Text $statement.pubDate
    $linkStr    = _Text $statement.link
    $descStr    = _Text $statement.description

    $pubDate = [datetime]$pubDateStr
    $ageMin  = ([datetime]::UtcNow - $pubDate.ToUniversalTime()).TotalMinutes
    if ($ageMin -gt $RecencyMinutes) {
        return $null
    }

    # The RSS description is just the title. Fetch the linked HTML to extract
    # the target range from the statement body.
    $rangeText = $null
    try {
        $html  = (Invoke-WebRequest -Uri $linkStr -UseBasicParsing).Content
        # Pattern: "target range for the federal funds rate at X to Y percent"
        if ($html -match '(?si)target range for the federal funds rate (?:at|to)\s+([^.]{1,80}?\s+percent)') {
            $rangeText = ($Matches[1] -replace '\s+', ' ').Trim()
        }
    } catch {
        Write-Warning "Could not fetch FOMC statement HTML: $_"
    }

    $lines = @()
    if ($rangeText) { $lines += "**Target range:** $rangeText" }
    $lines += "[Full statement]($linkStr)"

    @{
        Group       = 'FOMC'
        Emoji       = ':classical_building:'
        PeriodLabel = 'Decision'
        Lines       = $lines
    }
}

# --- Registry: FF event title → group + fetcher -------------------
$script:ActualRegistry = @(
    # CPI
    @{ Pattern = '^Core CPI m/m$';                 Group = 'CPI';  Fetcher = 'Get-CpiActual'  }
    @{ Pattern = '^CPI m/m$';                      Group = 'CPI';  Fetcher = 'Get-CpiActual'  }
    @{ Pattern = '^CPI y/y$';                      Group = 'CPI';  Fetcher = 'Get-CpiActual'  }
    @{ Pattern = '^Core CPI y/y$';                 Group = 'CPI';  Fetcher = 'Get-CpiActual'  }
    # NFP
    @{ Pattern = 'Non-Farm Employment Change';     Group = 'NFP';  Fetcher = 'Get-NfpActual'  }
    @{ Pattern = '^Unemployment Rate$';            Group = 'NFP';  Fetcher = 'Get-NfpActual'  }
    @{ Pattern = 'Average Hourly Earnings';        Group = 'NFP';  Fetcher = 'Get-NfpActual'  }
    # FOMC
    @{ Pattern = '^Federal Funds Rate$';           Group = 'FOMC'; Fetcher = 'Get-FomcActual' }
    @{ Pattern = '^FOMC Statement$';               Group = 'FOMC'; Fetcher = 'Get-FomcActual' }
    @{ Pattern = 'FOMC Economic Projections';      Group = 'FOMC'; Fetcher = 'Get-FomcActual' }
)

function Find-ActualEntry([string]$eventTitle) {
    foreach ($e in $script:ActualRegistry) {
        if ($eventTitle -match $e.Pattern) { return $e }
    }
    return $null
}
