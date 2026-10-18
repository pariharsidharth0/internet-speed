$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'multilink.ps1')
. (Join-Path $root 'console\Http.ps1')
. (Join-Path $root 'console\Store.ps1')
. (Join-Path $root 'console\Downloads.ps1')

Describe 'New-Aria2ArgList' {
  It 'spreads over every link in all mode' {
    $a = New-Aria2ArgList -Mode all -IPs '192.168.1.24', '192.168.42.129' -Dir 'C:\dl' -Port 6810 -Secret 's3' -ConsolePid 4242
    $a -contains '--multiple-interface=192.168.1.24,192.168.42.129' | Should Be $true
    $a -contains '-x16' | Should Be $true
    $a -contains '--stop-with-process=4242' | Should Be $true
    $a -contains '--rpc-listen-all=false' | Should Be $true
    $a -contains '--rpc-listen-port=6810' | Should Be $true
    $a -contains '--rpc-secret=s3' | Should Be $true
    $a -contains '--connect-timeout=10' | Should Be $true
    @($a | Where-Object { $_ -like 'http*' }).Count | Should Be 0
  }
  It 'binds one interface in one mode' {
    $a = New-Aria2ArgList -Mode one -IPs '192.168.42.129' -Dir 'C:\dl' -Port 6810 -Secret 's' -ConsolePid 1
    $a -contains '--interface=192.168.42.129' | Should Be $true
    @($a | Where-Object { $_ -like '--multiple-interface*' }).Count | Should Be 0
  }
  It 'keeps a dir with quotes, spaces and & as one element' {
    $dir = 'C:\Users\x\My "Downloads" & more'
    $a = New-Aria2ArgList -Mode all -IPs '1.1.1.1', '2.2.2.2' -Dir $dir -Port 1 -Secret 's' -ConsolePid 1
    @($a | Where-Object { $_ -eq "--dir=$dir" }).Count | Should Be 1
  }
}

Describe 'Get-CapAction' {
  It 'does nothing under the cap' { Get-CapAction -CapHit $false -Mode all -Link $null -MobileAlias 'E2' | Should Be 'none' }
  It 'moves an all-links download to wired' { Get-CapAction -CapHit $true -Mode all -Link $null -MobileAlias 'E2' | Should Be 'switch-to-wired' }
  It 'stops a 5G-only download' { Get-CapAction -CapHit $true -Mode one -Link 'E2' -MobileAlias 'E2' | Should Be 'stop' }
  It 'leaves a wired-only download alone' { Get-CapAction -CapHit $true -Mode one -Link 'Ethernet' -MobileAlias 'E2' | Should Be 'none' }
  It 'does nothing without a mobile link' { Get-CapAction -CapHit $true -Mode all -Link $null -MobileAlias $null | Should Be 'none' }
}

Describe 'Test-DownloadRequest' {
  $paths = @([pscustomobject]@{ Alias = 'Ethernet'; IP = '192.168.1.24' }, [pscustomobject]@{ Alias = 'E2'; IP = '192.168.42.129' })
  It 'rejects a non-http link' {
    (Test-DownloadRequest @{ url = 'ftp://x'; mode = 'all'; dir = $env:TEMP } $paths 'E2' $false $false).error | Should Be 'Enter a link that starts with http:// or https://'
  }
  It 'rejects a second download' {
    (Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'all'; dir = $env:TEMP } $paths 'E2' $false $true).status | Should Be 409
  }
  It 'refuses 5G-only after the cap' {
    $r = Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'one'; link = 'E2'; dir = $env:TEMP } $paths 'E2' $true $false
    $r.status | Should Be 409
    $r.error | Should Be 'Mobile data cap reached'
  }
  It 'turns all-links into wired-only after the cap' {
    $r = Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'all'; dir = $env:TEMP } $paths 'E2' $true $false
    $r.error | Should BeNullOrEmpty
    ($r.ips -join ',') | Should Be '192.168.1.24'
    $r.switchedByCap | Should Be $true
  }
  It 'puts wired links before the mobile link so the first request is reliable' {
    $mobileFirst = @([pscustomobject]@{ Alias = 'E2'; IP = '192.168.42.129' }, [pscustomobject]@{ Alias = 'Ethernet'; IP = '192.168.1.24' })
    $r = Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'all'; dir = $env:TEMP } $mobileFirst 'E2' $false $false
    ($r.ips -join ',') | Should Be '192.168.1.24,192.168.42.129'
  }
  It 'rejects an unknown link' {
    (Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'one'; link = 'Nope'; dir = $env:TEMP } $paths 'E2' $false $false).status | Should Be 400
  }
  It 'rejects a dir that cannot be created' {
    (Test-DownloadRequest @{ url = 'https://x/a.iso'; mode = 'all'; dir = 'Q:\no\such\drive' } $paths 'E2' $false $false).error | Should Match "^Can't save to"
  }
}

Describe 'Native job object' {
  It 'compiles under 5.1 and creates a kill-on-close job' {
    [Multilink.JobObject]::CreateKillOnClose() | Should Not Be ([IntPtr]::Zero)
  }
}

Describe 'ConvertTo-CommandLine' {
  It 'quotes spaces and escapes quotes so argv round-trips' {
    $parts = @('--dir=C:\My "Dl" & more\', 'plain', 'a b')
    $line = ConvertTo-CommandLine $parts
    # Ask Windows to split it back (CommandLineToArgvW) and compare.
    $back = [Multilink.CommandLine]::Split("x.exe $line")
    ($back[1..3] -join '|') | Should Be ($parts -join '|')
  }
}

Describe 'Update-Cap' {
  function New-CapState($mode, $link) {
    $s = New-ConsoleState
    $s.Mobile.Alias = 'E2'
    $s.Mobile.SessionBytes = [double]2GB
    $s.Settings.capGB = 1
    $s.Downloads.Current = [hashtable]::Synchronized(@{ id = 'abc'; state = 'active'; mode = $mode; link = $link; Port = 1; Secret = 'x'; Process = $null })
    $s
  }
  It 'pauses a 5G-only download when the cap is lowered below usage' {
    $s = New-CapState 'one' 'E2'
    Update-Cap $s
    $s.CapHit | Should Be $true
    $s.Downloads.Current.state | Should Be 'cancelled'
    $s.Downloads.Current.stoppedByCap | Should Be $true
  }
  It 'acts only on the rising edge' {
    $s = New-CapState 'one' 'E2'
    $s.CapHit = $true
    Update-Cap $s
    $s.Downloads.Current.state | Should Be 'active'
  }
  It 'clears the cap when it is raised above usage' {
    $s = New-CapState 'one' 'Ethernet'
    $s.CapHit = $true; $s.Settings.capGB = 5
    Update-Cap $s
    $s.CapHit | Should Be $false
  }
}

Describe 'Select-OrphanAria2' {
  It 'picks aria2 processes whose console is gone' {
    $procs = @(
      [pscustomobject]@{ ProcessId = 11; CommandLine = 'aria2c.exe -x16 --stop-with-process=500 --enable-rpc=true' },
      [pscustomobject]@{ ProcessId = 12; CommandLine = 'aria2c.exe -x16 --stop-with-process=600 --enable-rpc=true' },
      [pscustomobject]@{ ProcessId = 13; CommandLine = 'aria2c.exe -x4 somefile' })
    $o = @(Select-OrphanAria2 -Processes $procs -AlivePids @(600))
    ($o | ForEach-Object { $_.ProcessId }) -join ',' | Should Be '11'
  }
}
