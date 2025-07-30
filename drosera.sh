#!/usr/bin/env bash
# Drosera One-shot Installer v1.6.0 – 30-Jul-2025
# - Cài Docker & Compose (plugin hoặc binary), Bun, Foundry, Drosera CLI
# - Tạo trap, chờ deploy thành công, bloomboost 0.1 ETH
# - Dựng Operator bằng docker-compose.yaml mẫu, register + opt-in
# - Lấy IPv4 công khai tin cậy; trả summary JSON và log đầy đủ

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
trap 'printf "[%(%F %T)T] ERROR at line %s: %s\n" -1 "$LINENO" "$BASH_COMMAND" >&2' ERR

# ======================== Cấu hình ========================
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/Drosera-Network}"
OP_REPO_URL_DEFAULT="https://github.com/laodauhgc/drosera-network.git"
OP_REPO_URL="${OP_REPO_URL:-$OP_REPO_URL_DEFAULT}"

CHAIN_ID="${CHAIN_ID:-560048}"
HOODI_RPC="${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"
DROSERA_ADDRESS="${DROSERA_ADDRESS:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
DROSERA_RELAY_RPC="${DROSERA_RELAY_RPC:-https://relay.hoodi.drosera.io}"
ETH_AMOUNT="${ETH_AMOUNT:-0.1}"
WAIT_CODE_SECS="${WAIT_CODE_SECS:-300}"   # 5 phút

# ======================== Logging ========================
[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng sudo/root"; exit 1; }
mkdir -p /root
LOG="/root/drosera_setup_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
msg(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }

# ======================== Tham số ========================
PK_RAW=""; MANUAL_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_RAW="$2"; shift 2 ;;
    --repo) OP_REPO_URL="$2"; shift 2 ;;
    --ip) MANUAL_IP="$2"; shift 2 ;;
    --eth-amount) ETH_AMOUNT="$2"; shift 2 ;;
    --drosera-address) DROSERA_ADDRESS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "${PK_RAW:-}" ]]; then read -rsp "Private key (64 hex, có/không 0x): " PK_RAW; echo; fi
PK_RAW="${PK_RAW#0x}"
[[ "$PK_RAW" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Private key không hợp lệ"; exit 1; }
PK_HEX="0x$PK_RAW"

# ======================== Helpers ========================
add_path_once(){ local l="$1"; grep -qxF "$l" /root/.bashrc || echo "$l" >> /root/.bashrc; eval "$l"; }
detect_compose_file(){ for f in docker-compose.yaml docker-compose.yml compose.yaml; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done; return 1; }
is_public_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; set -- $ip
  # loại private/bogon: 10/8, 172.16–31/12, 192.168/16, 127/8, 169.254/16
  if (( $1==10 )) || ( (( $1==172 )) && (( $2>=16 && $2<=31 )) ) || ( (( $1==192 )) && (( $2==168 )) ) \
     || (( $1==127 )) || ( (( $1==169 )) && (( $2==254 )) ); then
    return 1
  fi
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
  local name="${GIT_NAME:-drosera-ops}"
  local email="${GIT_EMAIL:-ops@localhost}"
  if [[ -z "$(git config --global user.name || true)" ]]; then git config --global user.name "$name"; fi
  if [[ -z "$(git config --global user.email || true)" ]]; then git config --global user.email "$email"; fi
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
  # Ưu tiên plugin v2: 'docker compose'
  if docker compose version >/dev/null 2>&1; then return; fi
  # Thử cài plugin từ repo Docker (thêm repo nếu cần)
  add_docker_repo || true
  apt-get install -y docker-compose-plugin && docker compose version >/dev/null 2>&1 && return
  # Fallback: binary docker-compose (v2)
  curl -L "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  docker-compose --version >/dev/null 2>&1
}
compose(){
  # Gọi docker compose (plugin) nếu có, nếu không dùng docker-compose (binary)
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}
wait_code_deployed(){
  local addr="$1" rpc="$2" secs="$3"
  local start=$(date +%s)
  while :; do
    local code
    code=$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null || true)
    if [[ -n "$code" && "$code" != "0x" ]]; then echo "ok"; return 0; fi
    (( $(date +%s) - start >= secs )) && return 1
    sleep 5
  done
}

# ======================== Chuẩn bị hệ thống ========================
msg "Dọn khóa APT (nếu có) & cập nhật..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq unzip lz4 build-essential pkg-config \
  libssl-dev libleveldb-dev gnupg lsb-release dnsutils iproute2

# Docker
if ! command -v docker >/dev/null 2>&1; then
  msg "Cài Docker (script chính thức get.docker.com)..."
  curl -fsSL https://get.docker.com -o /root/install_docker.sh
  chmod +x /root/install_docker.sh
  /bin/bash /root/install_docker.sh
  rm -f /root/install_docker.sh
  systemctl enable --now docker
else
  msg "Docker đã có."
fi

# Compose (plugin hoặc binary v2)
msg "Đảm bảo Docker Compose v2..."
ensure_compose

# ======================== Bun / Foundry / Drosera ========================
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

# ======================== Địa chỉ ví ========================
ADDR=$(cast wallet address --private-key "$PK_HEX")
msg "Địa chỉ ví: $ADDR"

# ======================== Project trap ========================
msg "Chuẩn bị $TRAP_DIR ..."
ensure_git_identity
# Nếu trước đó init dở dang -> dọn sạch
if [[ -d "$TRAP_DIR/.git" && ! -f "$TRAP_DIR/foundry.toml" ]]; then rm -rf "$TRAP_DIR"; fi
mkdir -p "$TRAP_DIR"
cd "$TRAP_DIR"

if [[ ! -f "foundry.toml" ]]; then
  forge init -t drosera-network/trap-foundry-template
fi

bun install
forge build

# Cấu hình drosera.toml
[[ -f drosera.toml ]] || { echo "Thiếu drosera.toml"; exit 1; }
cp -f drosera.toml drosera.toml.bak

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

# Apply & lấy trapAddress
msg "drosera apply ..."
env DROSERA_PRIVATE_KEY="$PK_HEX" drosera apply <<<"ofc" | tee drosera_apply.log

TRAP_ADDR=$(grep -oE 'trapAddress: 0x[a-fA-F0-9]{40}' drosera_apply.log | awk '{print $2}' | tail -n1 || true)
[[ -z "${TRAP_ADDR:-}" && -f drosera.log ]] && TRAP_ADDR=$(grep -oE 'trapAddress: 0x[a-fA-F0-9]{40}' drosera.log | awk '{print $2}' | tail -n1 || true)
if [[ -z "${TRAP_ADDR:-}" ]]; then
  echo "Không trích được trapAddress từ log, nhập (0x...):"
  read -r TRAP_ADDR
fi
[[ "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "trapAddress không hợp lệ"; exit 1; }
msg "trapAddress: $TRAP_ADDR"

# Chờ deploy xong (bytecode ≠ 0x)
msg "Đợi contract tại $TRAP_ADDR deploy xong (tối đa ${WAIT_CODE_SECS}s)..."
if [[ "$(wait_code_deployed "$TRAP_ADDR" "$HOODI_RPC" "$WAIT_CODE_SECS")" != "ok" ]]; then
  echo "Timeout: cast code $TRAP_ADDR vẫn 0x. Hãy kiểm tra thủ công."; exit 1
fi

# Bloomboost 0.1 ETH
msg "Bloomboost ${ETH_AMOUNT} ETH ..."
env DROSERA_PRIVATE_KEY="$PK_HEX" drosera bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT"

# ======================== Operator repo ========================
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

# ======================== IPv4 công khai ========================
IPV4=""
if [[ -n "${MANUAL_IP:-}" ]]; then IPV4="$MANUAL_IP"; else IPV4=$(get_public_ipv4 || true); fi
if ! is_public_ipv4 "$IPV4"; then
  echo "Không lấy được IPv4 công khai tự động. Hãy dùng --ip <IPv4>."; exit 1
fi
msg "IPv4: $IPV4"

# ======================== .env theo mẫu ========================
touch .env && chmod 600 .env
grep -q '^ETH_PRIVATE_KEY=' .env && sed -i "s|^ETH_PRIVATE_KEY=.*|ETH_PRIVATE_KEY=$PK_HEX|" .env || echo "ETH_PRIVATE_KEY=$PK_HEX" >> .env
grep -q '^VPS_IP=' .env && sed -i "s|^VPS_IP=.*|VPS_IP=$IPV4|" .env || echo "VPS_IP=$IPV4" >> .env
msg ".env đã cập nhật."

# ======================== docker-compose.yaml (mẫu chuẩn) ========================
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

COMPOSE_FILE="$(detect_compose_file)" || { echo "Thiếu docker-compose file"; exit 1; }
compose -f "$COMPOSE_FILE" config >/dev/null
msg "docker compose up -d ..."
compose -f "$COMPOSE_FILE" up -d

# ======================== register & opt-in ========================
msg "Đăng ký operator (register)..."
docker pull ghcr.io/drosera-network/drosera-operator:v1.20.0
docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
  register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" --drosera-address "$DROSERA_ADDRESS"

msg "Opt-in operator ..."
docker run --rm -e ETH_PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
  optin --eth-rpc-url "$HOODI_RPC" --trap-config-address "$TRAP_ADDR"

# ======================== Summary ========================
SUMMARY_JSON="/root/drosera_summary.json"
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
  "operator_image": "ghcr.io/drosera-network/drosera-operator:v1.20.0",
  "operator_container": "drosera-operator",
  "vps_ipv4": "$IPV4",
  "logs": "$LOG"
}
JSON

msg "HOÀN TẤT."
msg "Summary JSON: $SUMMARY_JSON"
msg "Log đầy đủ : $LOG"
