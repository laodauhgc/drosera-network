#!/usr/bin/env bash
# Drosera AIO Installer (robust) - v1.8.0
set -Eeuo pipefail
: "${PS1:=# }"
export PATH="$PATH:/root/.drosera/bin:/root/.bun/bin:/root/.foundry/bin"

# ========= Config mặc định =========
TRAP_DIR="${TRAP_DIR:-/root/my-drosera-trap}"
NET_DIR="${NET_DIR:-/root/drosera-network}"
ENV_FILE="$NET_DIR/.env"
TEMPLATE_REPO="${TEMPLATE_REPO:-drosera-network/trap-foundry-template}"
OP_IMAGE="${OP_IMAGE:-ghcr.io/drosera-network/drosera-operator:v1.20.0}"
DEFAULT_RPC_URL="${DEFAULT_RPC_URL:-https://0xrpc.io/hoodi}"
P2P_TCP="${P2P_TCP:-31313}"
P2P_UDP="${P2P_UDP:-31313}"
RUN_OPTIN=1

LOG_DIR="/var/log/drosera"; mkdir -p "$LOG_DIR"
INSTALL_LOG="$LOG_DIR/install.log"
APPLY_LOG="$LOG_DIR/apply.log"
REG_LOG="$LOG_DIR/register.log"
OPTIN_LOG="$LOG_DIR/optin.log"

# ========= Utils =========
ts(){ date +"%Y-%m-%dT%H:%M:%S%z"; }
ok(){ echo -e "$(ts)  $*"; }
warn(){ echo -e "$(ts)  \e[33mWARNING:\e[0m $*"; }
err(){ echo -e "$(ts)  \e[31mERROR:\e[0m $*"; }

usage(){
  cat <<USAGE
Usage: $0 --pk <hex> [--auto] [--no-optin] [--rpc <url>] [--p2p-tcp <port>] [--p2p-udp <port>]
       [--trap-dir <path>] [--net-dir <path>]

Examples:
  $0 --auto --pk d9661f...903b2
  $0 --auto --pk 4242...ad37c --rpc https://0xrpc.io/hoodi
USAGE
}

sanitize_pk(){
  local pk="${1#0x}"
  [[ "$pk" =~ ^[0-9a-fA-F]{64}$ ]] || { err "Private key không hợp lệ (64 hex)"; exit 1; }
  echo -n "$pk"
}
apt_quiet(){ DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1; }
apt_install(){ apt_quiet update || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" "$@" >>"$INSTALL_LOG" 2>&1 || true; }
get_public_ip(){ curl -4fsSL https://api.ipify.org || curl -4fsSL ifconfig.me || echo 0.0.0.0; }
evm_address_from_pk(){ cast wallet address --private-key "0x$1" 2>/dev/null || true; }
strip_crlf(){ sed -i -e 's/\r$//' "$1" 2>/dev/null || true; }

ensure_deps(){
  ok "Updating apt & installing base packages..."
  apt_install curl ca-certificates gnupg lsb-release jq git unzip make \
              build-essential pkg-config libssl-dev clang cmake dnsutils
}
ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    apt_install apt-transport-https software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add - >/dev/null 2>&1 || true
    add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" >>"$INSTALL_LOG" 2>&1 || true
    apt_install docker-ce docker-ce-cli containerd.io
  else ok "Docker already installed. Skipping re-install."; fi
  systemctl enable --now docker >>"$INSTALL_LOG" 2>&1 || true
}
ensure_bun(){
  command -v bun >/dev/null 2>&1 || {
    curl -fsSL https://bun.sh/install | bash >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.bun/bin"
    grep -q '/root/.bun/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.bun/bin' >> /root/.bashrc
  }
}
ensure_foundry(){
  if ! command -v forge >/dev/null 2>&1; then
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$INSTALL_LOG" 2>&1 || true
    [[ -x /root/.foundry/bin/foundryup ]] && /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.foundry/bin"
    grep -q '/root/.foundry/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.foundry/bin' >> /root/.bashrc
  else /root/.foundry/bin/foundryup >>"$INSTALL_LOG" 2>&1 || true; fi
}
ensure_drosera_cli(){
  if ! command -v drosera >/dev/null 2>&1; then
    ok "Installing Drosera CLI from app.drosera.io..."
    local tmp="/tmp/drosera_install.sh" attempt=1 max=10
    while (( attempt<=max )); do
      rm -f "$tmp"; set +e
      curl -fsSL https://app.drosera.io/install -o "$tmp"; rc=$?
      set -e
      if [[ $rc -eq 0 && -s "$tmp" ]]; then
        bash "$tmp" >>"$INSTALL_LOG" 2>&1 || true
        break
      fi
      local sleep_s=$(( 2 ** (attempt-1) + RANDOM % 5 ))
      warn "Installer bị 429/failed, retry $attempt/$max sau ${sleep_s}s..."
      sleep "$sleep_s"; attempt=$((attempt+1))
    done
    command -v droseraup >/dev/null 2>&1 && droseraup >>"$INSTALL_LOG" 2>&1 || true
    export PATH="$PATH:/root/.drosera/bin"
    grep -q '/root/.drosera/bin' /root/.bashrc || echo 'export PATH=$PATH:/root/.drosera/bin' >> /root/.bashrc
  else
    command -v droseraup >/dev/null 2>&1 && droseraup >>"$INSTALL_LOG" 2>&1 || true
  fi
  drosera --help 2>&1 | grep -qE '\bapply\b' || { err "Drosera CLI thiếu 'apply' (có thể do 429). Thử lại sau vài phút."; exit 1; }
  ok "Drosera CLI sẵn sàng (có 'apply')."
}

init_trap(){
  ok "Preparing trap project at $TRAP_DIR ..."
  local need=0
  [[ ! -d "$TRAP_DIR" ]] && need=1
  [[ -d "$TRAP_DIR" && ! -f "$TRAP_DIR/drosera.toml" ]] && need=1
  if (( need )); then
    if [[ -d "$TRAP_DIR" && $(ls -A "$TRAP_DIR" 2>/dev/null | wc -l) -gt 0 ]]; then
      local bak="${TRAP_DIR}.bak.$(date +%s)"
      warn "$TRAP_DIR tồn tại nhưng thiếu drosera.toml → backup: $bak"
      mv "$TRAP_DIR" "$bak"
    fi
    rm -rf "$TRAP_DIR"
    forge init -t "$TEMPLATE_REPO" "$TRAP_DIR" >>"$INSTALL_LOG" 2>&1 || \
    git clone "https://github.com/${TEMPLATE_REPO}.git" "$TRAP_DIR" >>"$INSTALL_LOG" 2>&1 || true
  fi
  [[ -f "$TRAP_DIR/drosera.toml" ]] || { err "Không tìm thấy $TRAP_DIR/drosera.toml"; exit 1; }
  strip_crlf "$TRAP_DIR/drosera.toml"
  ( cd "$TRAP_DIR"; bun install >>"$INSTALL_LOG" 2>&1 || true; forge build >>"$INSTALL_LOG" 2>&1 || true )
}

ensure_whitelist(){
  local addr="$1" toml="$TRAP_DIR/drosera.toml"
  cp -f "$toml" "${toml}.bak" || true
  if grep -q '^\s*whitelist\s*=' "$toml"; then
    sed -i 's|^\s*whitelist\s*=.*|whitelist = ["'"$addr"'"]|' "$toml"
  elif grep -q '^\[traps\.mytrap\]' "$toml"; then
    awk -v addr="$addr" '
      BEGIN{done=0}
      {print}
      /^\[traps\.mytrap\]/{print; getline; print "whitelist = [\"" addr "\"]"; done=1}
      END{if(!done) print "whitelist = [\"" addr "\"]"}
    ' "$toml" > "${toml}.tmp" && mv "${toml}.tmp" "$toml"
  else
    echo "whitelist = [\"$addr\"]" >> "$toml"
  fi
  ok "Wrote whitelist = [$addr] to drosera.toml"
}

ensure_node_settings(){
  local toml="$TRAP_DIR/drosera.toml" ip="$1" rpc="$2"
  cp -f "$toml" "${toml}.node.bak.$(date +%s)" || true
  strip_crlf "$toml"

  # Top-level keys (tương thích nhiều binary)
  set_kv(){ local k="$1" v="$2"; if grep -q "^$k[[:space:]]*=" "$toml"; then sed -i "s|^$k[[:space:]]*=.*|$k = $v|" "$toml"; else echo "$k = $v" >> "$toml"; fi; }
  set_kv rpc_url "\"$rpc\""
  set_kv external_p2p_address "\"/ip4/$ip/udp/$P2P_UDP/quic-v1\""
  set_kv external_p2p_tcp_address "\"/ip4/$ip/tcp/$P2P_TCP\""

  # Loại bỏ block [node] cũ (KHÔNG dùng biến 'in')
  local tmp="${toml}.tmp.$$"
  awk 'BEGIN{inside=0}
       /^\[node\]/{inside=1; next}
       (inside==1 && /^\[/){inside=0}
       (inside==1){next}
       {print}' "$toml" > "$tmp" && mv "$tmp" "$toml"

  # Ghi lại block [node] mới
  cat >>"$toml" <<EOF

[node]
rpc_url = "$rpc"
external_p2p_address = "/ip4/$ip/udp/$P2P_UDP/quic-v1"
external_p2p_tcp_address = "/ip4/$ip/tcp/$P2P_TCP"
EOF
}

apply_and_get_trap(){
  : >"$APPLY_LOG"
  pushd "$TRAP_DIR" >/dev/null
  export DROSERA_PRIVATE_KEY="$1"
  ok "Running: echo \"ofc\" | drosera apply"
  set +e
  echo "ofc" | drosera apply >>"$APPLY_LOG" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "drosera apply thất bại. Xem $APPLY_LOG"
    popd >/dev/null
    return 0
  fi
  # Trích địa chỉ 0x... cuối cùng xuất hiện
  local trap=""; trap="$(grep -aEo '0x[a-fA-F0-9]{40}' "$APPLY_LOG" | tail -1 || true)"
  [[ -z "$trap" && -f "drosera.log" ]] && trap="$(grep -aEo '0x[a-fA-F0-9]{40}' drosera.log 2>/dev/null | tail -1 || true)"
  trap="$(echo -n "$trap" | tr -d '\r\n')"
  popd >/dev/null
  [[ -n "$trap" ]] && echo -n "$trap"
}

prepare_env(){
  mkdir -p "$NET_DIR"
  [[ -d "$NET_DIR/.git" ]] || git clone https://github.com/laodauhgc/drosera-network.git "$NET_DIR" >>"$INSTALL_LOG" 2>&1 || true

  local ip="$1" rpc="$2"
  local udp_maddr="/ip4/${ip}/udp/${P2P_UDP}/quic-v1"
  local tcp_maddr="/ip4/${ip}/tcp/${P2P_TCP}"
  touch "$ENV_FILE"

  # ETH_PRIVATE_KEY
  if grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE"; then
    sed -i 's|^ETH_PRIVATE_KEY=.*|ETH_PRIVATE_KEY=0x'"$PK_HEX"'|' "$ENV_FILE"
  else
    echo "ETH_PRIVATE_KEY=0x$PK_HEX" >> "$ENV_FILE"
  fi

  # RPC + P2P variables (đặt cả biến MADDR & ADDRESS cho chắc)
  set_env(){ local k="$1" v="$2"; if grep -q "^$k=" "$ENV_FILE"; then sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"; else echo "$k=$v" >> "$ENV_FILE"; fi; }
  set_env VPS_IP "$ip"
  set_env EXTERNAL_P2P_MADDR "$udp_maddr"
  set_env EXTERNAL_P2P_TCP_MADDR "$tcp_maddr"
  set_env EXTERNAL_P2P_ADDRESS "$udp_maddr"
  set_env EXTERNAL_P2P_TCP_ADDRESS "$tcp_maddr"
  set_env RPC_URL "$rpc"

  ok "Wrote .env with PK/RPC/P2P at $ENV_FILE"
}

start_node(){
  ok "Resetting operator container..."
  docker rm -f drosera-operator >/dev/null 2>&1 || true
  docker volume create drosera-network_drosera_data >/dev/null 2>&1 || true
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
    "$OP_IMAGE" -c /data/drosera.toml node >/dev/null

  local ok_spawn=0
  for i in {1..60}; do
    if docker logs --since=20s drosera-operator 2>/dev/null | grep -q 'Operator Node successfully spawned'; then ok_spawn=1; break; fi
    if docker logs --since=20s drosera-operator 2>/dev/null | grep -q 'missing field'; then
      warn "Node báo thiếu field (xem: docker logs drosera-operator)."
      break
    fi
    sleep 5
  done
  if [[ $ok_spawn -ne 1 ]]; then
    warn "Operator chưa in 'successfully spawned' sau 300s. Tạm dừng register/opt-in."
  fi
  return $ok_spawn
}

register(){
  ok "Registering operator..."
  : >"$REG_LOG"; set +e
  docker exec drosera-operator sh -lc "drosera-operator -c /data/drosera.toml register" >>"$REG_LOG" 2>&1
  local rc=$?; set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'already' "$REG_LOG"; then ok "Operator already registered. Skip."; else warn "Register lỗi. Xem $REG_LOG"; fi
  else ok "Register successful."; fi
}
optin(){
  [[ "$RUN_OPTIN" != "1" ]] && { ok "Skip opt-in (theo tham số)."; return; }
  local trap="$1"; [[ -z "$trap" ]] && { warn "Không có trap address để opt-in."; return; }
  : >"$OPTIN_LOG"; ok "Opting in operator to trap: $trap"
  set +e
  docker exec drosera-operator sh -lc "drosera-operator -c /data/drosera.toml optin --trap-config-address $trap" >>"$OPTIN_LOG" 2>&1
  local rc=$?; set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'already' "$OPTIN_LOG"; then ok "Operator already opted in."; else warn "Opt-in lỗi. Xem $OPTIN_LOG"; fi
  else ok "Opt-in done."; fi
}

# ========= Parse args =========
PK_HEX=""; AUTO=0; RPC_URL="$DEFAULT_RPC_URL"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_HEX="${2:-}"; shift 2;;
    --auto) AUTO=1; shift;;
    --no-optin) RUN_OPTIN=0; shift;;
    --rpc) RPC_URL="${2:-$DEFAULT_RPC_URL}"; shift 2;;
    --p2p-tcp) P2P_TCP="${2:-31313}"; shift 2;;
    --p2p-udp) P2P_UDP="${2:-31313}"; shift 2;;
    --trap-dir) TRAP_DIR="${2:-$TRAP_DIR}"; shift 2;;
    --net-dir) NET_DIR="${2:-$NET_DIR}"; ENV_FILE="$NET_DIR/.env"; shift 2;;
    --help|-h) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

main(){
  ok "Starting..."
  [[ -z "${PK_HEX:-}" ]] && { err "Thiếu --pk <hex>"; exit 2; }
  PK_HEX="$(sanitize_pk "$PK_HEX")"

  ensure_deps; ensure_docker; ensure_bun; ensure_foundry; ensure_drosera_cli

  local EVM_ADDR; EVM_ADDR="$(evm_address_from_pk "$PK_HEX")"
  [[ "$EVM_ADDR" =~ ^0x[0-9a-fA-F]{40}$ ]] || { err "Không lấy được EVM address từ private key."; exit 1; }
  ok "EVM address: $EVM_ADDR"

  init_trap
  ensure_whitelist "$EVM_ADDR"

  local trap; trap="$(apply_and_get_trap "$PK_HEX" || true)"
  [[ -n "$trap" ]] && ok "Detected trapAddress: $trap" || warn "Không trích xuất được trapAddress (xem $APPLY_LOG)."

  local ip; ip="$(get_public_ip)"
  ensure_node_settings "$ip" "$RPC_URL"
  prepare_env "$ip" "$RPC_URL"

  if start_node; then
    register
    [[ -n "$trap" ]] && optin "$trap"
  else
    warn "Container chưa ổn định, bỏ qua register/opt-in. Kiểm tra: docker logs -f drosera-operator"
  fi
  ok "Done."
}

main "$@"
