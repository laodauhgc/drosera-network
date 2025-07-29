#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
#  Drosera One-Click (aligned with original)
#  v1.3.1 (fix 429 & PS1, resilient installer)
# =========================================

# ---- PATH (giống script gốc, KHÔNG source .bashrc) ----
export PATH="$PATH:/root/.drosera/bin:/root/.bun/bin:/root/.foundry/bin"

# ---- Config mặc định (có thể override bằng ENV) ----
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
NET_DIR="${NET_DIR:-/root/drosera-network}"
ENV_FILE="$NET_DIR/.env"
LOG_DIR="/var/log/drosera"; mkdir -p "$LOG_DIR"
APPLY_LOG="$LOG_DIR/apply.log"
OPTIN_LOG="$LOG_DIR/optin.log"
REG_LOG="$LOG_DIR/register.log"
INSTALL_LOG="$LOG_DIR/install.log"
TRAP_SCAN_LOG="$LOG_DIR/trap_scan.log"

TEMPLATE_REPO="${TEMPLATE_REPO:-drosera-network/trap-foundry-template}"
OP_IMAGE="${OP_IMAGE:-ghcr.io/drosera-network/drosera-operator:v1.20.0}"

P2P_TCP="${P2P_TCP:-31313}"
P2P_UDP="${P2P_UDP:-31313}"

ETH_CHAIN_ID="${ETH_CHAIN_ID:-}"     # ví dụ 560048
ETH_RPC_URL="${ETH_RPC_URL:-}"       # ví dụ https://0xrpc.io/hoodi
DROSERA_ADDR="${DROSERA_ADDR:-}"     # ví dụ 0x91cB447BaF...

DO_BLOOMBOOST="${DO_BLOOMBOOST:-0}"
BLOOM_ETH_AMT="${BLOOM_ETH_AMT:-}"

AUTO=0
RUN_OPTIN=1

ts(){ date +"%Y-%m-%dT%H:%M:%S%z"; }
ok(){ echo -e "$(ts)  $*"; }
warn(){ echo -e "$(ts)  \e[33mWARNING:\e[0m $*"; }
err(){ echo -e "$(ts)  \e[31mERROR:\e[0m $*"; }

require_root(){ if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Hãy chạy bằng root."; exit 1; fi; }

usage(){
  cat <<USAGE
Usage:
  $0 --pk <hex> [--auto] [--no-optin] [--bloom <eth>] [--image <ref>]

Options:
  --pk <hex>       Private key (64 hex, có/không '0x').
  --auto           Chạy full tự động (install + trap + apply + [.env] + operator + register + opt-in).
  --no-optin       Bỏ qua opt-in operator vào trap.
  --bloom <eth>    drosera bloomboost với số ETH (vd: 0.01).
  --image <ref>    Đổi operator image (mặc định: $OP_IMAGE).
  --help           Trợ giúp.

ENV hữu ích:
  TEMPLATE_REPO=drosera-network/trap-foundry-template
  NET_DIR=/root/drosera-network
  ETH_CHAIN_ID=...   ETH_RPC_URL=...   DROSERA_ADDR=...
USAGE
}

# ---- Parse args ----
PK_HEX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_HEX="${2:-}"; shift 2;;
    --auto) AUTO=1; shift;;
    --no-optin) RUN_OPTIN=0; shift;;
    --bloom) DO_BLOOMBOOST=1; BLOOM_ETH_AMT="${2:-}"; shift 2;;
    --image) OP_IMAGE="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

require_root

apt_quiet(){
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1
}
apt_install(){
  apt_quiet update || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1 || true
}

get_public_ip(){
  local ip=""
  ip="$(curl -4fsSL https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -4fsSL ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)"
  echo -n "$ip"
}

sanitize_pk(){
  local pk="$1"
  pk="${pk#0x}"
  if [[ ! "$pk" =~ ^[0-9a-fA-F]{64}$ ]]; then
    err "Private key không đúng định dạng 64 hex."
    exit 1
  fi
  echo -n "$pk"
}

ensure_deps(){
  ok "Updating apt & installing base packages..."
  apt_install curl ca-certificates gnupg lsb-release jq git unzip make build-essential pkg-config libssl-dev clang cmake
}

ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    ok "Installing Docker..."
    apt_install apt-transport-https software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null 2>&1 || true
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >>"$INSTALL_LOG" 2>&1 || true
    apt_install docker-ce docker-ce-cli containerd.io
  else
    ok "Docker already installed. Skipping re-install."
  fi
  systemctl enable --now docker >>"$INSTALL_LOG" 2>&1 || true
}

ensure_compose(){
  if docker compose version >/dev/null 2>&1; then
    : # plugin OK
  elif command -v docker-compose >/dev/null 2>&1; then
    : # standalone OK
  else
    ok "Installing docker-compose..."
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}

ensure_bun(){
  if ! command -v bun >/dev/null 2>&1; then
    ok "Installing Bun..."
    curl -fsSL https://bun.sh/install | bash >>"$INSTALL_LOG" 2>&1 || true
    # KHÔNG source .bashrc; chỉ export tức thời & ghi thêm để lần sau tự có
    export PATH="$PATH:/root/.bun/bin"
    grep -q '/root/.bun/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.bun/bin' >> /root/.bashrc
  fi
}

ensure_foundry(){
  if ! command -v forge >/dev/null 2>&1; then
    ok "Installing Foundry..."
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$INSTALL_LOG" 2>&1 || true
    [[ -x /root/.foundry/bin/foundryup ]] && /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.foundry/bin"
    grep -q '/root/.foundry/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.foundry/bin' >> /root/.bashrc
  else
    /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true
  fi
}

ensure_drosera_cli(){
  # CÀI QUA app.drosera.io/install với retry/backoff, KHÔNG source .bashrc
  if ! command -v drosera >/dev/null 2>&1; then
    ok "Installing Drosera CLI from app.drosera.io..."
    local tmp="/tmp/drosera_install.sh"
    local max=10
    local attempt=1
    while (( attempt <= max )); do
      rm -f "$tmp"
      set +e
      curl -fsSL https://app.drosera.io/install -o "$tmp"
      local rc=$?
      set -e
      if [[ $rc -eq 0 && -s "$tmp" ]]; then
        bash "$tmp" >>"$INSTALL_LOG" 2>&1 || true
        break
      fi
      # 429 hoặc các lỗi HTTP → rc có thể = 22; xử lý như rate-limit
      local sleep_s=$(( 2 ** (attempt-1) ))
      local jitter=$(( RANDOM % 5 ))
      sleep_s=$(( sleep_s + jitter ))
      warn "Drosera installer download failed (rc=$rc), retry $attempt/$max after ${sleep_s}s..."
      sleep "$sleep_s"
      attempt=$((attempt+1))
    done
    # droseraup nếu có
    if command -v droseraup >/dev/null 2>&1; then
      droseraup >>"$INSTALL_LOG" 2>&1 || true
    fi
    export PATH="$PATH:/root/.drosera/bin"
    grep -q '/root/.drosera/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
  else
    # Đã có drosera → cập nhật
    if command -v droseraup >/dev/null 2>&1; then
      droseraup >>"$INSTALL_LOG" 2>&1 || true
    fi
  fi

  if ! command -v drosera >/dev/null 2>&1; then
    err "Không tìm thấy 'drosera' sau khi cài (có thể bị rate-limit quá lâu). Xem $INSTALL_LOG"; exit 1
  fi
  # Xác nhận có 'apply'
  if drosera --help 2>&1 | grep -qE '\bapply\b'; then
    ok "Drosera CLI sẵn sàng (có 'apply')."
  else
    warn "Drosera CLI chưa có 'apply'. Thử chạy droseraup thêm lần nữa..."
    command -v droseraup >/dev/null 2>&1 && droseraup >>"$INSTALL_LOG" 2>&1 || true
    if ! drosera --help 2>&1 | grep -qE '\bapply\b'; then
      err "Drosera CLI vẫn thiếu 'apply'. Hãy chạy lại sau ít phút khi server installer hết rate-limit."
      exit 1
    fi
  fi
}

evm_address_from_pk(){
  local pk="$1"; local addr=""
  addr="$(cast wallet address --private-key "0x$pk" 2>/dev/null || true)"
  echo -n "$addr"
}

init_trap_project(){
  ok "Preparing trap project at $TRAP_DIR ..."
  if [[ ! -d "$TRAP_DIR" ]]; then
    mkdir -p "$TRAP_DIR"
    pushd "$TRAP_DIR" >/dev/null
    forge init -t "$TEMPLATE_REPO" >>"$INSTALL_LOG" 2>&1 || true
    popd >/dev/null
  fi
  pushd "$TRAP_DIR" >/dev/null
  bun install >>"$INSTALL_LOG" 2>&1 || true
  forge build >>"$INSTALL_LOG" 2>&1 || true
  popd >/dev/null
}

ensure_whitelist(){
  local addr="$1"; local toml="$TRAP_DIR/drosera.toml"
  if [[ ! -f "$toml" ]]; then
    err "Không tìm thấy $toml — kiểm tra cài đặt Drosera/template."; exit 1
  fi
  cp -f "$toml" "${toml}.bak" || true
  if grep -q '^whitelist = ' "$toml"; then
    sed -i 's|^whitelist = .*|whitelist = ["'"$addr"'"]|' "$toml"
  else
    if grep -q '^\[traps\.mytrap\]' "$toml"; then
      awk -v addr="$addr" '
        BEGIN{printed=0}
        {print}
        /^\[traps\.mytrap\]/{print; getline; print "whitelist = [\"" addr "\"]"; printed=1}
        END{if(!printed) print "whitelist = [\"" addr "\"]"}
      ' "$toml" > "${toml}.tmp" && mv "${toml}.tmp" "$toml"
    else
      echo "whitelist = [\"$addr\"]" >> "$toml"
    fi
  fi
  ok "Wrote whitelist = [$addr] to drosera.toml"
}

run_apply_and_get_trap(){
  : >"$APPLY_LOG"
  pushd "$TRAP_DIR" >/dev/null
  export DROSERA_PRIVATE_KEY="$1"   # KHÔNG 0x (theo script gốc)
  ok 'Running: echo "ofc" | drosera apply'
  if echo "ofc" | drosera apply >>"$APPLY_LOG" 2>&1; then
    ok "drosera apply completed."
  else
    err "drosera apply thất bại. Xem $APPLY_LOG"; popd >/dev/null; exit 1
  fi
  local trap=""
  if [[ -f "$TRAP_DIR/drosera.log" ]]; then
    trap="$(grep -oE 'trapAddress: 0x[a-fA-F0-9]{40}' "$TRAP_DIR/drosera.log" | awk '{print $2}' | tail -1 || true)"
  fi
  [[ -z "$trap" ]] && trap="$(grep -oE '0x[a-fA-F0-9]{40}' "$APPLY_LOG" | tail -1 || true)"
  echo -n "$trap" > "$TRAP_SCAN_LOG"
  popd >/dev/null
  echo -n "$trap"
}

maybe_bloomboost(){
  [[ "$DO_BLOOMBOOST" != "1" ]] && return 0
  [[ -z "$BLOOM_ETH_AMT" ]] && { warn "Bỏ qua bloomboost vì thiếu --bloom <eth>"; return 0; }
  local trap="$1" ; local pk_no0x="$2"
  pushd "$TRAP_DIR" >/dev/null
  export DROSERA_PRIVATE_KEY="$pk_no0x"
  ok "Running bloomboost: drosera bloomboost --trap-address $trap --eth-amount $BLOOM_ETH_AMT"
  if drosera bloomboost --trap-address "$trap" --eth-amount "$BLOOM_ETH_AMT" >>"$LOG_DIR/bloomboost.log" 2>&1; then
    ok "bloomboost success."
  else
    warn "bloomboost thất bại — kiểm tra số dư/ mạng. Log: $LOG_DIR/bloomboost.log"
  fi
  popd >/dev/null
}

prepare_network_repo(){
  if [[ ! -d "$NET_DIR/.git" ]]; then
    ok "Cloning drosera-network repo..."
    git clone https://github.com/laodauhgc/drosera-network.git "$NET_DIR" >>"$INSTALL_LOG" 2>&1 || true
  fi
  mkdir -p "$NET_DIR"
  local ip; ip="$(get_public_ip)"
  [[ -z "$ip" ]] && { warn "Không lấy được public IP."; ip="0.0.0.0"; }

  local udp_maddr="/ip4/${ip}/udp/${P2P_UDP}/quic-v1"
  local tcp_maddr="/ip4/${ip}/tcp/${P2P_TCP}"

  touch "$ENV_FILE"
  if grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE"; then
    sed -i 's|^ETH_PRIVATE_KEY=.*|ETH_PRIVATE_KEY=0x'"$PK_HEX"'|' "$ENV_FILE"
  else
    echo "ETH_PRIVATE_KEY=0x$PK_HEX" >> "$ENV_FILE"
  fi
  if grep -q '^VPS_IP=' "$ENV_FILE"; then
    sed -i 's|^VPS_IP=.*|VPS_IP='"$ip"'|' "$ENV_FILE"
  else
    echo "VPS_IP=$ip" >> "$ENV_FILE"
  fi
  if grep -q '^EXTERNAL_P2P_MADDR=' "$ENV_FILE"; then
    sed -i 's|^EXTERNAL_P2P_MADDR=.*|EXTERNAL_P2P_MADDR='"$udp_maddr"'|' "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_MADDR=$udp_maddr" >> "$ENV_FILE"
  fi
  if grep -q '^EXTERNAL_P2P_TCP_MADDR=' "$ENV_FILE"; then
    sed -i 's|^EXTERNAL_P2P_TCP_MADDR=.*|EXTERNAL_P2P_TCP_MADDR='"$tcp_maddr"'|' "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_TCP_MADDR=$tcp_maddr" >> "$ENV_FILE"
  fi
  ok "Wrote .env with PK and P2P addrs at $ENV_FILE"
}

reset_and_run_operator(){
  ok "Resetting operator container..."
  docker rm -f drosera-operator >/dev/null 2>&1 || true
  docker volume rm -f drosera-network_drosera_data >/dev/null 2>&1 || true
  docker volume create drosera-network_drosera_data >/dev/null

  ok "Pulling operator image $OP_IMAGE..."
  docker pull "$OP_IMAGE" >>"$INSTALL_LOG" 2>&1 || true

  ok "Starting operator..."
  docker run -d \
    --name drosera-operator \
    --restart unless-stopped \
    -p "${P2P_TCP}:${P2P_TCP}/tcp" \
    -p "${P2P_UDP}:${P2P_UDP}/udp" \
    -v drosera-network_drosera_data:/data \
    --env-file "$ENV_FILE" \
    "$OP_IMAGE" >/dev/null

  for i in {1..36}; do
    if docker logs --since=20s drosera-operator 2>/dev/null | grep -q 'Operator Node successfully spawned'; then
      ok "Operator Node successfully spawned."
      return 0
    fi
    sleep 5
  done
  warn "Operator chưa in 'successfully spawned' sau 180s. Tiếp tục các bước sau."
  return 0
}

register_operator(){
  ok "Registering operator..."
  : >"$REG_LOG"
  set +e
  if [[ -n "$ETH_CHAIN_ID" || -n "$ETH_RPC_URL" || -n "$DROSERA_ADDR" ]]; then
    docker exec drosera-operator /bin/sh -lc \
      "drosera-operator register \
      ${ETH_CHAIN_ID:+--eth-chain-id $ETH_CHAIN_ID} \
      ${ETH_RPC_URL:+--eth-rpc-url $ETH_RPC_URL} \
      ${DROSERA_ADDR:+--drosera-address $DROSERA_ADDR}" >>"$REG_LOG" 2>&1
  else
    docker exec drosera-operator /bin/sh -lc 'drosera-operator register' >>"$REG_LOG" 2>&1
  fi
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'OperatorAlreadyRegistered' "$REG_LOG"; then
      ok "Operator already registered. Skip."
      return 0
    fi
    warn "Register error, retrying..."
    sleep 10
    set +e
    docker exec drosera-operator /bin/sh -lc 'drosera-operator register' >>"$REG_LOG" 2>&1
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      warn "Register still failing. See $REG_LOG"
    else
      ok "Register successful (retry)."
    fi
  else
    ok "Register successful."
  fi
}

optin_operator(){
  [[ "$RUN_OPTIN" != "1" ]] && { ok "Skip opt-in as requested."; return 0; }
  local trap="$1"
  if [[ -z "$trap" ]]; then
    warn "Không có trap address để opt-in."
    return 0
  fi
  : >"$OPTIN_LOG"
  ok "Opting in operator to trap: $trap"
  set +e
  if [[ -n "$ETH_RPC_URL" ]]; then
    docker exec drosera-operator /bin/sh -lc \
      "drosera-operator optin \
       --trap-config-address $trap \
       ${ETH_RPC_URL:+--eth-rpc-url $ETH_RPC_URL}" >>"$OPTIN_LOG" 2>&1
  else
    docker exec drosera-operator /bin/sh -lc \
      "drosera-operator optin --trap-config-address $trap" >>"$OPTIN_LOG" 2>&1
  fi
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'already opted' "$OPTIN_LOG"; then
      ok "Operator already opted in."
      return 0
    fi
    warn "Opt-in có thể lỗi. Xem $OPTIN_LOG"
  else
    ok "Opt-in done."
  fi
}

main(){
  ok "Starting..."
  ensure_deps
  ensure_docker
  ensure_compose
  ensure_bun
  ensure_foundry
  ensure_drosera_cli

  if [[ -z "$PK_HEX" ]]; then
    err "Thiếu --pk <hex>."; exit 2
  fi
  PK_HEX="$(sanitize_pk "$PK_HEX")"

  local EVM_ADDR; EVM_ADDR="$(evm_address_from_pk "$PK_HEX")"
  if [[ ! "$EVM_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    err "Không lấy được EVM address từ private key."; exit 1
  fi
  ok "EVM address: $EVM_ADDR"

  init_trap_project
  ensure_whitelist "$EVM_ADDR"

  local trap; trap="$(run_apply_and_get_trap "$PK_HEX")"
  if [[ -z "$trap" ]]; then
    warn "Không trích xuất được trapAddress từ log. Kiểm tra $TRAP_DIR/drosera.log hoặc $APPLY_LOG."
  else
    ok "Detected trapAddress: $trap"
  fi

  if [[ "$DO_BLOOMBOOST" == "1" && -n "${trap:-}" ]]; then
    maybe_bloomboost "$trap" "$PK_HEX"
  fi

  prepare_network_repo
  reset_and_run_operator
  register_operator
  if [[ -n "${trap:-}" ]]; then
    optin_operator "$trap"
  fi

  ok "Done."
}

main "$@"
