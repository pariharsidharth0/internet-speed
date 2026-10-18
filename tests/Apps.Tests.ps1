$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'multilink.ps1')
. (Join-Path $root 'console\Store.ps1')
. (Join-Path $root 'console\Apps.ps1')

$paths = @(
  [pscustomobject]@{ Alias = 'Ethernet'; IP = '192.168.1.24'; IPv6 = @('2405:201::24') },
  [pscustomobject]@{ Alias = 'Ethernet 2'; IP = '192.168.42.129'; IPv6 = @() })
$names = @{ 100 = @{ exe = 'aria2c.exe'; name = 'aria2c' }; 200 = @{ exe = 'chrome.exe'; name = 'Google Chrome' } }

Describe 'NetAggregator + Group-AppTraffic' {
  $agg = New-Object Multilink.NetAggregator
  $agg.SetLocalAddresses([string[]]@('192.168.1.24', '192.168.42.129', '2405:201::24'))
  # Local address may sit in either field; the aggregator works out which.
  $agg.Add(100, $false, 18875000, '91.189.91.38', 443, '192.168.1.24', 50000, $false)
  $agg.Add(100, $false, 31500000, '192.168.42.129', 50001, '91.189.91.39', 443, $false)
  $agg.Add(200, $false, 400000, '142.250.1.1', 443, '192.168.1.24', 50002, $true)
  $agg.Add(300, $false, 999999, '172.20.0.5', 1, '172.20.0.1', 2, $false)
  $rows = @(Group-AppTraffic -Rows $agg.Drain() -Paths $paths -Seconds 1 -ProcessNames $names -MobileAlias 'Ethernet 2')

  It 'drops traffic on addresses that are not internet links' { $rows.Count | Should Be 2 }
  It 'sorts by download speed and sums both links' {
    $rows[0].exe | Should Be 'aria2c.exe'
    $rows[0].downMbps | Should Be 403.0
    $rows[0].perLink['Ethernet'] | Should Be 151.0
    $rows[0].perLink['Ethernet 2'] | Should Be 252.0
  }
  It 'labels UDP to port 443 as QUIC' {
    $rows[1].protos -contains 'QUIC' | Should Be $true
    $rows[1].downMbps | Should Be 3.2
  }
  It 'counts distinct remote endpoints' { $rows[0].conns | Should Be 2 }
  It 'empties after a drain' { @($agg.Drain()).Count | Should Be 0 }
}

Describe 'Test-IsGame' {
  It 'knows cs2' { Test-IsGame 'cs2.exe' | Should Be $true }
  It 'is case-insensitive' { Test-IsGame 'VALORANT-Win64-Shipping.EXE' | Should Be $true }
  It 'ignores a browser' { Test-IsGame 'chrome.exe' | Should Be $false }
}

Describe 'laggy flag' {
  $agg = New-Object Multilink.NetAggregator
  $agg.SetLocalAddresses([string[]]@('192.168.1.24', '192.168.42.129'))
  $gameNames = @{ 7 = @{ exe = 'cs2.exe'; name = 'Counter-Strike 2' } }
  It 'flags a game with 10% on the mobile link' {
    $agg.Add(7, $false, 900, '1.1.1.1', 27015, '192.168.1.24', 5000, $true)
    $agg.Add(7, $false, 100, '1.1.1.1', 27015, '192.168.42.129', 5001, $true)
    $r = @(Group-AppTraffic -Rows $agg.Drain() -Paths $paths -Seconds 1 -ProcessNames $gameNames -MobileAlias 'Ethernet 2')
    $r[0].game | Should Be $true
    $r[0].laggy | Should Be $true
  }
  It 'does not flag a game fully on wired' {
    $agg.Add(7, $false, 1000, '1.1.1.1', 27015, '192.168.1.24', 5000, $true)
    $r = @(Group-AppTraffic -Rows $agg.Drain() -Paths $paths -Seconds 1 -ProcessNames $gameNames -MobileAlias 'Ethernet 2')
    $r[0].laggy | Should Be $false
  }
}

Describe 'NetMonitor type' {
  It 'compiles under 5.1' { ('Multilink.NetMonitor' -as [type]) | Should Not BeNullOrEmpty }
}
