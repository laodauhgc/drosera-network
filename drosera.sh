#!/usr/bin/env bash
# Drosera One-shot Installer v1.8.0 – 30-Jul-2025
# - Idempotent & resumable: stateful, skip tasks already done
# - Robust trap address extraction; soft-wait (no hard exit)
# - Docker Compose v2 (plugin or binary fallback); Git identity preset
# - Public IPv4 enforced; full logs; summary & state JSON

# ===== Strict early phase for base setup =====
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
trap 'printf "[%(%F %T)T] ERROR at line %s: %s\n" -1 "$LINENO" "$BASH_COMMAND" >&2' ERR

# ======================== Config ========================
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/Drosera-Network}"
OP_REPO_URL_DEFAULT="https://github.com/laodauhgc/drosera-network.git"
OP_REPO_URL="${OP_REPO_URL:-$OP_REPO_URL_DEFAULT}"

CHAIN_ID="${CHAIN_ID:-560048}"
HOODI_RPC="${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"
DROSERA_ADDRESS="${DROSERA_ADDRESS:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
DROSERA_RELAY_RPC="${DROSERA_RELAY_RPC:-https://relay.hoodi.drosera.io}"
ETH_AMOUNT="${ETH_AMOUNT:-0.1}"
WAIT_CODE_SECS="${WAIT_CODE_SECS:-300}"   # soft-wait tối đa 5 phút
RETRY_DELAY="${RETRY_DELAY:-20}"          # giãn cách retry non-critical

STATE_JSON="/root/drosera_state.json"
SUMMARY_JSON="/root/drosera_summary.json"

# ======================== Logging ========================
[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng sudo/root"; exit 1; }
mkdir -p /root
LOG="/root/drosera_setup_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
msg(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
warn(){ printf '[%(%F %T)T] WARN: %s\n' -1 "$*" >&2; }

# ======================== Args ===========================
PK_RAW=""; MANUAL_IP=""; TRAP_OVERRIDE=""
REDO_BLOOMBOOST=""; FORCE_REGISTER=""; FORCE_OPTIN=""; FORCE_ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_RAW="$2"; shift 2 ;;
    --repo) OP_REPO_URL="$2"; shift 2 ;;
    --ip) MANUAL_IP="$2"; shift 2 ;;
    --trap) TRAP_OVERRIDE="$2"; shift 2 ;;
    --eth-amount) ETH_AMOUNT="$2"; shift 2 ;;
    --drosera-address) DROSERA_ADDRESS="$2"; shift 2 ;;
    --redo-bloomboost) REDO_BLOOMBOOST=1; shift ;;
    --force-register)  FORCE_REGISTER=1; shift ;;
    --force-optin)     FORCE_OPTIN=1; shift ;;
    --force-env)       FORCE_ENV=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ======================== Helpers ========================
add_path_once(){ local l="$1"; grep -qxF "$l" /root/.bashrc || echo "$l" >> /root/.bashrc; eval "$l"; }
detect_compose_file(){ for f in docker-compose.yaml docker-compose.yml compose.yaml; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done; return 1; }
is_public_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; set -- $ip
  if (( $1==10 )) || ( (( $1==172 )) && (( $2>=16 && $2<=31 )) ) || ( (( $1==192 )) && (( $2==168 )) ) \
     || (( $1==127 )) || ( (( $1==169 )) && (( $2==254 )) ); then return 1; fi
  return 0
}
get_public_ipv4(){
  local ip=""
  ip=$(curl -4fsSL https://api.ipify.org || true) && is_public_ipv4 "$ip" && { echo "$ip"; return 0; }
  ip=$(curl -4fsSL https://ipv4.icanhazip.com || true) && ip="${ip//$'\n'/}" && is_public_ipv4 "$ip" && { echo "$ip"; return 0; }
  command -v dig >/dev/null 2>&1 && ip=$(dig +short -4 myip.opendns.com @resolver1.opendns.com || true) && is_public_ipv4 "$ip" && { echo "$ip"; return 0; }
  ip=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
  is_public_ipv4 "$ip" && { echo "$ip"; return 0; }
  return 1
}
ensure_git_identity(){
  local name="${GIT_NAME:-drosera-ops}" email="${GIT_EMAIL:-ops@localhost}"
  [[ -z "$(git config --global user.name || true)" ]] && git config --global user.name "$name" || true
  [[ -z "$(git config --global user.email || true)" ]] && git config --global user.email "$email" || true
}
add_docker_repo(){
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
}
ensure_compose(){
  if docker compose version >/dev/null 2>&1; then return; fi
  add_docker_repo || true
  apt-get install -y docker-compose-plugin && docker compose version >/dev/null 2>&1 && return
  curl -L "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  docker-compose --version >/dev/null 2>&1
}
compose(){ if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }
wait_code_deployed(){
  local addr="$1" rpc="$2" secs="$3"
  local start=$(date +%s)
  while :; do
    local code; code=$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null || true)
    if [[ -n "$code" && "$code" != "0x" ]]; then echo "ok"; return 0; fi
    (( $(date +%s) - start >= secs )) && return 1
    sleep 5
  done
}
last_nonzero_address_from(){
  grep -ahoE '0x[a-fA-F0-9]{40}' "$@" 2>/dev/null | awk '{print tolower($0)}' | awk '!/^0x0{40}$/' | tail -n1
}
extract_trap_address(){
  local addr=""
  addr=$(awk '/Created Trap Config/{f=1} f && /- address:/{print $3}' drosera_apply.log 2>/dev/null | tail -n1 | tr 'A-Z' 'a-z') || true
  [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] && echo "$addr" && return 0
  [[ -f drosera.log ]] && addr=$(awk '/Created Trap Config/{f=1} f && /- address:/{print $3}' drosera.log 2>/dev/null | tail -n1 | tr 'A-Z' 'a-z') || true
  [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] && echo "$addr" && return 0
  addr=$(last_nonzero_address_from drosera_apply.log drosera.log)
  [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] && echo "$addr" && return 0
  return 1
}

# ====== STATE management (resume) ======
STATE_EVM=""; STATE_TRAP=""; STATE_IPV4=""; STATE_BLOOM=""; STATE_REG=""; STATE_OPTIN=""
load_state(){
  [[ -f "$STATE_JSON" ]] || return 1
  STATE_EVM=$(jq -r '.evm_address // empty' "$STATE_JSON" 2>/dev/null || true)
  STATE_TRAP=$(jq -r '.trap_address // empty' "$STATE_JSON" 2>/dev/null || true)
  STATE_IPV4=$(jq -r '.vps_ipv4 // empty' "$STATE_JSON" 2>/dev/null || true)
  STATE_BLOOM=$(jq -r '.bloomboost_ok // 0' "$STATE_JSON" 2>/dev/null || echo 0)
  STATE_REG=$(jq -r '.register_ok // 0' "$STATE_JSON" 2>/dev/null || echo 0)
  STATE_OPTIN=$(jq -r '.optin_ok // 0' "$STATE_JSON" 2>/dev/null || echo 0)
}
save_state(){
  local evm="$1" trap="$2" ipv4="$3" bloom="$4" reg="$5" optin="$6"
  jq -n \
    --arg evm "$evm" \
    --arg trap "$trap" \
    --arg ipv4 "$ipv4" \
    --argjson bloom "${bloom:-0}" \
    --argjson reg "${reg:-0}" \
    --argjson optin "${optin:-0}" \
    --arg ts "$(date --iso-8601=seconds)" \
    '{evm_address:$evm, trap_address:$trap, vps_ipv4:$ipv4, bloomboost_ok:$bloom, register_ok:$reg, optin_ok:$optin, updated_at:$ts}' \
    > "$STATE_JSON"
}
set_state_flag(){
  local key="$1" val="${2:-0}"
  if [[ -f "$STATE_JSON" ]]; then
    jq --arg k "$key" --argjson v "$val" '.[$k]=$v' "$STATE_JSON" > "${STATE_JSON}.tmp" && mv "${STATE_JSON}.tmp" "$STATE_JSON"
  fi
}
migrate_summary_to_state(){
  # Hỗ trợ bản cũ: đọc trap từ /root/drosera_summary.json nếu state chưa có
  [[ -f "$STATE_JSON" ]] && return 0
  [[ -f "$SUMMARY_JSON" ]] || return 0
  local evm trap ipv4
  evm=$(jq -r '.evm_address // empty' "$SUMMARY_JSON" 2>/dev/null || true)
  trap=$(jq -r '.trap_address // empty' "$SUMMARY_JSON" 2>/dev/null || true)
  ipv4=$(jq -r '.vps_ipv4 // empty' "$SUMMARY_JSON" 2>/dev/null || true)
  [[ -n "$evm$trap$ipv4" ]] && save_state "${evm:-}" "${trap:-}" "${ipv4:-}" 0 0 0
}

# ======================== System prep ====================
msg "Dọn khóa APT & cập nhật..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq unzip lz4 build-essential pkg-config \
  libssl-dev libleveldb-dev gnupg lsb-release dnsutils iproute2

# Docker
if ! command -v docker >/dev/null 2>&1; then
  msg "Cài Docker (get.docker.com)..."
  curl -fsSL https://get.docker.com -o /root/install_docker.sh
  chmod +x /root/install_docker.sh
  /bin/bash /root/install_docker.sh
  rm -f /root/install_docker.sh
  systemctl enable --now docker
else
  msg "Docker đã có."
fi

# Compose
msg "Đảm bảo Docker Compose v2..."
ensure_compose

# ======================== Toolchain ======================
msg "Cài Bun..."
curl -fsSL https://bun.sh/install | bash
add_path_once 'export PATH=$PATH:/root/.bun/bin'

msg "Cài Foundry..."
curl -fsSL https://foundry.paradigm.xyz | bash
add_path_once 'export PATH=$PATH:/root/.foundry/bin'
/root/.foundry/bin/foundryup
forge --version
cast --version

msg "Cài Drosera CLI..."
curl -fsSL https://app.drosera.io/install | bash
add_path_once 'export PATH=$PATH:/root/.drosera/bin'
droseraup
drosera --version

# ======================== Wallet =========================
if [[ -z "${PK_RAW:-}" ]]; then read -rsp "Private key (64 hex, có/không 0x): " PK_RAW; echo; fi
PK_RAW="${PK_RAW#0x}"
[[ "$PK_RAW" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Private key không hợp lệ"; exit 1; }
PK_HEX="0x$PK_RAW"
ADDR=$(cast wallet address --private-key "$PK_HEX")
msg "Địa chỉ ví: $ADDR"

# ======================== Resume state ===================
migrate_summary_to_state || true
load_state || true

# ======================== Trap project ===================
msg "Chuẩn bị $TRAP_DIR ..."
ensure_git_identity
if [[ -d "$TRAP_DIR/.git" && ! -f "$TRAP_DIR/foundry.toml" ]]; then rm -rf "$TRAP_DIR"; fi
mkdir -p "$TRAP_DIR"
cd "$TRAP_DIR"

if [[ ! -f "foundry.toml" ]]; then
  forge init -t drosera-network/trap-foundry-template
fi

# switch to non-strict mode for the rest (avoid hard exits)
set +e

bun install
forge build

[[ -f drosera.toml ]] || { echo "Thiếu drosera.toml"; touch drosera.toml; }

cp -f drosera.toml drosera.toml.bak 2>/dev/null

# whitelist
if grep -Eq '^[[:space:]]*whitelist[[:space:]]*=' drosera.toml; then
  sed -i "s|^[[:space:]]*whitelist[[:space:]]*=.*|whitelist = [\"$ADDR\"]|g" drosera.toml
else
  awk -v a="$ADDR" 'BEGIN{d=0} /^\[traps\.mytrap\][[:space:]]*$/ {print; print "whitelist = [\"" a "\"]"; d=1; next} {print} END{if(!d) print "whitelist = [\"" a "\"]"}' \
    drosera.toml > drosera.toml.tmp && mv drosera.toml.tmp drosera.toml
fi
# drosera_rpc
if grep -Eq '^[[:space:]]*drosera_rpc[[:space:]]*=' drosera.toml; then
  sed -i "s|^[[:space:]]*drosera_rpc[[:space:]]*=.*|drosera_rpc = \"$DROSERA_RELAY_RPC\"|g" drosera.toml
else
  echo "drosera_rpc = \"$DROSERA_RELAY_RPC\"" >> drosera.toml
fi

# ======================== Trap address resolve ===================
TRAP_ADDR=""
SKIP_APPLY=""
if [[ -n "$TRAP_OVERRIDE" ]]; then
  TRAP_ADDR="$(echo "$TRAP_OVERRIDE" | tr 'A-Z' 'a-z')"
fi

# Dùng state nếu có và on-chain đã có bytecode
if [[ -z "$TRAP_ADDR" && -n "${STATE_TRAP:-}" ]]; then
  CODE=$(cast code "$STATE_TRAP" --rpc-url "$HOODI_RPC" 2>/dev/null || echo "0x")
  if [[ "$CODE" != "0x" ]]; then
    TRAP_ADDR="$STATE_TRAP"; SKIP_APPLY=1
    msg "Phát hiện trap từ state: $TRAP_ADDR (đã deploy) → bỏ qua drosera apply"
  fi
fi

# Nếu vẫn chưa có, thử từ summary cũ
if [[ -z "$TRAP_ADDR" && -f "$SUMMARY_JSON" ]]; then
  SUM_TRAP=$(jq -r '.trap_address // empty' "$SUMMARY_JSON" 2>/dev/null || true)
  if [[ "$SUM_TRAP" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    CODE=$(cast code "$SUM_TRAP" --rpc-url "$HOODI_RPC" 2>/dev/null || echo "0x")
    if [[ "$CODE" != "0x" ]]; then
      TRAP_ADDR="$(echo "$SUM_TRAP" | tr 'A-Z' 'a-z')"; SKIP_APPLY=1
      msg "Phát hiện trap từ summary: $TRAP_ADDR (đã deploy) → bỏ qua drosera apply"
    endif
  fi
fi

# Nếu vẫn chưa có, chạy apply rồi trích
if [[ -z "$TRAP_ADDR" && -z "$SKIP_APPLY" ]]; then
  msg "drosera apply ..."
  env DROSERA_PRIVATE_KEY="$PK_HEX" drosera apply <<<"ofc" | tee drosera_apply.log
  TRAP_ADDR="$(extract_trap_address || true)"
  if [[ ! "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ || "$TRAP_ADDR" =~ ^0x0{40}$ ]]; then
    warn "Không trích được trapAddress rõ ràng. Nhập (0x...):"
    read -r TRAP_ADDR
  fi
fi

TRAP_ADDR="$(echo "$TRAP_ADDR" | tr 'A-Z' 'a-z')"
msg "trapAddress: $TRAP_ADDR"

# Cập nhật state sớm
save_state "$ADDR" "$TRAP_ADDR" "${STATE_IPV4:-}" "${STATE_BLOOM:-0}" "${STATE_REG:-0}" "${STATE_OPTIN:-0}"

# Soft-wait (không exit nếu timeout)
msg "Đợi contract tại $TRAP_ADDR deploy xong (tối đa ${WAIT_CODE_SECS}s)..."
if [[ "$(wait_code_deployed "$TRAP_ADDR" "$HOODI_RPC" "$WAIT_CODE_SECS")" != "ok" ]]; then
  warn "Timeout chờ bytecode; vẫn tiếp tục các bước sau."
fi

# ======================== Bloomboost =====================
BLOOMBOOST_OK="${STATE_BLOOM:-0}"
if [[ "$BLOOMBOOST_OK" -eq 1 && -z "$REDO_BLOOMBOOST" ]]; then
  msg "Bloomboost đã OK trước đó → bỏ qua."
else
  msg "Bloomboost ${ETH_AMOUNT} ETH ..."
  if env DROSERA_PRIVATE_KEY="$PK_HEX" drosera bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT"; then
    BLOOMBOOST_OK=1; set_state_flag "bloomboost_ok" 1
  else
    warn "Bloomboost thất bại, retry sau ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    if env DROSERA_PRIVATE_KEY="$PK_HEX" drosera bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT"; then
      BLOOMBOOST_OK=1; set_state_flag "bloomboost_ok" 1
    else
      warn "Bloomboost vẫn thất bại. Tiếp tục."
    fi
  fi
fi

# ======================== Operator repo ==================
msg "Chuẩn bị Operator repo $OP_DIR ..."
if [[ -d "$OP_DIR/.git" ]]; then
  cd "$OP_DIR"
  git fetch --all --prune || true
  git reset --hard origin/HEAD || git pull --ff-only || true
else
  rm -rf "$OP_DIR"
  git clone "$OP_REPO_URL" "$OP_DIR"
  cd "$OP_DIR"
fi

# ======================== IPv4 & .env ====================
IPV4=""
if [[ -n "$MANUAL_IP" ]]; then
  IPV4="$MANUAL_IP"
elif [[ -n "${STATE_IPV4:-}" && -z "$FORCE_ENV" ]]; then
  IPV4="$STATE_IPV4"
else
  IPV4=$(get_public_ipv4 || true)
fi
if ! is_public_ipv4 "$IPV4"; then
  warn "Không lấy được IPv4 công khai tự động. Dùng --ip <IPv4> hoặc giữ nguyên .env hiện có."
  # Nếu .env có sẵn và không force-env → dùng lại
  if [[ -f .env && -z "$FORCE_ENV" ]]; then
    IPV4=$(grep -E '^VPS_IP=' .env | cut -d= -f2-)
  else
    IPV4="0.0.0.0"
  fi
fi
msg "IPv4: $IPV4"

if [[ -f .env && -z "$FORCE_ENV" ]]; then
  grep -q '^ETH_PRIVATE_KEY=' .env || echo "ETH_PRIVATE_KEY=$PK_HEX" >> .env
  grep -q '^VPS_IP=' .env || echo "VPS_IP=$IPV4" >> .env
else
  cat > .env <<EOF
ETH_PRIVATE_KEY=$PK_HEX
VPS_IP=$IPV4
EOF
  chmod 600 .env
fi
save_state "$ADDR" "$TRAP_ADDR" "$IPV4" "$BLOOMBOOST_OK" "${STATE_REG:-0}" "${STATE_OPTIN:-0}"

# ======================== docker-compose.yaml =============
cat > docker-compose.yaml <<'YAML'
version: '3'
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
      - DRO__NETWORK__EXTERNAL_P2P_ADDRESS=${VPS_IP}
      - DRO__SERVER__PORT=31314
    volumes:
      - drosera_data:/data
    command: ["node"]
    restart: always

volumes:
  drosera_data:
YAML

COMPOSE_FILE="$(detect_compose_file)" || { echo "Thiếu docker-compose file"; COMPOSE_FILE="docker-compose.yaml"; }
compose -f "$COMPOSE_FILE" config >/dev/null
msg "docker compose up -d ..."
compose -f "$COMPOSE_FILE" up -d || { warn "compose up thất bại, retry sau ${RETRY_DELAY}s"; sleep "$RETRY_DELAY"; compose -f "$COMPOSE_FILE" up -d || warn "compose vẫn lỗi, tiếp tục."; }

# ======================== register & opt-in ==============
REGISTER_OK="${STATE_REG:-0}"
OPTIN_OK="${STATE_OPTIN:-0}"

if [[ "$REGISTER_OK" -eq 1 && -z "$FORCE_REGISTER" ]]; then
  msg "Register đã OK trước đó → bỏ qua."
else
  msg "Đăng ký operator (register)..."
  docker pull ghcr.io/drosera-network/drosera-operator:v1.20.0 >/dev/null 2>&1 || true
  docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
    register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" --drosera-address "$DROSERA_ADDRESS"
  if [[ "$?" -ne 0 ]]; then
    warn "Register thất bại, retry sau ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
      register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" --drosera-address "$DROSERA_ADDRESS" \
    || warn "Register vẫn thất bại."
  else
    REGISTER_OK=1; set_state_flag "register_ok" 1
  fi
fi

if [[ "$OPTIN_OK" -eq 1 && -z "$FORCE_OPTIN" ]]; then
  msg "Opt-in đã OK trước đó → bỏ qua."
else
  msg "Opt-in operator ..."
  docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
    optin --eth-rpc-url "$HOODI_RPC" --trap-config-address "$TRAP_ADDR"
  if [[ "$?" -ne 0 ]]; then
    warn "Opt-in thất bại, retry sau ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
      optin --eth-rpc-url "$HOODI_RPC" --trap-config-address "$TRAP_ADDR" \
    || warn "Opt-in vẫn thất bại."
  else
    OPTIN_OK=1; set_state_flag "optin_ok" 1
  fi
fi

# ======================== Final Summary ==================
# Lấy cờ hiện tại từ state (sau khi có thể vừa set_state_flag)
load_state || true
CUR_BLOOM="${STATE_BLOOM:-$BLOOMBOOST_OK}"
CUR_REG="${STATE_REG:-$REGISTER_OK}"
CUR_OPTIN="${STATE_OPTIN:-$OPTIN_OK}"
save_state "$ADDR" "$TRAP_ADDR" "$IPV4" "$CUR_BLOOM" "$CUR_REG" "$CUR_OPTIN"

cat >"$SUMMARY_JSON" <<JSON
{
  "timestamp": "$(date --iso-8601=seconds)",
  "evm_address": "$ADDR",
  "trap_address": "$TRAP_ADDR",
  "chain_id": $CHAIN_ID,
  "hoodi_rpc": "$HOODI_RPC",
  "drosera_relay_rpc": "$DROSERA_RELAY_RPC",
  "drosera_address": "$DROSERA_ADDRESS",
  "bloomboost_eth": "$ETH_AMOUNT",
  "bloomboost_ok": $CUR_BLOOM,
  "register_ok": $CUR_REG,
  "optin_ok": $CUR_OPTIN,
  "operator_image": "ghcr.io/drosera-network/drosera-operator:v1.20.0",
  "operator_container": "drosera-operator",
  "vps_ipv4": "$IPV4",
  "logs": "$LOG"
}
JSON

msg "HOÀN TẤT."
msg "Summary JSON: $SUMMARY_JSON"
msg "State JSON  : $STATE_JSON"
msg "Log đầy đủ  : $LOG"
