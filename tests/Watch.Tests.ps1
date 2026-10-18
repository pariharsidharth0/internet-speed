$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'multilink.ps1')
. (Join-Path $root 'console\Http.ps1')
. (Join-Path $root 'console\Store.ps1')
. (Join-Path $root 'console\Jobs.ps1')
. (Join-Path $root 'console\Watch.ps1')

function Res($alias, $ip) { @{ Alias = $alias; PublicIp = $ip } }

Describe 'Get-SeparationStatus' {
  It 'ok for two distinct IPs' { Get-SeparationStatus @((Res 'a' '1.1.1.1'), (Res 'b' '2.2.2.2')) | Should Be 'ok' }
  It 'lost for two equal IPs' { Get-SeparationStatus @((Res 'a' '1.1.1.1'), (Res 'b' '1.1.1.1')) | Should Be 'lost' }
  It 'unverified when one link gave no IP' { Get-SeparationStatus @((Res 'a' '1.1.1.1'), (Res 'b' $null)) | Should Be 'unverified' }
  It 'single for one link' { Get-SeparationStatus @((Res 'a' '1.1.1.1')) | Should Be 'single' }
  It 'unknown for none' { Get-SeparationStatus @() | Should Be 'unknown' }
  It 'lost when two of three match' { Get-SeparationStatus @((Res 'a' '1.1.1.1'), (Res 'b' '2.2.2.2'), (Res 'c' '1.1.1.1')) | Should Be 'lost' }
}

Describe 'ConvertFrom-RangeProbe' {
  It 'reads the last response after a redirect' {
    $head = "HTTP/1.1 302 Found`r`nLocation: https://mirror/x.iso`r`n`r`nHTTP/1.1 200 OK`r`nAccept-Ranges: bytes`r`nContent-Length: 6114656256`r`n`r`n"
    $r = ConvertFrom-RangeProbe $head 0
    $r.splits | Should Be $true
    $r.sizeBytes | Should Be 6114656256
  }
  It 'does not split without range support' {
    $r = ConvertFrom-RangeProbe "HTTP/1.1 200 OK`r`nContent-Length: 100`r`n`r`n" 200
    $r.splits | Should Be $false
    $r.reason | Should Match 'does not accept range requests'
  }
  It 'splits on a 206 and takes the size from Content-Range' {
    $r = ConvertFrom-RangeProbe "HTTP/1.1 206 Partial Content`r`nContent-Range: bytes 0-0/1288490188`r`n`r`n" 206
    $r.splits | Should Be $true
    $r.sizeBytes | Should Be 1288490188
  }
  It 'reads a quoted filename' {
    $r = ConvertFrom-RangeProbe "HTTP/1.1 200 OK`r`nAccept-Ranges: bytes`r`nContent-Disposition: attachment; filename=`"a b.iso`"`r`n`r`n" 0
    $r.filename | Should Be 'a b.iso'
  }
}

Describe 'Start-ConsoleJob' {
  It 'collects emitted lines and the result' {
    $state = New-ConsoleState
    $id = Start-ConsoleJob $state 'test' { param($state, $emit) $emit.Invoke('one', 'info'); $emit.Invoke('two', 'good'); 42 }
    $deadline = (Get-Date).AddSeconds(20)
    while ($state.Jobs[$id].state -eq 'running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    $state.Jobs[$id].state | Should Be 'done'
    @($state.Jobs[$id].log).Count | Should Be 2
    $state.Jobs[$id].log[1].level | Should Be 'good'
    $state.Jobs[$id].result | Should Be 42
  }
  It 'marks a throwing job failed with its message' {
    $state = New-ConsoleState
    $id = Start-ConsoleJob $state 'test' { param($state, $emit) throw 'boom' }
    $deadline = (Get-Date).AddSeconds(20)
    while ($state.Jobs[$id].state -eq 'running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    $state.Jobs[$id].state | Should Be 'failed'
    ($state.Jobs[$id].log | ForEach-Object { $_.text }) -join ' ' | Should Match 'boom'
  }
}
