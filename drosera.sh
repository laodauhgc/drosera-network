#!/usr/bin/env bash
# Drosera AIO Installer (robust) - v1.5.1
set -Eeuo pipefail
: "${PS1:=# }"

export PATH="$PATH:/root/.drosera/bin:/root/.bun/bin:/root/.foundry/bin"

TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
NET_DIR="${NET_DIR:-/root/drosera-network}"
ENV_FILE="$NET_DIR/.env"

LOG_DIR="/var/log/drosera"; mkdir -p "$LOG_DIR"
INSTALL_LOG="$LOG_DIR/install.log"
APPLY_LOG="$LOG_DIR/apply.log"
OPTIN_LOG="$LOG_DIR/optin.log"
REG_LOG="$LOG_DIR/register.log"
TRAP_SCAN_LOG="$LOG_DIR/trap_scan.log"

TEMPLATE_REPO="${TEMPLATE_REPO:-drosera-network/trap-foundry-template}"
OP_IMAGE="${OP_IMAGE:-ghcr.io/drosera-network/drosera-operator:v1.20.0}"
DEFAULT_RPC_URL="${DEFAULT_RPC_URL:-https://0xrpc.io/hoodi}"

P2P_TCP="${P2P_TCP:-31313}"
P2P_UDP="${P2P_UDP:-31313}"

ETH_CHAIN_ID="${ETH_CHAIN_ID:-}"
ETH_RPC_URL="${ETH_RPC_URL:-}"     # dùng nếu bạn muốn ép register/optin dùng RPC riêng
DROSERA_ADDR="${DROSERA_ADDR:-}"

RUN_OPTIN=1
DO_BLOOMBOOST=0
BLOOM_ETH_AMT=""

ts(){ date +"%Y-%m-%dT%H:%M:%S%z"; }
ok(){ echo -e "$(ts)  $*"; }
warn(){ echo -e "$(ts)  \e[33mWARNING:\e[0m $*"; }
err(){ echo -e "$(ts)  \e[31mERROR:\e[0m $*"; }
require_root(){ if [[ ${EUID:-$(id -u)} -ne 0 ]]; then err "Hãy chạy bằng root."; exit 1; fi; }

usage(){ cat <<USAGE
Usage:
  $0 --pk <hex> [--auto] [--no-optin] [--bloom <eth>] [--image <ref>]
USAGE
}

PK_HEX=""; AUTO=0
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

sanitize_pk(){ local pk="${1#0x}"; [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]] || { err "Private key không hợp lệ"; exit 1; }; echo -n "$pk"; }
apt_quiet(){ DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1; }
apt_install(){ apt_quiet update || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1 || true; }
get_public_ip(){ local ip=""; ip="$(curl -4fsSL https://api.ipify.org || true)"; [[ -z "$ip" ]] && ip="$(curl -4fsSL ifconfig.me || true)"; [[ -z "$ip" ]] && ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)"; echo -n "$ip"; }
evm_address_from_pk(){ cast wallet address --private-key "0x$1" 2>/dev/null || true; }

ensure_deps(){ ok "Updating apt & installing base packages..."; apt_install curl ca-certificates gnupg lsb-release jq git unzip make build-essential pkg-config libssl-dev clang cmake dnsutils; }
ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    ok "Installing Docker..."; apt_install apt-transport-https software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null 2>&1 || true
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >>"$INSTALL_LOG" 2>&1 || true
    apt_install docker-ce docker-ce-cli containerd.io
  else ok "Docker already installed. Skipping re-install."; fi
  systemctl enable --now docker >>"$INSTALL_LOG" 2>&1 || true
}
ensure_compose(){
  if docker compose version >/dev/null 2>&1; then :; elif command -v docker-compose >/dev/null 2>&1; then :; else
    ok "Installing docker-compose..."
    curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
}
ensure_bun(){ command -v bun >/dev/null 2>&1 || { ok "Installing Bun..."; curl -fsSL https://bun.sh/install | bash >>"$INSTALL_LOG" 2>&1 || true; export PATH="$PATH:/root/.bun/bin"; grep -q '/root/.bun/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.bun/bin' >> /root/.bashrc; }; }
ensure_foundry(){
  if ! command -v forge >/dev/null 2>&1; then
    ok "Installing Foundry..."; curl -fsSL https://foundry.paradigm.xyz | bash >>"$INSTALL_LOG" 2>&1 || true
    [[ -x /root/.foundry/bin/foundryup ]] && /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.foundry/bin"; grep -q '/root/.foundry/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.foundry/bin' >> /root/.bashrc
  else /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true; fi
}
ensure_drosera_cli(){
  if ! command -v drosera >/dev/null 2>&1; then
    ok "Installing Drosera CLI from app.drosera.io..."
    local tmp="/tmp/drosera_install.sh" attempt=1 max=10
    while (( attempt<=max )); do
      rm -f "$tmp"; set +e; curl -fsSL https://app.drosera.io/install -o "$tmp"; rc=$?; set -e
      if [[ $rc -eq 0 && -s "$tmp" ]]; then bash "$tmp" >>"$INSTALL_LOG" 2>&1 || true; break; fi
      local sleep_s=$(( 2 ** (attempt-1) + RANDOM % 5 )); warn "Installer 429/failed, retry $attempt/$max after ${sleep_s}s..."; sleep "$sleep_s"; attempt=$((attempt+1))
    done
    command -v droseraup >/dev/null 2>&1 && droseraup >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.drosera/bin"; grep -q '/root/.drosera/bin' /root/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
  else command -v droseraup >/dev/null 2>&1 && droseraup >>"$INSTALL_LOG" 2>&1 || true; fi
  drosera --help 2>&1 | grep -qE '\bapply\b' || { err "CLI thiếu 'apply'. Thử lại sau ít phút (rate-limit)."; exit 1; }
  ok "Drosera CLI sẵn sàng (có 'apply')."
}

init_trap_project(){
  ok "Preparing trap project at $TRAP_DIR ..."
  local need_reinit=0
  [[ ! -d "$TRAP_DIR" ]] && need_reinit=1
  [[ -d "$TRAP_DIR" && ! -f "$TRAP_DIR/drosera.toml" ]] && need_reinit=1
  if (( need_reinit )); then
    if [[ -d "$TRAP_DIR" && $(ls -A "$TRAP_DIR" 2>/dev/null | wc -l) -gt 0 ]]; then
      local bak="${TRAP_DIR}.bak.$(date +%s)"; warn "Thư mục $TRAP_DIR tồn tại nhưng thiếu drosera.toml → backup: $bak"; mv "$TRAP_DIR" "$bak"
    fi
    rm -rf "$TRAP_DIR"
    if forge init -t "$TEMPLATE_REPO" "$TRAP_DIR" >>"$INSTALL_LOG" 2>&1; then
      ok "Initialized trap from template ($TEMPLATE_REPO)."
    else
      warn "forge init failed → fallback git clone"; git clone "https://github.com/${TEMPLATE_REPO}.git" "$TRAP_DIR" >>"$INSTALL_LOG" 2>&1 || true
    fi
  fi
  [[ -f "$TRAP_DIR/drosera.toml" ]] || { err "Không tìm thấy $TRAP_DIR/drosera.toml — kiểm tra cài đặt template."; exit 1; }
  ( cd "$TRAP_DIR"; bun install >>"$INSTALL_LOG" 2>&1 || true; forge build >>"$INSTALL_LOG" 2>&1 || true )
}

ensure_whitelist(){
  local addr="$1" toml="$TRAP_DIR/drosera.toml"
  cp -f "$toml" "${toml}.bak" || true
  if grep -q '^whitelist = ' "$toml"; then
    sed -i 's|^whitelist = .*|whitelist = ["'"$addr"'"]|' "$toml"
  elif grep -q '^\[traps\.mytrap\]' "$toml"; then
    awk -v addr="$addr" '
      BEGIN{done=0} {print}
      /^\[traps\.mytrap\]/{print; getline; print "whitelist = [\"" addr "\"]"; done=1}
      END{if(!done) print "whitelist = [\"" addr "\"]"}
    ' "$toml" > "${toml}.tmp" && mv "${toml}.tmp" "$toml"
  else echo "whitelist = [\"$addr\"]" >> "$toml"; fi
  ok "Wrote whitelist = [$addr] to drosera.toml"
}

run_apply_and_get_trap(){
  : >"$APPLY_LOG"
  pushd "$TRAP_DIR" >/dev/null
  export DROSERA_PRIVATE_KEY="$1"
  ok 'Running: echo "ofc" | drosera apply'
  if ! echo "ofc" | drosera apply >>"$APPLY_LOG" 2>&1; then err "drosera apply thất bại. Xem $APPLY_LOG"; popd >/dev/null; exit 1; fi
  # Lọc đúng 1 địa chỉ 0x...
  local trap=""
  [[ -f "$TRAP_DIR/drosera.log" ]] && trap="$(grep -aoE '0x[a-fA-F0-9]{40}' "$TRAP_DIR/drosera.log" | tail -1 || true)"
  [[ -z "$trap" ]] && trap="$(grep -aoE '0x[a-fA-F0-9]{40}' "$APPLY_LOG" | tail -1 || true)"
  trap="$(echo -n "$trap" | tr -d '\r\n' )"
  echo -n "$trap" > "$TRAP_SCAN_LOG"
  popd >/dev/null
  echo -n "$trap"
}

prepare_network_repo_and_env(){
  mkdir -p "$NET_DIR"
  [[ -d "$NET_DIR/.git" ]] || git clone https://github.com/laodauhgc/drosera-network.git "$NET_DIR" >>"$INSTALL_LOG" 2>&1 || true
  local ip; ip="$(get_public_ip)"; [[ -z "$ip" ]] && ip="0.0.0.0"
  local udp_maddr="/ip4/${ip}/udp/${P2P_UDP}/quic-v1"
  local tcp_maddr="/ip4/${ip}/tcp/${P2P_TCP}"
  touch "$ENV_FILE"
  # ETH_PRIVATE_KEY
  grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE" && sed -i 's|^ETH_PRIVATE_KEY=.*|ETH_PRIVATE_KEY=0x'"$PK_HEX"'|' "$ENV_FILE" || echo "ETH_PRIVATE_KEY=0x$PK_HEX" >> "$ENV_FILE"
  # P2P (đa dạng biến cho compatibility)
  for k in VPS_IP EXTERNAL_P2P_MADDR EXTERNAL_P2P_TCP_MADDR EXTERNAL_P2P_ADDRESS EXTERNAL_P2P_TCP_ADDRESS; do
    case "$k" in
      VPS_IP) val="$ip";;
      EXTERNAL_P2P_MADDR|EXTERNAL_P2P_ADDRESS) val="$udp_maddr";;
      EXTERNAL_P2P_TCP_MADDR|EXTERNAL_P2P_TCP_ADDRESS) val="$tcp_maddr";;
    esac
    if grep -q "^$k=" "$ENV_FILE"; then sed -i "s|^$k=.*|$k=$val|" "$ENV_FILE"; else echo "$k=$val" >> "$ENV_FILE"; fi
  done
  # RPC_URL (bắt buộc cho node settings)
  if grep -q '^RPC_URL=' "$ENV_FILE"; then
    sed -i "s|^RPC_URL=.*|RPC_URL=$DEFAULT_RPC_URL|" "$ENV_FILE"
  else
    echo "RPC_URL=$DEFAULT_RPC_URL" >> "$ENV_FILE"
  fi
  ok "Wrote .env with PK/RPC/P2P at $ENV_FILE"
}

start_operator_node(){
  ok "Resetting operator container..."
  docker rm -f drosera-operator >/dev/null 2>&1 || true
  docker volume rm -f drosera-network_drosera_data >/dev/null 2>&1 || true
  docker volume create drosera-network_drosera_data >/dev/null

  ok "Pulling operator image $OP_IMAGE..."
  docker pull "$OP_IMAGE" >>"$INSTALL_LOG" 2>&1 || true

  ok "Starting operator (node)..."
  docker run -d \
    --name drosera-operator \
    --restart unless-stopped \
    -p "${P2P_TCP}:${P2P_TCP}/tcp" \
    -p "${P2P_UDP}:${P2P_UDP}/udp" \
    -v drosera-network_drosera_data:/data \
    -v "$TRAP_DIR/drosera.toml":/data/drosera.toml:ro \
    --env-file "$ENV_FILE" \
    -e RPC_URL="$(grep ^RPC_URL= "$ENV_FILE" | cut -d= -f2-)" \
    -e EXTERNAL_P2P_ADDRESS="$(grep ^EXTERNAL_P2P_ADDRESS= "$ENV_FILE" | cut -d= -f2-)" \
    -e EXTERNAL_P2P_TCP_ADDRESS="$(grep ^EXTERNAL_P2P_TCP_ADDRESS= "$ENV_FILE" | cut -d= -f2-)" \
    "$OP_IMAGE" -c /data/drosera.toml node >/dev/null

  # Chờ tối đa ~3 phút
  local ok_spawn=0
  for i in {1..36}; do
    if docker logs --since=20s drosera-operator 2>/dev/null | grep -q 'Operator Node successfully spawned'; then ok_spawn=1; break; fi
    # Nếu help/Usage -> restart lại đúng lệnh
    if docker logs --since=5s drosera-operator 2>/dev/null | grep -q '^Usage: drosera-operator'; then
      warn "Container in 'Usage' state -> restarting with explicit node..."
      docker rm -f drosera-operator >/dev/null 2>&1 || true
      docker run -d \
        --name drosera-operator \
        --restart unless-stopped \
        -p "${P2P_TCP}:${P2P_TCP}/tcp" \
        -p "${P2P_UDP}:${P2P_UDP}/udp" \
        -v drosera-network_drosera_data:/data \
        -v "$TRAP_DIR/drosera.toml":/data/drosera.toml:ro \
        --env-file "$ENV_FILE" \
        -e RPC_URL="$(grep ^RPC_URL= "$ENV_FILE" | cut -d= -f2-)" \
        -e EXTERNAL_P2P_ADDRESS="$(grep ^EXTERNAL_P2P_ADDRESS= "$ENV_FILE" | cut -d= -f2-)" \
        -e EXTERNAL_P2P_TCP_ADDRESS="$(grep ^EXTERNAL_P2P_TCP_ADDRESS= "$ENV_FILE" | cut -d= -f2-)" \
        "$OP_IMAGE" -c /data/drosera.toml node >/dev/null
    fi
    sleep 5
  done
  if [[ $ok_spawn -eq 1 ]]; then ok "Operator Node successfully spawned."; else warn "Operator chưa in 'successfully spawned' sau 180s. Tiếp tục các bước sau."; fi
}

register_operator(){
  ok "Registering operator..."
  : >"$REG_LOG"
  set +e
  local base="drosera-operator -c /data/drosera.toml register"
  if [[ -n "$ETH_CHAIN_ID" || -n "$ETH_RPC_URL" || -n "$DROSERA_ADDR" ]]; then
    docker exec drosera-operator sh -lc "$base ${ETH_CHAIN_ID:+--eth-chain-id $ETH_CHAIN_ID} ${ETH_RPC_URL:+--eth-rpc-url $ETH_RPC_URL} ${DROSERA_ADDR:+--drosera-address $DROSERA_ADDR}" >>"$REG_LOG" 2>&1
  else
    docker exec drosera-operator sh -lc "$base" >>"$REG_LOG" 2>&1
  fi
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'OperatorAlreadyRegistered' "$REG_LOG"; then ok "Operator already registered. Skip."; return 0; fi
    warn "Register error, retry in 10s..."; sleep 10
    set +e; docker exec drosera-operator sh -lc "$base" >>"$REG_LOG" 2>&1; rc=$?; set -e
    [[ $rc -ne 0 ]] && warn "Register still failing. See $REG_LOG" || ok "Register successful (retry)."
  else ok "Register successful."; fi
}

optin_operator(){
  [[ "$RUN_OPTIN" != "1" ]] && { ok "Skip opt-in as requested."; return 0; }
  local trap="$1"; [[ -z "$trap" ]] && { warn "Không có trap address để opt-in."; return 0; }
  : >"$OPTIN_LOG"
  ok "Opting in operator to trap: $trap"
  set +e
  local cmd="drosera-operator -c /data/drosera.toml optin --trap-config-address $trap"
  [[ -n "$ETH_RPC_URL" ]] && cmd="$cmd --eth-rpc-url $ETH_RPC_URL"
  docker exec drosera-operator sh -lc "$cmd" >>"$OPTIN_LOG" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'already opted' "$OPTIN_LOG"; then ok "Operator already opted in."; else warn "Opt-in có thể lỗi. Xem $OPTIN_LOG"; fi
  else ok "Opt-in done."; fi
}

maybe_bloomboost(){
  [[ "$DO_BLOOMBOOST" != "1" || -z "$1" || -z "$2" ]] && return 0
  pushd "$TRAP_DIR" >/dev/null
  export DROSERA_PRIVATE_KEY="$2"
  ok "Running bloomboost: trap=$1 amount=$BLOOM_ETH_AMT"
  drosera bloomboost --trap-address "$1" --eth-amount "$BLOOM_ETH_AMT" >>"$LOG_DIR/bloomboost.log" 2>&1 || warn "bloomboost thất bại (xem $LOG_DIR/bloomboost.log)"
  popd >/dev/null
}

main(){
  ok "Starting..."
  [[ -z "${PK_HEX:-}" ]] && { err "Thiếu --pk <hex>."; exit 2; }
  PK_HEX="$(sanitize_pk "$PK_HEX")"
  require_root

  ensure_deps; ensure_docker; ensure_compose; ensure_bun; ensure_foundry; ensure_drosera_cli

  local EVM_ADDR; EVM_ADDR="$(evm_address_from_pk "$PK_HEX")"
  [[ "$EVM_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || { err "Không lấy được EVM address từ private key."; exit 1; }
  ok "EVM address: $EVM_ADDR"

  init_trap_project
  ensure_whitelist "$EVM_ADDR"

  local trap; trap="$(run_apply_and_get_trap "$PK_HEX")"
  [[ -n "$trap" ]] && ok "Detected trapAddress: $trap" || warn "Không trích xuất được trapAddress (xem $TRAP_DIR/drosera.log, $APPLY_LOG)."

  prepare_network_repo_and_env
  start_operator_node
  register_operator
  [[ -n "$trap" ]] && optin_operator "$trap"
  [[ "$DO_BLOOMBOOST" == "1" && -n "$trap" ]] && maybe_bloomboost "$trap" "$PK_HEX"

  ok "Done."
}

main "$@"
