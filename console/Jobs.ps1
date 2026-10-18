<#
  Jobs.ps1 - long-running console actions (check, latency, baseline, reset).

  Each job runs in its own runspace and appends log lines to
  $state.Jobs[<id>].log; the page polls GET /api/jobs/<id>.
#>

function Start-ConsoleJob {
  param($State, [string]$Kind, [scriptblock]$Work)
  $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
  $State.Jobs[$id] = [hashtable]::Synchronized(@{
    id = $id; kind = $Kind; state = 'running'; result = $null; startedAt = [DateTime]::UtcNow
    log = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  })
  # Keep the newest 30 jobs.
  $old = @($State.Jobs.Values | Sort-Object { $_.startedAt } | Select-Object -SkipLast 30)
  foreach ($j in $old) { if ($j.state -ne 'running') { $State.Jobs.Remove($j.id) } }

  Start-BackgroundRunspace $State "job-$Kind-$id" {
    param($id, $body)
    $job = $state.Jobs[$id]
    $emit = {
      param($text, $level)
      [void]$job.log.Add(@{ text = "$text"; level = $(if ($level) { $level } else { 'info' }) })
    }.GetNewClosure()
    try {
      $job.result = & ([scriptblock]::Create($body)) $state $emit
      $job.state = 'done'
    } catch {
      & $emit $_.Exception.Message 'bad'
      $job.state = 'failed'
    }
  } -Arguments @($id, $Work.ToString()) | Out-Null
  $id
}

function Get-JobDto {
  param($Job)
  @{ id = $Job.id; kind = $Job.kind; state = $Job.state; log = @($Job.log.ToArray()); result = $Job.result }
}

function Write-PathLines {
  param($State, $Emit)
  $paths = @($State.Paths)
  & $Emit 'Internet paths detected:' 'info'
  if (-not $paths.Count) { & $Emit '  none - no interface has its own default gateway.' 'bad'; return }
  foreach ($x in $paths) {
    & $Emit ("  {0,-14} {1,-16} gw {2,-16} metric {3} (auto: {4})" -f $x.Alias, $x.IP, $x.Gateway, $x.Metric, $x.Auto) 'info'
  }
  & $Emit ("  {0} path(s)." -f $paths.Count) 'dim'
}

function Write-LatencyLine {
  param($Emit, [string]$Alias, $L)
  if ($L.avgMs -eq $null) { & $Emit ("  {0,-14} no replies (ICMP loss {1}%)" -f $Alias, $L.lossPct) 'warn' }
  elseif ($L.tcpOnly) { & $Emit ("  {0,-14} TCP ~{1} ms to 1.1.1.1:443 (ICMP blocked)" -f $Alias, $L.avgMs) 'info' }
  else { & $Emit ("  {0,-14} avg {1,6} ms | max {2,5} ms | jitter {3,5} ms | loss {4}%" -f $Alias, $L.avgMs, $L.maxMs, $L.jitterMs, $L.lossPct) 'info' }
}

# Latency per path, stored for the link cards. Runs at console start and in Check.
function Invoke-LatencyPass {
  param($State, $Emit)
  foreach ($x in @($State.Paths)) {
    $l = Measure-PathLatency $x
    $State.Latency[$x.Alias] = $l
    if ($Emit) { Write-LatencyLine $Emit $x.Alias $l }
  }
}

# The full check, with the same sections and wording as the old -Action check.
function Invoke-CheckJob {
  param($State, $Emit)
  & $Emit 'Run check' 'cmd'
  Update-Paths $State
  Write-PathLines $State $Emit
  if (-not @($State.Paths).Count) { return @{ separation = 'unknown' } }

  & $Emit '' 'info'
  & $Emit 'Public egress IP per path (the test that decides everything):' 'info'
  $results = Invoke-EgressCheck $State
  foreach ($r in $results) {
    if ($r.PublicIp) { & $Emit ("  {0,-14} -> {1}" -f $r.Alias, $r.PublicIp) 'info' }
    else { & $Emit ("  {0,-14} -> (no response)" -f $r.Alias) 'warn' }
  }
  & $Emit '' 'info'
  foreach ($l in (Get-SeparationLines $State.Separation.status @($results).Count)) { & $Emit $l.text $l.level }

  & $Emit '' 'info'
  & $Emit 'Path used by ordinary traffic (games, browsing) right now:' 'info'
  $def = Get-DefaultEgress
  $match = @($results | Where-Object { $_.PublicIp -and $_.PublicIp -eq $def } | Select-Object -First 1)
  if ($match) { & $Emit ("  -> {0}  (egress {1})" -f $match[0].Alias, $def) 'info' }
  elseif ($def) { & $Emit ("  -> egress {0}" -f $def) 'info' }
  else { & $Emit '  -> (no response)' 'warn' }

  & $Emit '' 'info'
  & $Emit 'Background traffic (pause downloads before trusting any speed test):' 'info'
  $busy = $false
  foreach ($x in @($State.Paths)) {
    $r = $State.Rates[$x.Alias]
    $mbps = if ($r) { [double]$r.rx } else { 0 }
    & $Emit ("  {0,-14} {1,7:N1} MB/s = {2,6:N0} Mbps" -f $x.Alias, ($mbps / 8), $mbps) 'info'
    if ($mbps -gt 5) { $busy = $true }
  }
  if ($busy) {
    & $Emit 'A link is already busy. Pause Steam / Windows Update / torrents first.' 'warn'
    & $Emit '  (Measuring on a busy link is the single easiest way to get a wrong answer.)' 'dim'
  }

  & $Emit '' 'info'
  & $Emit 'Latency per path (games care about this, not bandwidth):' 'info'
  Invoke-LatencyPass $State $Emit
  & $Emit '  Lowest avg+jitter is your gaming link. Send bulk downloads over the other one.' 'dim'
  @{ separation = $State.Separation.status }
}
