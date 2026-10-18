<#
  Watch.ps1 - separation watcher, pre-download range probe, wired baseline.
#>

$script:IpServices = @('https://api.ipify.org', 'https://ipv4.icanhazip.com')

# Results: @{Alias; PublicIp|null}. Any repeated IP means two "links" share
# one exit - almost always a tethered phone that has joined Wi-Fi.
function Get-SeparationStatus {
  param([object[]]$Results)
  $r = @($Results)
  if ($r.Count -eq 0) { return 'unknown' }
  if ($r.Count -eq 1) { return 'single' }
  $ips = @($r | Where-Object { $_.PublicIp } | ForEach-Object { $_.PublicIp })
  if (@($ips | Select-Object -Unique).Count -lt $ips.Count) { return 'lost' }
  if ($ips.Count -lt $r.Count) { return 'unverified' }
  'ok'
}

function Get-SeparationLines {
  param([string]$Status, [int]$Count)
  switch ($Status) {
    'ok'         { ,@(@{ text = "$Count paths with distinct egress IPs - aggregation will work."; level = 'good' }) }
    'lost'       { @(@{ text = 'Duplicate egress IPs - your paths are NOT separate. Nothing will be split.'; level = 'warn' },
                     @{ text = 'Causes, most common first:'; level = 'info' },
                     @{ text = "  1. A tethered phone is on Wi-Fi. Turn the phone's Wi-Fi OFF (leave mobile data on)."; level = 'info' },
                     @{ text = '  2. Both interfaces genuinely go to the same router/ISP.'; level = 'info' }) }
    'unverified' { @(@{ text = 'A path gave no answer - separation is UNVERIFIED.'; level = 'warn' },
                     @{ text = '  Check that link has working internet (for a phone: mobile data on, signal OK).'; level = 'dim' }) }
    'single'     { @(@{ text = 'Only 1 usable path - nothing to aggregate yet.'; level = 'warn' },
                     @{ text = 'Add a second connection (USB-tether a phone with its Wi-Fi off, or add a NIC).'; level = 'info' }) }
    default      { ,@(@{ text = 'No path returned a public IP - cannot tell if they are separate.'; level = 'warn' }) }
  }
}

# Short timeouts on purpose: a dead link must not hold a re-check for a minute.
function Get-PublicIpVia {
  param([string]$LocalIP)
  foreach ($u in $script:IpServices) {
    $curlArgs = @('-sS', '--ipv4', '--connect-timeout', '4', '--max-time', '6')
    if ($LocalIP) { $curlArgs += @('--interface', $LocalIP) }
    $raw = & curl.exe @curlArgs $u 2>$null
    $t = if ($null -eq $raw) { '' } else { "$raw".Trim() }
    if (Test-Ipv4Text $t) { return $t }
  }
  $null
}

function Get-DefaultEgress { Get-PublicIpVia $null }

function Invoke-EgressCheck {
  param($State)
  $results = foreach ($x in @($State.Paths)) {
    $ip = Get-PublicIpVia $x.IP
    $State.PublicIps[$x.Alias] = $ip
    @{ Alias = $x.Alias; PublicIp = $ip }
  }
  $results = @($results)
  $State.Separation = @{ status = (Get-SeparationStatus $results); checkedAt = [DateTime]::UtcNow }
  $results
}

# Re-checks every 60 s, or right away when RecheckRequested is set.
function Start-Watcher {
  param($State)
  Start-BackgroundRunspace $State 'watcher' {
    while (-not $state.Stopping) {
      try { Invoke-EgressCheck $state | Out-Null } catch { }
      $until = [DateTime]::UtcNow.AddSeconds(60)
      while (-not $state.Stopping -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 500 }
    }
  } | Out-Null
}

# --- range probe ----------------------------------------------------------------
# $HeadText: curl -sSIL output (one block per redirect hop; the last one counts).
function ConvertFrom-RangeProbe {
  param([string]$HeadText, [int]$RangeStatus)
  $blocks = @([regex]::Split($HeadText.Trim(), "(\r?\n){2,}") | Where-Object { $_ -match '^HTTP/' })
  $last = if ($blocks.Count) { $blocks[-1] } else { '' }
  $hdr = @{}
  foreach ($line in ($last -split "\r?\n")) {
    if ($line -match '^([^:]+):\s*(.*)$') { $hdr[$Matches[1].Trim().ToLower()] = $Matches[2].Trim() }
  }
  $size = $null
  if ($RangeStatus -eq 206 -and $hdr['content-range'] -match '/(\d+)$') { $size = [long]$Matches[1] }
  elseif ($hdr['content-length'] -match '^\d+$') { $size = [long]$hdr['content-length'] }
  $file = $null
  if ($hdr['content-disposition'] -match 'filename="([^"]+)"') { $file = $Matches[1] }
  elseif ($hdr['content-disposition'] -match 'filename=([^;]+)') { $file = $Matches[1].Trim() }

  $splits = ($hdr['accept-ranges'] -match 'bytes') -or ($RangeStatus -eq 206)
  $reason = if ($splits) { 'Server accepts range requests.' }
            else { 'This server does not accept range requests, so it will download over one link at normal speed.' }
  @{ splits = [bool]$splits; sizeBytes = $size; filename = $file; reason = $reason }
}

function Invoke-RangeProbe {
  param([string]$Url)
  $Url = ConvertTo-SafeUrl $Url
  if (-not $Url) { throw 'Enter a link that starts with http:// or https://' }
  $head = Invoke-Curl @('-sSIL', '--max-time', '8', '--url', $Url) -MergeError
  $r = ConvertFrom-RangeProbe $head 0
  if (-not $r.splits) {
    # Some servers omit Accept-Ranges but still honour a Range request.
    $tail = Invoke-Curl @('-sS', '-L', '-r', '0-0', '-D', '-', '-o', 'NUL', '--max-time', '8', '-w', '%{http_code}', '--url', $Url)
    if ($tail -match '206\s*$') { $r = ConvertFrom-RangeProbe ($tail -replace '\d{3}\s*$', '') 206 }
  }
  if (-not $r.filename) {
    try { $r.filename = [Uri]::UnescapeDataString(([Uri]$Url).Segments[-1]) } catch { }
    if (-not $r.filename -or $r.filename -eq '/') { $r.filename = $null }
  }
  if ($head -notmatch 'HTTP/') { $r.reason = "Couldn't reach that server: $(($head -split "`n")[0].Trim())" }
  $r
}

# --- wired baseline -----------------------------------------------------------
# speed.cloudflare.com refuses bytes=500000000 (403, checked 2026-10-19), so
# each of 4 curl workers fetches 25 MB chunks back to back for 10 s.
function Invoke-Baseline {
  param($State, $Emit)
  $wired = @($State.Paths | Where-Object { $_.Alias -ne $State.Mobile.Alias } | Select-Object -First 1)
  if (-not $wired) { throw 'No wired link found to measure.' }
  $w = $wired[0]
  & $Emit "Measuring $($w.Alias) alone for 10 s (the phone link is left idle)..." 'info'
  if ($State.Downloads.Current -and $State.Downloads.Current.state -eq 'active') {
    & $Emit 'A download is running, so the result includes it.' 'warn'
  }
  $url = 'https://speed.cloudflare.com/__down?bytes=25000000'
  $argList = @('-s', '--interface', $w.IP)
  for ($i = 0; $i -lt 40; $i++) { $argList += @('-o', 'NUL', $url) }
  $before = [Multilink.IfStats]::Get([uint32]$w.InterfaceIndex)
  $t0 = [DateTime]::UtcNow
  $procs = 1..4 | ForEach-Object { Start-Process curl.exe -ArgumentList $argList -PassThru -WindowStyle Hidden }
  Start-Sleep -Seconds 10
  $after = [Multilink.IfStats]::Get([uint32]$w.InterfaceIndex)
  $secs = ([DateTime]::UtcNow - $t0).TotalSeconds
  foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }
  $mbps = [math]::Round(($after[0] - $before[0]) * 8 / $secs / 1e6, 0)
  if ($mbps -lt 1) { throw "No traffic measured on $($w.Alias). Check that it has internet." }
  $State.Settings.baselineMbps = $mbps
  $State.Settings.baselineAt = [DateTime]::UtcNow.ToString('o')
  Save-Settings -Settings $State.Settings
  & $Emit "Wired baseline: $mbps Mbps. Speed-up is now measured against this." 'good'
  @{ mbps = $mbps }
}
