#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_BACKUP_DIR="/var/backups/sakura-ipv6"

DRY_RUN=0
NO_APPLY=0
FORCE=0
IFACE=""
BACKUP_DIR="$DEFAULT_BACKUP_DIR"

INTERFACES_FILE="/etc/network/interfaces"
SYSCTL_FILE="/etc/sysctl.conf"

usage() {
  cat <<'EOF'
Usage:
  sakura-vps-ipv6.sh [options]

Options:
  --iface <name>        Specify network interface (default: auto-detect)
  --dry-run             Preview changes without modifying files
  --no-apply            Write config only; skip sysctl -p and runtime ip -6 commands
  --force               Skip interactive confirmation
  --backup-dir <path>   Backup directory (default: /var/backups/sakura-ipv6)
  -h, --help            Show this help message

Examples:
  sudo ./sakura-vps-ipv6.sh --dry-run
  sudo ./sakura-vps-ipv6.sh --iface ens3 --force
  sudo ./sakura-vps-ipv6.sh --iface ens3 --no-apply --force
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
    debian|ubuntu)
      ;;
    *)
      die "Unsupported distro ID=${ID:-unknown}. Expected debian or ubuntu."
      ;;
  esac
  [[ -f "$INTERFACES_FILE" ]] || die "$INTERFACES_FILE not found; ifupdown stack is required."
  [[ -f "$SYSCTL_FILE" ]] || die "$SYSCTL_FILE not found."
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
}

prompt_confirm() {
  [[ "$FORCE" -eq 1 || "$DRY_RUN" -eq 1 ]] && return 0
  printf 'About to modify %s and %s for interface "%s". Continue? [y/N]: ' "$SYSCTL_FILE" "$INTERFACES_FILE" "$IFACE"
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
  mkdir -p "$backup_path" || die "Failed to create backup directory: $backup_path"
  cp -a "$SYSCTL_FILE" "$backup_path/sysctl.conf.bak" || die "Failed to backup $SYSCTL_FILE"
  cp -a "$INTERFACES_FILE" "$backup_path/interfaces.bak" || die "Failed to backup $INTERFACES_FILE"
  printf '%s' "$backup_path"
}

restore_backup() {
  local backup_path="$1"
  [[ -f "$backup_path/sysctl.conf.bak" ]] || die "Missing backup file: $backup_path/sysctl.conf.bak"
  [[ -f "$backup_path/interfaces.bak" ]] || die "Missing backup file: $backup_path/interfaces.bak"
  cp -a "$backup_path/sysctl.conf.bak" "$SYSCTL_FILE" || die "Failed to restore $SYSCTL_FILE"
  cp -a "$backup_path/interfaces.bak" "$INTERFACES_FILE" || die "Failed to restore $INTERFACES_FILE"
}

update_key_in_file() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
    function rtrim(s) { sub(/[[:space:]]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)) }
    BEGIN { done=0 }
    {
      line=$0
      scan=line
      sub(/^[[:space:]]*#?[[:space:]]*/, "", scan)
      split(scan, parts, "=")
      lhs=trim(parts[1])
      if (lhs == key) {
        if (!done) {
          print key " = " value
          done=1
        }
        next
      }
      print line
    }
    END {
      if (!done) {
        print key " = " value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

prepare_sysctl_file() {
  local file="$1"
  update_key_in_file "$file" "net.ipv6.conf.all.disable_ipv6" "0"
  update_key_in_file "$file" "net.ipv6.conf.default.disable_ipv6" "0"
  update_key_in_file "$file" "net.ipv6.conf.${IFACE}.disable_ipv6" "0"
}

prepare_interfaces_file() {
  local src_file="$1" dst_file="$2"
  awk -v iface="$IFACE" '
    BEGIN { in_blk=0; found=0 }
    function uncomment_once(s) {
      sub(/^[[:space:]]*#[[:space:]]*/, "", s)
      return s
    }
    {
      line=$0
      if (!in_blk) {
        if (line ~ "^[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet6[[:space:]]+static([[:space:]].*)?$") {
          found=1
          in_blk=1
          print line
          next
        }
        if (line ~ "^[[:space:]]*#[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet6[[:space:]]+static([[:space:]].*)?$") {
          found=1
          in_blk=1
          print uncomment_once(line)
          next
        }
        print line
        next
      }

      if (line ~ /^[[:space:]]*$/ || line ~ /^[^[:space:]#]/) {
        in_blk=0
        print line
        next
      }

      if (line ~ "^[[:space:]]*#[[:space:]]*(address|netmask|gateway)[[:space:]]+") {
        print uncomment_once(line)
      } else {
        print line
      }
    }
    END {
      if (!found) {
        exit 3
      }
    }
  ' "$src_file" > "$dst_file"
}

extract_ipv6_values() {
  local file="$1"
  awk -v iface="$IFACE" '
    BEGIN { in_blk=0 }
    {
      line=$0
      if (!in_blk) {
        if (line ~ "^[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet6[[:space:]]+static([[:space:]].*)?$") {
          in_blk=1
        }
        next
      }

      if (line ~ /^[[:space:]]*$/ || line ~ /^[^[:space:]#]/) {
        in_blk=0
        next
      }

      work=line
      sub(/^[[:space:]]+/, "", work)
      split(work, parts, /[[:space:]]+/)
      key=parts[1]
      val=parts[2]
      if (key == "address" && val != "") {
        print "ADDRESS=" val
      } else if (key == "netmask" && val != "") {
        print "NETMASK=" val
      } else if (key == "gateway" && val != "") {
        print "GATEWAY=" val
      }
    }
  ' "$file"
}

print_diff() {
  local old_file="$1" new_file="$2" label="$3"
  if cmp -s "$old_file" "$new_file"; then
    log "$label: no changes"
  else
    log "$label: planned changes"
    diff -u "$old_file" "$new_file" || true
  fi
}

apply_runtime() {
  local address="$1" netmask="$2" gateway="$3"
  local address_only cidr
  address_only="${address%%/*}"

  if [[ "$address" == */* ]]; then
    cidr="$address"
  else
    cidr="${address}/${netmask:-64}"
  fi

  if ! sysctl -p >/tmp/"$SCRIPT_NAME".sysctl.log 2>&1; then
    return 1
  fi

  if ip -6 addr show dev "$IFACE" | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -Fxq "$address_only"; then
    log "IPv6 address already present on $IFACE: $address_only"
  else
    ip -6 addr add "$cidr" dev "$IFACE"
  fi

  ip -6 route replace default via "$gateway" dev "$IFACE"
}

run_ping_check() {
  local ping_cmd=""
  if command -v ping6 >/dev/null 2>&1; then
    ping_cmd="ping6"
  elif command -v ping >/dev/null 2>&1; then
    ping_cmd="ping -6"
  fi

  if [[ -z "$ping_cmd" ]]; then
    warn "No ping command found; skip connectivity check."
    return
  fi

  if $ping_cmd -c 3 ipv6.google.com >/dev/null 2>&1; then
    log "IPv6 connectivity check passed: ipv6.google.com"
  else
    warn "IPv6 connectivity check failed: ipv6.google.com"
  fi
}

main() {
  parse_args "$@"

  require_command ip
  require_command sysctl
  require_command awk
  require_command grep
  require_command cp
  require_command diff
  require_command mktemp

  [[ "$EUID" -eq 0 ]] || die "Please run as root."

  check_os_support
  detect_iface
  validate_iface
  prompt_confirm

  log "Target interface: $IFACE"
  log "Mode: dry-run=$DRY_RUN, no-apply=$NO_APPLY, force=$FORCE"

  local sysctl_tmp interfaces_tmp parse_tmp
  sysctl_tmp="$(mktemp)"
  interfaces_tmp="$(mktemp)"
  parse_tmp="$(mktemp)"
  trap 'rm -f "$sysctl_tmp" "$interfaces_tmp" "$parse_tmp"' EXIT

  cp -a "$SYSCTL_FILE" "$sysctl_tmp"
  cp -a "$INTERFACES_FILE" "$interfaces_tmp"

  prepare_sysctl_file "$sysctl_tmp"
  if ! prepare_interfaces_file "$INTERFACES_FILE" "$interfaces_tmp"; then
    die "No 'iface $IFACE inet6 static' block found in $INTERFACES_FILE."
  fi

  print_diff "$SYSCTL_FILE" "$sysctl_tmp" "$SYSCTL_FILE"
  print_diff "$INTERFACES_FILE" "$interfaces_tmp" "$INTERFACES_FILE"

  extract_ipv6_values "$interfaces_tmp" > "$parse_tmp"
  # shellcheck disable=SC1090
  source "$parse_tmp"
  : "${ADDRESS:?Missing IPv6 'address' in iface ${IFACE} inet6 static block}"
  : "${GATEWAY:?Missing IPv6 'gateway' in iface ${IFACE} inet6 static block}"
  NETMASK="${NETMASK:-64}"

  log "Parsed IPv6 config: address=$ADDRESS netmask=$NETMASK gateway=$GATEWAY"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$NO_APPLY" -eq 1 ]]; then
      log "Would write files only (no runtime apply)."
    else
      log "Would run: sysctl -p"
      log "Would run: ip -6 addr add <address>/<netmask> dev $IFACE (skip if exists)"
      log "Would run: ip -6 route replace default via $GATEWAY dev $IFACE"
      log "Would run: ping6 -c3 ipv6.google.com"
    fi
    exit 0
  fi

  local backup_path
  backup_path="$(create_backup)"
  log "Backup created at: $backup_path"

  cp -a "$sysctl_tmp" "$SYSCTL_FILE"
  cp -a "$interfaces_tmp" "$INTERFACES_FILE"
  log "Configuration files updated."

  if [[ "$NO_APPLY" -eq 1 ]]; then
    log "--no-apply set; skip runtime apply."
    log "Manual apply commands:"
    log "  sysctl -p"
    log "  ip -6 addr add ${ADDRESS}/${NETMASK} dev $IFACE"
    log "  ip -6 route replace default via $GATEWAY dev $IFACE"
    exit 0
  fi

  if ! apply_runtime "$ADDRESS" "$NETMASK" "$GATEWAY"; then
    warn "Runtime apply failed. Restoring backup..."
    restore_backup "$backup_path"
    sysctl -p >/dev/null 2>&1 || true
    die "Apply failed and configs restored from backup: $backup_path"
  fi

  run_ping_check
  log "Completed."
  log "Reboot check (recommended): reboot, then run 'ping6 -c3 ipv6.google.com'."
}

main "$@"
