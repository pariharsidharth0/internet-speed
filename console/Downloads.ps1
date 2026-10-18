<#
  Downloads.ps1 - one aria2c process per download, driven over its JSON-RPC.

  Each process gets its own loopback RPC port and secret, is tied to the
  console with --stop-with-process, and sits in the console's kill-on-close
  Job Object, so no aria2c outlives the console however it ends.
  One download runs at a time.
#>

# --- pure helpers ---------------------------------------------------------------
function New-Aria2ArgList {
  param([ValidateSet('all', 'one')][string]$Mode, [string[]]$IPs, [string]$Dir,
        [int]$Port, [string]$Secret, [int]$ConsolePid, [switch]$Continue)
  # --continue only when resuming: without a .aria2 control file aria2 would
  # treat an unrelated same-named file as a partial download of this one.
  $a = @('-x16', '-s16', '-k1M', '--file-allocation=none', '--async-dns=false',
         '--max-tries=5', '--retry-wait=2', '--connect-timeout=10', '--timeout=20', "--dir=$Dir",
         '--enable-rpc=true', '--rpc-listen-all=false', "--rpc-listen-port=$Port", "--rpc-secret=$Secret",
         "--stop-with-process=$ConsolePid", '--quiet=true', '--summary-interval=0')
  if ($Mode -eq 'all') { $a += "--multiple-interface=$($IPs -join ',')" } else { $a += "--interface=$($IPs[0])" }
  if ($Continue) { $a += '--continue=true' }
  $a
}

function Get-CapAction {
  param([bool]$CapHit, [string]$Mode, [string]$Link, [string]$MobileAlias)
  if (-not $CapHit -or -not $MobileAlias) { return 'none' }
  if ($Mode -eq 'all') { return 'switch-to-wired' }
  if ($Link -eq $MobileAlias) { return 'stop' }
  'none'
}

# Returns @{error; status} on refusal, else @{ips; mode; link; switchedByCap}.
function Test-DownloadRequest {
  param([hashtable]$Req, $Paths, [string]$MobileAlias, [bool]$CapHit, [bool]$Active)
  $fail = { param($status, $msg) @{ status = $status; error = $msg } }
  $url = ConvertTo-SafeUrl "$($Req.url)"
  if (-not $url) { return & $fail 400 'Enter a link that starts with http:// or https://' }
  if ($Active) { return & $fail 409 'A download is already running' }
  $dir = "$($Req.dir)".Trim()
  if (-not $dir) { return & $fail 400 'Choose a folder to save to' }
  try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null } }
  catch { return & $fail 400 "Can't save to $dir" }

  $paths = @($Paths)
  if (-not $paths.Count) { return & $fail 409 'No internet path found' }
  if ($Req.mode -eq 'one') {
    $p = @($paths | Where-Object { $_.Alias -eq $Req.link }) | Select-Object -First 1
    if (-not $p) { return & $fail 400 "No link named $($Req.link)" }
    if ($CapHit -and $p.Alias -eq $MobileAlias) { return & $fail 409 'Mobile data cap reached' }
    return @{ ips = @($p.IP); mode = 'one'; link = $p.Alias; switchedByCap = $false; url = $url; dir = $dir }
  }
  if ($CapHit -and $MobileAlias) {
    $w = @($paths | Where-Object { $_.Alias -ne $MobileAlias }) | Select-Object -First 1
    if (-not $w) { return & $fail 409 'Mobile data cap reached' }
    return @{ ips = @($w.IP); mode = 'one'; link = $w.Alias; switchedByCap = $true; url = $url; dir = $dir }
  }
  # aria2 makes its first request (size, redirects) on the first interface:
  # wired first, so a flaky phone link can't stall the start.
  $ordered = @($paths | Where-Object { $_.Alias -ne $MobileAlias }) + @($paths | Where-Object { $_.Alias -eq $MobileAlias })
  $ips = @($ordered | ForEach-Object { $_.IP })
  @{ ips = $ips; mode = $(if ($ips.Count -gt 1) { 'all' } else { 'one' }); link = $(if ($ips.Count -gt 1) { $null } else { $paths[0].Alias })
     switchedByCap = $false; url = $url; dir = $dir }
}

# --- aria2 RPC ------------------------------------------------------------------
# No proxy (Invoke-RestMethod in 5.1 can route localhost through a system
# proxy) and a 2 s timeout, so a hung aria2 can't stall the sampler or the
# request loop.
function Invoke-Aria2Rpc {
  param([int]$Port, [string]$Secret, [string]$Method, [object[]]$Params = @())
  $body = ConvertTo-Json -Depth 6 -Compress -InputObject @{
    jsonrpc = '2.0'; id = 'ml'; method = $Method; params = @("token:$Secret") + $Params }
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/jsonrpc")
  $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Proxy = $null
  $req.Timeout = 2000; $req.ReadWriteTimeout = 2000
  $res = $null
  try {
    $st = $req.GetRequestStream(); try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Close() }
    try { $res = $req.GetResponse() } catch [Net.WebException] { if ($_.Exception.Response) { $res = $_.Exception.Response } else { throw } }
    $rd = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
    try { $text = $rd.ReadToEnd() } finally { $rd.Close() }
  } finally { if ($res) { $res.Close() } }
  $r = ConvertFrom-Json $text
  if ($r.error) { throw "aria2: $($r.error.message)" }
  $r.result
}

function Start-Aria2Process {
  param($State, [hashtable]$Plan, [string]$OutName, [switch]$Continue)
  $aria = Get-Aria
  if (-not $aria) { throw 'aria2 is not installed and could not be installed. Install it with: winget install aria2.aria2' }
  $port = Get-FreePort -Start 6800 -End 6899
  $secret = New-Token
  $ariaArgs = New-Aria2ArgList -Mode $Plan.mode -IPs $Plan.ips -Dir $Plan.dir -Port $port -Secret $secret -ConsolePid $PID -Continue:$Continue
  $psi = New-Object Diagnostics.ProcessStartInfo $aria
  $psi.Arguments = ConvertTo-CommandLine $ariaArgs
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [Diagnostics.Process]::Start($psi)
  if ($State.JobHandle -and $State.JobHandle -ne [IntPtr]::Zero) { [void][Multilink.JobObject]::Assign($State.JobHandle, $proc.Handle) }

  $ready = $false
  for ($i = 0; $i -lt 25 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 200
    if ($proc.HasExited) { throw "aria2 exited at startup (code $($proc.ExitCode))" }
    try { Invoke-Aria2Rpc $port $secret 'aria2.getVersion' | Out-Null; $ready = $true } catch { }
  }
  if (-not $ready) { try { $proc.Kill() } catch { }; throw 'aria2 did not start its control interface within 5 s' }

  $opts = @{ dir = $Plan.dir }
  if ($OutName) { $opts.out = $OutName }
  try { $gid = Invoke-Aria2Rpc $port $secret 'aria2.addUri' (@(, @($Plan.url)) + @($opts)) }
  catch { try { $proc.Kill() } catch { }; throw }
  @{ Port = $port; Secret = $secret; Gid = $gid; Pid = $proc.Id; Process = $proc }
}

# --- lifecycle --------------------------------------------------------------------
function Start-Download {
  param($State, [hashtable]$Req)
  $cur = $State.Downloads.Current
  $active = [bool]($cur -and $cur.state -eq 'active')
  $plan = Test-DownloadRequest $Req $State.Paths $State.Mobile.Alias ([bool]$State.CapHit) $active
  if ($plan.error) { return New-ApiError $plan.status $plan.error }

  $proc = Start-Aria2Process $State $plan $null -Continue:([bool]$Req.resume)
  if ($cur) { [void]$State.Downloads.Finished.Add($cur); while ($State.Downloads.Finished.Count -gt 20) { $State.Downloads.Finished.RemoveAt(0) } }
  $perLink = @{}
  foreach ($p in @($State.Paths)) { if ($plan.ips -contains $p.IP) { $perLink[$p.Alias] = [double]0 } }
  $dl = [hashtable]::Synchronized(@{
    id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    url = $plan.url; filename = $null; dir = $plan.dir; mode = $plan.mode; link = $plan.link
    totalBytes = [double]0; completedBytes = [double]0; speedMbps = 0
    perLink = $perLink; state = 'active'
    switchedByCap = $plan.switchedByCap; stoppedByCap = $false
    message = $(if ($plan.switchedByCap) { 'Mobile data cap reached, so this download uses the wired link only.' } else { $null })
    KillAt = $null
  })
  foreach ($k in $proc.Keys) { $dl[$k] = $proc[$k] }
  $State.Downloads.Current = $dl
  @{ id = $dl.id }
}

function Stop-Aria2 {
  param($Dl, [switch]$Force)
  try { Invoke-Aria2Rpc $Dl.Port $Dl.Secret $(if ($Force) { 'aria2.forceShutdown' } else { 'aria2.shutdown' }) | Out-Null } catch { }
  $Dl.KillAt = [DateTime]::UtcNow.AddSeconds(5)
}

function Stop-Download {
  param($State, [string]$Id, [switch]$ByCap)
  $dl = $State.Downloads.Current
  if (-not $dl -or $dl.id -ne $Id) { return New-ApiError 404 'No such download' }
  if ($dl.state -ne 'active') { return @{} }
  Stop-Aria2 $dl -Force
  $dl.state = 'cancelled'
  if ($ByCap) {
    $dl.stoppedByCap = $true
    $dl.message = 'Mobile data cap reached. Paused with progress kept; raise the cap and press Resume.'
  }
  @{}
}

# Cap hit on an all-links download: restart it on the wired link only.
# --continue=true with the same file keeps every piece already on disk.
function Restart-DownloadWired {
  param($State)
  $dl = $State.Downloads.Current
  $w = @($State.Paths | Where-Object { $_.Alias -ne $State.Mobile.Alias }) | Select-Object -First 1
  if (-not $w) { Stop-Download $State $dl.id -ByCap | Out-Null; return }
  Stop-Aria2 $dl -Force
  # Two aria2 processes must never write one file.
  try { if (-not $dl.Process.WaitForExit(4000)) { $dl.Process.Kill() } } catch { }
  $plan = @{ ips = @($w.IP); mode = 'one'; link = $w.Alias; url = $dl.url; dir = $dl.dir }
  $proc = Start-Aria2Process $State $plan $dl.filename -Continue
  # The user may have cancelled or started another download meanwhile.
  if ($State.Downloads.Current -ne $dl -or $dl.state -ne 'active') {
    try { Invoke-Aria2Rpc $proc.Port $proc.Secret 'aria2.forceShutdown' | Out-Null } catch { }
    return
  }
  foreach ($k in $proc.Keys) { $dl[$k] = $proc[$k] }
  $dl.KillAt = $null
  $dl.mode = 'one'; $dl.link = $w.Alias; $dl.switchedByCap = $true
  $dl.message = "Mobile data cap reached. Continuing over $($w.Alias) only; nothing already downloaded is lost."
}

# Called by the sampler once a second.
function Update-Downloads {
  param($State)
  $dl = $State.Downloads.Current
  if (-not $dl) { return }
  if ($dl.KillAt -and [DateTime]::UtcNow -gt $dl.KillAt) {
    try { if (-not $dl.Process.HasExited) { $dl.Process.Kill() } } catch { }
    $dl.KillAt = $null
  }
  if ($dl.state -ne 'active') { return }

  try {
    $s = Invoke-Aria2Rpc $dl.Port $dl.Secret 'aria2.tellStatus' @($dl.Gid, @('status', 'totalLength', 'completedLength', 'downloadSpeed', 'files', 'errorMessage'))
  } catch {
    if ($dl.Process.HasExited) { $dl.state = 'error'; $dl.message = 'aria2 stopped unexpectedly.' }
    return
  }
  $dl.totalBytes = [double]$s.totalLength
  $dl.completedBytes = [double]$s.completedLength
  $dl.speedMbps = [math]::Round([double]$s.downloadSpeed * 8 / 1e6, 1)
  $path = @($s.files)[0].path
  if ($path) { $dl.filename = Split-Path -Leaf $path }

  # aria2 doesn't report bytes per interface; attribute each link's measured
  # traffic, minus other apps' traffic on it when the ETW monitor knows it.
  if ($State.AppMonitorMode -eq 'etw') {
    foreach ($alias in @($dl.perLink.Keys)) {
      $r = $State.Rates[$alias]
      if (-not $r) { continue }
      $other = 0.0
      foreach ($row in @($State.Apps.rows)) {
        if ($row.exe -ne 'aria2c.exe' -and $row.perLink -and $row.perLink[$alias]) { $other += [double]$row.perLink[$alias] }
      }
      $dl.perLink[$alias] += [math]::Max(0, ([double]$r.rx - $other)) * 1e6 / 8
    }
  }

  switch ($s.status) {
    'complete' { $dl.state = 'complete'; $dl.completedBytes = $dl.totalBytes; Stop-Aria2 $dl }
    'error'    { $dl.state = 'error'; $dl.message = $(if ($s.errorMessage) { "$($s.errorMessage)" } else { 'aria2 reported an error.' }); Stop-Aria2 $dl }
    'removed'  { $dl.state = 'cancelled'; Stop-Aria2 $dl }
  }
}

# Called by the sampler once a second; acts on the rising edge of the cap.
function Update-Cap {
  param($State)
  $mobile = $State.Mobile.Alias
  $hit = [bool]($mobile -and (Get-SessionGB $State) -ge [double]$State.Settings.capGB)
  $was = [bool]$State.CapHit
  $State.CapHit = $hit
  if (-not $hit -or $was) { return }
  $dl = $State.Downloads.Current
  if (-not $dl -or $dl.state -ne 'active') { return }
  switch (Get-CapAction -CapHit $true -Mode $dl.mode -Link $dl.link -MobileAlias $mobile) {
    'switch-to-wired' { Restart-DownloadWired $State }
    'stop'            { Stop-Download $State $dl.id -ByCap | Out-Null }
  }
}

function Get-DownloadDto {
  param($Dl)
  if (-not $Dl) { return $null }
  $per = $null
  if ($Dl.perLink -and @($Dl.perLink.Values | Where-Object { $_ -gt 0 }).Count) { $per = $Dl.perLink }
  [ordered]@{
    id = $Dl.id; url = $Dl.url; filename = $Dl.filename; dir = $Dl.dir; mode = $Dl.mode; link = $Dl.link
    totalBytes = $Dl.totalBytes; completedBytes = $Dl.completedBytes; speedMbps = $Dl.speedMbps
    perLinkBytes = $per; state = $Dl.state; switchedByCap = [bool]$Dl.switchedByCap; stoppedByCap = [bool]$Dl.stoppedByCap
    message = $Dl.message
  }
}

function Stop-AllDownloads {
  param($State)
  $dl = $State.Downloads.Current
  if ($dl -and $dl.Process) {
    try { Invoke-Aria2Rpc $dl.Port $dl.Secret 'aria2.forceShutdown' | Out-Null } catch { }
    try { if (-not $dl.Process.WaitForExit(3000)) { $dl.Process.Kill() } } catch { }
  }
}

# aria2c processes started by a console that no longer exists (it crashed
# before --stop-with-process noticed). Only ours carry that flag.
function Select-OrphanAria2 {
  param([object[]]$Processes, [int[]]$AlivePids)
  @($Processes | Where-Object {
    $_.CommandLine -match '--stop-with-process=(\d+)' -and $AlivePids -notcontains [int]$Matches[1]
  })
}

function Stop-OrphanAria2 {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='aria2c.exe'" -ErrorAction SilentlyContinue)
  if (-not $procs.Count) { return }
  $alive = @(Get-Process | ForEach-Object { $_.Id })
  foreach ($o in (Select-OrphanAria2 -Processes $procs -AlivePids $alive)) {
    Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
  }
}
