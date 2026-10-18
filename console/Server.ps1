<#
  Server.ps1 - the multilink console's local web server.

  A thin API layer (Facade) over the engine in multilink.ps1. The request loop
  runs on the main thread and never blocks on slow work: long actions run in
  background runspaces that write into one synchronized state hashtable.
#>

$script:ConsoleDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Http.ps1')
. (Join-Path $PSScriptRoot 'Store.ps1')
. (Join-Path $PSScriptRoot 'Jobs.ps1')
. (Join-Path $PSScriptRoot 'Watch.ps1')
. (Join-Path $PSScriptRoot 'Downloads.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'multilink.ps1')

# "METHOD /path" -> scriptblock { param($ctx, $state, $body, $m) }
# $m holds regex captures for parameterised routes.
$script:Routes = [ordered]@{}
function Register-Route {
  param([string]$Method, [string]$Pattern, [scriptblock]$Handler)
  $script:Routes["$Method $Pattern"] = @{ Method = $Method; Regex = "^$Pattern$"; Handler = $Handler }
}

function Find-Route {
  param([string]$Method, [string]$Path)
  foreach ($r in $script:Routes.Values) {
    if ($r.Method -eq $Method -and $Path -match $r.Regex) { return @{ Handler = $r.Handler; Match = $Matches.Clone() } }
  }
  $null
}

function Write-ConsoleLine {
  param([string]$Text)
  Write-Host ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $Text)
}

function Send-Page {
  param($Ctx, $State)
  $html = [IO.File]::ReadAllText((Join-Path $script:ConsoleDir 'index.html'))
  $html = $html.Replace('{{TOKEN}}', $State.Token).Replace('{{PORT}}', "$($State.Port)")
  $Ctx.Response.Headers['Content-Security-Policy'] =
    "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'"
  Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
}

# For handlers whose work can take seconds (network probes): the response is
# written from a background runspace so the request loop keeps serving.
function Start-DeferredResponse {
  param($State, $Ctx, [scriptblock]$Work, [object[]]$Arguments = @())
  Start-BackgroundRunspace $State 'deferred' {
    param($ctx, $body, $a)
    try {
      $r = & ([scriptblock]::Create($body)) @a
      if ($r -and $r.PSObject.TypeNames -contains 'Multilink.ApiResult') { Send-Json $ctx $r.Body $r.Status } else { Send-Json $ctx $r }
    } catch { try { Send-Json $ctx @{ error = $_.Exception.Message } 500 } catch { } }
  } -Arguments @($Ctx, $Work.ToString(), $Arguments) | Out-Null
  $d = [pscustomobject]@{}
  $d.PSObject.TypeNames.Insert(0, 'Multilink.Deferred')
  $d
}

function Invoke-Request {
  param($Ctx, $State)
  $req = $Ctx.Request
  $path = $req.Url.AbsolutePath
  $isApi = $path.StartsWith('/api/')
  $gate = Test-RequestAllowed -RemoteAddress $req.RemoteEndPoint.Address.ToString() `
    -HostHeader $req.Headers['Host'] -Origin $req.Headers['Origin'] -Method $req.HttpMethod `
    -ContentType $req.ContentType -Token $req.Headers['X-Multilink-Token'] -ExpectedToken $State.Token `
    -Port $State.Port -IsApi $isApi
  if (-not $gate.Allowed) {
    # Don't explain refusals to whoever is probing.
    Send-Json $Ctx @{ error = 'Forbidden' } $gate.Status
    return
  }

  if (-not $isApi) {
    if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) { Send-Page $Ctx $State }
    else { Send-Json $Ctx @{ error = 'Not found' } 404 }
    return
  }

  $route = Find-Route $req.HttpMethod $path
  if (-not $route) { Send-Json $Ctx @{ error = 'Not found' } 404; return }
  if ($req.HttpMethod -ne 'GET') { Write-ConsoleLine "$($req.HttpMethod) $path" }
  try {
    $body = if ($req.HttpMethod -eq 'POST') { Read-JsonBody $Ctx } else { @{} }
    $result = & $route.Handler $Ctx $State $body $route.Match
    if ($result -and $result.PSObject.TypeNames -contains 'Multilink.Deferred') { return }
    if ($result -and $result.PSObject.TypeNames -contains 'Multilink.ApiResult') { Send-Json $Ctx $result.Body $result.Status }
    else { Send-Json $Ctx $result }
  } catch {
    Write-ConsoleLine "  error: $($_.Exception.Message)"
    try { Send-Json $Ctx @{ error = $_.Exception.Message } 500 } catch { }
  }
}

# --- routes -------------------------------------------------------------------
Register-Route 'GET'  '/api/state' { param($ctx, $state) Get-StateDto $state }
Register-Route 'GET'  '/api/series' {
  param($ctx, $state)
  $copy = $null
  [Threading.Monitor]::Enter($state.Series.SyncRoot)
  try { $copy = @($state.Series.ToArray()) } finally { [Threading.Monitor]::Exit($state.Series.SyncRoot) }
  @{ intervalSec = 1; samples = $copy }
}
Register-Route 'POST' '/api/settings' {
  param($ctx, $state, $body)
  if ($body.ContainsKey('capGB')) {
    $cap = 0.0
    if (-not [double]::TryParse("$($body.capGB)", [ref]$cap) -or $cap -lt 1) { return New-ApiError 400 'Cap must be at least 1 GB' }
    $state.Settings.capGB = $cap
  }
  if ($body.ContainsKey('mobileAlias')) {
    $state.Settings.mobileAlias = $(if ($body.mobileAlias) { "$($body.mobileAlias)" } else { $null })
    $state.Mobile.Alias = Find-MobileAlias $state.Paths $state.Settings.mobileAlias
  }
  Save-Settings -Settings $state.Settings
  Get-StateDto $state
}
Register-Route 'GET' '/api/jobs/(?<id>[0-9a-f]{12})' {
  param($ctx, $state, $body, $m)
  $job = $state.Jobs[$m.id]
  if (-not $job) { return New-ApiError 404 'No such job' }
  Get-JobDto $job
}
Register-Route 'POST' '/api/check' {
  param($ctx, $state)
  @{ jobId = (Start-ConsoleJob $state 'check' { param($state, $emit) Invoke-CheckJob $state $emit }) }
}
Register-Route 'POST' '/api/recheck' {
  param($ctx, $state)
  @{ jobId = (Start-ConsoleJob $state 'recheck' {
    param($state, $emit)
    $results = Invoke-EgressCheck $state
    foreach ($r in $results) { & $emit ("  {0,-14} -> {1}" -f $r.Alias, $(if ($r.PublicIp) { $r.PublicIp } else { '(no response)' })) 'info' }
    foreach ($l in (Get-SeparationLines $state.Separation.status @($results).Count)) { & $emit $l.text $l.level }
    @{ separation = $state.Separation.status }
  }) }
}
Register-Route 'POST' '/api/baseline' {
  param($ctx, $state)
  @{ jobId = (Start-ConsoleJob $state 'baseline' { param($state, $emit) Invoke-Baseline $state $emit }) }
}
Register-Route 'POST' '/api/range' {
  param($ctx, $state, $body)
  $url = "$($body.url)".Trim()
  if ($url -notmatch '^https?://') { return New-ApiError 400 'Enter a link that starts with http:// or https://' }
  Start-DeferredResponse $state $ctx { param($u) Invoke-RangeProbe $u } @($url)
}
Register-Route 'GET' '/api/downloads' {
  param($ctx, $state)
  @{ current = (Get-DownloadDto $state.Downloads.Current)
     finished = @($state.Downloads.Finished.ToArray() | ForEach-Object { Get-DownloadDto $_ }) }
}
Register-Route 'POST' '/api/downloads' { param($ctx, $state, $body) Start-Download $state $body }
Register-Route 'POST' '/api/downloads/(?<id>[0-9a-f]{12})/cancel' {
  param($ctx, $state, $body, $m)
  Stop-Download $state $m.id
}
Register-Route 'POST' '/api/stop'  { param($ctx, $state) $state.Stopping = $true; @{} }

# --- entry --------------------------------------------------------------------
function Start-MultilinkConsole {
  param([string]$Root = (Split-Path -Parent $PSScriptRoot), [switch]$NoBrowser, [int]$Port = 0)

  $state = New-ConsoleState
  $state.Root = $Root
  $state.IsAdmin = Test-Admin
  $state.JobHandle = [Multilink.JobObject]::CreateKillOnClose()
  Update-Paths $state
  $state.Token = New-Token
  $state.Port = if ($Port) { $Port } else { Get-FreePort -Start 8642 -End 8662 }

  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add("http://localhost:$($state.Port)/")
  $listener.Start()
  $url = "http://localhost:$($state.Port)/"
  [IO.File]::WriteAllText((Join-Path $env:TEMP 'multilink-console.url'), $url)
  Write-ConsoleLine "Multilink console running at $url  (close this window to stop)"
  Start-Sampler $state
  Start-Watcher $state
  Start-ConsoleJob $state 'latency' { param($state, $emit) Invoke-LatencyPass $state $null } | Out-Null
  if (-not $NoBrowser) { Start-Process explorer.exe $url }

  try {
    while (-not $state.Stopping) {
      $iar = $listener.BeginGetContext($null, $null)
      # Wake every 250 ms so a stop request or close handler is never stuck
      # behind a blocking GetContext.
      while (-not $iar.AsyncWaitHandle.WaitOne(250)) { if ($state.Stopping) { break } }
      if ($state.Stopping -and -not $iar.IsCompleted) { break }
      $ctx = $listener.EndGetContext($iar)
      Invoke-Request $ctx $state
    }
  } finally {
    $state.Stopping = $true
    $listener.Stop(); $listener.Close()
    Stop-AllDownloads $state
    $state.IfPoller.Dispose()
    foreach ($r in @($state.Runspaces.ToArray())) {
      try { [void]$r.Handle.AsyncWaitHandle.WaitOne(2000); $r.PowerShell.Stop(); $r.PowerShell.Runspace.Dispose(); $r.PowerShell.Dispose() } catch { }
    }
    Remove-Item (Join-Path $env:TEMP 'multilink-console.url') -ErrorAction SilentlyContinue
    Write-ConsoleLine 'Console stopped.'
  }
}
