<#
.SYNOPSIS
    Compute average "Observed resource instance count" (autoscale ObservedCapacity metric)
    for an Azure ML Managed Online Deployment over a user-specified time window, bucketed
    every N hours.

.DESCRIPTION
    Pastes a Portal URL of an AML online deployment, picks a time window and bucket size,
    and prints per-bucket averages. Output CSVs are written to -OutDir.

.PARAMETER PortalUrl
    Any Azure Portal URL pointing to the AML deployment. Example:
    https://ms.portal.azure.com/#@<tenant>/resource/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<ws>/onlineEndpoints/<ep>/deployments/<dep>/scaling

.PARAMETER StartTime
    Window start time, format "yyyy-MM-dd HH:mm". Interpreted in -TimeZone.

.PARAMETER EndTime
    Window end time, format "yyyy-MM-dd HH:mm". Interpreted in -TimeZone.

.PARAMETER BucketHours
    Bucket size in hours (>=1). Default 3.

.PARAMETER TimeZone
    "Beijing" (UTC+8, default) or "UTC".

.PARAMETER Granularity
    Override metric sample interval. Allowed: PT1M, PT5M, PT15M, PT1H. Default: auto.

.PARAMETER OutDir
    Folder for CSV output. Default: this script's folder.

.EXAMPLE
    .\Get-MoEInstanceCount.ps1 `
      -PortalUrl 'https://ms.portal.azure.com/#@<tenant>/resource/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<ws>/onlineEndpoints/<ep>/deployments/<deployment>/scaling' `
      -StartTime '2026-05-28 10:00' -EndTime '2026-05-28 17:00' -BucketHours 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PortalUrl,
    [Parameter(Mandatory = $true)] [string] $StartTime,
    [Parameter(Mandatory = $true)] [string] $EndTime,
    [int] $BucketHours = 3,
    [ValidateSet('Beijing', 'UTC')] [string] $TimeZone = 'Beijing',
    [ValidateSet('Auto', 'PT1M', 'PT5M', 'PT15M', 'PT1H')] [string] $Granularity = 'Auto',
    [string] $OutDir = ''
)

$ErrorActionPreference = 'Stop'

# Resolve OutDir lazily so it works regardless of how the script is invoked
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
              else { (Get-Location).Path }
}

# ----- 1. Parse Portal URL ------------------------------------------------
$pattern = '/subscriptions/([0-9a-fA-F-]+)/resourceGroups/([^/]+)/providers/Microsoft\.MachineLearningServices/workspaces/([^/]+)/onlineEndpoints/([^/]+)/deployments/([^/?#]+)'
$m = [regex]::Match($PortalUrl, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
if (-not $m.Success) {
    throw "Could not parse a Microsoft.MachineLearningServices online deployment from PortalUrl. Expected the URL to contain '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.MachineLearningServices/workspaces/<ws>/onlineEndpoints/<ep>/deployments/<dep>'."
}
$subId     = $m.Groups[1].Value
$rgName    = $m.Groups[2].Value
$wsName    = $m.Groups[3].Value
$epName    = $m.Groups[4].Value
$depName   = $m.Groups[5].Value
$depResId  = "/subscriptions/$subId/resourceGroups/$rgName/providers/Microsoft.MachineLearningServices/workspaces/$wsName/onlineEndpoints/$epName/deployments/$depName"

Write-Host ""
Write-Host "[1/5] Parsed deployment:" -ForegroundColor Cyan
Write-Host "      Subscription : $subId"
Write-Host "      ResourceGroup: $rgName"
Write-Host "      Workspace    : $wsName"
Write-Host "      Endpoint     : $epName"
Write-Host "      Deployment   : $depName"

# ----- 2. Verify az login + correct subscription --------------------------
$acct = az account show --subscription $subId -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Write-Host "Subscription $subId not in current az context. Attempting 'az account set'..." -ForegroundColor Yellow
    az account set --subscription $subId | Out-Null
    $acct = az account show --subscription $subId -o json | ConvertFrom-Json
    if (-not $acct) { throw "Could not select subscription $subId. Run 'az login' and try again." }
}
Write-Host ("      Az context   : {0} ({1})" -f $acct.name, $acct.id)

# ----- 3. Find autoscale setting for this deployment ----------------------
Write-Host ""
Write-Host "[2/5] Locating autoscale setting for the deployment..." -ForegroundColor Cyan
$autoscalesJson = az monitor autoscale list -g $rgName --subscription $subId -o json
$autoscales = $autoscalesJson | ConvertFrom-Json
$match = $autoscales | Where-Object { $_.targetResourceUri -ieq $depResId }
if (-not $match) {
    throw "No autoscale setting found in resource group '$rgName' targeting deployment '$depName'. The 'Observed resource instance count' metric only exists when autoscale is configured. Either configure autoscale, or pick a different deployment."
}
$autoscaleName = $match[0].name
$autoscaleId   = "/subscriptions/$subId/resourceGroups/$rgName/providers/microsoft.insights/autoscalesettings/$autoscaleName"
Write-Host "      Autoscale    : $autoscaleName"

# ----- 4. Convert time window to UTC --------------------------------------
$tzOffsetHours = if ($TimeZone -eq 'Beijing') { 8 } else { 0 }
$culture = [System.Globalization.CultureInfo]::InvariantCulture
$startLocal = [datetime]::ParseExact($StartTime, 'yyyy-MM-dd HH:mm', $culture)
$endLocal   = [datetime]::ParseExact($EndTime,   'yyyy-MM-dd HH:mm', $culture)
if ($endLocal -le $startLocal) { throw "EndTime must be after StartTime." }
$startUtc = $startLocal.AddHours(-$tzOffsetHours)
$endUtc   = $endLocal.AddHours(-$tzOffsetHours)
$windowHours = ($endUtc - $startUtc).TotalHours

# Pick granularity if Auto
if ($Granularity -eq 'Auto') {
    if     ($windowHours -le 6)   { $Granularity = 'PT1M' }
    elseif ($windowHours -le 24)  { $Granularity = 'PT5M' }
    elseif ($windowHours -le 168) { $Granularity = 'PT15M' }
    else                          { $Granularity = 'PT1H' }
}
$intervalMin = switch ($Granularity) { 'PT1M' { 1 } 'PT5M' { 5 } 'PT15M' { 15 } 'PT1H' { 60 } }

Write-Host ""
Write-Host "[3/5] Time window:" -ForegroundColor Cyan
Write-Host ("      Input TZ     : {0}" -f $TimeZone)
Write-Host ("      Local window : {0}  ->  {1}" -f $startLocal.ToString('yyyy-MM-dd HH:mm'), $endLocal.ToString('yyyy-MM-dd HH:mm'))
Write-Host ("      UTC window   : {0}  ->  {1}" -f $startUtc.ToString('yyyy-MM-dd HH:mm'), $endUtc.ToString('yyyy-MM-dd HH:mm'))
Write-Host ("      Bucket size  : {0} hour(s)" -f $BucketHours)
Write-Host ("      Granularity  : {0}" -f $Granularity)

# ----- 5. Query Azure Monitor for ObservedCapacity ------------------------
Write-Host ""
Write-Host "[4/5] Querying ObservedCapacity metric..." -ForegroundColor Cyan
$startIso = $startUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$endIso   = $endUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
$tsStr    = (Get-Date).ToString('yyyyMMdd-HHmmss')
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$jsonOut  = Join-Path $OutDir "observed_capacity_$tsStr.json"
$rawCsv   = Join-Path $OutDir "observed_capacity_raw_$tsStr.csv"
$bktCsv   = Join-Path $OutDir "observed_capacity_buckets_$tsStr.csv"

az monitor metrics list `
    --resource $autoscaleId `
    --metric ObservedCapacity `
    --start-time $startIso `
    --end-time $endIso `
    --interval $Granularity `
    --aggregation Average Minimum Maximum `
    -o json > $jsonOut

$json = Get-Content $jsonOut -Raw | ConvertFrom-Json
$data = $json.value[0].timeseries[0].data | Where-Object { $_.average -ne $null }
if (-not $data -or @($data).Count -eq 0) {
    Write-Host "      No ObservedCapacity samples found in the window. The autoscale may not have evaluated, or the window is outside the metric retention period." -ForegroundColor Yellow
    return
}

$points = @($data) | ForEach-Object {
    $raw = $_.timeStamp
    $tUtc = if ($raw -is [datetime]) {
        if ($raw.Kind -eq [System.DateTimeKind]::Utc) { $raw } else { $raw.ToUniversalTime() }
    } else {
        [System.DateTimeOffset]::Parse([string]$raw, $culture).UtcDateTime
    }
    [pscustomobject]@{
        tsUtc   = $tUtc
        val     = [double]$_.average
        valMin  = if ($_.minimum -ne $null) { [double]$_.minimum } else { [double]$_.average }
        valMax  = if ($_.maximum -ne $null) { [double]$_.maximum } else { [double]$_.average }
    }
} | Sort-Object tsUtc

# Write raw CSV
$points | Select-Object `
    @{n='TimeUTC';     e={ $_.tsUtc.ToString('yyyy-MM-dd HH:mm:ss') }}, `
    @{n='TimeBeijing'; e={ $_.tsUtc.AddHours(8).ToString('yyyy-MM-dd HH:mm:ss') }}, `
    @{n='ObservedCapacity'; e={ $_.val }}, `
    @{n='Min'; e={ $_.valMin }}, `
    @{n='Max'; e={ $_.valMax }} |
    Export-Csv -NoTypeInformation -Encoding utf8 $rawCsv

# ----- 6. Bucket and aggregate --------------------------------------------
Write-Host "[5/5] Bucketing into $BucketHours-hour windows..." -ForegroundColor Cyan
$rows = @()
$bStart = $startUtc
while ($bStart -lt $endUtc) {
    $bEnd = $bStart.AddHours($BucketHours)
    if ($bEnd -gt $endUtc) { $bEnd = $endUtc }
    $bucket = $points | Where-Object { $_.tsUtc -ge $bStart -and $_.tsUtc -lt $bEnd }
    if ($bucket) {
        $sum = 0.0; $mn = [double]::MaxValue; $mx = [double]::MinValue
        foreach ($p in $bucket) {
            $sum += $p.val
            if ($p.valMin -lt $mn) { $mn = $p.valMin }
            if ($p.valMax -gt $mx) { $mx = $p.valMax }
        }
        $cnt = @($bucket).Count
        $avg = $sum / $cnt
        $rows += [pscustomobject]@{
            Bucket_Beijing             = ('{0} -> {1}' -f $bStart.AddHours(8).ToString('yyyy-MM-dd HH:mm'), $bEnd.AddHours(8).ToString('HH:mm'))
            Bucket_UTC                 = ('{0} -> {1}' -f $bStart.ToString('yyyy-MM-dd HH:mm'), $bEnd.ToString('HH:mm'))
            Samples                    = $cnt
            Minutes_Covered            = $cnt * $intervalMin
            Avg_ObservedInstanceCount  = [math]::Round($avg, 4)
            Min                        = $mn
            Max                        = $mx
        }
    } else {
        $rows += [pscustomobject]@{
            Bucket_Beijing             = ('{0} -> {1}' -f $bStart.AddHours(8).ToString('yyyy-MM-dd HH:mm'), $bEnd.AddHours(8).ToString('HH:mm'))
            Bucket_UTC                 = ('{0} -> {1}' -f $bStart.ToString('yyyy-MM-dd HH:mm'), $bEnd.ToString('HH:mm'))
            Samples                    = 0
            Minutes_Covered            = 0
            Avg_ObservedInstanceCount  = $null
            Min                        = $null
            Max                        = $null
        }
    }
    $bStart = $bEnd
}

Write-Host ""
Write-Host "=== Per-bucket averages ===" -ForegroundColor Green
$rows | Format-Table @{n='Bucket (Beijing)'; e={$_.Bucket_Beijing}}, `
                      @{n='Bucket (UTC)';     e={$_.Bucket_UTC}}, `
                      @{n='Samples'; e={$_.Samples}}, `
                      @{n='Minutes'; e={$_.Minutes_Covered}}, `
                      @{n='Avg';     e={$_.Avg_ObservedInstanceCount}}, `
                      @{n='Min';     e={$_.Min}}, `
                      @{n='Max';     e={$_.Max}} -AutoSize

$overall = $points | Measure-Object val -Average -Minimum -Maximum
Write-Host ("Window overall:  samples={0}  avg={1:N4}  min={2}  max={3}" -f @($points).Count, $overall.Average, $overall.Minimum, $overall.Maximum) -ForegroundColor Green
Write-Host ""
Write-Host ("Raw samples CSV : {0}" -f $rawCsv)
$rows | Export-Csv -NoTypeInformation -Encoding utf8 $bktCsv
Write-Host ("Bucket CSV      : {0}" -f $bktCsv)
Write-Host ("Source JSON     : {0}" -f $jsonOut)
