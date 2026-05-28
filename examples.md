# Examples

All commands assume your working directory is the `MoEInstanceCount` folder
and you have already run `az login` + `az account set`.

## 1. Typical usage — Beijing 10:00–17:00, 3-hour buckets

Replace `<PORTAL-URL>` with the Azure Portal URL of your AML online deployment
(any URL containing `/subscriptions/.../deployments/<name>` works — `/scaling`
suffix optional).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl '<PORTAL-URL>' `
    -StartTime '2026-05-28 10:00' `
    -EndTime   '2026-05-28 17:00' `
    -BucketHours 3
```

Example output format:

```
Bucket_Beijing            Bucket_UTC                       Samples  Avg  Min  Max
2026-05-28 10:00 -> 13:00 2026-05-28 02:00 -> 05:00        151      1.40  1    2
2026-05-28 13:00 -> 16:00 2026-05-28 05:00 -> 08:00        180      1.00  1    1
2026-05-28 16:00 -> 17:00 2026-05-28 08:00 -> 09:00         60      1.00  1    1
```

## 2. Same deployment, last 24 hours, 6-hour buckets, finer resolution

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl '<PORTAL-URL>' `
    -StartTime '2026-05-27 10:00' `
    -EndTime   '2026-05-28 10:00' `
    -BucketHours 6 `
    -Granularity PT5M
```

## 3. UTC inputs instead of Beijing

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl '<PORTAL-URL>' `
    -StartTime '2026-05-28 02:00' `
    -EndTime   '2026-05-28 09:00' `
    -BucketHours 3 `
    -TimeZone UTC
```

## 4. Different output folder

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl '<PORTAL-URL>' `
    -StartTime '2026-05-28 10:00' `
    -EndTime   '2026-05-28 17:00' `
    -BucketHours 3 `
    -OutDir 'C:\reports\moE'
```

## 5. Long window (7 days), auto-falls back to PT15M

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-MoEInstanceCount.ps1 `
    -PortalUrl '<PORTAL-URL>' `
    -StartTime '2026-05-21 10:00' `
    -EndTime   '2026-05-28 10:00' `
    -BucketHours 12
```

## 6. Sharing with a teammate

Send them this whole `MoEInstanceCount` folder. They only need:
1. Azure CLI installed and logged into the tenant that owns the resource.
2. The Portal URL of **their** deployment, copy-pasted into `-PortalUrl`.
3. The time window and bucket size they want.

No code changes required.
