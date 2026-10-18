$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'multilink.ps1')
. (Join-Path $root 'console\Http.ps1')
. (Join-Path $root 'console\Store.ps1')
. (Join-Path $root 'console\Network.ps1')

Describe 'Invoke-PreferApi' {
  $state = New-ConsoleState
  $state.Paths = @([pscustomobject]@{ Alias = 'Ethernet' }, [pscustomobject]@{ Alias = 'Ethernet 2' })
  Mock Set-PathMetrics { @('  Ethernet       metric -> 10') }

  It 'refuses without admin' {
    $r = Invoke-PreferApi $state 'Ethernet' $false
    $r.Status | Should Be 409
    $r.Body.error | Should Be 'Restart the console as administrator'
  }
  It 'refuses an unknown link' {
    $r = Invoke-PreferApi $state 'Nope' $true
    $r.Status | Should Be 400
    $r.Body.error | Should Be 'No link named Nope'
  }
  It 'sets metrics and returns log lines' {
    $r = Invoke-PreferApi $state 'Ethernet' $true
    $r.Status | Should Be 200
    Assert-MockCalled Set-PathMetrics -Times 1 -ParameterFilter { $PreferredAlias -eq 'Ethernet' }
    ($r.Body.log | ForEach-Object { $_.text }) -join "`n" | Should Match 'Ordinary traffic will now prefer Ethernet'
  }
}

Describe 'Invoke-UndoApi' {
  $state = New-ConsoleState
  Mock Reset-PathMetrics { @('  Ethernet       automatic metric restored') }
  It 'refuses without admin' { (Invoke-UndoApi $state $false).Status | Should Be 409 }
  It 'restores automatic metrics' {
    (Invoke-UndoApi $state $true).Status | Should Be 200
    Assert-MockCalled Reset-PathMetrics -Times 1
  }
}

Describe 'Get-ResetLevel' {
  It 'marks would-change lines as warnings' { Get-ResetLevel '   would remove team: T1' | Should Be 'warn' }
  It 'marks section headers as info' { Get-ResetLevel '1. Interface metrics' | Should Be 'info' }
  It 'marks nothing-to-do lines as good' { Get-ResetLevel '   None left.' | Should Be 'good' }
}
