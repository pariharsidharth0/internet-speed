<#
  Server.ps1 - the multilink console's local web server.

  A thin API layer (Facade) over the engine in multilink.ps1. The request loop
  runs on the main thread and never blocks on slow work: long actions run in
  background runspaces that write into one synchronized state hashtable.
#>

$script:ConsoleDir = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Http.ps1')
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
    if ($result -and $result.PSObject.TypeNames -contains 'Multilink.ApiResult') { Send-Json $Ctx $result.Body $result.Status }
    else { Send-Json $Ctx $result }
  } catch {
    Write-ConsoleLine "  error: $($_.Exception.Message)"
    try { Send-Json $Ctx @{ error = $_.Exception.Message } 500 } catch { }
  }
}

# --- routes -------------------------------------------------------------------
Register-Route 'GET'  '/api/state' { param($ctx, $state) @{ ok = $true } }
Register-Route 'POST' '/api/stop'  { param($ctx, $state) $state.Stopping = $true; @{} }

# --- entry --------------------------------------------------------------------
function Start-MultilinkConsole {
  param([string]$Root = (Split-Path -Parent $PSScriptRoot), [switch]$NoBrowser, [int]$Port = 0)

  $state = [hashtable]::Synchronized(@{ Stopping = $false })
  $state.Root = $Root
  $state.Token = New-Token
  $state.Port = if ($Port) { $Port } else { Get-FreePort -Start 8642 -End 8662 }

  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add("http://localhost:$($state.Port)/")
  $listener.Start()
  $url = "http://localhost:$($state.Port)/"
  [IO.File]::WriteAllText((Join-Path $env:TEMP 'multilink-console.url'), $url)
  Write-ConsoleLine "Multilink console running at $url  (close this window to stop)"
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
    $listener.Stop(); $listener.Close()
    Remove-Item (Join-Path $env:TEMP 'multilink-console.url') -ErrorAction SilentlyContinue
    Write-ConsoleLine 'Console stopped.'
  }
}
