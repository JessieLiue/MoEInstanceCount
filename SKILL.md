---
name: MoEInstanceCount
description: |
  Compute the Observed Resource Instance Count (autoscale Run history) for any Azure Machine Learning
  Managed Online Deployment over a user-specified time window, bucketed every N hours (default 3).
  Inputs: an Azure Portal URL pointing to the deployment (or its /scaling page), start/end times
  (Beijing or UTC), and BucketHours.
  USE FOR: "calculate observed instance count", "autoscale run history average", "MoE instance count",
  "scaling history of AML deployment", "average resource instance count over 3 hours",
  "ObservedCapacity metric of AML online endpoint deployment".
  DO NOT USE FOR: non-AML resources, cost analysis, or scaling configuration changes.
---

# MoEInstanceCount Skill

Computes per-bucket averages of the **`ObservedCapacity`** metric (shown as
"Observed resource instance count" on the Azure Portal's Run history panel) for an
**Azure ML Managed Online Deployment** autoscale setting.

## When to invoke

Trigger this skill whenever a user asks any of:

- "计算 [portal URL] 的 observed instance count 每 N 小时平均值"
- "Compute the average observed instance count from <start> to <end>"
- "把 Run history 里的 Observed resource instance count 每 3 小时平均一下"
- "MoE / AML 在线终结点的 autoscale run history 分时段统计"

## Required inputs (always ask the user)

| Input | Format | Example |
|---|---|---|
| **PortalUrl** | Any Azure Portal URL that points to the AML online deployment **or** its `/scaling` subpage. The skill parses the subscription, resource group, workspace, endpoint, and deployment from the URL. | `https://ms.portal.azure.com/#@<tenant>/resource/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<workspace>/onlineEndpoints/<endpoint>/deployments/<deployment>/scaling` |
| **StartTime** | `yyyy-MM-dd HH:mm` (Beijing time by default; pass `-TimeZone UTC` to switch) | `2026-05-28 10:00` |
| **EndTime** | `yyyy-MM-dd HH:mm` (same TZ as StartTime) | `2026-05-28 17:00` |
| **BucketHours** | Integer ≥ 1 | `3` |

If any of these are missing from the user's message, **ask for them explicitly** before running the script. Do not guess.

## How to run

The skill is implemented by the PowerShell script `Get-MoEInstanceCount.ps1` in this folder.
Prerequisites:

1. Azure CLI installed and signed in: `az login` and `az account set --subscription <id matching the portal URL>`.
2. The signed-in identity must have **Reader** on the autoscale setting (or on the workspace/resource group).
3. Windows PowerShell 5.1 or PowerShell 7+ both work.

Run from the folder containing the script:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
  -PortalUrl    '<paste the portal URL here>' `
  -StartTime    '2026-05-28 10:00' `
  -EndTime      '2026-05-28 17:00' `
  -BucketHours  3
```

Optional flags:

- `-TimeZone UTC` — interpret `StartTime` / `EndTime` as UTC instead of Beijing (default).
- `-OutDir <path>` — folder for output CSVs (default: same folder as the script).
- `-Granularity PT1M|PT5M|PT15M|PT1H` — override Azure Monitor sample interval (default: chosen by window size).

The script does the following automatically:
1. Parses the portal URL to extract `subscriptionId`, `resourceGroup`, `workspace`, `onlineEndpoint`, `deployment`.
2. Locates the autoscale setting whose `targetResourceUri` matches that deployment.
3. Picks a suitable metric granularity based on the requested window size.
4. Calls `az monitor metrics list` for the `ObservedCapacity` metric.
5. Buckets samples into N-hour windows (aligned to the start time, not midnight).
6. Prints a table with both Beijing and UTC bucket labels and writes CSV.

## Output

A console table plus two CSVs in `-OutDir`:

- `observed_capacity_raw_<timestamp>.csv` — per-sample values with UTC + Beijing columns.
- `observed_capacity_buckets_<timestamp>.csv` — per-bucket averages, min, max, and sample counts.

## Notes & limitations

- Azure Monitor only keeps 1-minute-grain samples for ~7 hours. For longer windows the script auto-falls back to PT5M / PT15M / PT1H.
- The metric does **not** exist if the deployment has no autoscale setting attached. In that case the script reports the error clearly and stops.
- "Beijing time" means UTC+8 with no DST.
