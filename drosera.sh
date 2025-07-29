#!/usr/bin/env bash
#===============================================================================
# Drosera Helper Script
# Version: v1.1.4
# Updated: 2025-07-30
#-------------------------------------------------------------------------------
# What this script does (Menu 1):
#   - Install / upgrade Docker, Bun, Foundry, Drosera CLI
#   - Initialize trap project from drosera-network/trap-foundry-template
#   - Auto-apply trap (non-interactive), auto-bloomboost with given ETH amount
#   - Generate docker-compose (proper multiaddr), write .env (ETH_PRIVATE_KEY no 0x)
#   - Bring up drosera-operator container, then register & opt-in (with retries)
#   - All steps are idempotent; safe to re-run
#-------------------------------------------------------------------------------
# Quick run:
#   sudo -E bash ./drosera.sh --auto --pk 0xYOUR_PRIVATE_KEY
#   sudo -E bash ./drosera.sh --auto --pk-file /root/pk.txt --eth-amount 0.2
#   DROSERA_PRIVATE_KEY=0xYOUR_PRIVATE_KEY sudo -E bash ./drosera.sh --auto
#===============================================================================

set -euo pipefail

VERSION="v1.1.4"
LC_ALL=C
LANG=C

# ---------- Defaults ----------
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/drosera-network}"
LOG_DIR="${LOG_DIR:-/var/log/drosera}"
ETH_AMOUNT_DEFAULT="${ETH_AMOUNT_DEFAULT:-0.1}"
CHAIN_ID="${CHAIN_ID:-560048}"
RPC_URL="${RPC_URL:-https://ethereum-hoodi-rpc.publicnode.com}"
BACKUP_RPC_URL="${BACKUP_RPC_URL:-https://ethereum-hoodi-rpc.publicnode.com}"
DROSERA_ADDR="${DROSERA_ADDR:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
RESPONSE_CONTRACT="${RESPONSE_CONTRACT:-0x183D78491555cb69B68d2354F7373cc2632508C7}"
RESPONSE_FUNCTION="${RESPONSE_FUNCTION:-helloworld(string)}"
P2P_PORT="${P2P_PORT:-31313}"
SERVER_PORT="${SERVER_PORT:-31314}"
IMG_TAG="${IMG_TAG:-v1.20.0}"
COMPOSE_BIN="docker compose"  # using plugin-style compose

# Flags
AUTO=0
ETH_AMOUNT="$ETH_AMOUNT_DEFAULT"
PK_INPUT="${DROSERA_PRIVATE_KEY:-}"     # allow env
PK_FILE=""
PUBLIC_IP_ENV="${PUBLIC_IP:-}"
SKIP_REGISTER=0

# ---------- Utils ----------
log()  { printf "%s  %s\n" "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "${LOG_DIR}/run.log"; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }
header() {
  cat <<EOF
================================================================
Drosera Helper Script  ${VERSION}  ($(date +%Y-%m-%d))
================================================================
This script will help you install, configure, and operate Drosera.
- Works best on Ubuntu (LTS). Run as root.
- Secrets can be provided interactively, via env, or via flags.
- Override defaults by exporting env vars before running.

Base directories:
- Trap project: ${TRAP_DIR}
- Operator repo: ${OP_DIR}
- Logs: ${LOG_DIR}

You may run with flags, e.g.:
  sudo -E bash ${PWD}/$(basename "$0") --auto --pk 0xYOUR_HEX_KEY
  sudo -E bash ${PWD}/$(basename "$0") --auto --pk-file /root/pk.txt --eth-amount 0.2
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash ${PWD}/$(basename "$0") --auto
EOF
}

usage() {
  cat <<'EOF'
Usage:
  drosera.sh [--auto] [--pk <hex>] [--pk-file <path>] [--eth-amount <float>]
             [--rpc <url>] [--backup-rpc <url>] [--public-ip <ip>]
             [--skip-register]

Options:
  --auto                Chạy full flow không hỏi (apply + bloomboost + operator up + register + optin)
  --pk HEX              Private key EVM (có hoặc không có '0x')
  --pk-file PATH        Đường dẫn tệp chứa private key (1 dòng)
  --eth-amount N        Số ETH dùng bloomboost (mặc định 0.1)
  --rpc URL             RPC chính (mặc định: public node Hoodi)
  --backup-rpc URL      RPC dự phòng (mặc định: giống RPC chính)
  --public-ip IP        IP public VPS nếu tự chỉ định; nếu không script sẽ tự dò
  --skip-register       Bỏ qua bước register & opt-in operator (nếu muốn chỉ dựng container)

Ví dụ:
  sudo -E bash ./drosera.sh --auto --pk 0xdeadbeef... --eth-amount 0.2
  sudo -E bash ./drosera.sh --auto --pk-file /root/pk.txt --public-ip 1.2.3.4

EOF
}

require_root() { [ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() { mkdir -p "$TRAP_DIR" "$OP_DIR" "$LOG_DIR"; }

pause() { read -r -p "Press Enter to return to menu..." _ || true; }

# Normalize and validate PK:
# - Accept with or without 0x
# - Validate 64 hex chars
# - Provide two forms: with 0x and without 0x
normalize_pk() {
  local raw="${1:-}"
  raw="$(echo -n "$raw" | tr -d '\r\n[:space:]')"
  if [[ -z "$raw" ]]; then
    die "Empty private key."
  fi
  # strip optional 0x/0X
  if [[ "$raw" =~ ^0[xX] ]]; then raw="${raw:2}"; fi
  # lowercase
  raw="$(echo -n "$raw" | tr 'A-F' 'a-f')"
  # validate
  if [[ ! "$raw" =~ ^[0-9a-f]{64}$ ]]; then
    die "Invalid private key format. Need 64 hex chars (with or without 0x)."
  fi
  PK_NO_0X="$raw"
  PK_WITH_0X="0x$raw"
  export PK_NO_0X PK_WITH_0X
}

detect_public_ip() {
  local ip="${PUBLIC_IP_ENV:-}"
  if [[ -n "$ip" ]]; then
    echo "$ip"; return 0
  fi
  # Try common methods
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
  if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  if command_exists curl; then
    ip="$(curl -s --max-time 2 https://ipv4.icanhazip.com || true)"
    ip="$(echo -n "$ip" | tr -d '\r\n')"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
  fi
  echo "your_vps_public_ip"
}

ensure_apt_packages() {
  log "Updating apt & installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >> "${LOG_DIR}/apt.log" 2>&1 || true
  apt-get upgrade -y >> "${LOG_DIR}/apt.log" 2>&1 || true
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    software-properties-common jq git wget unzip tar \
    build-essential pkg-config make gcc clang \
    autoconf automake libleveldb-dev bsdmainutils \
    libssl-dev libgbm1 ncdu nvme-cli \
    >> "${LOG_DIR}/apt.log" 2>&1 || true
}

ensure_docker() {
  if ! command_exists docker; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh >> "${LOG_DIR}/docker.log" 2>&1
    systemctl enable --now docker >> "${LOG_DIR}/docker.log" 2>&1 || true
  else
    log "Docker already installed. Upgrading if needed..."
    apt-get update -y >> "${LOG_DIR}/docker.log" 2>&1 || true
    apt-get install -y docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >> "${LOG_DIR}/docker.log" 2>&1 || true
    systemctl enable docker >> "${LOG_DIR}/docker.log" 2>&1 || true
  fi
}

ensure_bun() {
  if ! command_exists bun; then
    log "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash >> "${LOG_DIR}/bun.log" 2>&1 || true
    export BUN_INSTALL="${HOME}/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
  else
    log "Bun already installed."
  fi
}

ensure_foundry() {
  if ! command_exists foundryup; then
    log "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash >> "${LOG_DIR}/foundry.log" 2>&1 || true
    # load path for this shell
    if [[ -f "${HOME}/.bashrc" ]]; then . "${HOME}/.bashrc"; fi
  else
    log "Foundry already installed; running foundryup..."
  fi
  foundryup >> "${LOG_DIR}/foundry.log" 2>&1 || true
}

ensure_drosera_cli() {
  if [[ ! -x "${HOME}/.drosera/bin/drosera" ]]; then
    log "Installing Drosera CLI via droseraup..."
  else
    log "Drosera CLI present; running droseraup..."
  fi
  # droseraup installer from upstream releases
  curl -fsSL https://raw.githubusercontent.com/drosera-network/cli-install/main/droseraup.sh -o /usr/local/bin/droseraup
  chmod +x /usr/local/bin/droseraup
  droseraup >> "${LOG_DIR}/drosera.log" 2>&1 || true

  # Ensure drosera binaries in PATH
  export PATH="${HOME}/.drosera/bin:${PATH}"
  command -v drosera >/dev/null 2>&1 || die "drosera CLI not found in PATH"
}

trap_init_or_update() {
  log "Initializing trap project at ${TRAP_DIR} ..."
  if [[ ! -d "${TRAP_DIR}/.git" ]]; then
    rm -rf "${TRAP_DIR}"
    git clone --depth 1 https://github.com/drosera-network/trap-foundry-template "${TRAP_DIR}" >> "${LOG_DIR}/trap.log" 2>&1 || true
    (cd "${TRAP_DIR}" && forge init -q) >> "${LOG_DIR}/trap.log" 2>&1 || true
  else
    log "Found existing repo in ${TRAP_DIR}; skipping forge init."
  fi

  # Install deps & compile
  (cd "${TRAP_DIR}" && bun install) >> "${LOG_DIR}/trap.log" 2>&1 || true
  (cd "${TRAP_DIR}" && forge build -q) >> "${LOG_DIR}/trap.log" 2>&1 || true
}

show_address_from_pk() {
  local addr
  addr="$(cast wallet address --private-key "$PK_NO_0X" 2>/dev/null || true)"
  if [[ -z "$addr" ]]; then
    addr="$(cast wallet address --private-key "$PK_WITH_0X" 2>/dev/null || true)"
  fi
  if [[ -n "$addr" ]]; then
    echo "$addr"
  else
    echo "unknown"
  fi
}

drosera_apply_noninteractive() {
  log "Running: drosera apply (first time)"
  # drosera apply prompts for PK. We feed it via stdin.
  # Ensure consistent locale to avoid UTF-8 prompt issues.
  (
    cd "${TRAP_DIR}"
    printf "%s\n" "$PK_WITH_0X" | \
      DRO__ETH__CHAIN_ID="${CHAIN_ID}" \
      DRO__ETH__RPC_URL="${RPC_URL}" \
      DRO__DROSERA_ADDRESS="${DROSERA_ADDR}" \
      DRO__RESPONSE__CONTRACT="${RESPONSE_CONTRACT}" \
      DRO__RESPONSE__FUNCTION="${RESPONSE_FUNCTION}" \
      drosera apply 2>&1 | tee -a "${LOG_DIR}/apply.log"
  )
}

extract_config_and_rewards() {
  # Grep from apply log
  local conf rewards
  conf="$(grep -Eo 'Created Trap Config .* address: 0x[0-9a-fA-F]+' -A0 "${LOG_DIR}/apply.log" | tail -n1 | awk '{print $NF}')"
  if [[ -z "$conf" ]]; then
    conf="$(grep -Eo '0x[0-9a-fA-F]{40}' "${LOG_DIR}/apply.log" | tail -n1 || true)"
  fi
  rewards="$(grep -Eo 'trap_rewards: 0x[0-9a-fA-F]{40}' "${LOG_DIR}/apply.log" | tail -n1 | awk '{print $2}')"
  echo "${conf}|${rewards}"
}

bloom_boost_noninteractive() {
  local trap_config="$1"
  local eth_amount="$2"
  if [[ -z "$trap_config" ]]; then die "No trap_config address found for Bloom Boost."; fi
  log "Bloom Boosting trap..."
  log "trap_config: ${trap_config}"
  log "eth_amount: ${eth_amount}"
  # Feed 'ofc' confirmation
  printf "ofc\n" | drosera bloomboost --trap-config "$trap_config" --eth-amount "$eth_amount" 2>&1 | tee -a "${LOG_DIR}/boost.log" || true
}

render_compose() {
  local ip="$1"
  mkdir -p "${OP_DIR}"
  cat > "${OP_DIR}/docker-compose.yaml" <<EOF
services:
  drosera-operator:
    image: ghcr.io/drosera-network/drosera-operator:${IMG_TAG}
    container_name: drosera-operator
    network_mode: host
    environment:
      - DRO__DB_FILE_PATH=/data/drosera.db
      - DRO__DROSERA_ADDRESS=${DROSERA_ADDR}
      - DRO__LISTEN_ADDRESS=0.0.0.0
      - DRO__DISABLE_DNR_CONFIRMATION=true
      - DRO__ETH__CHAIN_ID=${CHAIN_ID}
      - DRO__ETH__RPC_URL=${RPC_URL}
      - DRO__ETH__BACKUP_RPC_URL=${BACKUP_RPC_URL}
      - DRO__ETH__PRIVATE_KEY=\${ETH_PRIVATE_KEY}
      - DRO__NETWORK__P2P_PORT=${P2P_PORT}
      - DRO__NETWORK__EXTERNAL_P2P_ADDRESS=/ip4/${ip}/tcp/${P2P_PORT}
      - DRO__SERVER__PORT=${SERVER_PORT}
    volumes:
      - drosera_data:/data
    command: ["node"]
    restart: always

volumes:
  drosera_data:
EOF
}

write_env_file() {
  local ip="$1"
  cat > "${OP_DIR}/.env" <<EOF
ETH_PRIVATE_KEY=${PK_NO_0X}
VPS_IP=${ip}
EOF
  log "Wrote ETH_PRIVATE_KEY=****** to ${OP_DIR}/.env"
}

operator_stack_restart() {
  log "Pulling latest operator image..."
  ${COMPOSE_BIN} -f "${OP_DIR}/docker-compose.yaml" pull >> "${LOG_DIR}/compose_full.log" 2>&1 || true
  log "Restarting operator stack..."
  ${COMPOSE_BIN} -f "${OP_DIR}/docker-compose.yaml" down -v >> "${LOG_DIR}/compose_full.log" 2>&1 || true
  ${COMPOSE_BIN} -f "${OP_DIR}/docker-compose.yaml" up -d >> "${LOG_DIR}/compose_full.log" 2>&1 || true
  ${COMPOSE_BIN} -f "${OP_DIR}/docker-compose.yaml" ps
}

operator_register_with_retry() {
  local max_tries=5
  local n=1
  log "Registering Drosera Operator..."
  # Register via container if CLI is present inside; otherwise via host drosera (if it exposes register).
  # First try host CLI subcommand
  while (( n <= max_tries )); do
    if drosera operator register 2>&1 | tee -a "${LOG_DIR}/register.log"; then
      log "Register OK."
      return 0
    else
      if grep -qi "rate limited" "${LOG_DIR}/register.log"; then
        log "Rate limited; retrying in $((n*5))s... ($n/${max_tries})"
        sleep $((n*5))
      else
        log "Register command failed (attempt $n/${max_tries})."
        sleep $((n*3))
      fi
    fi
    n=$((n+1))
  done
  log "WARNING: Register command failed; check logs."
  return 1
}

operator_optin_idempotent() {
  local trap_config="$1"
  log "Operator optin..."
  if drosera operator optin --trap-config "$trap_config" 2>&1 | tee -a "${LOG_DIR}/optin.log"; then
    log "Opt-in done."
    return 0
  else
    if grep -qi "OperatorAlreadyUnderTrap" "${LOG_DIR}/optin.log"; then
      log "Operator already opted in; continuing."
      return 0
    fi
    log "WARNING: Opt-in failed; you can try from Drosera dashboard."
    return 1
  fi
}

menu_main() {
  header
  cat <<'EOF'
Choose an option:
 1) Full install (AUTO-ready): Docker + Bun + Foundry + Drosera, init trap, normalize config, apply, bloomboost, operator register & optin
 2) View operator logs (docker compose logs -f)
 3) Restart operator stack (compose down/up)
 4) Upgrade Drosera & set relay RPC, then apply
 5) Claim Cadet role (Trap.sol + apply)
 0) Exit
EOF
  read -rp "Select (0-5): " choice || true
  case "${choice:-}" in
    1) run_full ;; 
    2) view_logs ;;
    3) restart_stack ;;
    4) upgrade_and_apply ;;
    5) claim_cadet ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
}

view_logs() {
  echo "==== Docker Compose logs (follow; Ctrl-C to exit) ===="
  ${COMPOSE_BIN} -f "${OP_DIR}/docker-compose.yaml" logs -f || true
}

restart_stack() {
  operator_stack_restart
  pause
}

upgrade_and_apply() {
  ensure_apt_packages
  ensure_docker
  ensure_bun
  ensure_foundry
  ensure_drosera_cli

  log "Upgrading drosera CLI & setting RPC..."
  # CLI upgrade already done; just re-apply with current RPCs
  if [[ -z "${PK_INPUT}" && -z "${PK_FILE}" ]]; then
    read -rsp "Enter your EVM private key (64 hex, may start with 0x): " PK_INPUT; echo
  fi
  if [[ -n "${PK_FILE}" && -z "${PK_INPUT}" ]]; then
    PK_INPUT="$(head -n1 "${PK_FILE}" | tr -d '\r\n[:space:]')"
  fi
  normalize_pk "$PK_INPUT"
  trap_init_or_update
  addr="$(show_address_from_pk)"
  echo "Your EVM address: ${addr}"

  drosera_apply_noninteractive
  pause
}

claim_cadet() {
  ensure_apt_packages
  ensure_docker
  ensure_bun
  ensure_foundry
  ensure_drosera_cli

  if [[ -z "${PK_INPUT}" && -z "${PK_FILE}" ]]; then
    read -rsp "Enter your EVM private key (64 hex, may start with 0x): " PK_INPUT; echo
  fi
  if [[ -n "${PK_FILE}" && -z "${PK_INPUT}" ]]; then
    PK_INPUT="$(head -n1 "${PK_FILE}" | tr -d '\r\n[:space:]')"
  fi
  normalize_pk "$PK_INPUT"
  trap_init_or_update
  log "Claiming Cadet role via Trap.sol ..."
  (
    cd "${TRAP_DIR}"
    printf "%s\n" "$PK_WITH_0X" | \
      drosera claim-cadet 2>&1 | tee -a "${LOG_DIR}/cadet.log" || true
  )
  pause
}

run_full() {
  ensure_apt_packages
  ensure_docker
  ensure_bun
  ensure_foundry
  ensure_drosera_cli

  # --- Secret input ---
  if [[ -z "${PK_INPUT}" && -z "${PK_FILE}" ]]; then
    read -rsp "Enter your EVM private key (64 hex, may start with 0x): " PK_INPUT; echo
  fi
  if [[ -n "${PK_FILE}" && -z "${PK_INPUT}" ]]; then
    PK_INPUT="$(head -n1 "${PK_FILE}" | tr -d '\r\n[:space:]')"
  fi
  normalize_pk "$PK_INPUT"

  # --- Trap project ---
  trap_init_or_update
  addr="$(show_address_from_pk)"
  echo "Your EVM address: ${addr}"

  # --- drosera apply ---
  drosera_apply_noninteractive

  # Extract trap_config from logs (best-effort)
  IFS="|" read -r TRAP_CONFIG_ADDR TRAP_REWARDS_ADDR <<<"$(extract_config_and_rewards)"
  if [[ -z "${TRAP_CONFIG_ADDR}" ]]; then
    # Try to parse a known line
    TRAP_CONFIG_ADDR="$(grep -Eo '0x[0-9a-fA-F]{40}' "${LOG_DIR}/apply.log" | tail -n1 || true)"
  fi
  log "Parsed trap_config: ${TRAP_CONFIG_ADDR:-unknown}"

  # --- Bloom boost ---
  bloom_boost_noninteractive "${TRAP_CONFIG_ADDR:-}" "${ETH_AMOUNT}"

  # --- Operator compose ---
  local_ip="$(detect_public_ip)"
  render_compose "$local_ip"
  write_env_file "$local_ip"
  operator_stack_restart

  # --- Register & opt-in (best-effort) ---
  if [[ "$SKIP_REGISTER" -eq 0 ]]; then
    operator_register_with_retry || true
    if [[ -n "${TRAP_CONFIG_ADDR:-}" ]]; then
      operator_optin_idempotent "${TRAP_CONFIG_ADDR}" || true
    fi
  fi

  echo
  echo "Choose an option:"
  echo " 1) Full install (AUTO-ready): Docker + Bun + Foundry + Drosera, init trap, normalize config, apply, bloomboost, operator register & optin"
  echo " 2) View operator logs (docker compose logs -f)"
  echo " 3) Restart operator stack (compose down/up)"
  echo " 4) Upgrade Drosera & set relay RPC, then apply"
  echo " 5) Claim Cadet role (Trap.sol + apply)"
  echo " 0) Exit"
}

# ---------- Parse flags ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --pk) PK_INPUT="${2:-}"; shift 2 ;;
    --pk-file) PK_FILE="${2:-}"; shift 2 ;;
    --eth-amount) ETH_AMOUNT="${2:-$ETH_AMOUNT_DEFAULT}"; shift 2 ;;
    --rpc) RPC_URL="${2:-$RPC_URL}"; shift 2 ;;
    --backup-rpc) BACKUP_RPC_URL="${2:-$BACKUP_RPC_URL}"; shift 2 ;;
    --public-ip) PUBLIC_IP_ENV="${2:-}"; shift 2 ;;
    --skip-register) SKIP_REGISTER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1"; usage; exit 1 ;;
  esac
done

# ---------- Main ----------
require_root
ensure_dirs

if [[ "$AUTO" -eq 1 ]]; then
  run_full
else
  menu_main
fi
