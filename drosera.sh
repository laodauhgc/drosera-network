#!/usr/bin/env bash
#
# drosera.sh — Best-practice installer & operator helper for Drosera
# Version: 1.1.2
#
# Changelog
# - v1.1.2: Fix drosera apply dry-run failure by NORMALIZING drosera.toml to HelloWorld defaults in Menu 1:
#           path = out/HelloWorldTrap.sol/HelloWorldTrap.json
#           response_function = "helloworld(string)"
#           response_contract = $DRO_RESPONDER_CONTRACT (kept from defaults)
#           Also removes 'version:' key from docker-compose.yaml on first compose up to silence deprecation warning.
# - v1.1.1: AUTO mode writes ETH_PRIVATE_KEY (normalized 64-hex, no 0x) to /root/drosera-network/.env,
#           to fix docker operator crash "Failed to parse private key (odd number of digits)".
# - v1.1.0: Menu 1 full-auto; new flags --auto, --eth-amount, --trap-address; auto confirms.
# - v1.0.3: Fix bloomboost confirm via piping "ofc"; force UTF-8 locale to prevent Rust stdin UTF-8 panic.
# - v1.0.2: Robust trap address parsing & zero-address guard.
# - v1.0.1: Flexible PK input; tries non-0x then 0x.
# - v1.0.0: Initial refactor.
#
set -Eeuo pipefail
IFS=$'\n\t'
# Ensure UTF-8 locale for Rust CLIs reading stdin
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

############################################
#                 CONFIG                    #
############################################

SCRIPT_VERSION="1.1.2"
SCRIPT_DATE="2025-07-30"

# --- Flags / CLI options ---
FLAGS_PK=""
FLAGS_PK_FILE=""
FLAGS_TRAP_ADDRESS=""
FLAGS_ETH_AMOUNT=""
NON_INTERACTIVE=0
ASSUME_YES=0
AUTO_MODE=0

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --pk HEX                  Provide EVM private key (with or without 0x)
  --pk-file PATH            Read EVM private key from file (first line used)
  --eth-amount N.N          Amount of ETH to fund via bloomboost (default: 0.1)
  --trap-address 0xADDR     Trap config address to use (optional; auto if not given)
  -a, --auto                Fully automatic for Menu 1 (no prompts)
  -n, --non-interactive     Do not prompt for input (fail if missing inputs)
  -y, --yes                 Assume 'yes' to confirmations when possible
  -h, --help                Show this help and exit

You can also provide the key via environment variables:
  DROSERA_PRIVATE_KEY=0x...  or  PK=0x...
You can override ETH amount via:
  DROSERA_ETH_AMOUNT=0.2
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pk) FLAGS_PK="${2:-}"; shift 2 || { echo "ERROR: --pk requires a value"; exit 1; } ;;
      --pk-file) FLAGS_PK_FILE="${2:-}"; shift 2 || { echo "ERROR: --pk-file requires a value"; exit 1; } ;;
      --trap-address) FLAGS_TRAP_ADDRESS="${2:-}"; shift 2 || { echo "ERROR: --trap-address requires a value"; exit 1; } ;;
      --eth-amount) FLAGS_ETH_AMOUNT="${2:-}"; shift 2 || { echo "ERROR: --eth-amount requires a value"; exit 1; } ;;
      -a|--auto) AUTO_MODE=1; shift ;;
      -n|--non-interactive) NON_INTERACTIVE=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

# --- Paths & dirs ---
ROOT_DIR="/root"
TRAP_DIR="${ROOT_DIR}/my-drosera-trap"
NET_DIR="${ROOT_DIR}/drosera-network"
ENV_FILE="${NET_DIR}/.env"
COMPOSE_FILE="${NET_DIR}/docker-compose.yaml"
LOG_DIR="/var/log/drosera"
mkdir -p "${LOG_DIR}"

# --- Docker Compose wrapper ---
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

# --- Chain & contract defaults ---
: "${DRO_CHAIN_ID:=560048}"
: "${DRO_ETH_RPC_URL:=https://0xrpc.io/hoodi}"
: "${DRO_ETH_RPC_URL_OPTIN:=https://ethereum-hoodi-rpc.publicnode.com}"
: "${DRO_DROSERA_ADDRESS:=0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
: "${DRO_RESPONDER_CONTRACT:=0x183D78491555cb69B68d2354F7373cc2632508C7}"
: "${DRO_RELAY_RPC:=https://relay.hoodi.drosera.io}"
: "${DRO_NETWORK_REPO:=https://github.com/laodauhgc/drosera-network.git}"

# --- Defaults for automation ---
DEFAULT_ETH_AMOUNT="${DROSERA_ETH_AMOUNT:-0.1}"

# --- PATH management ---
ensure_path_once() { local line="$1"; grep -qxF "$line" /root/.bashrc || echo "$line" >> /root/.bashrc; }
add_paths() {
  ensure_path_once 'export PATH=$PATH:/root/.bun/bin'
  ensure_path_once 'export PATH=$PATH:/root/.foundry/bin'
  ensure_path_once 'export PATH=$PATH:/root/.drosera/bin'
  export PATH="$PATH:/root/.bun/bin:/root/.foundry/bin:/root/.drosera/bin"
}

############################################
#               UTILITIES                   #
############################################

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then echo "Please run as root (sudo)." >&2; exit 1; fi; }
confirm() { local prompt="${1:-Are you sure?}"; [[ $ASSUME_YES -eq 1 ]] && return 0; read -r -p "${prompt} [y/N]: " ans || true; [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; }

trim_hex_key() {
  local x="$1"
  x="${x//$'\r'/}"        # strip CR
  x="${x//$'\n'/}"        # strip LF
  x="${x//[[:space:]]/}"  # strip spaces/tabs
  x="${x#0x}"             # drop 0x if present
  echo -n "$x"
}

mask_pk() {
  local x="$1"; local n=${#x}
  if (( n >= 12 )); then
    echo "${x:0:6}******${x:n-6:6}"
  else
    echo "******"
  fi
}

prompt_private_key() {
  local pk raw
  if [[ -t 0 ]]; then
    read -r -s -p "Enter your EVM private key (64 hex, 0x optional): " raw || true; echo
    pk="$(trim_hex_key "$raw")"
    if [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then echo "$pk"; return 0; fi
    echo "Input looks invalid. Paste again (visible, will be trimmed):"
    read -r raw || true
    pk="$(trim_hex_key "$raw")"
    if [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then echo "$pk"; return 0; fi
  fi
  echo "ERROR: Invalid private key. Provide via env (DROSERA_PRIVATE_KEY/PK), flags (--pk/--pk-file), or interactive TTY." >&2
  return 1
}

obtain_pk() {
  local pk="${DROSERA_PRIVATE_KEY:-${PK:-}}"
  if [[ -z "$pk" && -n "${FLAGS_PK:-}" ]]; then pk="$FLAGS_PK"; fi
  if [[ -z "$pk" && -n "${FLAGS_PK_FILE:-}" && -f "$FLAGS_PK_FILE" ]]; then pk="$(grep -m1 -E '.+' "$FLAGS_PK_FILE" || true)"; fi
  if [[ -z "$pk" && ! -t 0 ]]; then read -r pk || true; fi
  if [[ -z "$pk" ]]; then
    [[ $NON_INTERACTIVE -eq 1 || $AUTO_MODE -eq 1 ]] && { echo "ERROR: No private key provided in auto/non-interactive mode." >&2; return 1; }
    pk="$(prompt_private_key)" || return 1
  fi
  pk="$(trim_hex_key "$pk")"
  [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "ERROR: Provided private key is not 64 hex chars after normalization." >&2; return 1; }
  echo -n "$pk"
}

validate_evm_address() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_zero_address() { [[ "${1,,}" == "0x0000000000000000000000000000000000000000" ]]; }

get_evm_address_from_pk() {
  local pk="$(trim_hex_key "$1")"
  command -v cast >/dev/null 2>&1 || { echo "ERROR: 'cast' not found." >&2; return 1; }
  local out
  # prefer NON-0x first
  if out="$(cast wallet address --private-key "$pk" 2>/dev/null)"; then echo "$out"; return 0; fi
  # fallback: with 0x
  if out="$(cast wallet address --private-key "0x$pk" 2>/dev/null)"; then echo "$out"; return 0; fi
  echo "ERROR: Unable to compute address from private key (tried non-0x and 0x)." >&2
  return 1
}

net_check() {
  echo "Checking network connectivity..."
  if curl -fsS --max-time 5 https://ifconfig.me >/dev/null 2>&1 || curl -fsS --max-time 5 https://api.ipify.org >/dev/null 2>&1; then
    echo "Network OK."
  else
    echo "WARNING: Network check failed." >&2
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

log() { echo "$(date +'%Y-%m-%dT%H:%M:%S%z')  $*" | tee -a "${LOG_DIR}/drosera.log"; }
tee_log() { local f="${1}"; tee -a "${LOG_DIR}/${f}"; }

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
  if command -v docker >/dev/null 2>&1; then log "Docker already installed. Upgrading if needed..."; else log "Installing Docker Engine..."; fi
  install -m 0755 -d /etc/apt/keyrings
  [[ -f /etc/apt/keyrings/docker.gpg ]] || { curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; chmod a+r /etc/apt/keyrings/docker.gpg; }
  local CODENAME; CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker; systemctl start docker
  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    log "Installing legacy docker-compose (v1) as fallback..."
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

install_bun() { command -v bun >/dev/null 2>&1 && { log "Bun already installed."; return 0; }; log "Installing Bun..."; curl -fsSL https://bun.sh/install | bash; }
install_foundry() {
  if command -v forge >/dev/null 2>&1 && command -v cast >/dev/null 2>&1; then log "Foundry already installed; running foundryup..."; foundryup || true; return 0; fi
  log "Installing Foundry..."; curl -fsSL https://foundry.paradigm.xyz | bash; [[ -x /root/.foundry/bin/foundryup ]] && /root/.foundry/bin/foundryup
}
install_drosera_cli() {
  if command -v drosera >/dev/null 2>&1; then log "Drosera CLI present; running droseraup..."; droseraup || true; return 0; fi
  log "Installing Drosera CLI..."; curl -fsSL https://app.drosera.io/install | bash; command -v droseraup >/dev/null 2>&1 && droseraup || true
}
post_install_env() {
  add_paths; hash -r || true
  forge --version || { echo "forge missing"; exit 1; }
  cast --version || { echo "cast missing"; exit 1; }
  drosera --version || { echo "drosera missing"; exit 1; }
  docker --version || { echo "docker missing"; exit 1; }
  if docker compose version >/dev/null 2>&1; then :; else docker-compose --version >/dev/null 2>&1 || true; fi
}

############################################
#       NORMALIZE drosera.toml (HelloWorld) #
############################################

normalize_drosera_toml_helloworld() {
  local toml="${TRAP_DIR}/drosera.toml"
  [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found."; exit 1; }
  cp -f "$toml" "${toml}.bak.$(date +%s)"

  # path => HelloWorldTrap artifact
  if grep -q '^path[[:space:]]*=' "$toml"; then
    sed -i 's|^path[[:space:]]*=.*|path = "out/HelloWorldTrap.sol/HelloWorldTrap.json"|' "$toml"
  else
    echo 'path = "out/HelloWorldTrap.sol/HelloWorldTrap.json"' >> "$toml"
  fi

  # response_contract => default responder
  if grep -q '^response_contract[[:space:]]*=' "$toml"; then
    sed -i "s|^response_contract[[:space:]]*=.*|response_contract = \"${DRO_RESPONDER_CONTRACT}\"|" "$toml"
  else
    echo "response_contract = \"${DRO_RESPONDER_CONTRACT}\"" >> "$toml"
  fi

  # response_function => helloworld(string)
  if grep -q '^response_function[[:space:]]*=' "$toml"; then
    sed -i 's|^response_function[[:space:]]*=.*|response_function = "helloworld(string)"|' "$toml"
  else
    echo 'response_function = "helloworld(string)"' >> "$toml"
  fi
}

############################################
#            HELPERS: TRAP ADDRESS          #
############################################

validate_evm_address() { [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_zero_address() { [[ "${1,,}" == "0x0000000000000000000000000000000000000000" ]]; }

extract_trap_address_from_apply_log() {
  local log="${LOG_DIR}/apply.log"
  [[ -s "$log" ]] || return 1

  local addr
  addr="$(awk '/Created Trap Config/{flag=1} flag && /- address: 0x[0-9a-fA-F]{40}/{print $3}' "$log" | tail -1 || true)"
  if validate_evm_address "$addr" && ! is_zero_address "$addr"; then
    echo "$addr"; return 0
  fi

  addr="$(grep -oE '- address: 0x[a-fA-F0-9]{40}' "$log" | awk '{print $3}' | tail -1 || true)"
  if validate_evm_address "$addr" && ! is_zero_address "$addr"; then
    echo "$addr"; return 0
  fi

  addr="$(grep -oE 'trapAddress: 0x[a-fA-F0-9]{40}' "$log" | awk '{print $2}' | awk 'tolower($0)!="0x0000000000000000000000000000000000000000"' | tail -1 || true)"
  if validate_evm_address "$addr" && ! is_zero_address "$addr"; then
    echo "$addr"; return 0
  fi

  return 1
}

############################################
#            HIGH-LEVEL ACTIONS            #
############################################

init_trap_project() {
  log "Initializing trap project at ${TRAP_DIR} ..."
  mkdir -p "${TRAP_DIR}"; cd "${TRAP_DIR}"
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

safe_edit_drosera_toml_whitelist_and_normalize() {
  local toml="${TRAP_DIR}/drosera.toml"; [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found."; exit 1; }

  # Always normalize to HelloWorld defaults for Menu 1 to avoid mismatch from prior Cadet edits
  normalize_drosera_toml_helloworld

  local pk addr; pk="$(obtain_pk)" || exit 1; addr="$(get_evm_address_from_pk "$pk")" || exit 1; echo "Your EVM address: ${addr}"
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
    END{ if (!done) print "whitelist = [\"" addr "\"]" }
  ' "$toml" > "${toml}.tmp" && mv "${toml}.tmp" "$toml"

  echo "Running: drosera apply (first time)"
  ( cd "${TRAP_DIR}" && DROSERA_PRIVATE_KEY="$pk" bash -c 'echo "ofc" | drosera apply' ) 2>&1 | tee -a "${LOG_DIR}/apply.log"

  # Determine trap address (flag > log)
  local trap_address="${FLAGS_TRAP_ADDRESS:-}"
  if [[ -z "$trap_address" ]]; then trap_address="$(extract_trap_address_from_apply_log || true)"; fi

  if ! validate_evm_address "$trap_address" || is_zero_address "$trap_address"; then
    if [[ $AUTO_MODE -eq 1 ]]; then
      echo "ERROR: Could not auto-detect trap address from logs in --auto mode. Provide --trap-address 0x... and retry." >&2
      exit 1
    fi
    echo "Detected trap address is missing or zero."
    read -r -p "Enter trap address manually (0x...): " trap_address
    validate_evm_address "$trap_address" && ! is_zero_address "$trap_address" || { echo "Invalid trap address."; exit 1; }
  fi

  echo "Trap address: $trap_address"

  local eth_amount
  if [[ -n "${FLAGS_ETH_AMOUNT:-}" ]]; then
    eth_amount="${FLAGS_ETH_AMOUNT}"
  else
    eth_amount="${DEFAULT_ETH_AMOUNT}"
  fi

  if [[ $AUTO_MODE -ne 1 ]]; then
    read -r -p "Enter ETH amount for bloomboost (default ${eth_amount}): " _in || true
    eth_amount="${_in:-$eth_amount}"
  fi

  if ! [[ "$eth_amount" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: Invalid ETH amount: ${eth_amount}"; exit 1;
  fi

  echo "Bloom Boosting trap..."
  echo "trap_config: ${trap_address}"
  echo "eth_amount: ${eth_amount}"
  ( DROSERA_PRIVATE_KEY="$pk" bash -c 'echo "ofc" | drosera bloomboost --trap-address "'"$trap_address"'" --eth-amount "'"$eth_amount"'"' ) 2>&1 | tee -a "${LOG_DIR}/bloomboost.log"

  # Export PK for next steps in this shell
  export DROSERA_PK_CACHE="$pk"
}

setup_operator_stack() {
  log "Syncing drosera-network at ${NET_DIR} ..."
  cd "${ROOT_DIR}"
  if [[ -d "${NET_DIR}/.git" ]]; then
    (cd "${NET_DIR}" && git fetch --all -q && git pull --ff-only -q) || echo "WARN: git pull failed; continuing with existing checkout."
  elif [[ -d "${NET_DIR}" ]]; then
    echo "WARN: ${NET_DIR} exists but is not a git repo. Using as-is."
  else
    git clone "${DRO_NETWORK_REPO}" "$(basename "${NET_DIR}")"
  fi
  cd "${NET_DIR}"
  if [[ -f ".env.example" && ! -f ".env" ]]; then
    cp .env.example .env; chmod 600 .env; echo ".env created from example."
  fi

  # Fill VPS_IP if empty
  if ! grep -q '^VPS_IP=' "${ENV_FILE}" || [[ -z "$(grep -E '^VPS_IP=' "${ENV_FILE}" | cut -d= -f2-)" ]]; then
    local vps_ip; vps_ip="$(curl -fsS ifconfig.me || curl -fsS ipinfo.io/ip || true)"
    [[ -n "${vps_ip:-}" ]] && sed -i "s|^VPS_IP=.*|VPS_IP=${vps_ip}|" "${ENV_FILE}" || true
  fi

  # Write ETH_PRIVATE_KEY in AUTO (and when a key is available) — normalized w/o 0x
  local pk="${DROSERA_PK_CACHE:-}"
  if [[ -z "$pk" ]]; then pk="$(obtain_pk || true)"; fi
  if [[ -n "$pk" ]]; then
    local norm="$(trim_hex_key "$pk")"
    if [[ "$norm" =~ ^[0-9a-fA-F]{64}$ ]]; then
      if grep -q '^ETH_PRIVATE_KEY=' "${ENV_FILE}"; then
        sed -i "s|^ETH_PRIVATE_KEY=.*|ETH_PRIVATE_KEY=${norm}|" "${ENV_FILE}"
      else
        echo "ETH_PRIVATE_KEY=${norm}" >> "${ENV_FILE}"
      fi
      echo "Wrote ETH_PRIVATE_KEY=$(mask_pk "$norm") to ${ENV_FILE}"
    else
      echo "WARNING: Normalized PK is invalid; NOT writing ETH_PRIVATE_KEY to ${ENV_FILE}."
    fi
  else
    echo "WARNING: No PK available to write ETH_PRIVATE_KEY to ${ENV_FILE}."
  fi

  [[ -f "${COMPOSE_FILE}" ]] || { echo "ERROR: docker-compose.yaml not found in ${NET_DIR}" >&2; exit 1; }

  # Remove obsolete 'version:' key once to avoid warning
  if grep -qE '^\s*version\s*:' "${COMPOSE_FILE}"; then
    sed -i '/^\s*version\s*:/d' "${COMPOSE_FILE}"
  fi

  dc -f "${COMPOSE_FILE}" config >/dev/null
  log "Pulling latest operator image..."; docker pull ghcr.io/drosera-network/drosera-operator:latest 2>&1 | tee_log "docker_pull.log"

  # Restart stack cleanly (avoid backoff loops holding bad env)
  log "Restarting operator stack..."
  dc -f "${COMPOSE_FILE}" down -v 2>&1 | tee_log "compose_down.log" || true
  dc -f "${COMPOSE_FILE}" up -d 2>&1 | tee_log "compose_up.log"
  dc -f "${COMPOSE_FILE}" ps
}

register_and_optin_operator() {
  local pk addr trap_address
  pk="${DROSERA_PK_CACHE:-}"
  if [[ -z "$pk" ]]; then pk="$(obtain_pk)" || exit 1; fi
  addr="$(get_evm_address_from_pk "$pk")" || exit 1
  echo "Using EVM address: ${addr}"
  log "Registering Drosera Operator..."
  docker run --rm ghcr.io/drosera-network/drosera-operator:latest register \
    --eth-chain-id "${DRO_CHAIN_ID}" \
    --eth-rpc-url "${DRO_ETH_RPC_URL}" \
    --drosera-address "${DRO_DROSERA_ADDRESS}" \
    --eth-private-key "${pk}" \
    2>&1 | tee -a "${LOG_DIR}/operator_register.log" || echo "WARNING: Register command failed; check logs."

  # trap address: flag > logs > (prompt if not auto)
  trap_address="${FLAGS_TRAP_ADDRESS:-}"
  if [[ -z "$trap_address" ]]; then trap_address="$(extract_trap_address_from_apply_log || true)"; fi

  if ! validate_evm_address "$trap_address" || is_zero_address "$trap_address"; then
    if [[ $AUTO_MODE -eq 1 ]]; then
      echo "ERROR: Could not resolve trap address for opt-in in --auto mode. Provide --trap-address 0x... and retry." >&2
      exit 1
    fi
    read -r -p "Enter trap address to opt-in (0x...): " trap_address
  fi

  validate_evm_address "$trap_address" && ! is_zero_address "$trap_address" || { echo "Invalid trap address."; exit 1; }

  log "Operator optin..."
  docker run --rm ghcr.io/drosera-network/drosera-operator:latest optin \
    --eth-rpc-url "${DRO_ETH_RPC_URL_OPTIN}" \
    --eth-private-key "${pk}" \
    --trap-config-address "${trap_address}" \
    2>&1 | tee -a "${LOG_DIR}/operator_optin.log" || echo "WARNING: Optin command failed; you can try from Drosera dashboard."
}

upgrade_and_fix_relay() {
  install_drosera_cli; add_paths; hash -r || true
  local toml="${TRAP_DIR}/drosera.toml"; [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found. Run the install first (menu 1)." >&2; exit 1; }
  cp -f "$toml" "${toml}.bak.$(date +%s)"
  if grep -q '^drosera_rpc[[:space:]]*=' "$toml"; then sed -i "s|^drosera_rpc[[:space:]]*=.*|drosera_rpc = \"${DRO_RELAY_RPC}\"|" "$toml"; else printf "\n# Added by drosera.sh %s\n" "${SCRIPT_VERSION}" >> "$toml"; echo "drosera_rpc = \"${DRO_RELAY_RPC}\"" >> "$toml"; fi
  local pk; pk="$(obtain_pk)" || exit 1
  echo "Applying drosera with relay RPC: ${DRO_RELAY_RPC}"
  ( cd "${TRAP_DIR}" && DROSERA_PRIVATE_KEY="$pk" bash -c 'sleep 20; echo "ofc" | drosera apply' ) 2>&1 | tee -a "${LOG_DIR}/apply.log"
}

claim_cadet_role() {
  add_paths; hash -r || true
  local owner_addr discord_name pk evm_from_pk
  while :; do read -r -p "Enter your EVM address (0x...): " owner_addr; validate_evm_address "$owner_addr" && break || echo "Invalid EVM address."; done
  [[ -d "${TRAP_DIR}/src" ]] || { echo "ERROR: ${TRAP_DIR}/src not found. Run install first (menu 1)." >&2; exit 1; }
  while :; do read -r -p "Enter your Discord username (e.g., user#1234): " discord_name; [[ -n "${discord_name}" ]] && break || echo "Discord name must not be empty."; done
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
  local toml="${TRAP_DIR}/drosera.toml"; [[ -f "$toml" ]] || { echo "ERROR: ${toml} not found."; exit 1; }
  cp -f "$toml" "${toml}.bak.$(date +%s)"
  grep -q '^path[[:space:]]*=' "$toml" && sed -i 's|^path[[:space:]]*=.*|path = "out/Trap.sol/Trap.json"|' "$toml" || echo 'path = "out/Trap.sol/Trap.json"' >> "$toml"
  grep -q '^response_contract[[:space:]]*=' "$toml" && sed -i "s|^response_contract[[:space:]]*=.*|response_contract = \"${DRO_RESPONDER_CONTRACT}\"|" "$toml" || echo "response_contract = \"${DRO_RESPONDER_CONTRACT}\"" >> "$toml"
  grep -q '^response_function[[:space:]]*=' "$toml" && sed -i 's|^response_function[[:space:]]*=.*|response_function = "respondWithDiscordName(string)"|' "$toml" || echo 'response_function = "respondWithDiscordName(string)"' >> "$toml"
  ( cd "${TRAP_DIR}" && forge build ) 2>&1 | tee -a "${LOG_DIR}/forge_build.log"
  pk="$(obtain_pk)" || exit 1
  evm_from_pk="$(get_evm_address_from_pk "$pk")"; echo "PK-derived address: ${evm_from_pk}"
  if [[ "${evm_from_pk,,}" != "${owner_addr,,}" ]]; then echo "ERROR: Provided EVM address does not match the private key address."; return 1; fi
  ( cd "${TRAP_DIR}" && DROSERA_PRIVATE_KEY="$pk" bash -c 'echo "ofc" | drosera apply' ) 2>&1 | tee -a "${LOG_DIR}/apply.log"
  [[ -f "${COMPOSE_FILE}" ]] && ( cd "${NET_DIR}" && dc up -d ) || echo "NOTE: ${COMPOSE_FILE} not found; skipping compose up."
  echo "Now follow Discord verification steps on Drosera server."
  echo "You can optionally check Responder status:"
  echo "cast call ${DRO_RESPONDER_CONTRACT} \"isResponder(address)(bool)\" ${owner_addr} --rpc-url https://ethereum-holesky-rpc.publicnode.com"
  command -v cast >/dev/null 2>&1 && cast call "${DRO_RESPONDER_CONTRACT}" "getDiscordNamesBatch(uint256,uint256)(string[])" 0 2000 --rpc-url https://ethereum-holesky-rpc.publicnode.com/ 2>/dev/null || true
}

view_logs() {
  echo "==== Docker Compose logs (follow; Ctrl-C to exit) ===="
  if [[ -f "${COMPOSE_FILE}" ]]; then ( cd "${NET_DIR}" && dc logs -f --tail=200 ); else echo "Compose file not found at ${COMPOSE_FILE}"; fi
}

restart_operators() {
  [[ -f "${COMPOSE_FILE}" ]] || { echo "ERROR: docker-compose.yaml not found in ${NET_DIR}." >&2; exit 1; }
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
  sudo -E bash $0 --auto --pk 0xYOUR_HEX_KEY
  sudo -E bash $0 --auto --pk-file /root/pk.txt --eth-amount 0.2
  DROSERA_PRIVATE_KEY=0xYOUR_HEX_KEY sudo -E bash $0 --auto

EOH
}

menu() {
  require_root; add_paths; net_check; sys_check
  while :; do
    print_header
    echo "Choose an option:"
    echo " 1) Full install (AUTO-ready): Docker + Bun + Foundry + Drosera, init trap, normalize config, apply, bloomboost, operator register & optin"
    echo " 2) View operator logs (docker compose logs -f)"
    echo " 3) Restart operator stack (compose down/up)"
    echo " 4) Upgrade Drosera & set relay RPC, then apply"
    echo " 5) Claim Cadet role (Trap.sol + apply)"
    echo " 0) Exit"
    read -r -p "Select (0-5): " choice || true
    case "${choice:-}" in
      1) install_deps; install_docker; install_bun; install_foundry; install_drosera_cli; post_install_env; init_trap_project; safe_edit_drosera_toml_whitelist_and_normalize; setup_operator_stack; register_and_optin_operator; if [[ $AUTO_MODE -ne 1 ]]; then read -r -p "Press Enter to return to menu..." _ ; fi ;;
      2) view_logs; read -r -p "Press Enter to return to menu..." _ ;;
      3) restart_operators; read -r -p "Press Enter to return to menu..." _ ;;
      4) upgrade_and_fix_relay; read -r -p "Press Enter to return to menu..." _ ;;
      5) claim_cadet_role; read -r -p "Press Enter to return to menu..." _ ;;
      0) echo "Bye."; exit 0 ;;
      *) echo "Invalid choice. Try again."; sleep 1 ;;
    esac
    [[ $AUTO_MODE -eq 1 ]] && exit 0
  done
}

main() { parse_args "$@"; print_header; menu; }
main "$@"
