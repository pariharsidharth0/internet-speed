$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'console\Store.ps1')

Describe 'Get-RateTable' {
  It 'converts a byte delta to Mbps' {
    $r = Get-RateTable @{ 'Ethernet' = @{ Rx = 0; Tx = 0 } } @{ 'Ethernet' = @{ Rx = 18875000; Tx = 125000 } } 1
    $r['Ethernet'].rx | Should Be 151.0
    $r['Ethernet'].tx | Should Be 1.0
  }
  It 'gives 0 for a link that just appeared' {
    $r = Get-RateTable @{} @{ 'Ethernet 2' = @{ Rx = 5000000; Tx = 0 } } 1
    $r['Ethernet 2'].rx | Should Be 0
  }
  It 'gives 0 when the counter went backwards' {
    $r = Get-RateTable @{ 'Ethernet' = @{ Rx = 900; Tx = 900 } } @{ 'Ethernet' = @{ Rx = 100; Tx = 100 } } 1
    $r['Ethernet'].rx | Should Be 0
  }
  It 'drops a link that disappeared' {
    $r = Get-RateTable @{ 'Ethernet 2' = @{ Rx = 1; Tx = 1 } } @{ 'Ethernet' = @{ Rx = 1; Tx = 1 } } 1
    $r.ContainsKey('Ethernet 2') | Should Be $false
  }
}

Describe 'Add-Sample' {
  It 'keeps only the newest 60' {
    $series = New-Object System.Collections.ArrayList
    1..61 | ForEach-Object { Add-Sample $series @{ t = $_ } 60 }
    $series.Count | Should Be 60
    $series[0].t | Should Be 2
  }
}

Describe 'Find-MobileAlias' {
  $paths = @(
    [pscustomobject]@{ Alias = 'Ethernet'; Description = 'Realtek Gaming 2.5GbE Family Controller' },
    [pscustomobject]@{ Alias = 'Ethernet 2'; Description = 'SAMSUNG Mobile USB Remote NDIS Network Device' })
  It 'detects the RNDIS tether' { Find-MobileAlias $paths $null | Should Be 'Ethernet 2' }
  It 'honours an override' { Find-MobileAlias $paths 'Ethernet' | Should Be 'Ethernet' }
  It 'ignores an override that is not present' { Find-MobileAlias $paths 'Wi-Fi' | Should Be 'Ethernet 2' }
}

Describe 'Get-Settings' {
  $f = Join-Path $env:TEMP 'ml-settings-test.json'
  It 'defaults when the file is missing' {
    Remove-Item $f -ErrorAction SilentlyContinue
    (Get-Settings $f).capGB | Should Be 10
  }
  It 'defaults when the file is corrupt' {
    Set-Content $f '{bad'
    (Get-Settings $f).capGB | Should Be 10
  }
  It 'round-trips a value' {
    $s = Get-Settings $f; $s.capGB = 5; Save-Settings $f $s
    (Get-Settings $f).capGB | Should Be 5
    Remove-Item $f
  }
}

Describe 'Native interface counters' {
  It 'match Get-NetAdapterStatistics for a real adapter' {
    $a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    $ref = Get-NetAdapterStatistics -Name $a.Name
    $v = [Multilink.IfStats]::Get([uint32]$a.ifIndex)
    [math]::Abs($v[0] - $ref.ReceivedBytes) / [math]::Max([double]1, [double]$ref.ReceivedBytes) | Should BeLessThan 0.01
    [math]::Abs($v[1] - $ref.SentBytes) / [math]::Max([double]1, [double]$ref.SentBytes) | Should BeLessThan 0.01
  }
  It 'returns null for an interface that does not exist' {
    [Multilink.IfStats]::Get([uint32]999999) | Should BeNullOrEmpty
  }
}

Describe 'Get-RateTable with per-adapter timestamps' {
  It 'uses each adapter''s own time delta' {
    $r = Get-RateTable @{ 'Ethernet 2' = @{ Rx = 0; Tx = 0; At = 10.0 } } @{ 'Ethernet 2' = @{ Rx = 37750000; Tx = 0; At = 12.0 } } 1
    $r['Ethernet 2'].rx | Should Be 151.0
  }
  It 'carries the last rate forward when a slow adapter has no new reading' {
    $last = @{ 'Ethernet 2' = @{ rx = 151.0; tx = 2.0 } }
    $r = Get-RateTable @{ 'Ethernet 2' = @{ Rx = 5; Tx = 5; At = 12.0 } } @{ 'Ethernet 2' = @{ Rx = 5; Tx = 5; At = 12.0 } } 1 $last
    $r['Ethernet 2'].rx | Should Be 151.0
    $r['Ethernet 2'].tx | Should Be 2.0
  }
}

Describe 'IfPoller' {
  It 'reads a tracked adapter in the background' {
    $a = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    $p = New-Object Multilink.IfPoller
    try {
      $p.Track([uint32]$a.ifIndex)
      Start-Sleep -Milliseconds 2500
      $v = $p.Read([uint32]$a.ifIndex)
      $v.Count | Should Be 3
      $v[0] | Should BeGreaterThan 0
      $p.Read([uint32]999999) | Should BeNullOrEmpty
    } finally { $p.Dispose() }
  }
}

Describe 'Complete-RateTable' {
  It 'adds a zero entry for a path with no reading yet' {
    $paths = @([pscustomobject]@{ Alias = 'Ethernet' }, [pscustomobject]@{ Alias = 'Ethernet 2' })
    $r = Complete-RateTable @{ 'Ethernet' = @{ rx = 5; tx = 1 } } $paths
    $r['Ethernet 2'].rx | Should Be 0
    $r['Ethernet'].rx | Should Be 5
  }
}
