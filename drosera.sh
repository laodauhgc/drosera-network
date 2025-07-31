#!/usr/bin/env bash
# Drosera Installer / Runner v2.2.0 – Focused fix for `drosera apply` PK parsing
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8 LC_ALL=C.UTF-8
trap 'printf "[%(%F %T)T] ERROR at line %s: %s\n" -1 "$LINENO" "$BASH_COMMAND" >&2' ERR

# ====== Config ======
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/Drosera-Network}"
CHAIN_ID="${CHAIN_ID:-560048}"
HOODI_RPC="${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"
DROSERA_ADDRESS="${DROSERA_ADDRESS:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
DROSERA_RELAY_RPC="${DROSERA_RELAY_RPC:-https://relay.hoodi.drosera.io}"
ETH_AMOUNT="${ETH_AMOUNT:-0.1}"
RETRY_DELAY="${RETRY_DELAY:-20}"
WAIT_CODE_SECS="${WAIT_CODE_SECS:-300}"
STATE_JSON="/root/drosera_state.json"
LOG="/root/drosera_setup_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
msg(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
warn(){ printf '[%(%F %T)T] WARN: %s\n' -1 "$*" >&2; }

# ====== Args ======
PK_RAW=""; TRAP_OVERRIDE=""; OP_REPO_URL="${OP_REPO_URL:-https://github.com/laodauhgc/drosera-network.git}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_RAW="$2"; shift 2 ;;
    --trap) TRAP_OVERRIDE="$2"; shift 2 ;;
    --repo) OP_REPO_URL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng sudo/root"; exit 1; }

# ====== System deps (rút gọn) ======
msg "Dọn khóa APT & cập nhật..."; apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl wget git jq unzip lz4 build-essential pkg-config libssl-dev libleveldb-dev gnupg lsb-release dnsutils iproute2 expect
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; systemctl enable --now docker; fi

# Docker compose v2
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin || {
    curl -L "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  }
fi
compose(){ if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi; }

# Toolchain
curl -fsSL https://bun.sh/install | bash; export PATH=$PATH:/root/.bun/bin; grep -qxF 'export PATH=$PATH:/root/.bun/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.bun/bin' >> /root/.bashrc
curl -fsSL https://foundry.paradigm.xyz | bash; export PATH=$PATH:/root/.foundry/bin; grep -qxF 'export PATH=$PATH:/root/.foundry/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.foundry/bin' >> /root/.bashrc
/root/.foundry/bin/foundryup || true
CAST_BIN="$(command -v cast || true)"; [[ -x "${CAST_BIN:-}" ]] || CAST_BIN="/root/.foundry/bin/cast"

# ====== droseraup (tránh 403) ======
install_drosera_cli() {
  msg "Cài droseraup từ GitHub Raw..."
  local tmp="/tmp/drosera_install_$$.sh"
  curl -A 'Mozilla/5.0' -fsSL https://raw.githubusercontent.com/drosera-network/releases/main/droseraup/install -o "$tmp"
  bash "$tmp"; rm -f "$tmp"
  export PATH=$PATH:/root/.drosera/bin; grep -qxF 'export PATH=$PATH:/root/.drosera/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
  if command -v droseraup >/dev/null 2>&1; then droseraup || true; fi
}
install_drosera_cli
DROSERA_BIN="$(command -v drosera || true)"; [[ -x "${DROSERA_BIN:-}" ]] || DROSERA_BIN="/root/.drosera/bin/drosera"
[[ -x "$DROSERA_BIN" ]] || { echo "Không tìm thấy drosera CLI"; exit 1; }
"$DROSERA_BIN" --version || true

# ====== Sanitize private key ======
if [[ -z "${PK_RAW:-}" ]]; then read -rsp "Private key (64 hex, có/không 0x): " PK_RAW; echo; fi
PK_RAW="$(printf %s "$PK_RAW" | tr -d ' \t\r\n')"
PK_SAN_NO0X="$(printf %s "$PK_RAW" | sed 's/^0[xX]//' | tr -cd '0-9a-fA-F')"
if [[ ${#PK_SAN_NO0X} -ne 64 ]]; then
  echo "Private key sau sanitize phải 64 hex; hiện tại len=${#PK_SAN_NO0X}."; exit 1
fi
PK_NO0X="$PK_SAN_NO0X"
PK_HEX="0x$PK_SAN_NO0X"

ADDR=$("$CAST_BIN" wallet address --private-key "$PK_HEX" 2>/dev/null || true)
msg "Địa chỉ ví: ${ADDR:-unknown}"
msg "Key forms sẽ thử (đã sanitize): 0x${PK_SAN_NO0X:0:4}...${PK_SAN_NO0X: -4} (len=66), ${PK_SAN_NO0X:0:6}...${PK_SAN_NO0X: -4} (len=64)"

# ====== Chuẩn bị trap project ======
mkdir -p "$TRAP_DIR"; cd "$TRAP_DIR"
if [[ ! -f "foundry.toml" ]]; then forge init -t drosera-network/trap-foundry-template || true; fi
bun install || true; forge build || true
[[ -f drosera.toml ]] || { echo "Thiếu drosera.toml"; touch drosera.toml; }
cp -f drosera.toml drosera.toml.bak 2>/dev/null || true

# --- Ghi drosera_rpc ---
if grep -Eq '^[[:space:]]*drosera_rpc[[:space:]]*=' drosera.toml; then
  sed -i "s|^[[:space:]]*drosera_rpc[[:space:]]*=.*|drosera_rpc = \"$DROSERA_RELAY_RPC\"|g" drosera.toml
else
  echo "drosera_rpc = \"$DROSERA_RELAY_RPC\"" >> drosera.toml
fi

# --- Ghi whitelist ---
if [[ -n "${ADDR:-}" ]]; then
  if grep -Eq '^[[:space:]]*whitelist[[:space:]]*=' drosera.toml; then
    sed -i "s|^[[:space:]]*whitelist[[:space:]]*=.*|whitelist = [\"$ADDR\"]|g" drosera.toml
  else
    awk -v a="$ADDR" 'BEGIN{d=0} /^\[traps\.mytrap\][[:space:]]*$/ {print; print "whitelist = [\"" a "\"]"; d=1; next} {print} END{if(!d) print "whitelist = [\"" a "\"]"}' \
      drosera.toml > drosera.toml.tmp && mv drosera.toml.tmp drosera.toml
  fi
fi

# --- 🔴 FIX QUAN TRỌNG: Ghi private key vào [wallet] (và các alias) ---
ensure_wallet_section_and_keys() {
  local toml="$1" keyhex="$2"
  # nếu có dòng private_key thì thay; nếu không có thì thêm khối [wallet]
  if grep -Eq '^\[wallet\]' "$toml"; then
    if grep -Eq '^[[:space:]]*private_key[[:space:]]*=' "$toml"; then
      sed -i "s|^[[:space:]]*private_key[[:space:]]*=.*|private_key = \"$keyhex\"|g" "$toml"
    else
      # chèn ngay sau [wallet]
      awk -v k="$keyhex" '
        BEGIN{p=0}
        /^\[wallet\]/ {print; print "private_key = \""k"\""; p=1; next}
        {print}
      ' "$toml" > "$toml.tmp" && mv "$toml.tmp" "$toml"
    fi
  else
    {
      echo ""; echo "[wallet]"
      echo "private_key = \"$keyhex\""
    } >> "$toml"
  fi
  # Thêm các alias (nếu CLI map sang tên khác)
  for alias in eth_private_key signer_private_key wallet_private_key; do
    if grep -Eq "^[[:space:]]*$alias[[:space:]]*=" "$toml"; then
      sed -i "s|^[[:space:]]*$alias[[:space:]]*=.*|$alias = \"$keyhex\"|g" "$toml"
    else
      awk -v a="$alias" -v k="$keyhex" '
        BEGIN{w=0}
        /^\[wallet\]/ {print; print a " = \""k"\""; w=1; next}
        {print}
        END{if(!w){print ""; print "[wallet]"; print a " = \""k"\""}}
      ' "$toml" > "$toml.tmp" && mv "$toml.tmp" "$toml"
    fi
  done
}
ensure_wallet_section_and_keys "drosera.toml" "$PK_HEX"

# Ghi thêm .env để mọi tool có thể pick up
cat > .env.drosera <<EOF
DROSERA_PRIVATE_KEY=$PK_HEX
ETH_PRIVATE_KEY=$PK_HEX
PRIVATE_KEY=$PK_HEX
DRO__ETH__PRIVATE_KEY=$PK_HEX
DRO__WALLET__PRIVATE_KEY=$PK_HEX
EOF
chmod 600 .env.drosera
export DROSERA_PRIVATE_KEY="$PK_HEX" ETH_PRIVATE_KEY="$PK_HEX" PRIVATE_KEY="$PK_HEX" DRO__ETH__PRIVATE_KEY="$PK_HEX" DRO__WALLET__PRIVATE_KEY="$PK_HEX"

# ====== drosera apply (mở rộng prompt handler) ======
run_apply() {
  local key="$1"
  : > drosera_apply.log
  # thử --yes nếu có
  local YESFLAG=""
  if "$DROSERA_BIN" apply --help 2>&1 | grep -Eq -- '--yes|--assume-yes|--no-confirm'; then
    YESFLAG="--yes"
  fi

  # 1) chạy trực tiếp (nhiều bản apply tự đọc từ drosera.toml, env chỉ là fallback)
  if "$DROSERA_BIN" apply $YESFLAG >> drosera_apply.log 2>&1; then
    return 0
  fi

  # 2) expect: xử lý cả ofc lẫn các kiểu nhắc nhập private key
  /usr/bin/env PK_VAL="$key" DROSERA_BIN="$DROSERA_BIN" YESF="$YESFLAG" expect <<'EOF' >> drosera_apply.log 2>&1
set timeout 600
spawn -noecho env "$env(DROSERA_BIN)" apply $env(YESF)
expect {
  -re {Do you want to .* \[ofc/N\]:} {send -- "ofc\r"; exp_continue}
  -re {enter.*private.*key} -nocase {send -- "$env(PK_VAL)\r"; exp_continue}
  -re {private.*key.*:} -nocase {send -- "$env(PK_VAL)\r"; exp_continue}
  -re {paste.*key} -nocase {send -- "$env(PK_VAL)\r"; exp_continue}
  eof {}
}
expect eof
EOF
  return $?
}

msg "drosera apply ..."
if ! run_apply "$PK_HEX"; then
  warn "Apply thất bại. In 200 dòng đầu log để soi lỗi:"
fi
sed -n '1,200p' drosera_apply.log || true

# ====== Lấy trapAddress ======
extract_trap_address(){
  local addr
  addr=$(grep -ahoE 'trapAddress[: ]+0x[a-fA-F0-9]{40}' drosera_apply.log 2>/dev/null | awk '{print tolower($NF)}' | tail -1)
  [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] && { echo "$addr"; return 0; }
  addr=$(awk '/Created Trap Config/{f=1} f && /- address:/{print $3}' drosera_apply.log 2>/dev/null | tail -1 | tr 'A-Z' 'a-z')
  [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] && { echo "$addr"; return 0; }
  return 1
}

TRAP_ADDR=""
[[ -n "$TRAP_OVERRIDE" ]] && TRAP_ADDR="$(echo "$TRAP_OVERRIDE" | tr 'A-Z' 'a-z')"
[[ -z "$TRAP_ADDR" ]] && TRAP_ADDR="$(extract_trap_address || true)"
if [[ ! "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ || "$TRAP_ADDR" =~ ^0x0{40}$ ]]; then
  warn "Không trích được trapAddress rõ ràng. Nhập (0x...):"
  read -r TRAP_ADDR
fi
TRAP_ADDR="$(echo "$TRAP_ADDR" | tr 'A-Z' 'a-z')"
msg "trapAddress: $TRAP_ADDR"

# ====== Đợi deploy xong (không bắt buộc) ======
wait_code_deployed(){
  local addr="$1" rpc="$2" secs="$3"; local start=$(date +%s)
  while :; do
    local code; code=$("$CAST_BIN" code "$addr" --rpc-url "$rpc" 2>/dev/null || true)
    if [[ -n "$code" && "$code" != "0x" ]]; then echo "ok"; return 0; fi
    (( $(date +%s) - start >= secs )) && return 1
    sleep 5
  done
}
msg "Đợi contract tại $TRAP_ADDR deploy (tối đa ${WAIT_CODE_SECS}s)..."
wait_code_deployed "$TRAP_ADDR" "$HOODI_RPC" "$WAIT_CODE_SECS" || warn "Timeout chờ bytecode; tiếp tục."

# ====== Bloomboost (non-interactive, ưu tiên --yes nếu có) ======
bb_yes=""
if "$DROSERA_BIN" bloomboost --help 2>&1 | grep -Eq -- '--yes|--assume-yes|--no-confirm'; then bb_yes="--yes"; fi
if "$DROSERA_BIN" bloomboost --help 2>&1 | grep -q -- '--eth-private-key'; then
  DRO__ETH__PRIVATE_KEY="$PK_HEX" "$DROSERA_BIN" bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT" $bb_yes --eth-private-key "$PK_HEX" || true
else
  DRO__ETH__PRIVATE_KEY="$PK_HEX" "$DROSERA_BIN" bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT" $bb_yes || true
fi

# ====== Operator compose + register + optin (giữ nguyên như trước) ======
mkdir -p "$OP_DIR"
if [[ -d "$OP_DIR/.git" ]]; then (cd "$OP_DIR" && git reset --hard && git pull --ff-only) || true
else git clone "$OP_REPO_URL" "$OP_DIR" || true
fi
cd "$OP_DIR"
cat > .env <<EOF
ETH_PRIVATE_KEY=$PK_HEX
VPS_IP=$(curl -4fsSL https://api.ipify.org || echo 0.0.0.0)
EOF
cat > docker-compose.yaml <<'YAML'
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
    restart: unless-stopped
volumes:
  drosera_data:
YAML

compose up -d || { sleep "$RETRY_DELAY"; compose up -d || true; }
docker pull ghcr.io/drosera-network/drosera-operator:v1.20.0 >/dev/null 2>&1 || true

docker run --rm -e DRO__ETH__PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
  register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" --drosera-address "$DROSERA_ADDRESS" \
  $(docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 register --help 2>&1 | grep -q -- '--eth-private-key' && echo --eth-private-key "$PK_HEX" || true) || true

docker run --rm -e DRO__ETH__PRIVATE_KEY="$PK_HEX" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
  optin --eth-rpc-url "$HOODI_RPC" --trap-config-address "$TRAP_ADDR" \
  $(docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 optin --help 2>&1 | grep -q -- '--eth-private-key' && echo --eth-private-key "$PK_HEX" || true) || true

# ====== Lưu state ======
jq -n --arg evm "${ADDR:-}" --arg trap "$TRAP_ADDR" --arg ip "$(grep -E '^VPS_IP=' .env | cut -d= -f2-)" \
  --arg ts "$(date --iso-8601=seconds)" \
  '{evm_address:$evm, trap_address:$trap, vps_ipv4:$ip, updated_at:$ts}' > "$STATE_JSON" || true

msg "HOÀN TẤT. trapAddress: $TRAP_ADDR"
