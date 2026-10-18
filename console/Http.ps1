<#
  Http.ps1 - request gate and JSON helpers for the multilink console.

  The listener prefix is http://localhost:<port>/, but http.sys accepts the
  connection on every interface and only filters by Host header, which a LAN
  client can forge. So the remote address is checked first, before anything else.
#>

function Test-RequestAllowed {
  param(
    [string]$RemoteAddress, [string]$HostHeader, [string]$Origin,
    [string]$Method, [string]$ContentType,
    [string]$Token, [string]$ExpectedToken,
    [int]$Port, [bool]$IsApi
  )
  $deny = { param($status, $reason) @{ Allowed = $false; Status = $status; Reason = $reason } }

  $ip = $null
  if (-not [Net.IPAddress]::TryParse("$RemoteAddress", [ref]$ip)) { return & $deny 403 'bad remote address' }
  if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
  if (-not [Net.IPAddress]::IsLoopback($ip)) { return & $deny 403 'not loopback' }

  # Exact Host match blocks DNS rebinding (evil.com resolving to 127.0.0.1).
  if ("$HostHeader" -ne "localhost:$Port") { return & $deny 403 'bad host' }
  if ($Origin -and $Origin -ne "http://localhost:$Port") { return & $deny 403 'bad origin' }

  if ($IsApi) {
    if (-not $Token -or -not [string]::Equals($Token, $ExpectedToken, [StringComparison]::Ordinal)) {
      return & $deny 403 'bad token'
    }
    # Forms can't send application/json without a CORS preflight, so this
    # blocks simple cross-site POSTs.
    if ($Method -eq 'POST' -and "$ContentType" -notlike 'application/json*') { return & $deny 415 'json only' }
  }
  @{ Allowed = $true; Status = 200; Reason = '' }
}

function New-Token {
  $bytes = New-Object byte[] 32
  $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-FreePort {
  param([int]$Start = 8642, [int]$End = 8662)
  for ($p = $Start; $p -le $End; $p++) {
    $l = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $p
    try { $l.Start(); $l.Stop(); return $p } catch { }
  }
  throw "No free port between $Start and $End"
}

# Handlers return either a plain object (sent as 200) or one of these.
function New-ApiResult {
  param([int]$Status = 200, $Body = @{})
  $r = [pscustomobject]@{ Status = $Status; Body = $Body }
  $r.PSObject.TypeNames.Insert(0, 'Multilink.ApiResult')
  $r
}

function New-ApiError {
  param([int]$Status, [string]$Message)
  New-ApiResult -Status $Status -Body @{ error = $Message }
}

function Send-Bytes {
  param($Ctx, [byte[]]$Bytes, [string]$ContentType, [int]$Status = 200)
  $res = $Ctx.Response
  $res.StatusCode = $Status
  $res.ContentType = $ContentType
  $res.Headers['Cache-Control'] = 'no-store'
  $res.Headers['X-Content-Type-Options'] = 'nosniff'
  $res.ContentLength64 = $Bytes.Length
  try { $res.OutputStream.Write($Bytes, 0, $Bytes.Length) } finally { $res.OutputStream.Close() }
}

function Send-Json {
  param($Ctx, $Obj, [int]$Status = 200)
  $json = if ($null -eq $Obj) { 'null' } else { ConvertTo-Json -InputObject $Obj -Depth 8 -Compress }
  Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Status
}

# ConvertFrom-Json gives PSCustomObjects in 5.1; handlers want hashtables.
function ConvertTo-Hashtable {
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
    return $h
  }
  if ($Obj -is [Array]) { return ,@($Obj | ForEach-Object { ConvertTo-Hashtable $_ }) }
  $Obj
}

function Read-JsonBody {
  param($Ctx)
  if (-not $Ctx.Request.HasEntityBody) { return @{} }
  $reader = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
  try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
  if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
  $h = ConvertTo-Hashtable (ConvertFrom-Json $text)
  if ($h -isnot [hashtable]) { return @{} }
  $h
}

# Windows argv quoting (the rules CommandLineToArgvW reverses): quote when
# needed, double backslashes that precede a quote, escape embedded quotes.
function ConvertTo-CommandLine {
  param([string[]]$Parts)
  ($Parts | ForEach-Object {
    if ($_ -and $_ -notmatch '[\s"]') { return $_ }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $_.ToCharArray()) {
      if ($ch -eq '\') { $slashes++; continue }
      if ($ch -eq '"') { [void]$sb.Append('\', $slashes * 2 + 1) }
      elseif ($slashes) { [void]$sb.Append('\', $slashes) }
      $slashes = 0
      [void]$sb.Append($ch)
    }
    [void]$sb.Append('\', $slashes * 2)
    [void]$sb.Append('"')
    $sb.ToString()
  }) -join ' '
}

# The only form of a user-supplied link that leaves this process: absolute
# http(s), re-serialised so spaces, quotes and backslashes are %-escaped and
# can never split into extra arguments.
function ConvertTo-SafeUrl {
  param([string]$Url)
  $u = $null
  if (-not [Uri]::TryCreate("$Url".Trim(), [UriKind]::Absolute, [ref]$u)) { return $null }
  if ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https') { return $null }
  $u.AbsoluteUri
}

# curl with real argv quoting. Windows PowerShell 5.1 builds `& curl.exe $x`
# command lines without escaping a trailing backslash-quote, which lets a
# crafted value smuggle in extra curl options.
function Invoke-Curl {
  param([string[]]$Arguments, [switch]$MergeError)
  $psi = New-Object Diagnostics.ProcessStartInfo 'curl.exe'
  $psi.Arguments = ConvertTo-CommandLine $Arguments
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $err = $p.StandardError.ReadToEndAsync()
  $out = $p.StandardOutput.ReadToEnd()
  $p.WaitForExit()
  if ($MergeError) { $out + $err.Result } else { $out }
}

# Starting the listener is the only reliable probe: a port held on 0.0.0.0
# passes a loopback test-bind but still makes HttpListener.Start() fail.
function Start-ConsoleListener {
  param([int]$Start = 8642, [int]$End = 8662)
  for ($p = $Start; $p -le $End; $p++) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); return @{ Listener = $l; Port = $p } } catch { $l.Close() }
  }
  throw "No free port between $Start and $End"
}
