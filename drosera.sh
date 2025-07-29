#!/usr/bin/env bash
# drosera.sh - Setup & operate drosera-operator stack
# Version: v1.1.9
#
# Changes (v1.1.9):
# - Force IPv4-first for EXTERNAL_P2P_MADDR (fallback IPv6 if requested or no IPv4)
# - Fix restart loop due to wrong multiaddr (/ip4 with IPv6 string)
# - Cleanly remove old container/volume before compose up
# - Pass DROSERA_PRIVATE_KEY/ETH_PRIVATE_KEY to `drosera apply` to avoid key-missing
# - Wait for container stability before `register`; retry with backoff
# - Write .env only (preserve docker-compose.yaml), create if missing
# - Robust IP discovery & optional --ip override / --prefer-ipv6
# - Log outputs to /var/log/drosera

set -Eeuo pipefail

# ----------------------------- Config ---------------------------------
APP_DIR="/root/my-drosera-trap"
STACK_DIR="/root/drosera-network"
ENV_FILE="${STACK_DIR}/.env"
LOG_DIR="/var/log/drosera"
APPLY_LOG="${LOG_DIR}/apply.log"
REGISTER_LOG="${LOG_DIR}/register.log"
GENERAL_LOG="${LOG_DIR}/install.log"

OPERATOR_SVC_NAME="drosera-operator"
DEFAULT_OPERATOR_IMAGE="ghcr.io/drosera-network/drosera-operator:latest"
DEFAULT_P2P_PORT="31313"

# ----------------------------- Utils ----------------------------------
ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "$(ts)  $*" | tee -a "$GENERAL_LOG" >&2; }
info() { log "$@"; }
warn() { echo "$(ts)  WARNING: $*" | tee -a "$GENERAL_LOG" >&2; }
err() { echo "$(ts)  ERROR: $*" | tee -a "$GENERAL_LOG" >&2; }

on_error() {
  err "Script failed at line ${1:-unknown}. Check logs in ${LOG_DIR}."
}
trap 'on_error ${LINENO}' ERR

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

mask_key() {
  local v="$1"
  # mask middle chars
  if [[ "${#v}" -ge 14 ]]; then
    echo "${v:0:6}******${v: -6}"
  else
    echo "******"
  fi
}

retry() {
  # retry <max> <sleep_seconds> <command...>
  local max="$1"; shift
  local slp="$1"; shift
  local n=1
  until "$@"; do
    if (( n >= max )); then return 1; fi
    warn "Attempt $n/$max failed. Retry in ${slp}s: $*"
    sleep "$slp"
    ((n++))
  done
}

ensure_dirs() {
  mkdir -p "$LOG_DIR"
  touch "$GENERAL_LOG" "$APPLY_LOG" "$REGISTER_LOG"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

# ----------------------------- IP helpers ------------------------------
get_ipv4() {
  # Try public IPv4 via curl -4; fallback to iproute/hostname
  local ip=""
  ip=$(curl -4 -sS --max-time 3 https://api.ipify.org || true)
  if [[ -z "${ip}" ]]; then
    ip=$(ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 | grep -vE '^(127\.|10\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.|192\.168\.)' | head -n1 || true)
  fi
  if [[ -z "${ip}" ]]; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  fi
  echo "$ip"
}

get_ipv6() {
  local ip=""
  ip=$(curl -6 -sS --max-time 3 https://api64.ipify.org || true)
  if [[ -z "${ip}" ]]; then
    ip=$(ip -6 addr show scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -n1 || true)
  fi
  echo "$ip"
}

build_multiaddr() {
  local ip="$1"
  local port="${2:-$DEFAULT_P2P_PORT}"
  if [[ "$ip" == *:* ]]; then
    # IPv6
    echo "/ip6/${ip}/tcp/${port}"
  else
    echo "/ip4/${ip}/tcp/${port}"
  fi
}

# ----------------------------- Installers ------------------------------
apt_prepare() {
  info "Updating apt & installing base packages..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y >>"$GENERAL_LOG" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates jq git unzip lsb-release net-tools iproute2 \
    >>"$GENERAL_LOG" 2>&1
}

ensure_docker() {
  if ! cmd_exists docker; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh >>"$GENERAL_LOG" 2>&1
    systemctl enable --now docker >>"$GENERAL_LOG" 2>&1 || true
  else
    info "Docker already installed. Upgrading if needed..."
    systemctl enable docker >/dev/null 2>&1 || true
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    export COMPOSE="docker compose"
  elif cmd_exists docker-compose; then
    export COMPOSE="docker-compose"
  else
    info "Installing docker compose plugin..."
    # most systems will have it with docker package, try again
    if docker compose version >/dev/null 2>&1; then
      export COMPOSE="docker compose"
    else
      err "Docker compose not found. Please install docker compose plugin."
      exit 1
    fi
  fi
}

ensure_bun() {
  if ! cmd_exists bun; then
    info "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash >>"$GENERAL_LOG" 2>&1 || true
    export BUN_INSTALL="${HOME}/.bun"
    export PATH="${BUN_INSTALL}/bin:${PATH}"
  else
    info "Bun already installed."
  fi
}

ensure_foundry() {
  if [[ ! -x "${HOME}/.foundry/bin/forge" ]]; then
    info "Installing Foundry..."
    # Foundry adds lines to .bashrc; we don't source it to avoid PS1 errors.
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$GENERAL_LOG" 2>&1
  else
    info "Foundry already installed; running foundryup..."
  fi
  "${HOME}/.foundry/bin/foundryup" >>"$GENERAL_LOG" 2>&1 || true
}

ensure_drosera_cli() {
  if cmd_exists drosera; then
    info "Drosera CLI present."
  else
    warn "Drosera CLI not found in PATH. If you have a local CLI, ensure it's installed."
    # You may add your own install steps here if needed.
  fi
}

# ----------------------------- Compose Ops -----------------------------
compose_reset_stack() {
  info "Resetting operator stack (container & volume)..."
  mkdir -p "$STACK_DIR"
  cd "$STACK_DIR"

  # Best-effort down
  $COMPOSE down --remove-orphans -v >>"$GENERAL_LOG" 2>&1 || true

  # Remove named volume if still around
  docker volume rm "${OPERATOR_SVC_NAME%:*}_drosera_data" >/dev/null 2>&1 || true
  docker volume rm "drosera-network_drosera_data" >/dev/null 2>&1 || true
}

compose_pull_and_up() {
  info "Pulling latest operator image..."
  cd "$STACK_DIR"
  # If image is pinned in docker-compose.yaml, compose pull will respect that
  $COMPOSE pull >>"$GENERAL_LOG" 2>&1 || docker pull "$DEFAULT_OPERATOR_IMAGE" >>"$GENERAL_LOG" 2>&1 || true

  info "Starting operator stack..."
  $COMPOSE up -d >>"$GENERAL_LOG" 2>&1
}

wait_container_stable() {
  local name="$1"
  local timeout="${2:-120}"
  local start_ts
  start_ts=$(date +%s)

  info "Waiting up to ${timeout}s for container '${name}' to stabilize..."
  while true; do
    local now status restarts
    now=$(date +%s)
    if (( now - start_ts > timeout )); then
      warn "Container not stable after ${timeout}s."
      return 1
    fi

    if ! docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${name} "; then
      sleep 2
      continue
    fi

    status=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
    restarts=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "0")

    if [[ "$status" == "running" ]]; then
      # wait a short stability window
      local r0="$restarts"
      sleep 5
      local r1
      r1=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "0")
      if [[ "$r0" == "$r1" ]]; then
        info "Container '${name}' is running and stable."
        return 0
      fi
    fi
    sleep 3
  done
}

# ----------------------------- Drosera Ops -----------------------------
trap_project_sync() {
  info "Initializing trap project at ${APP_DIR} ..."
  mkdir -p "$APP_DIR"

  if [[ -d "${APP_DIR}/.git" ]]; then
    info "Found existing repo in ${APP_DIR}; syncing deps..."
    (cd "$APP_DIR" && git reset --hard >/dev/null 2>&1 || true && git pull --rebase --autostash >/dev/null 2>&1 || true)
  else
    # If you need to clone a template repo, add commands here.
    info "Using existing directory ${APP_DIR} (no git)."
  fi

  # bun install if package.json exists
  if [[ -f "${APP_DIR}/package.json" ]]; then
    (cd "$APP_DIR" && bun install) >>"$GENERAL_LOG" 2>&1 || true
  fi
}

drosera_apply_noninteractive() {
  local pk_hex="$1" # without 0x
  local pk0x="0x${pk_hex#0x}"

  info "Running: drosera apply (non-interactive)"
  (
    cd "$APP_DIR"
    # Some CLIs read ETH_PRIVATE_KEY, some read DROSERA_PRIVATE_KEY; export both.
    DROSERA_PRIVATE_KEY="${pk0x}" \
    ETH_PRIVATE_KEY="${pk0x}" \
    yes ofc | drosera apply
  ) | tee "$APPLY_LOG"
}

parse_apply_output() {
  # Extract trap_config/trap_rewards if present in output
  local tc tr
  tc=$(grep -Eo 'trap_config:\s*0x[a-fA-F0-9]{40,}' "$APPLY_LOG" | awk '{print $2}' | tail -n1 || true)
  tr=$(grep -Eo 'trap_rewards:\s*0x[a-fA-F0-9]{40,}' "$APPLY_LOG" | awk '{print $2}' | tail -n1 || true)

  if [[ -n "$tc" ]]; then echo "$tc|$tr"; else echo "|"; fi
}

operator_register() {
  info "Registering Drosera Operator..."
  # run inside container
  (docker exec "$OPERATOR_SVC_NAME" /drosera-operator register) | tee "$REGISTER_LOG"
}

# ----------------------------- .env Writer -----------------------------
write_env() {
  local pk_hex="$1"  # without 0x
  local ip="$2"      # chosen IP (v4 or v6)
  local pk0x="0x${pk_hex#0x}"
  local maddr
  maddr=$(build_multiaddr "$ip" "$DEFAULT_P2P_PORT")

  mkdir -p "$STACK_DIR"
  touch "$ENV_FILE"

  # Write/replace keys
  if grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^ETH_PRIVATE_KEY=.*#ETH_PRIVATE_KEY=${pk0x}#g" "$ENV_FILE"
  else
    echo "ETH_PRIVATE_KEY=${pk0x}" >> "$ENV_FILE"
  fi

  if grep -q '^VPS_IP=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^VPS_IP=.*#VPS_IP=${ip}#g" "$ENV_FILE"
  else
    echo "VPS_IP=${ip}" >> "$ENV_FILE"
  fi

  if grep -q '^EXTERNAL_P2P_MADDR=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^EXTERNAL_P2P_MADDR=.*#EXTERNAL_P2P_MADDR=${maddr}#g" "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_MADDR=${maddr}" >> "$ENV_FILE"
  fi

  info "Wrote ETH_PRIVATE_KEY=$(mask_key "$pk0x") to ${ENV_FILE}"
  info "Wrote VPS_IP=${ip} to ${ENV_FILE}"
  info "Wrote EXTERNAL_P2P_MADDR=${maddr} to ${ENV_FILE}"
}

# ----------------------------- Args ------------------------------------
AUTO=0
PREF_IPV6=0
FORCED_IP=""
PRIVATE_KEY_HEX=""
OP_DO_REGISTER=1

usage() {
  cat <<'USAGE'
Usage:
  drosera.sh --auto --pk <PRIVATE_KEY_64_HEX> [--ip <IP>] [--prefer-ipv6] [--no-register]

Options:
  --auto            Chạy toàn bộ quy trình (cài deps, sync, apply, compose up, register)
  --pk KEY          Private key 64 hex (không kèm 0x). Ví dụ: 0b68ef...97fc
  --ip IP           Ép dùng IP này cho EXTERNAL_P2P_MADDR (ví dụ 152.53.82.237 hoặc 2a0a:....)
  --prefer-ipv6     Ưu tiên IPv6 nếu có; nếu không có sẽ fallback IPv4
  --no-register     KHÔNG chạy bước register bên trong container
  -h, --help        Hiển thị trợ giúp

Ví dụ:
  /bin/bash drosera.sh --auto --pk YOUR_PRIVATE_KEY_NO_0x
  /bin/bash drosera.sh --auto --pk YOUR_PRIVATE_KEY_NO_0x --ip 152.53.82.237
  /bin/bash drosera.sh --auto --pk YOUR_PRIVATE_KEY_NO_0x --prefer-ipv6
USAGE
}

while (( "$#" )); do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --pk) PRIVATE_KEY_HEX="${2:-}"; shift 2 ;;
    --ip) FORCED_IP="${2:-}"; shift 2 ;;
    --prefer-ipv6) PREF_IPV6=1; shift ;;
    --no-register) OP_DO_REGISTER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ----------------------------- Main ------------------------------------
main() {
  require_root
  ensure_dirs

  if [[ "$AUTO" -ne 1 ]]; then
    usage
    exit 0
  fi

  if [[ -z "${PRIVATE_KEY_HEX}" ]]; then
    err "Missing --pk <PRIVATE_KEY_64_HEX>."
    exit 1
  fi

  info "Using Private Key: $(mask_key "${PRIVATE_KEY_HEX}")"
  apt_prepare
  ensure_docker
  ensure_compose
  ensure_bun
  ensure_foundry
  ensure_drosera_cli

  # Detect IP
  local chosen_ip=""
  if [[ -n "$FORCED_IP" ]]; then
    chosen_ip="$FORCED_IP"
    info "Using forced IP: ${chosen_ip}"
  else
    local ip4 ip6
    ip4=$(get_ipv4)
    ip6=$(get_ipv6)

    if [[ "$PREF_IPV6" -eq 1 ]]; then
      if [[ -n "$ip6" ]]; then chosen_ip="$ip6"; else chosen_ip="$ip4"; fi
    else
      if [[ -n "$ip4" ]]; then chosen_ip="$ip4"; else chosen_ip="$ip6"; fi
    fi
    if [[ -z "$chosen_ip" ]]; then
      err "Unable to detect public IP (IPv4 or IPv6). Use --ip to specify."
      exit 1
    fi
  fi

  info "Using Public IP: ${chosen_ip}"

  # Prepare stack env
  write_env "${PRIVATE_KEY_HEX}" "${chosen_ip}"

  # Sync trap project & apply (best-effort)
  trap_project_sync
  if cmd_exists drosera; then
    if drosera_apply_noninteractive "${PRIVATE_KEY_HEX}"; then
      :
    else
      warn "Apply failed. See ${APPLY_LOG}"
    fi
  else
    warn "Drosera CLI missing; skipped 'drosera apply'."
  fi

  # Bring up the operator stack
  compose_reset_stack
  compose_pull_and_up

  if ! wait_container_stable "$OPERATOR_SVC_NAME" 120; then
    warn "Operator not stable; you may check logs: docker logs -f ${OPERATOR_SVC_NAME}"
  fi

  # Register (optional)
  if [[ "$OP_DO_REGISTER" -eq 1 ]]; then
    # Only attempt when container is running
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$OPERATOR_SVC_NAME" 2>/dev/null || echo "unknown")
    if [[ "$status" != "running" ]]; then
      warn "Container not running; skip register. Check logs."
    else
      # retry register up to 4 times with backoff (10, 20, 40, 80s)
      local delays=(10 20 40 80)
      local ok=0
      for d in "${delays[@]}"; do
        if operator_register; then
          ok=1; break
        else
          warn "Register attempt failed; retrying in ${d}s..."
          sleep "$d"
        fi
      done
      if [[ "$ok" -ne 1 ]]; then
        warn "Register command failed; see ${REGISTER_LOG}"
      fi
    fi
  else
    info "Skipping register as requested (--no-register)."
  fi

  info "Done."
}

main "$@"
