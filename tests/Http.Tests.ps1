$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'console\Http.ps1')

function Gate {
  param($Remote = '127.0.0.1', $HostHeader = 'localhost:8642', $Origin = $null,
        $Method = 'GET', $ContentType = $null, $Token = 'tok', $IsApi = $true)
  Test-RequestAllowed -RemoteAddress $Remote -HostHeader $HostHeader -Origin $Origin -Method $Method `
    -ContentType $ContentType -Token $Token -ExpectedToken 'tok' -Port 8642 -IsApi $IsApi
}

Describe 'Test-RequestAllowed' {
  It 'rejects a LAN client' { (Gate -Remote '192.168.1.50').Status | Should Be 403 }
  It 'allows IPv4 loopback' { (Gate -Remote '127.0.0.1').Allowed | Should Be $true }
  It 'allows IPv6 loopback' { (Gate -Remote '::1').Allowed | Should Be $true }
  It 'rejects a foreign Host header' { (Gate -HostHeader 'evil.com:8642').Status | Should Be 403 }
  It 'rejects a foreign Origin' { (Gate -Origin 'http://evil.com').Status | Should Be 403 }
  It 'allows the console Origin' { (Gate -Origin 'http://localhost:8642').Allowed | Should Be $true }
  It 'rejects a wrong token' { (Gate -Token 'x').Status | Should Be 403 }
  It 'rejects a missing token' { (Gate -Token $null).Status | Should Be 403 }
  It 'rejects a non-JSON POST' { (Gate -Method 'POST' -ContentType 'text/plain').Status | Should Be 415 }
  It 'allows a JSON POST' { (Gate -Method 'POST' -ContentType 'application/json; charset=utf-8').Allowed | Should Be $true }
  It 'serves the page without a token' { (Gate -Token $null -IsApi $false).Allowed | Should Be $true }
  It 'still checks Host for the page' { (Gate -Token $null -IsApi $false -HostHeader 'evil.com').Status | Should Be 403 }
}

Describe 'New-Token' {
  It 'is 64 lowercase hex chars and random' {
    $a = New-Token; $b = New-Token
    $a.Length | Should Be 64
    $a -cmatch '^[0-9a-f]+$' | Should Be $true
    $a | Should Not Be $b
  }
}

Describe 'Get-FreePort' {
  It 'skips a port that is in use' {
    $l = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 8642
    $l.Start()
    try { Get-FreePort -Start 8642 -End 8662 | Should Be 8643 } finally { $l.Stop() }
  }
  It 'throws when the whole range is taken' {
    $l = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 8650
    $l.Start()
    try { { Get-FreePort -Start 8650 -End 8650 } | Should Throw 'No free port between 8650 and 8650' } finally { $l.Stop() }
  }
}

Describe 'ConvertTo-SafeUrl' {
  It 'rejects non-http and relative links' {
    ConvertTo-SafeUrl 'javascript:alert(1)' | Should BeNullOrEmpty
    ConvertTo-SafeUrl '/relative/path' | Should BeNullOrEmpty
    ConvertTo-SafeUrl 'ftp://x/a.iso' | Should BeNullOrEmpty
  }
  It 'escapes quotes and spaces so nothing can become a separate argument' {
    $u = ConvertTo-SafeUrl 'http://127.0.0.1:1/\" -w INJECTED -o NUL http://127.0.0.1:1/'
    $u | Should Not BeNullOrEmpty
    $u -match '[\s"]' | Should Be $false
  }
  It 'keeps a normal link intact' {
    ConvertTo-SafeUrl 'https://releases.ubuntu.com/24.04/a.iso?x=1&y=2' | Should Be 'https://releases.ubuntu.com/24.04/a.iso?x=1&y=2'
  }
}

Describe 'Invoke-Curl' {
  It 'passes a hostile value as one argument (no option injection)' {
    $payload = 'http://127.0.0.1:1/\" -w INJECTED-%{http_code} -o NUL http://127.0.0.1:1/'
    $out = Invoke-Curl @('-s', '--max-time', '3', '-o', 'NUL', '-w', 'X%{http_code}', '--url', $payload)
    "$out" | Should Be 'X000'
  }
}

Describe 'Start-ConsoleListener' {
  It 'falls back when the first port is held on all interfaces' {
    $l = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Any), 8655
    $l.Start()
    try {
      $r = Start-ConsoleListener -Start 8655 -End 8660
      try { $r.Port | Should Not Be 8655; $r.Listener.IsListening | Should Be $true } finally { $r.Listener.Close() }
    } finally { $l.Stop() }
  }
}
