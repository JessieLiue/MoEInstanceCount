# MoEInstanceCount

Compute the **Observed resource instance count** (Azure ML autoscale Run history) for any AML
Managed Online Deployment, bucketed every N hours.

## What problem does this solve

The Azure Portal's **Deployment → Scaling → Run history** panel shows a chart of
"Observed resource instance count" over time, but does not expose per-time-bucket
averages. This skill pulls the underlying `ObservedCapacity` metric from Azure Monitor
and computes the average over any user-defined window with any bucket size.

## Prerequisites

1. **Azure CLI** (`az`) installed and signed in:
   ```powershell
   az login
   az account set --subscription <subscription-id-from-portal-url>
   ```
2. The signed-in identity needs **Reader** on the autoscale setting (or higher on
   the resource group / workspace).
3. PowerShell 5.1 (`powershell.exe`) **or** PowerShell 7+ (`pwsh`) — both work.
4. The deployment must have an **autoscale setting** attached. (If `scaleType: Default`
   with no autoscale rule, the `ObservedCapacity` metric is not emitted.)

## Quick start

From this folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl    'PASTE_PORTAL_URL_HERE' `
    -StartTime    '2026-05-28 10:00' `
    -EndTime      '2026-05-28 17:00' `
    -BucketHours  3
```

You will get:

- A table in the console with **Beijing** and **UTC** bucket labels, sample count, average, min, max.
- Two CSV files in this folder:
  - `observed_capacity_raw_<timestamp>.csv` — every per-minute (or per-N-minute) sample.
  - `observed_capacity_buckets_<timestamp>.csv` — per-bucket aggregates.
- A raw JSON snapshot of the metric query.

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-PortalUrl` | ✅ | — | Any Portal URL containing `/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<ws>/onlineEndpoints/<ep>/deployments/<dep>`. The `/scaling` suffix is optional. |
| `-StartTime` | ✅ | — | `yyyy-MM-dd HH:mm`. Interpreted in `-TimeZone`. |
| `-EndTime` | ✅ | — | `yyyy-MM-dd HH:mm`. Must be > StartTime. |
| `-BucketHours` | ❌ | `3` | Integer, ≥ 1. |
| `-TimeZone` | ❌ | `Beijing` | `Beijing` (UTC+8, no DST) or `UTC`. |
| `-Granularity` | ❌ | `Auto` | `Auto`, `PT1M`, `PT5M`, `PT15M`, `PT1H`. |
| `-OutDir` | ❌ | Script's folder | Where to write CSVs/JSON. |

## URL parsing

All of these URL shapes are accepted (the regex only requires the
deployment-scoped path; URL fragments and query strings are ignored):

```
https://ms.portal.azure.com/#@<tenant>/resource/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<workspace>/onlineEndpoints/<endpoint>/deployments/<deployment>/scaling

https://portal.azure.com/#@.../resource/subscriptions/.../deployments/<deployment>

https://ms.portal.azure.com/#blade/HubsExtension/.../subscriptions/.../deployments/<deployment>/overview
```

## Granularity auto-pick

Azure Monitor limits 1-minute samples to a ~7-hour retention window. The script picks:

| Window size | Default granularity |
|---|---|
| ≤ 6 h | PT1M |
| 6–24 h | PT5M |
| 24 h – 7 d | PT15M |
| > 7 d | PT1H |

Override with `-Granularity PT1M` etc. if you need finer resolution within retention limits.

## Common pitfalls

- **"No autoscale setting found"** — the deployment uses manual scaling (`scaleType: Default`). Configure autoscale first or pick a deployment that has it.
- **Empty results** — the window is outside the metric's retention period, or autoscale didn't evaluate during that time. Try shrinking the window or moving it closer to "now".
- **`ParseExact` errors** — make sure StartTime/EndTime use the exact format `yyyy-MM-dd HH:mm` (24-hour, leading zeros).
- **Wrong subscription** — the script auto-runs `az account set`, but you must have logged into the tenant that owns the subscription.

## See also

- [`examples.md`](./examples.md) — copy-paste invocations for common scenarios.
- [`SKILL.md`](./SKILL.md) — agent-callable skill manifest.
