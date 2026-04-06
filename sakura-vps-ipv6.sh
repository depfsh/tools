#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_BACKUP_DIR="/var/backups/sakura-ipv6"
ORIGIN_HINT="99-sakura-ipv6"
CHECK_IPV6_HOST="2404:6800:4004:80a::200e"

DRY_RUN=0
NO_APPLY=0
FORCE=0
IFACE=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"

usage() {
  cat <<'EOF'
Usage:
  sakura-vps-ipv6.sh [options]

Options:
  --iface <name>        Specify network interface (default: auto-detect)
  --dry-run             Show what would change without modifying files
  --no-apply            Write config and validate, but do not apply
  --force               Skip interactive confirmation and idempotent early exit
  --backup-dir <path>   Backup directory (default: /var/backups/sakura-ipv6)
  -h, --help            Show this help message

Examples:
  sudo ./sakura-vps-ipv6.sh
  sudo ./sakura-vps-ipv6.sh --iface ens3 --no-apply
  sudo ./sakura-vps-ipv6.sh --dry-run
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[DRY-RUN] %s\n' "$*"
    return 0
  fi
  "$@"
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface)
        [[ $# -ge 2 ]] || die "--iface requires a value"
        IFACE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --no-apply)
        NO_APPLY=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --backup-dir)
        [[ $# -ge 2 ]] || die "--backup-dir requires a value"
        BACKUP_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

check_os_support() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not readable"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      die "Unsupported distro ID=${ID:-unknown}. Expected ubuntu or debian."
      ;;
  esac
  [[ -d /etc/netplan ]] || die "/etc/netplan not found. This host does not appear to use netplan."
}

detect_iface() {
  if [[ -n "$IFACE" ]]; then
    return 0
  fi

  IFACE="$(ip route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  if [[ -z "$IFACE" ]]; then
    IFACE="$(ip -6 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  fi
  [[ -n "$IFACE" ]] || die "Unable to auto-detect interface. Use --iface <name>."
}

validate_iface() {
  [[ "$IFACE" =~ ^[a-zA-Z0-9_:-]+$ ]] || die "Invalid interface name: $IFACE"
  ip link show dev "$IFACE" >/dev/null 2>&1 || die "Interface not found: $IFACE"

  local state
  state="$(ip -o link show dev "$IFACE" | awk '{for (i=1;i<=NF;i++) if ($i=="state") {print $(i+1); exit}}')"
  if [[ "$state" != "UP" && "$state" != "UNKNOWN" ]]; then
    warn "Interface $IFACE state is $state. Continuing, but IPv6 may not come up until link is up."
  fi
}

has_global_ipv6() {
  ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -q 'inet6 '
}

has_default_ipv6_route() {
  ip -6 route show default 2>/dev/null | grep -q '^default '
}

prompt_confirm() {
  [[ "$FORCE" -eq 1 ]] && return 0
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  printf 'About to enable IPv6 on interface "%s". Continue? [y/N]: ' "$IFACE"
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

create_backup() {
  local stamp backup_path
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${BACKUP_DIR%/}/$stamp"

  mkdir -p "$backup_path/netplan" || die "Failed to create backup dir: $backup_path"
  cp -a /etc/netplan/. "$backup_path/netplan/" || die "Failed to backup /etc/netplan"

  printf '%s' "$backup_path"
}

restore_backup() {
  local backup_path="$1"
  [[ -d "$backup_path/netplan" ]] || die "Backup missing: $backup_path/netplan"

  find /etc/netplan -mindepth 1 -maxdepth 1 -exec rm -rf {} + || die "Failed to clean /etc/netplan"
  cp -a "$backup_path/netplan/." /etc/netplan/ || die "Failed to restore /etc/netplan from backup"
}

netplan_set_ipv6() {
  run netplan set --origin-hint "$ORIGIN_HINT" "ethernets.${IFACE}.dhcp6=true"
  run netplan set --origin-hint "$ORIGIN_HINT" "ethernets.${IFACE}.accept-ra=true"
}

validate_and_apply() {
  local backup_path="$1"

  if ! netplan generate >/tmp/"$SCRIPT_NAME".generate.log 2>&1; then
    warn "netplan generate failed. Restoring backup..."
    restore_backup "$backup_path"
    netplan generate >/dev/null 2>&1 || true
    die "Validation failed. Original config restored."
  fi
  log "netplan generate succeeded."

  if [[ "$NO_APPLY" -eq 1 ]]; then
    log "--no-apply set; configuration written but not applied."
    log "Run manually: netplan apply"
    return 0
  fi

  if ! netplan apply >/tmp/"$SCRIPT_NAME".apply.log 2>&1; then
    warn "netplan apply failed. Restoring backup..."
    restore_backup "$backup_path"
    if ! netplan apply >/tmp/"$SCRIPT_NAME".rollback-apply.log 2>&1; then
      die "Failed to apply rollback config. Check console access and /etc/netplan."
    fi
    die "Apply failed. Original config restored."
  fi

  log "netplan apply succeeded."
}

check_firewall_hint() {
  local warned=0

  if command -v nft >/dev/null 2>&1; then
    local rules
    rules="$(nft list ruleset 2>/dev/null || true)"
    if grep -Eq 'hook input.*policy (drop|reject)' <<<"$rules" && ! grep -Eq 'icmpv6|ipv6-icmp' <<<"$rules"; then
      warn "nftables input policy appears restrictive and no ICMPv6 rule was detected."
      warned=1
    fi
  fi

  if command -v ip6tables >/dev/null 2>&1; then
    local input_policy rules_v6
    input_policy="$(ip6tables -S INPUT 2>/dev/null | awk '/^-P INPUT /{print $3}')"
    rules_v6="$(ip6tables -S INPUT 2>/dev/null || true)"
    if [[ "$input_policy" =~ ^(DROP|REJECT)$ ]] && ! grep -Eq -- '-p (ipv6-icmp|icmpv6).* -j ACCEPT' <<<"$rules_v6"; then
      warn "ip6tables INPUT policy is $input_policy and no explicit ICMPv6 allow rule was found."
      warned=1
    fi
  fi

  if [[ "$warned" -eq 1 ]]; then
    warn "IPv6 may fail without ICMPv6 (RA/ND). Review firewall policy."
  fi
}

post_checks() {
  if has_global_ipv6; then
    log "Global IPv6 address detected on $IFACE."
  else
    warn "No global IPv6 address detected yet on $IFACE. It may take time to receive RA/DHCPv6."
  fi

  if has_default_ipv6_route; then
    log "IPv6 default route detected."
  else
    warn "No IPv6 default route detected."
  fi

  if command -v ping >/dev/null 2>&1; then
    if ping -6 -c 2 -W 2 "$CHECK_IPV6_HOST" >/dev/null 2>&1; then
      log "IPv6 connectivity test passed: $CHECK_IPV6_HOST"
    else
      warn "IPv6 connectivity test failed: $CHECK_IPV6_HOST"
    fi
  fi
}

main() {
  parse_args "$@"

  require_command ip
  require_command netplan
  require_command sysctl
  require_command awk
  require_command grep
  require_command find
  require_command cp

  if [[ "$EUID" -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi

  check_os_support
  detect_iface
  validate_iface

  if has_global_ipv6 && has_default_ipv6_route && [[ "$FORCE" -eq 0 ]]; then
    log "IPv6 already appears active on $IFACE (global address + default route). Nothing to do."
    exit 0
  fi

  prompt_confirm

  log "Target interface: $IFACE"
  log "Backup directory: $BACKUP_DIR"
  log "Mode: dry-run=$DRY_RUN, no-apply=$NO_APPLY, force=$FORCE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Planned changes:"
    run netplan set --origin-hint "$ORIGIN_HINT" "ethernets.${IFACE}.dhcp6=true"
    run netplan set --origin-hint "$ORIGIN_HINT" "ethernets.${IFACE}.accept-ra=true"
    if [[ "$NO_APPLY" -eq 1 ]]; then
      log "Would skip netplan apply due to --no-apply."
    else
      log "Would run: netplan generate && netplan apply"
    fi
    exit 0
  fi

  local backup_path
  backup_path="$(create_backup)"
  log "Backup created at: $backup_path"

  netplan_set_ipv6
  validate_and_apply "$backup_path"
  post_checks
  check_firewall_hint

  log "Completed."
  log "If rollback is needed: restore files from $backup_path/netplan and run netplan apply."
}

main "$@"
