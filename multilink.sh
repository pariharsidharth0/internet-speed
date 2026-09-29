#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  multilink.sh - use every internet connection at once for faster downloads
#
#  Splits one file into many HTTP range requests and spreads them across every
#  network interface that has its own default route (e.g. wired ethernet + a
#  phone's 5G tether). The file is reassembled locally, so no VPN, bonding
#  service or paid tunnel is required.
#
#  Usage:
#    ./multilink.sh                      interactive menu
#    ./multilink.sh check                show paths + public egress IP of each
#    ./multilink.sh get <URL> [outdir]   download using all paths
#    ./multilink.sh only <IFACE> <URL>   download using ONE path (keeps others
#                                        free - use this while gaming)
#    ./multilink.sh setup                install policy routing (needs root)
#    ./multilink.sh undo                 remove policy routing (needs root)
#
#  IMPORTANT - Linux differs from Windows here. On Windows, binding a socket to
#  a source address is enough to make it leave via that interface. On Linux it
#  usually is NOT: route lookup happens on destination, so both sockets follow
#  the single preferred default route, and reverse-path filtering may drop the
#  replies. 'setup' fixes that with per-interface routing tables + ip rules.
#  Run 'check' first: if all paths report the SAME public IP, run 'setup'.
# ---------------------------------------------------------------------------
set -uo pipefail

RTT_BASE=200            # routing table ids start here
MARK_FILE=/etc/iproute2/rt_tables
CONN=16                 # connections per download

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$c_cyn" "$*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_yel" "$*" "$c_off"; }
err()  { printf '%s%s%s\n' "$c_red" "$*" "$c_off" >&2; }
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_off"; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This action needs root. Re-run with: sudo $0 $*"
    exit 1
  fi
}

# --- dependency -------------------------------------------------------------
pkg_install() {
  local sudo_cmd=""
  [ "$(id -u)" -ne 0 ] && sudo_cmd="sudo"
  if   command -v apt-get >/dev/null 2>&1; then $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y "$@"
  elif command -v dnf     >/dev/null 2>&1; then $sudo_cmd dnf install -y "$@"
  elif command -v yum     >/dev/null 2>&1; then $sudo_cmd yum install -y "$@"
  elif command -v pacman  >/dev/null 2>&1; then $sudo_cmd pacman -Sy --noconfirm "$@"
  elif command -v zypper  >/dev/null 2>&1; then $sudo_cmd zypper install -y "$@"
  elif command -v apk     >/dev/null 2>&1; then $sudo_cmd apk add "$@"
  else err "Could not detect a package manager. Install manually: $*"; return 1
  fi
}

# Every discovery path below needs iproute2. Without it the script would
# otherwise report "no default route" and send you chasing the wrong problem.
ensure_iproute() {
  command -v ip >/dev/null 2>&1 && return 0
  warn "The 'ip' command (iproute2) is missing - it is required to find your"
  warn "network paths. Attempting to install it..."
  pkg_install iproute2 || pkg_install iproute || true
  if command -v ip >/dev/null 2>&1; then ok "iproute2 installed."; return 0; fi
  err "Could not install iproute2. Install it with your package manager, e.g.:"
  err "  apt install iproute2   |   dnf install iproute   |   pacman -S iproute2"
  return 1
}

ensure_aria2() {
  command -v aria2c >/dev/null 2>&1 && return 0
  warn "aria2 is not installed."
  pkg_install aria2 || return 1
  command -v aria2c >/dev/null 2>&1
}

# --- discovery --------------------------------------------------------------
# Emits: "<iface> <src_ip> <gateway>" per usable internet path.
discover() {
  local dev gw src
  ip -4 route show default 2>/dev/null | while read -r line; do
    gw=$(sed -n 's/.*via \([0-9.]*\).*/\1/p'   <<<"$line")
    dev=$(sed -n 's/.*dev \([^ ]*\).*/\1/p'    <<<"$line")
    [ -z "$dev" ] && continue
    src=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | head -n1)
    [ -z "$src" ] && continue
    case "$src" in 169.254.*) continue;; esac
    printf '%s %s %s\n' "$dev" "$src" "$gw"
  done | sort -u -k2,2
}

show_paths() {
  ensure_iproute || return 1
  local n=0
  info "Internet paths detected:"
  while read -r dev src gw; do
    [ -z "${dev:-}" ] && continue
    printf '  %-12s src %-16s gw %s\n' "$dev" "$src" "$gw"
    n=$((n+1))
  done < <(discover)
  [ "$n" -eq 0 ] && { err "No interface with a default route found."; return 1; }
  printf '%s  %d path(s).%s\n' "$c_dim" "$n" "$c_off"
  return 0
}

# --- the critical verification ---------------------------------------------
check_egress() {
  ensure_iproute || return 1
  ensure_aria2 || return 1
  show_paths || return 1
  echo
  info "Public egress IP per path (this is the test that matters):"
  local tmp; tmp=$(mktemp -d); local seen="" dup=0 npath=0 nfail=0
  while read -r dev src gw; do
    [ -z "${dev:-}" ] && continue
    npath=$((npath+1))
    rm -f "$tmp/ip" "$tmp/ip.aria2"
    aria2c --interface="$src" -x1 -s1 --allow-overwrite=true --file-allocation=none \
           --summary-interval=0 --console-log-level=error --timeout=15 --max-tries=2 \
           -d "$tmp" -o ip "https://api.ipify.org" >/dev/null 2>&1
    local pub; pub=$(cat "$tmp/ip" 2>/dev/null | tr -d '[:space:]')
    # only something that looks like an IPv4 address counts as a real answer
    if ! printf '%s' "$pub" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
      printf '  %-12s -> %s(no response - could not reach api.ipify.org)%s\n' "$dev" "$c_yel" "$c_off"
      nfail=$((nfail+1)); continue
    fi
    printf '  %-12s -> %s\n' "$dev" "$pub"
    case " $seen " in *" $pub "*) dup=1;; esac
    seen="$seen $pub"
  done < <(discover)
  rm -rf "$tmp"
  echo
  if [ "$dup" -eq 1 ]; then
    warn "Duplicate egress IPs - your paths are NOT separate."
    say  "Causes, most common first:"
    say  "  1. A tethered phone is on Wi-Fi. Turn the phone's Wi-Fi OFF."
    say  "  2. Linux is ignoring the source binding. Run: sudo $0 setup"
    return 1
  fi
  if [ "$nfail" -gt 0 ]; then
    warn "$nfail of $npath path(s) gave no answer, so separation is UNVERIFIED."
    say  "Check that path has working internet, or that api.ipify.org is reachable."
    return 1
  fi
  if [ "$npath" -lt 2 ]; then
    warn "Only $npath usable path - there is nothing to aggregate yet."
    say  "Add a second internet connection (e.g. USB-tether a phone with its Wi-Fi OFF)."
    return 1
  fi
  ok "$npath paths, all with distinct egress IPs - aggregation will work."
}

# --- contention check -------------------------------------------------------
check_busy() {
  ensure_iproute || return 1
  info "Checking for background traffic (a busy link makes every measurement a lie):"
  local devs=() a=() b=() i=0
  while read -r dev src gw; do [ -n "${dev:-}" ] && devs+=("$dev"); done < <(discover)
  for d in "${devs[@]}"; do a+=("$(cat /sys/class/net/"$d"/statistics/rx_bytes 2>/dev/null || echo 0)"); done
  sleep 5
  for d in "${devs[@]}"; do b+=("$(cat /sys/class/net/"$d"/statistics/rx_bytes 2>/dev/null || echo 0)"); done
  local busy=0
  for i in "${!devs[@]}"; do
    local delta=$(( (${b[$i]} - ${a[$i]}) / 5 ))
    local mbps=$(( delta * 8 / 1000000 ))
    printf '  %-12s %6d KB/s = %5d Mbps\n' "${devs[$i]}" "$((delta/1024))" "$mbps"
    [ "$mbps" -gt 5 ] && busy=1
  done
  [ "$busy" -eq 1 ] && warn "A link is already busy. Pause other downloads before benchmarking."
  return 0
}

# --- policy routing (the Linux-specific part) -------------------------------
setup_routing() {
  need_root setup
  ensure_iproute || return 1
  local n=0
  while read -r dev src gw; do
    [ -z "${dev:-}" ] && continue
    [ -z "$gw" ] && continue
    local tid=$((RTT_BASE + n)) tname="ml_$dev"
    touch "$MARK_FILE" 2>/dev/null || true
    grep -qE "^[[:space:]]*$tid[[:space:]]" "$MARK_FILE" 2>/dev/null \
      || echo "$tid $tname" >> "$MARK_FILE"
    # a routing table that sends everything out this interface
    ip route replace default via "$gw" dev "$dev" table "$tid" 2>/dev/null
    ip route replace "$(ip -4 route show dev "$dev" scope link | head -n1 | awk '{print $1}')" \
       dev "$dev" scope link table "$tid" 2>/dev/null
    # anything sourced from this address uses that table
    ip rule del from "$src" table "$tid" 2>/dev/null
    ip rule add from "$src" table "$tid" priority $((1000 + n))
    # loose reverse-path filtering so replies arriving on this iface aren't dropped
    sysctl -qw "net.ipv4.conf.$dev.rp_filter=2" 2>/dev/null
    ok "  $dev  src $src  -> table $tid ($tname)"
    n=$((n+1))
  done < <(discover)
  sysctl -qw net.ipv4.conf.all.rp_filter=2 2>/dev/null
  echo
  if [ "$n" -lt 2 ]; then
    warn "Only $n path(s) configured - need at least 2 for aggregation."
  else
    ok "Policy routing active for $n paths."
  fi
  warn "These rules are runtime-only and vanish on reboot."
  say  "To persist, re-run 'sudo $0 setup' at boot (systemd unit or rc.local)."
  echo
  say  "Now verify:  $0 check"
}

undo_routing() {
  need_root undo
  ensure_iproute || return 1
  local n=0
  while read -r dev src gw; do
    [ -z "${dev:-}" ] && continue
    local tid=$((RTT_BASE + n))
    ip rule del from "$src" table "$tid" 2>/dev/null && ok "  removed rule for $src"
    ip route flush table "$tid" 2>/dev/null
    n=$((n+1))
  done < <(discover)
  ok "Policy routing removed. Routing is back to the kernel default."
}

# --- downloads --------------------------------------------------------------
do_get() {
  local url="${1:-}" outdir="${2:-$PWD}"
  [ -z "$url" ] && { err "No URL given."; return 1; }
  ensure_iproute || return 1
  ensure_aria2 || return 1
  local srcs=""
  while read -r dev src gw; do
    [ -z "${dev:-}" ] && continue
    srcs="${srcs:+$srcs,}$src"
  done < <(discover)
  [ -z "$srcs" ] && { err "No usable interface found."; return 1; }
  mkdir -p "$outdir"
  info "Paths in use: $srcs"
  if [[ "$srcs" != *,* ]]; then
    warn "Only one path available - this will be an ordinary download."
    aria2c -x"$CONN" -s"$CONN" -k1M --continue=true --file-allocation=none \
           --max-tries=5 --retry-wait=2 -d "$outdir" "$url"
  else
    aria2c --multiple-interface="$srcs" -x"$CONN" -s"$CONN" -k1M --continue=true \
           --file-allocation=none --max-tries=5 --retry-wait=2 -d "$outdir" "$url"
  fi
}

do_only() {
  local want="${1:-}" url="${2:-}" outdir="${3:-$PWD}"
  [ -z "$want" ] || [ -z "$url" ] && { err "Usage: $0 only <IFACE|IP> <URL> [outdir]"; return 1; }
  ensure_iproute || return 1
  ensure_aria2 || return 1
  local src=""
  while read -r dev s gw; do
    [ -z "${dev:-}" ] && continue
    if [ "$dev" = "$want" ] || [ "$s" = "$want" ]; then src="$s"; fi
  done < <(discover)
  [ -z "$src" ] && { err "No path matching '$want'. Run '$0 check' to list them."; return 1; }
  mkdir -p "$outdir"
  info "Using only $want (src $src) - other links stay free."
  aria2c --interface="$src" -x"$CONN" -s"$CONN" -k1M --continue=true \
         --file-allocation=none --max-tries=5 --retry-wait=2 -d "$outdir" "$url"
}

menu() {
  while :; do
    echo
    printf '%s==== multilink ====%s\n' "$c_cyn" "$c_off"
    say "  1) Check my connections (paths + egress IPs + contention)"
    say "  2) Download a file using ALL connections"
    say "  3) Download using ONE connection (keeps others free for gaming)"
    say "  4) Set up Linux policy routing (needs sudo)"
    say "  5) Remove policy routing (needs sudo)"
    say "  6) Quit"
    printf 'Choose [1-6]: '
    read -r ch
    case "$ch" in
      1) echo; check_egress; echo; check_busy ;;
      2) printf 'URL: '; read -r u; printf 'Save to [%s]: ' "$PWD"; read -r o
         do_get "$u" "${o:-$PWD}" ;;
      3) show_paths; printf 'Which interface/IP: '; read -r i
         printf 'URL: '; read -r u; printf 'Save to [%s]: ' "$PWD"; read -r o
         do_only "$i" "$u" "${o:-$PWD}" ;;
      4) if [ "$(id -u)" -eq 0 ]; then setup_routing; else sudo "$0" setup; fi ;;
      5) if [ "$(id -u)" -eq 0 ]; then undo_routing;  else sudo "$0" undo;  fi ;;
      6) exit 0 ;;
      *) warn "Pick 1-6." ;;
    esac
  done
}

case "${1:-}" in
  check)          check_egress; echo; check_busy ;;
  get)            shift; do_get "$@" ;;
  only)           shift; do_only "$@" ;;
  setup)          setup_routing ;;
  undo)           undo_routing ;;
  ""|menu)        menu ;;
  -h|--help|help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' ;;
  http*)          do_get "$1" "${2:-$PWD}" ;;   # bare URL
  *)              err "Unknown command: $1"; sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
