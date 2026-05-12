# Discord Economic Events Poster

Posts the day's USD economic events from Forex Factory to a Discord channel on a schedule, with **live countdown timestamps** rendered natively by each Discord client. Runs entirely on GitHub Actions — no local PC required.

## Architecture

```
.github/workflows/daily-events.yml   GitHub Actions cron + manual trigger
scripts/Post-EconomicEvents.ps1      Downloads FF CSV, posts colored embed
```

1. GitHub Actions fires the workflow on a cron schedule (default: weekdays 11:00 UTC).
2. Workflow runs `Post-EconomicEvents.ps1` on a free `ubuntu-latest` runner with `pwsh`.
3. Script downloads `https://nfs.faireconomy.media/ff_calendar_thisweek.csv`, filters USD + today (ET), and posts an embed.

## Setup

### 1. Create a GitHub repo
Push this folder to a new repo (private is fine — Actions still runs free).

### 2. Add the Discord webhook as a secret
Repo → Settings → Secrets and variables → Actions → New repository secret
- Name: `DISCORD_WEBHOOK_URL`
- Value: your A-Team webhook URL (do **not** commit it to the script)

### 3. Adjust the cron (optional)
Edit `.github/workflows/daily-events.yml`:
```yaml
- cron: '0 11 * * 1-5'   # min hour day-of-month month day-of-week
```
GitHub cron is **UTC** and has 1–15 min jitter. Common ET conversions:

| Want it at | EDT (Mar–Nov) | EST (Nov–Mar) |
|---|---|---|
| 6:00 AM ET | `0 10 * * 1-5` | `0 11 * * 1-5` |
| 7:00 AM ET | `0 11 * * 1-5` | `0 12 * * 1-5` |
| 8:00 AM ET | `0 12 * * 1-5` | `0 13 * * 1-5` |

The current `0 11 * * 1-5` lands at 6 AM EST / 7 AM EDT — a one-hour seasonal drift. To avoid DST drift entirely you'd need a hosted runner that knows the local zone (out of scope here).

## How the script handles time

Forex Factory's `ff_calendar_thisweek.csv` reports times in **UTC**. The script:

1. Parses `Date` (`MM-DD-YYYY`) + `Time` (`8:30am`) as UTC
2. Converts UTC → ET (`America/New_York`, DST-aware) for the displayed time text
3. Hard-codes "ET" in the message so every viewer sees Eastern regardless of their Discord locale
4. Emits `<t:UNIX:R>` for an auto-updating live countdown

"All Day" / "Tentative" / blank-time rows are kept and shown without a countdown, sorted to the bottom.

## Discord dynamic timestamps

| Code | Renders as |
|---|---|
| `<t:UNIX:t>` | `8:30 AM` (short time, **viewer's local zone**) |
| `<t:UNIX:R>` | `in 2 hours` / `5 minutes ago` (auto-updating) |
| `<t:UNIX:F>` | `Friday, May 15, 2026 8:30 AM` (full) |

We use only `<t:UNIX:R>` here, because we want all viewers to see ET — not their local zone.

Example post:
```
**__ Tuesday, May. 12 __**
🔴 8:30 AM ET (in 47 minutes) — Core CPI m/m
   Forecast: 0.3% | Previous: 0.2%
🟡 6:00 AM ET (5 hours ago) — NFIB Small Business Index
   Forecast: 96.1 | Previous: 95.8
```

## Running locally

```pwsh
$env:DISCORD_WEBHOOK_URL = 'https://discord.com/api/webhooks/...'
./scripts/Post-EconomicEvents.ps1
```

Test against a private channel first.

## Manual trigger from GitHub

Actions tab → "Daily Economic Events to Discord" → Run workflow.

## Migrating off the Windows scheduled task

Once you've confirmed a couple of successful Actions runs:
1. Disable the Task Scheduler entry on your Windows PC
2. Optional: keep the original PS1 around as a fallback
