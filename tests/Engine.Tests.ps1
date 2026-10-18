$root = Split-Path -Parent $PSScriptRoot
$dotOutput = . (Join-Path $root 'multilink.ps1')

$pingOk = @'

Pinging 1.1.1.1 from 192.168.1.24 with 32 bytes of data:
Reply from 1.1.1.1: bytes=32 time=11ms TTL=57
Reply from 1.1.1.1: bytes=32 time=12ms TTL=57
Reply from 1.1.1.1: bytes=32 time=10ms TTL=57
Reply from 1.1.1.1: bytes=32 time=15ms TTL=57
Reply from 1.1.1.1: bytes=32 time=11ms TTL=57
Reply from 1.1.1.1: bytes=32 time=12ms TTL=57

Ping statistics for 1.1.1.1:
    Packets: Sent = 6, Received = 6, Lost = 0 (0% loss),
Approximate round trip times in milli-seconds:
    Minimum = 10ms, Maximum = 15ms, Average = 11ms
'@

$pingDead = @'

Pinging 8.8.8.8 from 192.168.42.129 with 32 bytes of data:
Request timed out.
Request timed out.
Request timed out.
Request timed out.
Request timed out.
Request timed out.

Ping statistics for 8.8.8.8:
    Packets: Sent = 6, Received = 0, Lost = 6 (100% loss),
'@

Describe 'dot-sourcing multilink.ps1' {
  It 'defines functions without running the menu' {
    $dotOutput | Should BeNullOrEmpty
    (Get-Command Get-Paths -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
  }
}

Describe 'ConvertFrom-PingOutput' {
  It 'parses six replies and 0% loss' {
    $r = ConvertFrom-PingOutput $pingOk
    ($r.Times -join ',') | Should Be '11,12,10,15,11,12'
    $r.LossPct | Should Be 0
  }
  It 'parses total loss' {
    $r = ConvertFrom-PingOutput $pingDead
    @($r.Times).Count | Should Be 0
    $r.LossPct | Should Be 100
  }
}

Describe 'Get-LatencyStats' {
  It 'computes avg, max, jitter and loss' {
    $s = Get-LatencyStats @(11,12,10,15,11,12) 0
    $s.avgMs | Should Be 11.8
    $s.maxMs | Should Be 15
    $s.jitterMs | Should Be 2.6
    $s.lossPct | Should Be 0
  }
}

Describe 'Test-Ipv4Text' {
  It 'rejects null' { Test-Ipv4Text $null | Should Be $false }
  It 'accepts padded IPv4' { Test-Ipv4Text ' 49.36.112.87 ' | Should Be $true }
  It 'rejects text' { Test-Ipv4Text 'abc' | Should Be $false }
}
