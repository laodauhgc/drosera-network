#!/usr/bin/env bash
#===============================================================================
# Drosera Helper Script
# Version: v1.1.6
# Key changes in v1.1.6:
# - Idempotent install: stop/rm old container, rm old volume (default), recreate.
# - Wait for container to be running & stable before register/optin.
# - Normalize ETH private key (allow with/without 0x) -> 64 hex (no 0x) in .env.
# - Use multiaddr for P2P address; remove 'version:' from compose; clean warnings.
# - Avoid sourcing .bashrc; guard PS1 to prevent "unbound variable".
# - droseraup 404 tolerated; continue with existing CLI.
# - Flags: --auto, --pk/--pk-file, --eth-amount, --public-ip, --preserve-volume,
#          --no-register, --no-optin
#===============================================================================

set -Eeuo pipefail
: "${PS1:=}"  # prevent 'unbound variable' if .bashrc gets sourced somewhere

VERSION="v1.1.6"
DATE="2025-07-30"

#------------------------------- UI helpers -----------------------------------
log()   { printf "%s  %s\n" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" ; }
warn()  { printf "%s  WARNING: %s\n" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }
die()   { printf "%s  ERROR: %s\n" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; exit 1; }

#------------------------------- Defaults -------------------------------------
BASE_TRAP_DIR="${BASE_TRAP_DIR:-/root/my-drosera-trap}"
BASE_OP_DIR="${BASE_OP_DIR:-/root/drosera-network}"
LOG_DIR="${LOG_DIR:-/var/log/drosera}"
mkdir -p "$LOG_DIR"

ETH_AMOUNT="0.10"          # bloom boost default
AUTO="false"
DO_REGISTER="true"
DO_OPTIN="true"
PRESERVE_VOLUME="false"
PUBLIC_IP="${PUBLIC_IP:-}"
PK_IN=""

#------------------------------- Flags ----------------------------------------
usage() {
  cat <<EOF
Drosera Helper Script $VERSION ($DATE)

Usage:
  sudo -E bash $0 [--auto] [--pk <hex>] [--pk-file <file>] [--eth-amount <ETH>]
                   [--public-ip <IP>] [--preserve-volume] [--no-register] [--no-optin]

Examples:
  sudo -E bash $0 --auto --pk 0xYOUR_HEX_KEY
  sudo -E bash $0 --auto --pk-file /root/pk.txt --eth-amount 0.2
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash $0 --auto
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO="true"; shift ;;
    --pk) PK_IN="$2"; shift 2 ;;
    --pk-file) PK_IN="$(tr -d ' \n\r\t' < "$2")"; shift 2 ;;
    --eth-amount) ETH_AMOUNT="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
    --no-register) DO_REGISTER="false"; shift ;;
    --no-optin) DO_OPTIN="false"; shift ;;
    --preserve-volume) PRESERVE_VOLUME="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi
}
require_root

#----------------------------- Utilities --------------------------------------
normalize_pk() {
  local in="$1"
  [[ -z "$in" ]] && return 1
  in="${in#0x}"                               # strip 0x if present
  in="$(echo -n "$in" | tr 'A-F' 'a-f')"      # lowercase
  if [[ ${#in} -ne 64 ]] || ! [[ "$in" =~ ^[0-9a-f]{64}$ ]]; then
    return 2
  fi
  echo -n "$in"
}

get_pk() {
  local pk="${PK_IN:-${DROSERA_PRIVATE_KEY:-${ETH_PRIVATE_KEY:-}}}"
  if [[ -z "$pk" && "$AUTO" != "true" ]]; then
    read -rsp "Enter your EVM private key (64 hex, may start with 0x): " pk; echo
  fi
  local norm
  norm="$(normalize_pk "$pk" 2>/dev/null || true)" || true
  if [[ -z "$norm" ]]; then
    die "Invalid private key. Provide 64 hex chars (with or without 0x)."
  fi
  echo -n "$norm"
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP" ]]; then
    echo -n "$PUBLIC_IP"; return 0
  fi
  # Try external services quickly; fallback to primary non-loopback addr
  local ip=""
  ip="$(curl -fsS --max-time 3 https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 3 https://ifconfig.me || true)"
  if [[ -z "$ip" ]]; then
    # fallback to first global address if any
    ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i!~/^127\./){print $i; exit}}}')"
  fi
  echo -n "$ip"
}

ensure_paths() {
  mkdir -p "$BASE_TRAP_DIR" "$BASE_OP_DIR" "$LOG_DIR"
}

append_path_session() {
  export PATH="$HOME/.drosera/bin:$HOME/.foundry/bin:$PATH"
}

#-------------------------- Installers ----------------------------------------
install_base() {
  log "Updating apt & installing base packages..."
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    git jq wget tar unzip build-essential make gcc \
    software-properties-common pkg-config \
    clang libssl-dev autoconf automake libleveldb-dev \
    htop tmux ncdu lz4
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  else
    log "Docker already installed. Upgrading if needed..."
    apt-get update -y -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    systemctl enable docker || true
  fi
}

install_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    log "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash
  else
    log "Bun already installed."
  fi
}

install_foundry() {
  if ! command -v foundryup >/dev/null 2>&1; then
    log "Installing Foundry..."
    curl -fsSL https://foundry.paradigm.xyz | bash | tee -a "$LOG_DIR/foundry_install.log"
  else
    log "Foundry already installed; running foundryup..."
  fi
  append_path_session
  foundryup | tee -a "$LOG_DIR/foundry_update.log"
}

install_drosera_cli() {
  append_path_session
  if command -v drosera >/dev/null 2>&1; then
    log "Drosera CLI present; running droseraup..."
    # try to fetch updater script; tolerate 404
    if ! curl -fsSL https://raw.githubusercontent.com/drosera-network/drosera/main/droseraup -o /usr/local/bin/droseraup; then
      warn "Failed to download droseraup (network?). Skipping."
    else
      chmod +x /usr/local/bin/droseraup || true
      droseraup || true
    fi
  else
    warn "Drosera CLI not found; proceeding (some steps may fail)."
  fi
}

#------------------------- Trap project ops -----------------------------------
init_trap_project() {
  log "Initializing trap project at $BASE_TRAP_DIR ..."
  if [[ ! -d "$BASE_TRAP_DIR/.git" ]]; then
    git clone --depth=1 https://github.com/drosera-network/trap-foundry-template "$BASE_TRAP_DIR" 2>/dev/null || true
    (cd "$BASE_TRAP_DIR" && bun install || true)
  else
    log "Found existing repo in $BASE_TRAP_DIR; syncing deps..."
    (cd "$BASE_TRAP_DIR" && bun install || true)
  fi
  append_path_session
  # quick compile once to fetch solc etc (non-fatal)
  (cd "$BASE_TRAP_DIR" && forge build || true)
}

calc_address_from_pk() {
  local pk_no0x="$1"
  append_path_session
  if ! command -v cast >/dev/null 2>&1; then
    warn "Foundry 'cast' not found; cannot compute address."
    echo ""
    return 0
  fi
  local addr
  addr="$(cast wallet address --private-key "0x${pk_no0x}" 2>/dev/null || true)"
  echo -n "${addr:-}"
}

run_apply_non_interactive() {
  local pk_no0x="$1"
  append_path_session
  if ! command -v drosera >/dev/null 2>&1; then
    warn "drosera CLI not available; skip apply."
    return 0
  fi
  log "Running: drosera apply (non-interactive)"
  # Provide multiple env names just in case; and auto-confirm
  (cd "$BASE_TRAP_DIR" && \
    DROSERA_PRIVATE_KEY="0x${pk_no0x}" \
    ETH_PRIVATE_KEY="0x${pk_no0x}" \
    PRIVATE_KEY="0x${pk_no0x}" \
    yes ofc | drosera apply \
  ) | tee "$LOG_DIR/apply.log" || {
      warn "Apply failed. See $LOG_DIR/apply.log"
      return 1
  }
  return 0
}

parse_trap_config_from_apply_log() {
  # Try several patterns to extract trap_config address
  local addr=""
  if [[ -f "$LOG_DIR/apply.log" ]]; then
    addr="$(grep -Eo 'trap_config:\s*0x[0-9a-fA-F]{40}' "$LOG_DIR/apply.log" | tail -n1 | awk '{print $2}')"
    if [[ -z "$addr" ]]; then
      addr="$(grep -Eo 'Created Trap Config .*address:\s*0x[0-9a-fA-F]{40}' "$LOG_DIR/apply.log" | tail -n1 | awk '{print $NF}')"
    fi
  fi
  echo -n "$addr"
}

#------------------------- Operator (docker) -----------------------------------
write_compose() {
  local vps_ip="$1"
  mkdir -p "$BASE_OP_DIR"
  cat > "$BASE_OP_DIR/docker-compose.yaml" <<'YAML'
services:
  drosera-operator:
    image: ghcr.io/drosera-network/drosera-operator:v1.20.0
    container_name: drosera-operator
    network_mode: host
    environment:
      - DRO__DB_FILE_PATH=/data/drosera.db
      - DRO__DROSERA_ADDRESS=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D
      - DRO__LISTEN_ADDRESS=0.0.0.0
      - DRO__DISABLE_DNR_CONFIRMATION=true
      - DRO__ETH__CHAIN_ID=560048
      - DRO__ETH__RPC_URL=https://ethereum-hoodi-rpc.publicnode.com
      - DRO__ETH__BACKUP_RPC_URL=https://ethereum-hoodi-rpc.publicnode.com
      - DRO__ETH__PRIVATE_KEY=${ETH_PRIVATE_KEY}
      - DRO__NETWORK__P2P_PORT=31313
      - DRO__NETWORK__EXTERNAL_P2P_ADDRESS=${EXTERNAL_P2P_MADDR}
      - DRO__SERVER__PORT=31314
    volumes:
      - drosera_data:/data
    command: ["node"]
    restart: always

volumes:
  drosera_data:
YAML

  # .env for docker compose
  # ETH_PRIVATE_KEY must be 64 hex (no 0x). EXTERNAL_P2P_MADDR must be multiaddr.
  local pk_no0x="$2"
  local maddr="/ip4/${vps_ip}/tcp/31313"
  {
    echo "ETH_PRIVATE_KEY=${pk_no0x}"
    echo "VPS_IP=${vps_ip}"
    echo "EXTERNAL_P2P_MADDR=${maddr}"
  } > "$BASE_OP_DIR/.env"
}

compose_reset_stack() {
  log "Resetting operator stack (container & volume)..."
  (cd "$BASE_OP_DIR" && docker compose down --remove-orphans --volumes || true)
  docker rm -f drosera-operator 2>/dev/null || true
  # remove only our volume (safe)
  docker volume rm -f drosera-network_drosera_data 2>/dev/null || true
}

compose_preserve_stack() {
  log "Stopping/removing container only (preserve data volume)..."
  (cd "$BASE_OP_DIR" && docker compose down --remove-orphans || true)
  docker rm -f drosera-operator 2>/dev/null || true
}

compose_up() {
  log "Pulling latest operator image..."
  (cd "$BASE_OP_DIR" && docker compose pull)
  log "Starting operator stack..."
  (cd "$BASE_OP_DIR" && docker compose up -d)
}

wait_container_ready() {
  # Wait until container is running and not restarting for at least a short window
  local name="drosera-operator"
  local timeout=120
  local start_ts
  start_ts=$(date +%s)
  while true; do
    if ! docker ps --format '{{.Names}} {{.Status}}' | grep -q "^${name}\b"; then
      sleep 2
    else
      local status
      status="$(docker ps --format '{{.Names}} {{.Status}}' | awk -v n="$name" '$1==n{print substr($0, index($0,$2))}')"
      if echo "$status" | grep -qi '^Up '; then
        # check restart count stable
        local rc
        rc="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)"
        sleep 3
        local rc2
        rc2="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)"
        if [[ "$rc" == "$rc2" ]]; then
          log "Container is running and stable (RestartCount=$rc)."
          return 0
        fi
      fi
    fi
    if (( $(date +%s) - start_ts > timeout )); then
      warn "Container not stable after ${timeout}s."
      docker logs --tail=200 "$name" || true
      return 1
    fi
    sleep 2
  done
}

operator_register() {
  local retries=4
  local backoff=10
  log "Registering Drosera Operator..."
  for ((i=1;i<=retries;i++)); do
    if docker exec drosera-operator /drosera-operator register | tee -a "$LOG_DIR/register.log"; then
      log "Operator register OK."
      return 0
    fi
    warn "Register attempt $i/$retries failed; retrying in ${backoff}s..."
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
  done
  warn "Register command failed; see $LOG_DIR/register.log"
  return 1
}

operator_optin() {
  local trap_config="$1"
  if [[ -z "$trap_config" ]]; then
    warn "No trap_config available; skip opt-in."
    return 0
  fi
  log "Operator optin to trap ${trap_config}..."
  if docker exec drosera-operator /drosera-operator optin --trap-config "$trap_config" | tee -a "$LOG_DIR/optin.log"; then
    log "Operator opt-in OK."
    return 0
  fi
  warn "Opt-in command failed; see $LOG_DIR/optin.log"
  return 1
}

#------------------------------ Main Flow -------------------------------------
main_auto() {
  ensure_paths
  install_base
  install_docker
  install_bun
  install_foundry
  install_drosera_cli

  local pk_no0x
  pk_no0x="$(get_pk)"
  append_path_session

  # show derived address (for visibility)
  local addr
  addr="$(calc_address_from_pk "$pk_no0x")"
  [[ -n "$addr" ]] && echo "Your EVM address: $addr"

  init_trap_project
  run_apply_non_interactive "$pk_no0x" || true

  local trap_config
  trap_config="$(parse_trap_config_from_apply_log || true)"

  # bloom boost (best-effort)
  if command -v drosera >/dev/null 2>&1; then
    log "Bloom Boosting trap (best-effort)..."
    if [[ -n "$trap_config" ]]; then
      (cd "$BASE_TRAP_DIR" && yes ofc | drosera boost --trap-config "$trap_config" --eth "$ETH_AMOUNT") \
        | tee "$LOG_DIR/boost.log" || warn "Bloom boost failed; see $LOG_DIR/boost.log"
    else
      warn "No trap_config available; skipping bloom boost."
    fi
  fi

  # Compose & operator
  local ip
  ip="$(detect_public_ip)"
  [[ -z "$ip" ]] && die "Could not detect public IP; provide --public-ip <IP>."
  log "Using Public IP: $ip"
  write_compose "$ip" "$pk_no0x"

  if [[ "$PRESERVE_VOLUME" == "true" ]]; then
    compose_preserve_stack
  else
    compose_reset_stack
  fi
  compose_up
  if ! wait_container_ready; then
    warn "Operator not stable; you may check logs: docker logs -f drosera-operator"
  fi

  # Register & optin
  if [[ "$DO_REGISTER" == "true" ]]; then
    operator_register || true
  else
    log "Skipped register as requested."
  fi
  if [[ "$DO_OPTIN" == "true" ]]; then
    operator_optin "$trap_config" || true
  else
    log "Skipped opt-in as requested."
  fi

  echo "Done."
}

main_menu() {
  cat <<MENU

================================================================
Drosera Helper Script  $VERSION  ($DATE)
================================================================
This script will help you install, configure, and operate Drosera.
- Works best on Ubuntu (LTS). Run as root.
- Secrets can be provided interactively, via env, or via flags.
- Override defaults by exporting env vars before running.

Base directories:
- Trap project: $BASE_TRAP_DIR
- Operator repo: $BASE_OP_DIR
- Logs: $LOG_DIR

You may run with flags, e.g.:
  sudo -E bash $0 --auto --pk 0xYOUR_HEX_KEY
  sudo -E bash $0 --auto --pk-file /root/pk.txt --eth-amount 0.2
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash $0 --auto

Choose an option:
 1) Full install (AUTO-ready): Docker + Bun + Foundry + Drosera, init trap, normalize config, apply, bloomboost, operator register & optin
 2) View operator logs (docker compose logs -f)
 3) Restart operator stack (compose down/up)
 4) Upgrade Drosera & set relay RPC, then apply
 5) Claim Cadet role (Trap.sol + apply)
 0) Exit
MENU
  read -rp "Select (0-5): " choice
  case "$choice" in
    1) AUTO="true"; main_auto ;;
    2) cd "$BASE_OP_DIR" && echo "==== Docker Compose logs (follow; Ctrl-C to exit) ====" && docker compose logs -f ;;
    3) cd "$BASE_OP_DIR" && compose_preserve_stack && compose_up ;;
    4) install_drosera_cli && run_apply_non_interactive "$(get_pk)" || true ;;
    5) append_path_session; (cd "$BASE_TRAP_DIR" && yes ofc | drosera claim) || true ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac
}

if [[ "$AUTO" == "true" ]]; then
  main_auto
else
  main_menu
fi
