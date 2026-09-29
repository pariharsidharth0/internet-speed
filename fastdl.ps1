<#
  fastdl.ps1 - Download a file using ALL of your internet connections at once.

  Splits a single download into many HTTP range requests and spreads them
  across every network interface that has its own default gateway (e.g. your
  wired ISP + your phone's 5G tether). The file is reassembled locally, so no
  VPN or bonding service is required.

  Usage:
    .\fastdl.ps1 "https://example.com/bigfile.iso"
    .\fastdl.ps1 "https://example.com/bigfile.iso" -OutDir "D:\Downloads" -Connections 24
    .\fastdl.ps1 "https://example.com/bigfile.iso" -ShowLinks

  Notes:
    * The source server must support HTTP range requests. Most CDNs do.
    * This consumes mobile data. Watch your cap.
#>
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Url,
  [string]$OutDir = "$env:USERPROFILE\Downloads",
  [int]$Connections = 16,
  [switch]$ShowLinks
)

$aria = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\aria2c.exe"
if (-not (Test-Path $aria)) { $aria = (Get-Command aria2c -ErrorAction SilentlyContinue).Source }
if (-not $aria) { throw "aria2c not found. Install it with:  winget install aria2.aria2" }

# Any interface holding both an IPv4 address and its own default gateway is a
# usable path to the internet. Link-local and Hyper-V switches are excluded.
$sources = @()
foreach ($cfg in (Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.IPv4DefaultGateway })) {
  $ip = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
  if ($ip -and $ip -notlike '169.254.*') {
    $sources += [pscustomobject]@{ Name = $cfg.InterfaceAlias; IP = $ip }
  }
}
$sources = $sources | Sort-Object IP -Unique

if ($sources.Count -eq 0) { throw "No interface with a default gateway found." }

Write-Host ""
Write-Host "Paths in use:" -ForegroundColor Cyan
foreach ($s in $sources) { Write-Host ("  {0,-14} {1}" -f $s.Name, $s.IP) }

if ($ShowLinks) {
  Write-Host ""
  Write-Host "Checking egress IP of each path..." -ForegroundColor Cyan
  $tmp = Join-Path $env:TEMP "fastdl-check"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  foreach ($s in $sources) {
    Remove-Item "$tmp\ip.txt", "$tmp\ip.txt.aria2" -Force -ErrorAction SilentlyContinue
    & $aria --interface=$($s.IP) -x1 -s1 --allow-overwrite=true --file-allocation=none `
            --summary-interval=0 --console-log-level=error -d $tmp -o ip.txt `
            "https://api.ipify.org" 2>&1 | Out-Null
    $pub = (Get-Content "$tmp\ip.txt" -Raw -ErrorAction SilentlyContinue)
    Write-Host ("  {0,-14} -> {1}" -f $s.Name, $pub)
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host ""
  Write-Host "Distinct egress IPs mean the paths are genuinely separate." -ForegroundColor DarkGray
  Write-Host "Identical IPs mean your phone is on Wi-Fi - turn its Wi-Fi off." -ForegroundColor DarkGray
  Write-Host ""
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$argList = @(
  "-x$Connections", "-s$Connections", "-k1M",
  "--file-allocation=none", "--continue=true",
  "--max-tries=5", "--retry-wait=2",
  "-d", $OutDir
)
if ($sources.Count -gt 1) {
  $argList += "--multiple-interface=$(($sources.IP) -join ',')"
} else {
  Write-Host "Only one path available - running as a normal download." -ForegroundColor Yellow
}
$argList += $Url

Write-Host ""
& $aria @argList
