#!/usr/bin/env bash
# ============================================================================
# Drosera Helper Script
# Version: v1.1.5
# Usage examples:
#   sudo -E bash ./drosera.sh --auto --pk 0xYOUR_PRIVATE_KEY
#   sudo -E bash ./drosera.sh --auto --pk-file /root/pk.txt --eth-amount 0.2
#   DROSERA_PRIVATE_KEY=0xYOUR_PRIVATE_KEY sudo -E bash ./drosera.sh --auto
# ============================================================================

set -Eeuo pipefail

# Prevent "PS1: unbound variable" if any installer/profile sources ~/.bashrc under set -u.
: "${PS1:=}"

# ------------- Global constants ----------------
VERSION="v1.1.5"
TODAY="$(date +'%Y-%m-%d')"
OS="$(uname -s || echo Linux)"
ARCH="$(uname -m || echo x86_64)"
ROOT_REQUIRED=true

# Paths
ROOT_HOME="${HOME:-/root}"
TRAP_DIR="${TRAP_DIR:-$ROOT_HOME/my-drosera-trap}"
OP_DIR="${OP_DIR:-$ROOT_HOME/drosera-network}"
LOG_DIR="${LOG_DIR:-/var/log/drosera}"
BIN_DIR_DRO="$ROOT_HOME/.drosera/bin"
BIN_DIR_FOUND="$ROOT_HOME/.foundry/bin"

# Network defaults (Hoodi)
CHAIN_ID="${CHAIN_ID:-560048}"
RPC_URL_DEFAULT="${RPC_URL_DEFAULT:-https://ethereum-hoodi-rpc.publicnode.com}"
RPC_URL_BACKUP_DEFAULT="${RPC_URL_BACKUP_DEFAULT:-https://ethereum-hoodi-rpc.publicnode.com}"
DROSERA_ADDRESS_DEFAULT="${DROSERA_ADDRESS_DEFAULT:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"

# Operator ports
P2P_PORT="${P2P_PORT:-31313}"
SERVER_PORT="${SERVER_PORT:-31314}"

# Defaults for auto flow
AUTO=false
PK_FLAG=""
PK_FILE_FLAG=""
ETH_AMOUNT="${ETH_AMOUNT:-0.1}"
PUBLIC_IP_FLAG=""
RPC_URL="${RPC_URL:-$RPC_URL_DEFAULT}"
RPC_URL_BACKUP="${RPC_URL_BACKUP:-$RPC_URL_BACKUP_DEFAULT}"
NO_REGISTER=false
NO_OPTIN=false

# Files
COMPOSE_FILE="$OP_DIR/docker-compose.yaml"
ENV_FILE="$OP_DIR/.env"
APPLY_LOG="$LOG_DIR/apply.log"
BOOST_LOG="$LOG_DIR/boost.log"
COMPOSE_LOG="$LOG_DIR/compose_full.log"
REGISTER_LOG="$LOG_DIR/register.log"
OPTIN_LOG="$LOG_DIR/optin.log"

# ------------- Colors & logging ----------------
if [ -t 1 ]; then
  BOLD="\033[1m"; DIM="\033[2m"; RED="\033[31m"; GRN="\033[32m"; YLW="\033[33m"
  BLU="\033[34m"; MAG="\033[35m"; CYN="\033[36m"; RST="\033[0m"
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYN=""; RST=""
fi

log()   { echo -e "${DIM}$(date +'%Y-%m-%dT%H:%M:%S%z')${RST}  $*"; }
info()  { echo -e "${GRN}$*${RST}"; }
warn()  { echo -e "${YLW}WARNING:${RST} $*"; }
err()   { echo -e "${RED}ERROR:${RST} $*" >&2; }

header() {
cat <<EOF
================================================================
Drosera Helper Script  ${BOLD}${VERSION}${RST}  (${TODAY})
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
  sudo -E bash $0 --auto --pk 0xYOUR_HEX_KEY
  sudo -E bash $0 --auto --pk-file /root/pk.txt --eth-amount 0.2
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash $0 --auto
EOF
}

# ------------- Utilities ----------------
ensure_root() {
  if $ROOT_REQUIRED && [ "${EUID:-0}" -ne 0 ]; then
    err "Please run as root (sudo -E bash $0 ...)"
    exit 1
  fi
}

mkdirs() {
  mkdir -p "$TRAP_DIR" "$OP_DIR" "$LOG_DIR" "$BIN_DIR_DRO"
}

# Normalize PK: accept with/without 0x, spaces/newlines; output 64-lower-hex without 0x.
normalize_pk() {
  local in="$1"
  local s="${in//[[:space:]]/}"
  s="${s#0x}"; s="${s#0X}"
  local lower="$(echo "$s" | tr 'A-F' 'a-f')"
  if [[ "${#lower}" -ne 64 || ! "$lower" =~ ^[0-9a-f]{64}$ ]]; then
    return 1
  fi
  echo -n "$lower"
}

detect_public_ip() {
  # Try the env override first
  if [ -n "$PUBLIC_IP_FLAG" ]; then
    echo -n "$PUBLIC_IP_FLAG"; return 0
  fi
  # Try known methods without failing the script if offline
  local ip=""
  ip="$(curl -fsSL --max-time 2 https://ipv4.icanhazip.com 2>/dev/null || true)"
  ip="${ip//$'\n'/}"
  if [[ -n "$ip" && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo -n "$ip"; return 0
  fi
  # Fallback to first non-loopback IPv4
  ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/ && $i != "127.0.0.1"){print $i; exit}}' || true)"
  ip="${ip//$'\n'/}"
  if [[ -n "$ip" ]]; then
    echo -n "$ip"; return 0
  fi
  echo -n "127.0.0.1"
}

# Export PATH for this session without sourcing .bashrc
export_paths() {
  export PATH="$BIN_DIR_DRO:$BIN_DIR_FOUND:$PATH"
}

confirm_ofc_pipe() { yes ofc | tr -d '\r'; }

retry() {
  local max="$1"; shift
  local delay="$1"; shift
  local n=1
  until "$@"; do
    if (( n >= max )); then return 1; fi
    sleep "$delay"
    n=$((n+1))
  done
}

# ------------- Package installation ----------------
install_base() {
  log "Updating apt & installing base packages..."
  {
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confold" || true
    apt-get install -y \
      ca-certificates curl gnupg lsb-release \
      build-essential pkg-config git jq unzip wget tar nano tmux \
      clang make lz4 htop \
      software-properties-common \
      autoconf automake m4 bsdmainutils \
      libssl-dev libgbm1 \
      libleveldb-dev libsnappy1v5 ncdu nvme-cli
  } >>"$LOG_DIR/apt.log" 2>&1 || true
}

install_docker() {
  log "Docker already installed. Upgrading if needed..."
  {
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
    systemctl enable docker || true
    systemctl start docker || true
  } >>"$LOG_DIR/docker.log" 2>&1 || true
}

install_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "Bun already installed."
  else
    log "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash >>"$LOG_DIR/bun.log" 2>&1 || true
    # Bun installer adjusts profile; we export PATH ourselves for current shell
    export BUN_INSTALL="${BUN_INSTALL:-$ROOT_HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
  fi
}

install_foundry() {
  if command -v forge >/dev/null 2>&1 && command -v cast >/dev/null 2>&1; then
    log "Foundry already installed; running foundryup..."
    export_paths
    foundryup >>"$LOG_DIR/foundry.log" 2>&1 || true
  else
    log "Installing Foundry..."
    # Do NOT source ~/.bashrc here; set PATH directly
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$LOG_DIR/foundry.log" 2>&1 || true
    export_paths
    foundryup >>"$LOG_DIR/foundry.log" 2>&1 || true
  fi
}

install_drosera_cli() {
  export_paths
  if command -v drosera >/dev/null 2>&1; then
    log "Drosera CLI present; running droseraup..."
  else
    log "Installing Drosera CLI via droseraup..."
  fi
  # Use the droseraup installer; tolerate network hiccups
  TMP_DA="$(mktemp)"
  if curl -fsSL https://raw.githubusercontent.com/drosera-network/droseraup/main/droseraup -o "$TMP_DA"; then
    chmod +x "$TMP_DA"
    "$TMP_DA" >>"$LOG_DIR/droseraup.log" 2>&1 || true
  else
    warn "Failed to download droseraup (network?). Skipping."
  fi
  export_paths
}

# ------------- Trap project ----------------
init_trap_project() {
  log "Initializing trap project at $TRAP_DIR ..."
  if [ ! -d "$TRAP_DIR/.git" ]; then
    rm -rf "$TRAP_DIR" && mkdir -p "$TRAP_DIR"
    git clone --depth 1 https://github.com/drosera-network/trap-foundry-template.git "$TRAP_DIR" >>"$LOG_DIR/trap_init.log" 2>&1 || true
    (cd "$TRAP_DIR" && bun install >>"$LOG_DIR/trap_init.log" 2>&1 || true)
  else
    log "Found existing repo in $TRAP_DIR; syncing deps..."
    (cd "$TRAP_DIR" && bun install >>"$LOG_DIR/trap_init.log" 2>&1 || true)
  fi
}

# ------------- Drosera Apply (non-interactive) ----------------
drosera_apply_noninteractive() {
  export_paths
  : >"$APPLY_LOG"
  info "Running: drosera apply (non-interactive)"
  (
    cd "$TRAP_DIR"
    # Auto confirm all prompts with "ofc"
    if confirm_ofc_pipe | drosera apply >>"$APPLY_LOG" 2>&1; then
      true
    else
      false
    fi
  )
}

# Parse trap config address from apply log
extract_trap_config_from_apply_log() {
  local addr
  # Try common patterns
  addr="$(grep -Eo 'trap_config: 0x[a-fA-F0-9]{40}' "$APPLY_LOG" | tail -n1 | awk '{print $2}' || true)"
  if [ -z "$addr" ]; then
    addr="$(grep -Eo 'Created Trap Config .*address: 0x[a-fA-F0-9]{40}' "$APPLY_LOG" | tail -n1 | grep -Eo '0x[a-fA-F0-9]{40}' || true)"
  fi
  echo -n "$addr"
}

# ------------- Bloomboost (non-interactive) ----------------
bloomboost_noninteractive() {
  export_paths
  local trap_config="$1"
  local amount="$2" # in ETH
  : >"$BOOST_LOG"
  info "Bloom Boosting trap..."

  # The 'drosera' CLI typically prompts for confirm; pipe ofc
  if confirm_ofc_pipe | drosera bloomboost --trap-config "$trap_config" --amount "$amount" >>"$BOOST_LOG" 2>&1; then
    true
  else
    false
  fi
}

# ------------- Compose generation ----------------
write_compose() {
  local rpc="${1:-$RPC_URL}"
  local rpcb="${2:-$RPC_URL_BACKUP}"
  local dro_addr="${3:-$DROSERA_ADDRESS_DEFAULT}"
  local ip="${4}"
  mkdir -p "$OP_DIR"

  # Generate docker-compose.yaml WITHOUT 'version:' and with multiaddr for P2P
  cat >"$COMPOSE_FILE" <<YAML
services:
  drosera-operator:
    image: ghcr.io/drosera-network/drosera-operator:v1.20.0
    container_name: drosera-operator
    network_mode: host
    environment:
      - DRO__DB_FILE_PATH=/data/drosera.db
      - DRO__DROSERA_ADDRESS=${dro_addr}
      - DRO__LISTEN_ADDRESS=0.0.0.0
      - DRO__DISABLE_DNR_CONFIRMATION=true
      - DRO__ETH__CHAIN_ID=${CHAIN_ID}
      - DRO__ETH__RPC_URL=${rpc}
      - DRO__ETH__BACKUP_RPC_URL=${rpcb}
      - DRO__ETH__PRIVATE_KEY=\${ETH_PRIVATE_KEY}
      - DRO__NETWORK__P2P_PORT=${P2P_PORT}
      - DRO__NETWORK__EXTERNAL_P2P_ADDRESS=/ip4/\${VPS_IP}/tcp/${P2P_PORT}
      - DRO__SERVER__PORT=${SERVER_PORT}
    volumes:
      - drosera_data:/data
    command: ["node"]
    restart: always

volumes:
  drosera_data:
YAML
}

write_envfile() {
  local pk_64="$1"   # 64 hex without 0x
  local ip="$2"
  cat >"$ENV_FILE" <<EOF
ETH_PRIVATE_KEY=${pk_64}
VPS_IP=${ip}
EOF
}

compose_up() {
  : >"$COMPOSE_LOG"
  (cd "$OP_DIR" && docker compose up -d) >>"$COMPOSE_LOG" 2>&1
  sleep 1
  docker ps | grep -q "drosera-operator" || {
    warn "Operator container not visible yet. See $COMPOSE_LOG"
  }
}

# ------------- Register & Opt-in ----------------
operator_register() {
  export_paths
  : >"$REGISTER_LOG"
  # drosera-operator binary inside the container supports subcommands
  if retry 5 3 docker exec drosera-operator ./drosera-operator register >>"$REGISTER_LOG" 2>&1; then
    info "Operator register: OK"
    return 0
  fi
  # Accept rate-limit as transient; surface log path
  warn "Register command failed; see $REGISTER_LOG"
  return 1
}

operator_optin() {
  export_paths
  local trap_config="$1"
  : >"$OPTIN_LOG"
  if docker exec drosera-operator ./drosera-operator opt-in "$trap_config" >>"$OPTIN_LOG" 2>&1; then
    info "Operator opt-in: OK"
    return 0
  fi
  if grep -qi "OperatorAlreadyUnderTrap" "$OPTIN_LOG"; then
    info "Operator already opted-in; continuing."
    return 0
  fi
  warn "Opt-in command failed; see $OPTIN_LOG"
  return 1
}

# ------------- Upgrade path ----------------
upgrade_drosera() {
  export_paths
  drosera upgrade >>"$LOG_DIR/upgrade.log" 2>&1 || true
  # Allow passing new RPC as flags; here we just print guidance
  info "Drosera upgraded (see $LOG_DIR/upgrade.log)."
}

# ------------- Claim cadet role ----------------
claim_cadet() {
  export_paths
  (cd "$TRAP_DIR" && confirm_ofc_pipe | drosera claim-cadet >>"$LOG_DIR/claim.log" 2>&1) || true
  info "Cadet role claim attempted (see $LOG_DIR/claim.log)."
}

# ------------- Menu actions ----------------
action_full_install_auto() {
  local pk_in="${PK_FLAG}"
  if [ -z "$pk_in" ] && [ -n "$PK_FILE_FLAG" ] && [ -f "$PK_FILE_FLAG" ]; then
    pk_in="$(cat "$PK_FILE_FLAG")"
  fi
  if [ -z "$pk_in" ] && [ -n "${DROSERA_PRIVATE_KEY:-}" ]; then
    pk_in="${DROSERA_PRIVATE_KEY}"
  fi
  if [ -z "$pk_in" ]; then
    read -r -p "Enter your EVM private key (64 hex, may start with 0x): " pk_in || true
  fi
  local norm_pk
  if ! norm_pk="$(normalize_pk "$pk_in")"; then
    err "Invalid private key. Must be 64 hex characters (with or without 0x)."
    exit 1
  fi

  local my_ip
  my_ip="$(detect_public_ip)"
  log "Using Public IP: $my_ip"

  export_paths
  install_base
  install_docker
  install_bun
  install_foundry
  install_drosera_cli
  init_trap_project

  # Show address for confirmation
  local addr=""
  if command -v cast >/dev/null 2>&1; then
    addr="$(cast wallet address --private-key "$norm_pk" 2>/dev/null || true)"
  fi
  if [ -n "$addr" ]; then
    echo "Your EVM address: $addr"
  fi

  # Apply trap config
  if drosera_apply_noninteractive; then
    info "Apply completed. (log: $APPLY_LOG)"
  else
    err "Apply failed. See $APPLY_LOG"
    # Still continue to compose; user may already have a trap config
  fi

  # Extract trap_config from log (if present)
  local trap_config_addr
  trap_config_addr="$(extract_trap_config_from_apply_log || true)"
  if [ -z "$trap_config_addr" ]; then
    warn "Could not parse trap_config from apply log. You may set it later for opt-in."
  else
    echo "trap_config: $trap_config_addr"
  fi

  # Bloomboost (optional if trap_config detected)
  if [ -n "$trap_config_addr" ]; then
    echo "Bloom Boosting trap..."
    echo
    echo "trap_config: $trap_config_addr"
    echo "eth_amount: $ETH_AMOUNT"
    if bloomboost_noninteractive "$trap_config_addr" "$ETH_AMOUNT"; then
      info "Bloomboost OK (log: $BOOST_LOG)"
    else
      warn "Bloomboost failed. See $BOOST_LOG"
    fi
  fi

  # Compose: write files and bring up
  write_compose "$RPC_URL" "$RPC_URL_BACKUP" "$DROSERA_ADDRESS_DEFAULT" "$my_ip"
  write_envfile "$norm_pk" "$my_ip"
  info "Syncing drosera-network at $OP_DIR ..."
  echo "Wrote ETH_PRIVATE_KEY=$(echo "$norm_pk" | sed 's/./*/g; s/.\{8\}$/&/')" to "$ENV_FILE"
  echo "Wrote VPS_IP=$my_ip to $ENV_FILE"
  compose_up
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

  # Register & Opt-in
  if ! $NO_REGISTER; then
    info "Registering Drosera Operator..."
    if ! operator_register; then
      warn "Register may have failed due to rate limit; you can retry via menu or dashboard."
    fi
  fi
  if [ -n "$trap_config_addr" ] && ! $NO_OPTIN; then
    info "Operator optin..."
    operator_optin "$trap_config_addr" || true
  fi

  echo "Done."
  read -r -p "Press Enter to return to menu..." _ || true
}

action_view_logs() {
  echo "==== Docker Compose logs (follow; Ctrl-C to exit) ===="
  (cd "$OP_DIR" && docker compose logs -f) || true
  read -r -p "Press Enter to return to menu..." _ || true
}

action_restart_stack() {
  echo "==== Restarting operator stack (compose down/up) ===="
  (cd "$OP_DIR" && docker compose down -v && docker compose up -d) | tee -a "$COMPOSE_LOG" || true
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  read -r -p "Press Enter to return to menu..." _ || true
}

action_upgrade_and_apply() {
  export_paths
  upgrade_drosera
  init_trap_project
  drosera_apply_noninteractive || warn "Apply failed. See $APPLY_LOG"
  read -r -p "Press Enter to return to menu..." _ || true
}

action_claim_cadet() {
  claim_cadet
  read -r -p "Press Enter to return to menu..." _ || true
}

# ------------- Flag parsing ----------------
print_help() {
cat <<EOF
Usage: sudo -E bash $0 [--auto] [--pk HEX|0xHEX] [--pk-file PATH] [--eth-amount N]
                       [--rpc URL] [--backup-rpc URL] [--public-ip IP]
                       [--no-register] [--no-optin]

Flags:
  --auto             Run full install + apply + bloomboost + compose + register + opt-in
  --pk               EVM private key (64 hex, may start with 0x)
  --pk-file          File containing the private key
  --eth-amount       ETH amount for bloomboost (default: ${ETH_AMOUNT})
  --rpc              Primary RPC URL (default: ${RPC_URL_DEFAULT})
  --backup-rpc       Backup RPC URL (default: ${RPC_URL_BACKUP_DEFAULT})
  --public-ip        Force external IP for P2P multiaddr
  --no-register      Skip operator register step
  --no-optin         Skip operator opt-in step
  -h, --help         Show this help and exit
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) AUTO=true; shift ;;
      --pk) PK_FLAG="${2:-}"; shift 2 ;;
      --pk-file) PK_FILE_FLAG="${2:-}"; shift 2 ;;
      --eth-amount) ETH_AMOUNT="${2:-$ETH_AMOUNT}"; shift 2 ;;
      --rpc) RPC_URL="${2:-$RPC_URL}"; shift 2 ;;
      --backup-rpc) RPC_URL_BACKUP="${2:-$RPC_URL_BACKUP}"; shift 2 ;;
      --public-ip) PUBLIC_IP_FLAG="${2:-}"; shift 2 ;;
      --no-register) NO_REGISTER=true; shift ;;
      --no-optin) NO_OPTIN=true; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) err "Unknown flag: $1"; print_help; exit 1 ;;
    esac
  done
}

# ------------- Menu ----------------
menu() {
  while true; do
    header
    cat <<'MNU'
Choose an option:
 1) Full install (AUTO-ready): Docker + Bun + Foundry + Drosera, init trap, apply, bloomboost, operator register & optin
 2) View operator logs (docker compose logs -f)
 3) Restart operator stack (compose down/up)
 4) Upgrade Drosera & set relay RPC, then apply
 5) Claim Cadet role (Trap.sol + apply)
 0) Exit
MNU
    read -r -p "Select (0-5): " choice || true
    case "${choice:-}" in
      1) action_full_install_auto ;;
      2) action_view_logs ;;
      3) action_restart_stack ;;
      4) action_upgrade_and_apply ;;
      5) action_claim_cadet ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid choice.";;
    esac
  done
}

# ------------- Main ----------------
main() {
  ensure_root
  mkdirs
  export_paths
  parse_flags "$@"

  if $AUTO; then
    action_full_install_auto
  else
    menu
  fi
}

main "$@"
