#!/usr/bin/env bash
# Drosera One-shot Installer v2.3.1 – 03-Aug-2025 (SGT)
# Hotfix vs v2.3.0:
# - Sửa lỗi khối capture output/exit-code dưới set -e (register/opt-in)
# - Tránh dùng command substitution khi lệnh có thể fail → không bị trap ERR
# - Loại bỏ RPC Ankr sai do người dùng báo
# - Giữ toàn bộ cải tiến chọn RPC thông minh + fallback

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
trap 'printf "[%(%F %T)T] ERROR at line %s: %s\n" -1 "$LINENO" "$BASH_COMMAND" >&2' ERR

[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng root/sudo"; exit 1; }

# =================== Defaults & Constants ===================
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
OP_DIR="${OP_DIR:-/root/Drosera-Network}"
OP_REPO_URL_DEFAULT="https://github.com/laodauhgc/drosera-network.git"
OP_REPO_URL="${OP_REPO_URL:-$OP_REPO_URL_DEFAULT}"

# Pin chain & endpoints (sẽ được override bởi bộ chọn RPC)
export CHAIN_ID="${CHAIN_ID:-560048}"
export HOODI_RPC="${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"
export DROSERA_ADDRESS="${DROSERA_ADDRESS:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"
export DROSERA_RELAY_RPC="${DROSERA_RELAY_RPC:-https://relay.hoodi.drosera.io}"

ETH_AMOUNT="${ETH_AMOUNT:-0.1}"

WAIT_CODE_SECS="${WAIT_CODE_SECS:-300}"
RETRY_DELAY="${RETRY_DELAY:-20}"

STATE_JSON="/root/drosera_state.json"
SUMMARY_JSON="/root/drosera_summary.json"

# Drosera home/binary (KHÓA TUYỆT ĐỐI)
DRO_HOME="${DRO_HOME:-/root/.drosera}"
DRO_BIN_DIR="${DRO_BIN_DIR:-$DRO_HOME/bin}"
DROSERA_BIN="${DROSERA_BIN:-$DRO_BIN_DIR/drosera}"   # <== luôn ưu tiên đường dẫn này

mkdir -p /root
LOG="/root/drosera_setup_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
msg(){ printf '[%(%F %T)T] %s\n' -1 "$*"; }
warn(){ printf '[%(%F %T)T] WARN: %s\n' -1 "$*" >&2; }

# =================== RPC candidates & chooser ===================
# Danh sách RPC thử lần lượt (ưu tiên của bạn trước)
# Có thể override bằng: --rpc-list "url1,url2,..." hoặc --rpc <url>
RPC_LIST_DEFAULT=(
  # ƯU TIÊN: RPC người dùng cung cấp (đã loại bỏ endpoint sai)
  "https://rpc.ankr.com/eth_hoodi/c54291b21199feab4e2aa0f79cf6d1167a99fbf0d2c8c77e422e654fc43efa87"

  # RPC mặc định hiện có
  "${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"

  # CHÚ Ý: endpoint holesky có chain-id khác → sẽ bị loại qua kiểm tra chain-id
  "https://rpc.ankr.com/eth_holesky/84c317ede17b1e7bb18244798af6a1680473d1c0b46c133dc041181c839784ca"
)

ASK_RPC_ON_FAIL="${ASK_RPC_ON_FAIL:-1}"  # 1 = nếu tất cả đều fail thì bắt buộc nhập tay
FORCED_RPC=""                             # set qua --rpc
RPC_LIST_CLI=""                           # set qua --rpc-list (chuỗi csv)

# Probe 1 RPC: check chain-id khớp & gọi block-number được (lọc 403/HTML)
probe_rpc() {
  local rpc="$1" out cid
  [[ -z "$rpc" ]] && return 1
  if ! out="$(cast chain-id --rpc-url "$rpc" 2>/dev/null)"; then
    return 1
  fi
  cid="$(echo "$out" | tr -dc '0-9')"
  [[ "$cid" == "$CHAIN_ID" ]] || return 2
  cast block-number --rpc-url "$rpc" >/dev/null 2>&1 || return 1
  return 0
}

# Chọn RPC hoạt động; nếu tất cả fail và ASK_RPC_ON_FAIL=1 thì yêu cầu nhập tay
choose_working_rpc() {
  local -a candidates=("$@")
  local ok=""
  for rpc in "${candidates[@]}"; do
    [[ -z "$rpc" ]] && continue
    if probe_rpc "$rpc"; then
      ok="$rpc"
      break
    fi
  done
  if [[ -n "$ok" ]]; then
    echo "$ok"
    return 0
  fi
  if [[ "$ASK_RPC_ON_FAIL" == "1" ]]; then
    while :; do
      read -rp "Không RPC nào hoạt động. Nhập RPC URL thủ công: " manual
      [[ -z "$manual" ]] && { echo "RPC trống. Thử lại."; continue; }
      if probe_rpc "$manual"; then
        echo "$manual"
        return 0
      else
        echo "RPC không hợp lệ/không khớp chain-id $CHAIN_ID. Thử lại."
      fi
    done
  fi
  return 1
}

# Build danh sách RPC (ép 1 cái, danh sách csv, rồi defaults) & loại trùng
build_rpc_candidates() {
  local -a arr=()
  if [[ -n "$FORCED_RPC" ]]; then arr+=("$FORCED_RPC"); fi
  if [[ -n "$RPC_LIST_CLI" ]]; then
    IFS=',' read -r -a tmp <<<"$RPC_LIST_CLI"
    arr+=("${tmp[@]}")
  fi
  arr+=("${RPC_LIST_DEFAULT[@]}")
  declare -A seen=()
  for x in "${arr[@]}"; do
    [[ -z "$x" ]] && continue
    if [[ -z "${seen[$x]+x}" ]]; then
      echo "$x"
      seen[$x]=1
    fi
  done
}

# =================== Args ===================
PK_RAW=""; MANUAL_IP=""; TRAP_OVERRIDE=""
FORCE_REGISTER=""; FORCE_OPTIN=""; FORCE_ENV=""
FORCED_RPC=""; RPC_LIST_CLI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_RAW="$2"; shift 2 ;;
    --repo) OP_REPO_URL="$2"; shift 2 ;;
    --ip) MANUAL_IP="$2"; shift 2 ;;
    --trap) TRAP_OVERRIDE="$2"; shift 2 ;;
    --eth-amount) ETH_AMOUNT="$2"; shift 2 ;;
    --force-register) FORCE_REGISTER=1; shift ;;
    --force-optin) FORCE_OPTIN=1; shift ;;
    --force-env) FORCE_ENV=1; shift ;;
    --rpc) FORCED_RPC="$2"; shift 2 ;;
    --rpc-list) RPC_LIST_CLI="$2"; shift 2 ;;
    --no-ask-rpc) ASK_RPC_ON_FAIL=0; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# =================== Helpers ===================
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
  if [[ -f drosera_apply.log ]]; then
    addr=$(awk 'BEGIN{IGNORECASE=1}
      /Created Trap Config for|Updated Trap Config for/ {seen=1}
      seen && /- +address: *0x[0-9a-fA-F]{40}/{
        for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print tolower($i)}
      }' drosera_apply.log | awk '!/^0x0{40}$/' | tail -n1) || true
  fi
  if [[ -z "$addr" && -f drosera.log ]]; then
    addr=$(awk 'BEGIN{IGNORECASE=1}
      /Created Trap Config for|Updated Trap Config for/ {seen=1}
      seen && /- +address: *0x[0-9a-fA-F]{40}/{
        for(i=1;i<=NF;i++) if($i ~ /^0x[0-9a-fA-F]{40}$/){print tolower($i)}
      }' drosera.log | awk '!/^0x0{40}$/' | tail -n1) || true
  fi
  if [[ -z "$addr" ]]; then
    addr=$(last_nonzero_address_from drosera_apply.log drosera.log) || true
  fi
  if [[ -z "$addr" && -f drosera.toml ]]; then
    addr=$(grep -Eoi 'address\s*=\s*"0x[0-9a-fA-F]{40}"' drosera.toml | grep -Eoi '0x[0-9a-fA-F]{40}' | tr 'A-Z' 'a-z' | awk '!/^0x0{40}$/' | tail -n1) || true
  fi
  [[ -n "$addr" ]] && echo "$addr"
}

# =================== System prep ===================
msg "Dọn khóa APT & cập nhật..."
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq unzip lz4 build-essential pkg-config \
  libssl-dev libleveldb-dev gnupg lsb-release dnsutils iproute2 expect

# Docker & Compose
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
msg "Đảm bảo Docker Compose v2..."
ensure_compose

# =================== Toolchain ===================
msg "Cài Bun..."
curl -fsSL https://bun.sh/install | bash
add_path_once 'export PATH=$PATH:/root/.bun/bin'

msg "Cài Foundry..."
curl -fsSL https://foundry.paradigm.xyz | bash
add_path_once 'export PATH=$PATH:/root/.foundry/bin'
/root/.foundry/bin/foundryup
forge --version
cast --version

# =================== Wallet & PK sanitize ===================
if [[ -z "${PK_RAW:-}" ]]; then read -rsp "Private key (64 hex, có/không 0x): " PK_RAW; echo; fi
PK_RAW="$(echo -n "$PK_RAW" | tr -d '[:space:]\r\n' )"
PK_RAW="${PK_RAW#0x}"
if [[ ! "$PK_RAW" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Private key không hợp lệ (cần 64 hex)."; exit 1
fi
PK_NO0X="$(echo -n "$PK_RAW" | tr 'A-F' 'a-f')"
PK_0X="0x$PK_NO0X"

ADDR=$(cast wallet address --private-key "0x$PK_NO0X")
msg "Địa chỉ ví: $ADDR"

# =================== State load/save ===================
STATE_EVM=""; STATE_TRAP=""; STATE_IPV4=""; STATE_BLOOM="0"; STATE_REG="0"; STATE_OPTIN="0"
load_state(){
  [[ -f "$STATE_JSON" ]] || return 0
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

load_state || true

# =================== Prepare Trap Project ===================
msg "Chuẩn bị $TRAP_DIR ..."
ensure_git_identity
mkdir -p "$TRAP_DIR"
cd "$TRAP_DIR"

if [[ ! -f "foundry.toml" ]]; then
  forge init -t drosera-network/trap-foundry-template
fi

# build deps
bun install || true
forge build || true

# drosera.toml minimal edits: drosera_rpc + whitelist
[[ -f drosera.toml ]] || touch drosera.toml
cp -f drosera.toml drosera.toml.bak 2>/dev/null || true

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

# =================== Chọn RPC trước khi apply/opt-in ===================
mapfile -t _RPC_CANDIDATES < <(build_rpc_candidates)
SELECTED_RPC="$(choose_working_rpc "${_RPC_CANDIDATES[@]}")" || {
  warn "Không tìm được RPC hoạt động và --no-ask-rpc đang bật. Thoát."
  exit 1
}
BACKUP_RPC=""
for candidate in "${_RPC_CANDIDATES[@]}"; do
  [[ "$candidate" == "$SELECTED_RPC" ]] && continue
  if probe_rpc "$candidate"; then
    BACKUP_RPC="$candidate"
    break
  fi
done

# Ghi đè biến môi trường dùng xuyên suốt
export HOODI_RPC="$SELECTED_RPC"
export ETH_RPC_URL="$SELECTED_RPC"
export BACKUP_HOODI_RPC="${BACKUP_RPC:-$SELECTED_RPC}"
export ETH_BACKUP_RPC_URL="${BACKUP_HOODI_RPC}"

msg "RPC đã chọn: $HOODI_RPC"
[[ -n "$BACKUP_HOODI_RPC" && "$BACKUP_HOODI_RPC" != "$HOODI_RPC" ]] && msg "RPC dự phòng: $BACKUP_HOODI_RPC"

# =================== droseraup (installer) with robust fallback ===================
install_droseraup(){
  local tmp=/tmp/drosera_install.sh
  msg "Tải installer: https://app.drosera.io/install"
  if curl -fsSL https://app.drosera.io/install -o "$tmp"; then
    bash "$tmp"
  else
    warn "app.drosera.io bị 403 hoặc lỗi mạng → dùng GitHub Raw fallback."
    curl -fsSL "https://raw.githubusercontent.com/drosera-network/releases/main/droseraup/install" -o "$tmp"
    bash "$tmp"
  fi
}
msg "Cài droseraup..."
install_droseraup

# PATH cho drosera (NHƯNG KHÔNG override DROSERA_BIN đã khóa)
add_path_once "export PATH=\$PATH:$DRO_BIN_DIR"
hash -r || true

# Lấy/đổi drosera bằng droseraup (giữ nguyên bản do installer chọn; ưu tiên binary trong $DRO_BIN_DIR)
if command -v droseraup >/dev/null 2>&1; then
  droseraup || true
fi

# KHÓA: luôn dùng $DROSERA_BIN (tuyệt đối). Nếu thiếu thì mới fallback command -v (kèm kiểm tra subcommand apply)
if [[ ! -x "$DROSERA_BIN" ]]; then
  if command -v drosera >/dev/null 2>&1; then
    CAND="$(command -v drosera)"
    if "$CAND" --help 2>&1 | grep -qE '^\s*apply\b'; then
      DROSERA_BIN="$CAND"
    fi
  fi
fi
[[ -x "$DROSERA_BIN" ]] || { echo "Không tìm thấy drosera binary tại $DROSERA_BIN"; exit 1; }
"$DROSERA_BIN" --version || true

# =================== Apply (create/update trap config) ===================
APPLY_OK=0
NI_APPLY=""
if "$DROSERA_BIN" apply --help 2>&1 | grep -q -- '--non-interactive'; then NI_APPLY="--non-interactive"; fi
HAS_PK_FLAG=0
if "$DROSERA_BIN" apply --help 2>&1 | grep -q -- '--private-key'; then HAS_PK_FLAG=1; fi

msg "drosera apply ..."
{
  echo "[INFO] TRY apply (env PK without 0x) ..."
  DROSERA_PRIVATE_KEY="$PK_NO0X" "$DROSERA_BIN" apply $NI_APPLY --eth-rpc-url "$HOODI_RPC" --drosera-rpc-url "$DROSERA_RELAY_RPC" --eth-chain-id "$CHAIN_ID" --drosera-address "$DROSERA_ADDRESS"
} 2>&1 | tee drosera_apply.log && APPLY_OK=1 || true

if [[ "$APPLY_OK" -ne 1 ]]; then
  echo "[INFO] TRY apply (env PK with 0x) ..."
  DROSERA_PRIVATE_KEY="$PK_0X" "$DROSERA_BIN" apply $NI_APPLY --eth-rpc-url "$HOODI_RPC" --drosera-rpc-url "$DROSERA_RELAY_RPC" --eth-chain-id "$CHAIN_ID" --drosera-address "$DROSERA_ADDRESS" \
    2>&1 | tee -a drosera_apply.log && APPLY_OK=1 || true
fi

if [[ "$APPLY_OK" -ne 1 && "$HAS_PK_FLAG" -eq 1 ]]; then
  echo "[INFO] TRY apply (flag PK without 0x) ..."
  "$DROSERA_BIN" apply $NI_APPLY --private-key "$PK_NO0X" --eth-rpc-url "$HOODI_RPC" --drosera-rpc-url "$DROSERA_RELAY_RPC" --eth-chain-id "$CHAIN_ID" --drosera-address "$DROSERA_ADDRESS" \
    2>&1 | tee -a drosera_apply.log && APPLY_OK=1 || true
fi

if [[ "$APPLY_OK" -ne 1 && "$HAS_PK_FLAG" -eq 1 ]]; then
  echo "[INFO] TRY apply (flag PK with 0x) ..."
  "$DROSERA_BIN" apply $NI_APPLY --private-key "$PK_0X" --eth-rpc-url "$HOODI_RPC" --drosera-rpc-url "$DROSERA_RELAY_RPC" --eth-chain-id "$CHAIN_ID" --drosera-address "$DROSERA_ADDRESS" \
    2>&1 | tee -a drosera_apply.log && APPLY_OK=1 || true
fi

if [[ "$APPLY_OK" -ne 1 && -z "$NI_APPLY" ]]; then
  echo "[INFO] TRY apply (ENV+expect with ofc) ..."
  /usr/bin/env \
    DROSERA_PRIVATE_KEY="$PK_NO0X" \
    HOODI_RPC="$HOODI_RPC" \
    DROSERA_RELAY_RPC="$DROSERA_RELAY_RPC" \
    CHAIN_ID="$CHAIN_ID" \
    DROSERA_ADDRESS="$DROSERA_ADDRESS" \
    /usr/bin/env expect <<'EOF' 2>&1 | tee -a drosera_apply.log || true
set timeout 300
set drosera_bin [exec bash -lc "if [ -x /root/.drosera/bin/drosera ]; then printf /root/.drosera/bin/drosera; else command -v drosera; fi"]
spawn -noecho $drosera_bin apply --eth-rpc-url "$env(HOODI_RPC)" --drosera-rpc-url "$env(DROSERA_RELAY_RPC)" --eth-chain-id "$env(CHAIN_ID)" --drosera-address "$env(DROSERA_ADDRESS)"
expect {
  -re {Do you want to .* \[ofc/N\]:} {send -- "ofc\r"}
  eof {}
}
expect eof
EOF
  APPLY_OK=1 || true
fi

if [[ "$APPLY_OK" -ne 1 ]]; then
  warn "Apply thất bại."
fi

# =================== Resolve Trap Address ===================
TRAP_ADDR=""
if [[ -n "$TRAP_OVERRIDE" ]]; then
  TRAP_ADDR="$(echo "$TRAP_OVERRIDE" | tr 'A-Z' 'a-z')"
fi
if [[ -z "$TRAP_ADDR" ]]; then TRAP_ADDR="$(extract_trap_address || true)"; fi

if [[ ! "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ || "$TRAP_ADDR" =~ ^0x0{40}$ ]]; then
  warn "Không trích được trapAddress tự động."
fi
TRAP_ADDR="$(echo -n "$TRAP_ADDR" | tr 'A-Z' 'a-z')"
msg "trapAddress: ${TRAP_ADDR:-<chưa xác định>}"

# Lưu state sớm
save_state "$ADDR" "${TRAP_ADDR:-}" "${STATE_IPV4:-}" "${STATE_BLOOM:-0}" "${STATE_REG:-0}" "${STATE_OPTIN:-0}"

if [[ "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  msg "Đợi contract tại $TRAP_ADDR deploy xong (tối đa ${WAIT_CODE_SECS}s)..."
  if [[ "$(wait_code_deployed "$TRAP_ADDR" "$HOODI_RPC" "$WAIT_CODE_SECS")" != "ok" ]]; then
    warn "Timeout chờ bytecode; vẫn tiếp tục."
  fi
fi

# =================== Bloomboost (deposit ETH) ===================
BLOOMBOOST_OK="${STATE_BLOOM:-0}"
if [[ "$BLOOMBOOST_OK" -ne 1 && "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  msg "Bloomboost ${ETH_AMOUNT} ETH ..."
  NI_BB=""
  if "$DROSERA_BIN" bloomboost --help 2>&1 | grep -q -- '--non-interactive'; then NI_BB="--non-interactive"; fi

  BB_OK=0
  if [[ -n "$NI_BB" ]]; then
    DROSERA_PRIVATE_KEY="$PK_NO0X" "$DROSERA_BIN" bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT" $NI_BB && BB_OK=1 || true
    if [[ "$BB_OK" -ne 1 ]]; then
      DROSERA_PRIVATE_KEY="$PK_0X" "$DROSERA_BIN" bloomboost --trap-address "$TRAP_ADDR" --eth-amount "$ETH_AMOUNT" $NI_BB && BB_OK=1 || true
    fi
  fi
  if [[ "$BB_OK" -ne 1 ]]; then
    /usr/bin/env \
      DROSERA_PRIVATE_KEY="$PK_NO0X" \
      TRAP_ADDR="$TRAP_ADDR" \
      ETH_AMOUNT="$ETH_AMOUNT" \
      /usr/bin/env expect <<'EOF' || true
set timeout 180
set drosera_bin [exec bash -lc "if [ -x /root/.drosera/bin/drosera ]; then printf /root/.drosera/bin/drosera; else command -v drosera; fi"]
set trap "$env(TRAP_ADDR)"
set amt "$env(ETH_AMOUNT)"
spawn -noecho $drosera_bin bloomboost --trap-address "$trap" --eth-amount "$amt"
expect {
  -re {Do you want to boost this trap\? \[ofc/N\]:} {send -- "ofc\r"}
  eof {}
}
expect eof
EOF
    BB_OK=1 || true
  fi

  if [[ "$BB_OK" -eq 1 ]]; then
    set_state_flag "bloomboost_ok" 1
    BLOOMBOOST_OK=1
  else
    warn "Bloomboost thất bại."
  fi
else
  [[ "$BLOOMBOOST_OK" -eq 1 ]] && msg "Bloomboost đã OK trước đó → bỏ qua."
fi

# =================== Operator repo & env ===================
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

# IPv4
IPV4=""
if [[ -n "$MANUAL_IP" ]]; then
  IPV4="$MANUAL_IP"
elif [[ -n "${STATE_IPV4:-}" && -z "$FORCE_ENV" ]]; then
  IPV4="$STATE_IPV4"
else
  IPV4=$(get_public_ipv4 || true)
fi
if ! is_public_ipv4 "$IPV4"; then
  warn "Không lấy được IPv4 công khai tự động. Dùng --ip <IPv4> hoặc giữ .env hiện có."
  if [[ -f .env && -z "$FORCE_ENV" ]]; then
    IPV4=$(grep -E '^VPS_IP=' .env | cut -d= -f2-)
  else
    IPV4="0.0.0.0"
  fi
fi
msg "IPv4: $IPV4"

# .env
if [[ -f .env && -z "$FORCE_ENV" ]]; then
  grep -q '^ETH_PRIVATE_KEY=' .env || echo "ETH_PRIVATE_KEY=$PK_0X" >> .env
  grep -q '^VPS_IP=' .env || echo "VPS_IP=$IPV4" >> .env
else
  cat > .env <<EOF
ETH_PRIVATE_KEY=$PK_0X
VPS_IP=$IPV4
EOF
  chmod 600 .env
fi
save_state "$ADDR" "${TRAP_ADDR:-}" "$IPV4" "$BLOOMBOOST_OK" "${STATE_REG:-0}" "${STATE_OPTIN:-0}"

# docker-compose.yaml (ghi đè chuẩn, pin image, dùng primary/backup)
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
      - DRO__ETH__RPC_URL=${ETH_RPC_URL:-${HOODI_RPC}}
      - DRO__ETH__BACKUP_RPC_URL=${ETH_BACKUP_RPC_URL:-${BACKUP_HOODI_RPC:-${HOODI_RPC}}}
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

compose -f docker-compose.yaml config >/dev/null
msg "docker compose up -d ..."
compose -f docker-compose.yaml up -d || { warn "compose up thất bại, retry sau ${RETRY_DELAY}s"; sleep "$RETRY_DELAY"; compose -f docker-compose.yaml up -d || warn "compose vẫn lỗi, tiếp tục."; }

# =================== Register & Opt-in ===================
REGISTER_OK="${STATE_REG:-0}"
OPTIN_OK="${STATE_OPTIN:-0}"

# Helper phát hiện 403/Cloudflare trong log
is_rpc_403() {
  grep -qiE 'HTTP error 403|Attention Required|You are unable to access|Cloudflare' <<<"${1:-}"
}

if [[ "$REGISTER_OK" -ne 1 || -n "$FORCE_REGISTER" ]]; then
  msg "Đăng ký operator (register)..."
  HAS_OP_PK_FLAG=0
  docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 register --help 2>&1 | grep -q -- '--eth-private-key' && HAS_OP_PK_FLAG=1 || true

  reg_tmp="$(mktemp)"
  if [[ "$HAS_OP_PK_FLAG" -eq 1 ]]; then
    set +e
    docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 \
      register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" \
               --drosera-address "$DROSERA_ADDRESS" \
               --eth-private-key "$PK_0X" \
      >"$reg_tmp" 2>&1
    rc=$?
    set -e
  else
    set +e
    docker run --rm -e DRO__ETH__PRIVATE_KEY="$PK_0X" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
      register --eth-chain-id "$CHAIN_ID" --eth-rpc-url "$HOODI_RPC" --drosera-address "$DROSERA_ADDRESS" \
      >"$reg_tmp" 2>&1
    rc=$?
    set -e
  fi
  out="$(cat "$reg_tmp")"; rm -f "$reg_tmp"

  if [[ "$rc" -eq 0 ]] || grep -q 'OperatorAlreadyRegistered' <<<"$out"; then
    REGISTER_OK=1; set_state_flag "register_ok" 1
  else
    warn "Register thất bại."; echo "$out" >&2
  fi
else
  msg "Register đã OK trước đó → bỏ qua."
fi

if [[ "$OPTIN_OK" -ne 1 || -n "$FORCE_OPTIN" ]]; then
  if [[ "$TRAP_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    msg "Opt-in operator ..."
    HAS_OP_PK_FLAG=0
    docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 optin --help 2>&1 | grep -q -- '--eth-private-key' && HAS_OP_PK_FLAG=1 || true

    run_optin() {
      local rpc="$1" tmp rc
      tmp="$(mktemp)"
      if [[ "$HAS_OP_PK_FLAG" -eq 1 ]]; then
        set +e
        docker run --rm ghcr.io/drosera-network/drosera-operator:v1.20.0 \
          optin --eth-rpc-url "$rpc" \
                --trap-config-address "$TRAP_ADDR" \
                --eth-private-key "$PK_0X" \
          >"$tmp" 2>&1
        rc=$?
        set -e
      else
        set +e
        docker run --rm -e DRO__ETH__PRIVATE_KEY="$PK_0X" ghcr.io/drosera-network/drosera-operator:v1.20.0 \
          optin --eth-rpc-url "$rpc" --trap-config-address "$TRAP_ADDR" \
          >"$tmp" 2>&1
        rc=$?
        set -e
      fi
      OUT_CONTENT="$(cat "$tmp")"
      rm -f "$tmp"
      return "$rc"
    }

    # Try primary
    if run_optin "$HOODI_RPC"; then
      out="$OUT_CONTENT"; rc=0
    else
      out="$OUT_CONTENT"; rc=$?
      # Nếu 403 → thử backup
      if [[ "$rc" -ne 0 && -n "${BACKUP_HOODI_RPC:-}" && "$BACKUP_HOODI_RPC" != "$HOODI_RPC" ]] && is_rpc_403 "$out"; then
        warn "RPC primary bị 403 → thử backup"
        if run_optin "$BACKUP_HOODI_RPC"; then
          out="$OUT_CONTENT"; rc=0
        else
          out="$OUT_CONTENT"; rc=$?
        fi
      fi
    fi

    if [[ "$rc" -eq 0 ]]; then
      OPTIN_OK=1; set_state_flag "optin_ok" 1
    else
      warn "Opt-in thất bại."; echo "$out" >&2
    fi
  else
    warn "Không có trapAddress hợp lệ → bỏ qua opt-in."
  fi
else
  msg "Opt-in đã OK trước đó → bỏ qua."
fi

# =================== Final Summary ===================
load_state || true
BLOOM="${STATE_BLOOM:-$BLOOMBOOST_OK}"
REG="${STATE_REG:-$REGISTER_OK}"
OPT="${STATE_OPTIN:-$OPTIN_OK}"
IPV4_SAVE="${STATE_IPV4:-$IPV4}"
TRAP_SAVE="${STATE_TRAP:-$TRAP_ADDR}"

save_state "$ADDR" "${TRAP_SAVE:-}" "$IPV4_SAVE" "$BLOOM" "$REG" "$OPT"

cat >"$SUMMARY_JSON" <<JSON
{
  "timestamp": "$(date --iso-8601=seconds)",
  "evm_address": "$ADDR",
  "trap_address": "${TRAP_SAVE:-}",
  "chain_id": $CHAIN_ID,
  "hoodi_rpc": "$HOODI_RPC",
  "drosera_relay_rpc": "$DROSERA_RELAY_RPC",
  "drosera_address": "$DROSERA_ADDRESS",
  "bloomboost_eth": "$ETH_AMOUNT",
  "bloomboost_ok": $BLOOM,
  "register_ok": $REG,
  "optin_ok": $OPT,
  "operator_image": "ghcr.io/drosera-network/drosera-operator:v1.20.0",
  "operator_container": "drosera-operator",
  "vps_ipv4": "$IPV4_SAVE",
  "logs": "$LOG"
}
JSON

msg "HOÀN TẤT."
msg "Summary JSON: $SUMMARY_JSON"
msg "State JSON  : $STATE_JSON"
msg "Log đầy đủ  : $LOG"
