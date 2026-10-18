<#
  Network.ps1 - the console's admin actions: prefer a link, undo, reset.
#>

$script:NeedsAdmin = 'Restart the console as administrator'

function Invoke-PreferApi {
  param($State, [string]$Alias, [bool]$IsAdmin)
  if (-not $IsAdmin) { return New-ApiError 409 $script:NeedsAdmin }
  if (-not (@($State.Paths | Where-Object { $_.Alias -eq $Alias }).Count)) { return New-ApiError 400 "No link named $Alias" }
  $log = @(@{ text = "Prefer $Alias for games and browsing"; level = 'cmd' })
  $log += @(Set-PathMetrics -PreferredAlias $Alias | ForEach-Object { @{ text = $_; level = $(if ($_ -match 'metric ->') { 'good' } else { 'bad' }) } })
  $log += @{ text = "Ordinary traffic will now prefer $Alias."; level = 'good' }
  $log += @{ text = 'Both paths keep their default route, so multi-path downloads still work.'; level = 'info' }
  $log += @{ text = 'Restart games and browsers so their open connections move over.'; level = 'dim' }
  try { Update-Paths $State } catch { }
  New-ApiResult -Status 200 -Body @{ log = $log }
}

function Invoke-UndoApi {
  param($State, [bool]$IsAdmin)
  if (-not $IsAdmin) { return New-ApiError 409 $script:NeedsAdmin }
  $log = @(@{ text = 'Undo: restore automatic metrics'; level = 'cmd' })
  $log += @(Reset-PathMetrics | ForEach-Object { @{ text = $_; level = $(if ($_ -match 'restored') { 'good' } else { 'bad' }) } })
  try { Update-Paths $State } catch { }
  New-ApiResult -Status 200 -Body @{ log = $log }
}

function Get-ResetLevel {
  param([string]$Line)
  if ($Line -match 'would|MANUAL|NOT running elevated|needs an elevated|Re-run') { return 'warn' }
  if ($Line -match '^\s*\d\.\s|=====') { return 'info' }
  if ($Line -match 'None|Nothing to undo|already|restored|deleted|removed|uninstalled|complete|\(ok\)') { return 'good' }
  'dim'
}

# Runs reset-network.ps1 as a child process and streams its report.
function Invoke-ResetJob {
  param($State, $Emit, [bool]$Apply)
  $script = Join-Path $State.Root 'reset-network.ps1'
  $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script)
  if ($Apply) { $args += '-Apply' }
  & $Emit $(if ($Apply) { 'reset-network.ps1 -Apply' } else { 'reset-network.ps1  (report only)' }) 'cmd'
  & powershell.exe @args 2>&1 | ForEach-Object {
    $line = "$_".TrimEnd()
    if ($line) { & $Emit $line (Get-ResetLevel $line) }
  }
  if ($Apply) { try { Update-Paths $State } catch { } }
  @{ applied = $Apply }
}
