<#
.SYNOPSIS
    NYSE/Nasdaq US market holiday lookup. Returns the holiday name if today
    (or the given ET date) is a market closure day, else $null.

.NOTES
    Hardcoded list — update annually. Dates reflect *observed* dates (when
    markets are actually closed), not calendar dates of the holiday.
#>

function Get-MarketHoliday {
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime]$DateEt)

    $iso = $DateEt.ToString('yyyy-MM-dd')
    $holidays = @{
        # 2026
        '2026-01-01' = "New Year's Day"
        '2026-01-19' = 'Martin Luther King Jr. Day'
        '2026-02-16' = "Presidents' Day"
        '2026-04-03' = 'Good Friday'
        '2026-05-25' = 'Memorial Day'
        '2026-06-19' = 'Juneteenth'
        '2026-07-03' = 'Independence Day (observed)'   # July 4 is Saturday
        '2026-09-07' = 'Labor Day'
        '2026-11-26' = 'Thanksgiving Day'
        '2026-12-25' = 'Christmas Day'
        # 2027
        '2027-01-01' = "New Year's Day"
        '2027-01-18' = 'Martin Luther King Jr. Day'
        '2027-02-15' = "Presidents' Day"
        '2027-03-26' = 'Good Friday'
        '2027-05-31' = 'Memorial Day'
        '2027-06-18' = 'Juneteenth (observed)'         # June 19 is Saturday
        '2027-07-05' = 'Independence Day (observed)'   # July 4 is Sunday
        '2027-09-06' = 'Labor Day'
        '2027-11-25' = 'Thanksgiving Day'
        '2027-12-24' = 'Christmas Day (observed)'      # December 25 is Saturday
    }

    if ($holidays.ContainsKey($iso)) { return $holidays[$iso] }
    return $null
}
