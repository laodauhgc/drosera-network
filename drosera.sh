#!/usr/bin/env bash
#
# drosera.sh — Best-practice installer & operator helper for Drosera
# Version: 1.0.1 

set -Eeuo pipefail
IFS=$'\n\t'

############################################
#                 CONFIG                    #
############################################

# --- Script metadata ---
SCRIPT_VERSION="1.0.1"
SCRIPT_DATE="2025-07-30"

# --- Flags / CLI options (global) ---
FLAGS_PK=""
FLAGS_PK_FILE=""
NON_INTERACTIVE=0
ASSUME_YES=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --pk HEX                  Provide EVM private key (with or without 0x)
  --pk-file PATH            Read EVM private key from file (first line used)
  -n, --non-interactive     Do not prompt for input (fail if missing inputs)
  -y, --yes                 Assume 'yes' to confirmations when possible
  -h, --help                Show this help and exit

You can also provide the key via environment variables:
  DROSERA_PRIVATE_KEY=0x...  or  PK=0x...
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pk)
        FLAGS_PK="${2:-}"; shift 2 || { echo "ERROR: --pk requires a value"; exit 1; } ;;
      --pk-file)
        FLAGS_PK_FILE="${2:-}"; shift 2 || { echo "ERROR: --pk-file requires a value"; exit 1; } ;;
      -n|--non-interactive)
        NON_INTERACTIVE=1; shift ;;
      -y|--yes)
        ASSUME_YES=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

# --- Paths & dirs ---
ROOT_DIR="/root"
TRAP_DIR="${ROOT_DIR}/my-drosera-trap"
NET_DIR="${ROOT_DIR}/drosera-network"
LOG_DIR="/var/log/drosera"
mkdir -p "${LOG_DIR}"

# --- Docker Compose wrapper: try v2 plugin first, then v1 binary ---
dc() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "ERROR: Docker Compose (v2 or v1) not found." >&2
    exit 1
  fi
}

# --- Chain & contract defaults (override by exporting env before running) ---
: "${DRO_CHAIN_ID:=560048}"
: "${DRO_ETH_RPC_URL:=https://0xrpc.io/hoodi}"
: "${DRO_ETH_RPC_URL_OPTIN:=https://ethereum-hoodi-rpc.publicnode.com}"
: "${DRO_DROSERA_ADDRESS:=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
: "${DRO_RESPONDER_CONTRACT:=0x183D78491555cb69B68d2354F7373cc2632508C7}"
: "${DRO_RELAY_RPC:=https://relay.hoodi.drosera.io}"
: "${DRO_NETWORK_REPO:=https://github.com/laodauhgc/drosera-network.git}"

# --- PATH management (add once) ---
ensure_path_once() {
  local line="$1"
  grep -qxF "$line" /root/.bashrc || echo "$line" >> /root/.bashrc
}
add_paths() {
  ensure_path_once 'export PATH=$PATH:/root/.bun/bin'
  ensure_path_once 'export PATH=$PATH:/root/.foundry/bin'
  ensure_path_once 'export PATH=$PATH:/root/.drosera/bin'
  export PATH="$PATH:/root/.bun/bin:/root/.foundry/bin:/root/.drosera/bin"
}

############################################
#               UTILITIES                   #
############################################

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

confirm() {
  local prompt="${1:-Are you sure?}"
  if [[ $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

trim_hex_key() {
  # Remove whitespace, newlines, carriage returns; strip 0x prefix
  local x="$1"
  x="${x//$'\r'/}"
  x="${x//$'\n'/}"
  # remove all spaces/tabs
  x="${x//[[:space:]]/}"
  x="${x#0x}"
  echo -n "$x"
}

prompt_private_key() {
  local pk raw
  # First attempt: silent input (hidden)
  if [[ -t 0 ]]; then
    read -r -s -p "Enter your EVM private key (64 hex, may start with 0x): " raw || true
    echo
    pk="$(trim_hex_key "$raw")"
    if [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "$pk"; return 0
    fi
    echo "Input seems invalid. Paste again (visible, will be trimmed):"
    read -r raw || true
    pk="$(trim_hex_key "$raw")"
    if [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "$pk"; return 0
    fi
  fi
  echo "ERROR: Invalid private key format. Provide via env (DROSERA_PRIVATE_KEY/PK), flags (--pk/--pk-file), or interactive TTY." >&2
  return 1
}

obtain_pk() {
  # Precedence: env DROSERA_PRIVATE_KEY -> env PK -> --pk -> --pk-file -> (stdin if non-tty) -> prompt
  local pk="${DROSERA_PRIVATE_KEY:-}"
  if [[ -z "$pk" ]]; then pk="${PK:-}"; fi
  if [[ -z "$pk" && -n "${FLAGS_PK:-}" ]]; then pk="$FLAGS_PK"; fi
  if [[ -z "$pk" && -n "${FLAGS_PK_FILE:-}" && -f "$FLAGS_PK_FILE" ]]; then
    # Use first non-empty line
    pk="$(grep -m1 -E '.+' "$FLAGS_PK_FILE" || true)"
  fi
  if [[ -z "$pk" && ! -t 0 ]]; then
    # Read from stdin (one line)
    read -r pk || true
  fi
  if [[ -z "$pk" ]]; then
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
      echo "ERROR: No private key provided in non-interactive mode." >&2
      return 1
    fi
    pk="$(prompt_private_key)" || return 1
  fi
  pk="$(trim_hex_key "$pk")"
  if [[ ! "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "ERROR: Provided private key is not 64 hex chars after normalization." >&2
    return 1
  fi
  echo -n "$pk"
}

validate_evm_address() {
  [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

get_evm_address_from_pk() {
  local pk="$(trim_hex_key "$1")"
  if ! command -v cast >/dev/null 2>&1; then
    echo "ERROR: 'cast' not found (Foundry not installed/loaded)." >&2
    return 1
  fi
  local out
  # Try without 0x
  if out="$(cast wallet address --private-key "$pk" 2>/dev/null)"; then
    echo "$out"; return 0
  fi
  # Try with 0x
  if out="$(cast wallet address --private-key "0x$pk" 2>/dev/null)"; then
    echo "$out"; return 0
  fi
  echo "ERROR: Unable to compute address from private key (tried with/without 0x). Check your key." >&2
  return 1
}

net_check() {
  echo "Checking network connectivity..."
  if curl -fsS --max-time 5 https://ifconfig.me >/dev/null 2>&1 || \
     curl -fsS --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
    echo "Network OK."
  else
    echo "WARNING: Network check failed. Continuing may fail." >&2
  fi
}

sys_check() {
  echo "System check:"
  local total_mem free_space cpu_cores
  total_mem=$(free -m | awk '/^Mem:/{print $2}')
  free_space=$(df -m / | awk 'NR==2{print $4}')
  cpu_cores=$(nproc)

  [[ "${total_mem:-0}" -lt 2048 ]] && echo "  - WARN: RAM < 2GB"
  [[ "${free_space:-0}" -lt 10240 ]] && echo "  - WARN: Disk free < 10GB"
  [[ "${cpu_cores:-0}" -lt 2 ]] && echo "  - WARN: CPU cores < 2"

  echo "System check done."
}

log() {
  local msg="$*"
  echo "$(date +'%Y-%m-%dT%H:%M:%S%z')  ${msg}" | tee -a "${LOG_DIR}/drosera.log"
}

tee_log() {
  local f="${1}"
  tee -a "${LOG_DIR}/${f}"
}

############################################
#           INSTALLATION STEPS              #
############################################

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y -o Dpkg::Options::="--force-confold"
  apt-get install -y \
    ca-certificates curl gnupg lsb-release software-properties-common \
    build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop \
    nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang \
    bsdmainutils ncdu unzip
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed. Upgrading if needed..."
  else
    log "Installing Docker Engine..."
  fi

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local CODENAME
  CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME}")"
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log "Installing legacy docker-compose (v1) as fallback..."
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

install_bun() {
  if command -v bun >/dev/null 2>&1; then
    log "Bun already installed."
    return 0
  fi
  log "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash
}

install_foundry() {
  if command -v forge >/dev/null 2>&1 && command -v cast >/dev/null 2>&1; then
    log "Foundry already installed; running foundryup..."
    foundryup || true
    return 0
  fi
  log "Installing Foundry..."
  curl -fsSL https://foundry.paradigm.xyz | bash
  if [[ -x /root/.foundry/bin/foundryup ]]; then
    /root/.foundry/bin/foundryup
  fi
}

install_drosera_cli() {
  if command -v drosera >/dev/null 2>&1; then
    log "Drosera CLI present; running droseraup..."
    droseraup || true
    return 0
  fi
  log "Installing Drosera CLI..."
  curl -fsSL https://app.drosera.io/install | bash
  if command -v droseraup >/dev/null 2>&1; then
    droseraup || true
  fi
}

post_install_env() {
  add_paths
  hash -r || true
  forge --version   || { echo "forge missing"; exit 1; }
  cast --version    || { echo "cast missing"; exit 1; }
  drosera --version || { echo "drosera missing"; exit 1; }
  docker --version  || { echo "docker missing"; exit 1; }
  if docker compose version >/dev/null 2>&1; then :; else docker-compose --version >/dev/null 2>&1 || true; fi
}

############################################
#            HIGH-LEVEL ACTIONS            #
############################################

init_trap_project() {
  log "Initializing trap project at ${TRAP_DIR} ..."
  mkdir -p "${TRAP_DIR}"
  cd "${TRAP_DIR}"

  git config --global user.email "user@example.com"
  git config --global user.name "DroseraUser"

  if [[ -d .git ]]; then
    log "Found existing repo in ${TRAP_DIR}; skipping forge init."
  else
    forge init -t drosera-network/trap-foundry-template 2>&1 | tee_log "forge_init.log"
  fi

  bun install 2>&1 | tee_log "bun_install.log" || { echo "bun install failed"; exit 1; }
  forge build   2>&1 | tee_log "forge_build.log" || { echo "forge build failed"; exit 1; }
}

safe_edit_drosera_toml_whitelist() {
  local toml="${TRAP_DIR}/drosera.toml"
  [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found."; exit 1; }

  local pk addr
  pk="$(obtain_pk)" || exit 1
  addr="$(get_evm_address_from_pk "$pk")" || exit 1
  echo "Your EVM address: ${addr}"

  cp -f "$toml" "${toml}.bak.$(date +%s)"

  awk -v addr="$addr" '
    BEGIN{intrap=0; done=0}
    /^\[traps\.[^]]+\]/ {intrap=1}
    /^\[/ && !/^\[traps\./ {intrap=0}
    {
      if (intrap && !done) {
        if ($0 ~ /^whitelist[[:space:]]*=/) {
          sub(/^whitelist[[:space:]]*=.*/, "whitelist = [\"" addr "\"]")
          done=1
        }
      }
      print
    }
    END{
      if (!done) {
        print "whitelist = [\"" addr "\"]"
      }
    }
  ' "$toml" > "${toml}.tmp" && mv "${toml}.tmp" "$toml"

  echo "Running: drosera apply (first time)"
  ( cd "${TRAP_DIR}" && \
    DROSERA_PRIVATE_KEY="$pk" bash -c 'echo "ofc" | drosera apply' 2>&1 | tee -a "${LOG_DIR}/apply.log" )

  local trap_address
  trap_address="$(grep -oE 'trapAddress: 0x[a-fA-F0-9]{40}' "${LOG_DIR}/apply.log" | awk '{print $2}' | tail -1 || true)"
  if [[ -z "${trap_address:-}" ]]; then
    read -r -p "Unable to detect trapAddress from logs. Enter it manually (0x...): " trap_address
    validate_evm_address "$trap_address" || { echo "Invalid trap address."; exit 1; }
  fi
  echo "Trap address: $trap_address"

  local eth_amount
  while :; do
    read -r -p "Enter ETH amount for bloomboost (e.g., 0.01): " eth_amount || true
    if [[ "$eth_amount" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      break
    fi
    echo "Invalid number. Use dot as decimal separator."
  done

  echo "Funding Hoodi via bloomboost..."
  ( DROSERA_PRIVATE_KEY="$pk" drosera bloomboost --trap-address "$trap_address" --eth-amount "$eth_amount" ) \
    2>&1 | tee -a "${LOG_DIR}/bloomboost.log"
}

setup_operator_stack() {
  log "Cloning drosera-network at ${NET_DIR} ..."
  cd "${ROOT_DIR}"
  if [[ -d "${NET_DIR}" ]]; then
    echo "Existing ${NET_DIR} found."
    if confirm "Reclone drosera-network (removes current folder)?"; then
      rm -rf "${NET_DIR}"
      git clone "${DRO_NETWORK_REPO}" "$(basename "${NET_DIR}")"
    fi
  else
    git clone "${DRO_NETWORK_REPO}" "$(basename "${NET_DIR}")"
  fi

  cd "${NET_DIR}"

  if [[ -f ".env.example" ]]; then
    cp .env.example .env
    chmod 600 .env
    echo ".env created from example."
  else
    echo "ERROR: .env.example not found in ${NET_DIR}." >&2
    exit 1
  fi

  local vps_ip
  vps_ip="$(curl -fsS ifconfig.me || curl -fsS ipinfo.io/ip || true)"
  if [[ -z "${vps_ip:-}" ]]; then
    read -r -p "Enter your public VPS IP: " vps_ip
  fi

  sed -i "s|^VPS_IP=.*|VPS_IP=\"${vps_ip}\"|" .env
  echo "Wrote VPS_IP=${vps_ip} to .env (ETH_PRIVATE_KEY left blank for security)."

  if [[ -f docker-compose.yaml ]]; then
    dc -f docker-compose.yaml config >/dev/null
    log "Pulling latest operator image..."
    docker pull ghcr.io/drosera-network/drosera-operator:latest 2>&1 | tee_log "docker_pull.log"
    log "Starting operator stack..."
    dc -f docker-compose.yaml up -d 2>&1 | tee_log "compose_up.log"
    dc -f docker-compose.yaml ps
  else
    echo "ERROR: docker-compose.yaml not found in ${NET_DIR}" >&2
    exit 1
  fi
}

register_and_optin_operator() {
  local pk addr
  pk="$(obtain_pk)" || exit 1
  addr="$(get_evm_address_from_pk "$pk")" || exit 1
  echo "Using EVM address: ${addr}"

  log "Registering Drosera Operator..."
  docker run --rm ghcr.io/drosera-network/drosera-operator:latest register \
    --eth-chain-id "${DRO_CHAIN_ID}" \
    --eth-rpc-url "${DRO_ETH_RPC_URL}" \
    --drosera-address "${DRO_DROSERA_ADDRESS}" \
    --eth-private-key "${pk}" \
    2>&1 | tee -a "${LOG_DIR}/operator_register.log" || {
      echo "WARNING: Register command failed; check logs."
    }

  local trap_address
  read -r -p "Enter trap address to opt-in (0x...): " trap_address
  validate_evm_address "$trap_address" || { echo "Invalid trap address."; exit 1; }

  log "Operator optin..."
  docker run --rm ghcr.io/drosera-network/drosera-operator:latest optin \
    --eth-rpc-url "${DRO_ETH_RPC_URL_OPTIN}" \
    --eth-private-key "${pk}" \
    --trap-config-address "${trap_address}" \
    2>&1 | tee -a "${LOG_DIR}/operator_optin.log" || {
      echo "WARNING: Optin command failed; you can try from Drosera dashboard."
    }
}

upgrade_and_fix_relay() {
  install_drosera_cli
  add_paths
  hash -r || true

  local toml="${TRAP_DIR}/drosera.toml"
  if [[ ! -f "$toml" ]]; then
    echo "ERROR: ${toml} not found. Run the install first (menu 1)." >&2
    exit 1
  fi

  cp -f "$toml" "${toml}.bak.$(date +%s)"
  if grep -q '^drosera_rpc[[:space:]]*=' "$toml"; then
    sed -i "s|^drosera_rpc[[:space:]]*=.*|drosera_rpc = \"${DRO_RELAY_RPC}\"|" "$toml"
  else
    printf "\n# Added by drosera.sh %s\n" "${SCRIPT_VERSION}" >> "$toml"
    echo "drosera_rpc = \"${DRO_RELAY_RPC}\"" >> "$toml"
  fi

  local pk
  pk="$(obtain_pk)" || exit 1
  echo "Applying drosera with relay RPC: ${DRO_RELAY_RPC}"
  ( cd "${TRAP_DIR}" && \
    DROSERA_PRIVATE_KEY="$pk" bash -c 'sleep 20; echo "ofc" | drosera apply' 2>&1 | tee -a "${LOG_DIR}/apply.log" )
}

claim_cadet_role() {
  add_paths
  hash -r || true

  local owner_addr discord_name pk evm_from_pk
  while :; do
    read -r -p "Enter your EVM address (0x...): " owner_addr
    validate_evm_address "$owner_addr" && break || echo "Invalid EVM address."
  done

  if [[ ! -d "${TRAP_DIR}/src" ]]; then
    echo "ERROR: ${TRAP_DIR}/src not found. Run install first (menu 1)." >&2
    exit 1
  fi

  while :; do
    read -r -p "Enter your Discord username (e.g., user#1234): " discord_name
    [[ -n "${discord_name}" ]] && break || echo "Discord name must not be empty."
  done

  cat > "${TRAP_DIR}/src/Trap.sol" <<EOF
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

interface IMockResponse {
    function isActive() external view returns (bool);
}

contract Trap is ITrap {
    address public constant RESPONSE_CONTRACT = ${DRO_RESPONDER_CONTRACT};
    string constant discordName = "${discord_name}";

    function collect() external view returns (bytes memory) {
        bool active = IMockResponse(RESPONSE_CONTRACT).isActive();
        return abi.encode(active, discordName);
    }

    function shouldRespond(bytes[] calldata data) external pure returns (bool, bytes memory) {
        (bool active, string memory name) = abi.decode(data[0], (bool, string));
        if (!active || bytes(name).length == 0) {
            return (false, bytes(""));
        }
        return (true, abi.encode(name));
    }
}
EOF

  echo "Updated ${TRAP_DIR}/src/Trap.sol with your Discord name."

  local toml="${TRAP_DIR}/drosera.toml"
  [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found."; exit 1; }
  cp -f "$toml" "${toml}.bak.$(date +%s)"

  if grep -q '^path[[:space:]]*=' "$toml"; then
    sed -i 's|^path[[:space:]]*=.*|path = "out/Trap.sol/Trap.json"|' "$toml"
  else
    echo 'path = "out/Trap.sol/Trap.json"' >> "$toml"
  fi
  if grep -q '^response_contract[[:space:]]*=' "$toml"; then
    sed -i "s|^response_contract[[:space:]]*=.*|response_contract = \"${DRO_RESPONDER_CONTRACT}\"|" "$toml"
  else
    echo "response_contract = \"${DRO_RESPONDER_CONTRACT}\"" >> "$toml"
  fi
  if grep -q '^response_function[[:space:]]*=' "$toml"; then
    sed -i 's|^response_function[[:space:]]*=.*|response_function = "respondWithDiscordName(string)"|' "$toml"
  else
    echo 'response_function = "respondWithDiscordName(string)"' >> "$toml"
  fi

  ( cd "${TRAP_DIR}" && forge build ) 2>&1 | tee -a "${LOG_DIR}/forge_build.log"

  pk="$(obtain_pk)" || exit 1
  evm_from_pk="$(get_evm_address_from_pk "$pk")"
  echo "PK-derived address: ${evm_from_pk}"
  if [[ "${evm_from_pk,,}" != "${owner_addr,,}" ]]; then
    echo "ERROR: Provided EVM address does not match the private key address."
    return 1
  fi

  ( cd "${TRAP_DIR}" && \
    DROSERA_PRIVATE_KEY="$pk" bash -c 'echo "ofc" | drosera apply' ) \
    2>&1 | tee -a "${LOG_DIR}/apply.log"

  if [[ -f "${NET_DIR}/docker-compose.yaml" ]]; then
    ( cd "${NET_DIR}" && dc up -d )
  else
    echo "NOTE: ${NET_DIR}/docker-compose.yaml not found; skipping compose up."
  fi

  echo "Now follow Discord verification steps on Drosera server."
  echo "You can optionally check Responder status:"
  echo "cast call ${DRO_RESPONDER_CONTRACT} \"isResponder(address)(bool)\" ${owner_addr} --rpc-url https://ethereum-holesky-rpc.publicnode.com"

  if command -v cast >/dev/null 2>&1; then
    echo "Fetching discord names (best effort)..."
    cast call "${DRO_RESPONDER_CONTRACT}" "getDiscordNamesBatch(uint256,uint256)(string[])" 0 2000 \
      --rpc-url https://ethereum-holesky-rpc.publicnode.com/ 2>/dev/null || true
  fi
}

view_logs() {
  echo "==== Docker Compose logs (follow; Ctrl-C to exit) ===="
  if [[ -f "${NET_DIR}/docker-compose.yaml" ]]; then
    ( cd "${NET_DIR}" && dc logs -f --tail=200 )
  else
    echo "Compose file not found at ${NET_DIR}/docker-compose.yaml"
  fi
}

restart_operators() {
  if [[ ! -f "${NET_DIR}/docker-compose.yaml" ]]; then
    echo "ERROR: docker-compose.yaml not found in ${NET_DIR}." >&2
    exit 1
  fi

  ( cd "${NET_DIR}" && dc down ) 2>&1 | tee -a "${LOG_DIR}/compose_down.log"
  ( cd "${NET_DIR}" && dc up -d ) 2>&1 | tee -a "${LOG_DIR}/compose_up.log"
  ( cd "${NET_DIR}" && dc logs --no-color ) > "${LOG_DIR}/compose_full.log" 2>&1 || true
  echo "Restart complete. Logs at ${LOG_DIR}/compose_full.log"
}

############################################
#                  MENU                     #
############################################

print_header() {
  clear || true
  cat <<EOH
================================================================
Drosera Helper Script  v${SCRIPT_VERSION}  (${SCRIPT_DATE})
================================================================
This script will help you install, configure, and operate Drosera.
- Works best on Ubuntu (LTS). Run as root.
- Secrets can be provided interactively, via env, or via flags.
- Override defaults by exporting env vars before running.

Base directories:
- Trap project: ${TRAP_DIR}
- Operator repo: ${NET_DIR}
- Logs: ${LOG_DIR}

You may run with flags, e.g.:
  sudo -E bash $0 --pk 0xYOUR_HEX_KEY
  sudo -E bash $0 --pk-file /root/pk.txt
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash $0

EOH
}

menu() {
  require_root
  add_paths
  net_check
  sys_check

  while :; do
    print_header
    echo "Choose an option:"
    echo " 1) Full install: Docker + Bun + Foundry + Drosera, init trap, apply"
    echo " 2) View operator logs (docker compose logs -f)"
    echo " 3) Restart operator stack (compose down/up)"
    echo " 4) Upgrade Drosera & set relay RPC, then apply"
    echo " 5) Claim Cadet role (Trap.sol + apply)"
    echo " 0) Exit"
    read -r -p "Select (0-5): " choice || true
    case "${choice:-}" in
      1)
        install_deps
        install_docker
        install_bun
        install_foundry
        install_drosera_cli
        post_install_env
        init_trap_project
        safe_edit_drosera_toml_whitelist
        setup_operator_stack
        register_and_optin_operator
        read -r -p "Press Enter to return to menu..." _ ;;
      2)
        view_logs
        read -r -p "Press Enter to return to menu..." _ ;;
      3)
        restart_operators
        read -r -p "Press Enter to return to menu..." _ ;;
      4)
        upgrade_and_fix_relay
        read -r -p "Press Enter to return to menu..." _ ;;
      5)
        claim_cadet_role
        read -r -p "Press Enter to return to menu..." _ ;;
      0)
        echo "Bye."
        exit 0 ;;
      *)
        echo "Invalid choice. Try again."
        sleep 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
  print_header
  menu
}

main "$@"
