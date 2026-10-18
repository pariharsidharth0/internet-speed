<#
  integration.ps1 - start a real console (no browser) and probe it over HTTP.
  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/integration.ps1
  Exit code 1 if any check fails.
#>
param([switch]$Quick)   # -Quick skips checks that need real internet / downloads

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$urlFile = Join-Path $env:TEMP 'multilink-console.url'
$script:failed = 0

function Check {
  param([string]$Name, [scriptblock]$Test)
  try {
    $ok = & $Test
    if ($ok) { Write-Host "PASS  $Name" -ForegroundColor Green }
    else { Write-Host "FAIL  $Name" -ForegroundColor Red; $script:failed++ }
  } catch { Write-Host "FAIL  $Name  ($($_.Exception.Message))" -ForegroundColor Red; $script:failed++ }
}

# curl.exe returns body + status; -H lets us forge Host/Origin.
function Http {
  param([string]$Method = 'GET', [string]$Path, $Body = $null, [string[]]$Headers = @(), [switch]$NoToken)
  $args = @('-s', '-m', '20', '-X', $Method, '-w', "`n%{http_code}")
  if (-not $NoToken) { $args += @('-H', "X-Multilink-Token: $script:token") }
  foreach ($h in $Headers) { $args += @('-H', $h) }
  if ($null -ne $Body) {
    $tmp = Join-Path $env:TEMP 'ml-it-body.json'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json $Body -Depth 6 -Compress))
    $args += @('-H', 'Content-Type: application/json', '--data-binary', "@$tmp")
  }
  $out = & curl.exe @args "$script:base$Path"
  $lines = @($out)
  $status = [int]$lines[-1]
  $text = ($lines[0..($lines.Count - 2)] -join "`n")
  $json = $null; try { $json = ConvertFrom-Json $text } catch { }
  [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}

Remove-Item $urlFile -ErrorAction SilentlyContinue
$cmd = ". '$root\console\Server.ps1'; Start-MultilinkConsole -Root '$root' -NoBrowser"
$proc = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)

try {
  $deadline = (Get-Date).AddSeconds(20)
  while (-not (Test-Path $urlFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  if (-not (Test-Path $urlFile)) { throw "console did not start (no $urlFile)" }
  $script:base = (Get-Content $urlFile -Raw).Trim().TrimEnd('/')
  $page = Http -Path '/' -NoToken
  $script:token = [regex]::Match($page.Text, 'name="ml-token" content="([0-9a-f]{64})"').Groups[1].Value

  # --- Task 2: gate --------------------------------------------------------
  Check 'page served with a token' { $page.Status -eq 200 -and $script:token.Length -eq 64 }
  Check 'api without token -> 403' { (Http -Path '/api/state' -NoToken).Status -eq 403 }
  Check 'api with token -> 200' { (Http -Path '/api/state').Status -eq 200 }
  Check 'forged Host -> rejected (http.sys 400 or gate 403)' { (Http -Path '/api/state' -Headers 'Host: evil.com').Status -in 400, 403 }
  Check 'foreign Origin -> 403' { (Http -Path '/api/state' -Headers 'Origin: http://evil.com').Status -eq 403 }
  Check 'unknown api route -> 404' { (Http -Path '/api/nope').Status -eq 404 }

  # --- Task 3: state + series -----------------------------------------------
  # The sampler runspace needs a few seconds to load the engine.
  $deadline = (Get-Date).AddSeconds(15)
  do { Start-Sleep -Milliseconds 500; $n = @((Http -Path '/api/series').Json.samples).Count } while ($n -lt 3 -and (Get-Date) -lt $deadline)
  $st = (Http -Path '/api/state').Json
  Check 'state lists paths' { @($st.paths).Count -ge 1 -and $st.paths[0].alias }
  Check 'series has >=2 samples keyed by every path' {
    $se = (Http -Path '/api/series').Json
    $aliases = @($st.paths | ForEach-Object { $_.alias })
    @($se.samples).Count -ge 2 -and -not (@($se.samples | Where-Object { $s = $_; @($aliases | Where-Object { -not $s.links.PSObject.Properties[$_] }).Count }).Count)
  }
  Check 'settings rejects cap 0' { (Http -Method POST -Path '/api/settings' -Body @{ capGB = 0 }).Status -eq 400 }

  # --- Task 5: jobs, range ---------------------------------------------------
  Check 'unknown job -> 404' { (Http -Path '/api/jobs/000000000000').Status -eq 404 }
  Check 'range rejects a non-http link' { (Http -Method POST -Path '/api/range' -Body @{ url = 'ftp://x' }).Status -eq 400 }
  if (-not $Quick) {
    Check 'range: Ubuntu ISO splits' {
      $r = (Http -Method POST -Path '/api/range' -Body @{ url = 'https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso' }).Json
      $r.splits -eq $true -and $r.sizeBytes -gt 1e9 -and $r.filename -eq 'ubuntu-24.04.5.1-desktop-amd64.iso'
    }
    Check 'requests are served while a range probe runs' {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $job = Start-Job { param($b, $t) curl.exe -s -m 20 -X POST -H "X-Multilink-Token: $t" -H 'Content-Type: application/json' --data-binary '{"url":"https://10.255.255.1/x.iso"}' "$b/api/range" } -ArgumentList $script:base, $script:token
      Start-Sleep -Milliseconds 800
      $ok = (Http -Path '/api/state').Status -eq 200 -and $sw.Elapsed.TotalSeconds -lt 5
      Receive-Job $job -Wait -AutoRemoveJob | Out-Null
      $ok
    }
    Check 'check job completes with output' {
      $id = (Http -Method POST -Path '/api/check' -Body @{}).Json.jobId
      $deadline = (Get-Date).AddSeconds(150)
      do { Start-Sleep 2; $j = (Http -Path "/api/jobs/$id").Json } while ($j.state -eq 'running' -and (Get-Date) -lt $deadline)
      $j.state -eq 'done' -and (@($j.log | Where-Object { $_.text -like 'Public egress IP per path*' }).Count -eq 1)
    }
  }

  # --- Task 6: downloads -----------------------------------------------------
  Check 'download rejects a non-http link' {
    $r = Http -Method POST -Path '/api/downloads' -Body @{ url = 'nope'; mode = 'all'; dir = $env:TEMP }
    $r.Status -eq 400 -and $r.Json.error -eq 'Enter a link that starts with http:// or https://'
  }
  if (-not $Quick) {
    $dlDir = Join-Path $env:TEMP 'ml-it'
    Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue
    $iso = 'https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso'
    $start = Http -Method POST -Path '/api/downloads' -Body @{ url = $iso; mode = 'all'; dir = $dlDir }
    Check 'download starts' { $start.Status -eq 200 -and $start.Json.id }
    Check 'a second download is refused' {
      $r = Http -Method POST -Path '/api/downloads' -Body @{ url = $iso; mode = 'all'; dir = $dlDir }
      $r.Status -eq 409 -and $r.Json.error -eq 'A download is already running'
    }
    Start-Sleep -Seconds 8
    $d = (Http -Path '/api/downloads').Json.current
    Check 'download makes progress' { $d.state -eq 'active' -and $d.completedBytes -gt 0 -and $d.filename -eq 'ubuntu-24.04.5.1-desktop-amd64.iso' }
    $ariaPid = (Get-CimInstance Win32_Process -Filter "Name='aria2c.exe'" | Where-Object { $_.CommandLine -like "*stop-with-process=$($proc.Id)*" }).ProcessId
    Check 'aria2 is tied to the console' { @($ariaPid).Count -eq 1 }
    $c = Http -Method POST -Path "/api/downloads/$($start.Json.id)/cancel" -Body @{}
    Start-Sleep -Seconds 6
    Check 'cancel stops aria2 and keeps the control file' {
      $c.Status -eq 200 -and (Http -Path '/api/downloads').Json.current.state -eq 'cancelled' -and
        -not (Get-Process -Id $ariaPid -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $dlDir 'ubuntu-24.04.5.1-desktop-amd64.iso.aria2'))
    }
    Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # --- Task 7: admin actions (the test console is not elevated) -------------
  Check 'prefer without admin -> 409' {
    $r = Http -Method POST -Path '/api/prefer' -Body @{ alias = 'Ethernet' }
    $r.Status -eq 409 -and $r.Json.error -eq 'Restart the console as administrator'
  }
  Check 'reset apply without admin -> 409' { (Http -Method POST -Path '/api/reset' -Body @{ apply = $true }).Status -eq 409 }
  Check 'reset preview streams the report' {
    $id = (Http -Method POST -Path '/api/reset' -Body @{ apply = $false }).Json.jobId
    $deadline = (Get-Date).AddSeconds(60)
    do { Start-Sleep 1; $j = (Http -Path "/api/jobs/$id").Json } while ($j.state -eq 'running' -and (Get-Date) -lt $deadline)
    $j.state -eq 'done' -and @($j.log | Where-Object { $_.text -like '*Interface metrics*' }).Count -ge 1
  }

  # --- later tasks append checks here --------------------------------------

  Check 'stop -> process exits' {
    $null = Http -Method POST -Path '/api/stop' -Body @{}
    $proc.WaitForExit(8000)
  }
} finally {
  if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
}

if ($script:failed) { Write-Host "$script:failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All integration checks passed' -ForegroundColor Green
