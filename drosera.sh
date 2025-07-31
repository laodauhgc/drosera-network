#!/usr/bin/env bash
set -euo pipefail

# =========================
#   CONFIG & CONSTANTS
# =========================
TS() { date +"[%Y-%m-%d %H:%M:%S]"; }
log()  { echo "$(TS) $*"; }
warn() { echo "$(TS) WARN: $*" >&2; }
die()  { echo "$(TS) ERROR: $*" >&2; exit 1; }

# RPC & Chain defaults (override được qua ENV)
export HOODI_RPC="${HOODI_RPC:-https://ethereum-hoodi-rpc.publicnode.com}"
export DROSERA_RELAY_RPC="${DROSERA_RELAY_RPC:-https://relay.hoodi.drosera.io}"
export CHAIN_ID="${CHAIN_ID:-560048}"

# Drosera on-chain registry (cho operator register)
export DROSERA_ADDRESS="${DROSERA_ADDRESS:-0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D}"

# Paths
ROOT="${HOME:-/root}"
WORK_DIR="${WORK_DIR:-$ROOT/my-drosera-trap}"
DHOME="${DHOME:-$ROOT/.drosera}"
DBIN="$DHOME/bin/drosera"           # absolute path bắt buộc
DROESERAUP_BIN="$DHOME/bin/droseraup"

LOG_DIR="${LOG_DIR:-$ROOT}"
RUN_LOG="$LOG_DIR/drosera_setup_$(date +%F_%H%M%S).log"
SUMMARY_JSON="$ROOT/drosera_summary.json"
STATE_JSON="$ROOT/drosera_state.json"

# Operator image/tag
OP_IMG="ghcr.io/drosera-network/drosera-operator"
OP_TAG="v1.20.0"

# =========================
#   ARGS
# =========================
PK_RAW=""
BOOST_ETH=""
SKIP_OPERATOR="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk)
      PK_RAW="${2:-}"; shift 2;;
    --boost)
      BOOST_ETH="${2:-}"; shift 2;;
    --skip-operator)
      SKIP_OPERATOR="1"; shift;;
    *)
      warn "Unknown arg: $1"; shift;;
  esac
done

[[ -n "$PK_RAW" ]] || die "Thiếu --pk <hex-64|0x...>"

# Sanitize PK (nhận cả có/không 0x)
sanitize_pk() {
  local s="$1"
  s="${s//[[:space:]]/}"
  s="${s#0x}"
  echo "$s"
}
PK_HEX="$(sanitize_pk "$PK_RAW")"
[[ "$PK_HEX" =~ ^[0-9a-fA-F]{64}$ ]] || die "Private key không hợp lệ (cần 64 hex)."

PK_0X="0x$PK_HEX"

# =========================
#   PREREQS
# =========================
ensure_packages() {
  log "Dọn khóa APT & cập nhật..."
  apt-get update -y >>"$RUN_LOG" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl wget git jq unzip gnupg lsb-release \
    build-essential pkg-config libssl-dev libleveldb-dev lz4 \
    iproute2 dnsutils >>"$RUN_LOG" 2>&1 || true
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    die "Docker chưa cài. Hãy cài docker trước."
  fi
  log "Docker đã có."
  # Compose v2
  log "Đảm bảo Docker Compose v2..."
  if ! docker compose version >/dev/null 2>&1; then
    # fallback docker-compose plugin (nếu cần)
    if ! command -v docker-compose >/dev/null 2>&1; then
      curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
        -o /usr/local/bin/docker-compose
      chmod +x /usr/local/bin/docker-compose
    fi
  fi
}

ensure_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    log "Cài Bun..."
    curl -fsSL https://bun.sh/install | bash >>"$RUN_LOG" 2>&1 || die "Cài Bun thất bại"
    export PATH="$HOME/.bun/bin:$PATH"
    echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
  fi
}

ensure_foundry() {
  if ! command -v forge >/dev/null 2>&1; then
    log "Cài Foundry..."
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$RUN_LOG" 2>&1 || die "Cài Foundry thất bại"
    export PATH="$HOME/.foundry/bin:$PATH"
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$HOME/.bashrc"
    "$HOME/.foundry/bin/foundryup" >>"$RUN_LOG" 2>&1 || true
  else
    "$HOME/.foundry/bin/foundryup" >>"$RUN_LOG" 2>&1 || true
  fi
}

install_droseraup_and_cli() {
  log "Cài droseraup..."
  mkdir -p "$DHOME/bin"
  # Try official installer first
  if ! curl -fsSL https://app.drosera.io/install | bash >>"$RUN_LOG" 2>&1; then
    # Fallback to GitHub Raw installer
    log "Tải installer (fallback GitHub Raw)..."
    curl -fsSL https://raw.githubusercontent.com/drosera-network/releases/main/droseraup/install \
      -o /tmp/droseraup_install || die "Tải droseraup install thất bại"
    bash /tmp/droseraup_install >>"$RUN_LOG" 2>&1
  fi

  # Chạy droseraup để lấy CLI
  if [[ -x "$DROESERAUP_BIN" ]]; then
    "$DROESERAUP_BIN" >>"$RUN_LOG" 2>&1 || true
  else
    # nếu droseraup đã add PATH:
    if command -v droseraup >/dev/null 2>&1; then
      droseraup >>"$RUN_LOG" 2>&1 || true
    fi
  fi
}

force_drosera_bin() {
  # Đặt ~/.drosera/bin lên đầu PATH và dùng absolute path
  export PATH="$DHOME/bin:$PATH"
  hash -r 2>/dev/null || true

  [[ -x "$DBIN" ]] || die "Không tìm thấy Drosera CLI tại $DBIN"

  # Kiểm tra subcommand 'apply'
  if ! "$DBIN" --help 2>&1 | grep -q '\bapply\b'; then
    # Có thể đang bị bản cũ ngoài PATH. Tắt bản cũ nếu có.
    if command -v drosera >/dev/null 2>&1; then
      CURR="$(command -v drosera || true)"
      if [[ "$CURR" != "$DBIN" && -x "$CURR" ]]; then
        warn "Phát hiện drosera cũ tại $CURR (không có 'apply'). Sẽ sử dụng tuyệt đối: $DBIN"
      fi
    fi
    # Thử chạy lại droseraup 1 lần
    "$DROESERAUP_BIN" >>"$RUN_LOG" 2>&1 || true
    if ! "$DBIN" --help 2>&1 | grep -q '\bapply\b'; then
      die "Drosera CLI hiện tại không có 'apply'. Hãy kiểm tra lại droseraup."
    fi
  fi

  log "Dùng drosera: $DBIN"
  "$DBIN" --version || true
}

# =========================
#   TRAP INIT & APPLY
# =========================
init_trap_repo() {
  log "Chuẩn bị $WORK_DIR ..."
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"

  if [[ ! -d ".git" ]]; then
    # init template nếu chưa có
    forge init -t drosera-network/trap-foundry-template >>"$RUN_LOG" 2>&1 || true
  fi

  # deps + build
  bun install >>"$RUN_LOG" 2>&1 || true
  forge build >>"$RUN_LOG" 2>&1 || true
}

apply_trap() {
  log "drosera apply ..."
  export DROSERA_PRIVATE_KEY="$PK_0X"

  # Non-interactive + flags đầy đủ
  if ! ( echo ofc | "$DBIN" apply \
      --non-interactive \
      --eth-rpc-url "$HOODI_RPC" \
      --drosera-rpc-url "$DROSERA_RELAY_RPC" \
      --eth-chain-id "$CHAIN_ID" \
      2>&1 | tee "$WORK_DIR/drosera_apply.log" ); then
    warn "Apply thất bại."
  fi
}

extract_trap_address() {
  local addr=""
  # Ưu tiên đọc từ log apply
  if [[ -f "$WORK_DIR/drosera_apply.log" ]]; then
    addr="$(grep -Eoi 'trap(address|Address)[^0-9a-fA-F]*0x[0-9a-fA-F]{40}' "$WORK_DIR/drosera_apply.log" | \
            grep -Eoi '0x[0-9a-fA-F]{40}' | tail -n1 || true)"
  fi
  # fallback đọc drosera.log nếu có
  if [[ -z "$addr" && -f "$WORK_DIR/drosera.log" ]]; then
    addr="$(grep -Eo 'trapAddress:\s*0x[0-9a-fA-F]{40}' "$WORK_DIR/drosera.log" 2>/dev/null | \
            grep -Eo '0x[0-9a-fA-F]{40}' | tail -n1 || true)"
  fi

  echo "${addr:-}"
}

maybe_bloomboost() {
  local trap_addr="$1"
  local eth_amt="$2"
  [[ -n "$eth_amt" ]] || return 0
  log "Send Bloom Boost: nạp $eth_amt ETH vào trap $trap_addr ..."
  if ! "$DBIN" bloomboost --trap-address "$trap_addr" --eth-amount "$eth_amt" 2>&1 | tee -a "$RUN_LOG"; then
    warn "Bloomboost thất bại. Bạn có thể nạp sau bằng lệnh này:"
    echo "$DBIN bloomboost --trap-address $trap_addr --eth-amount $eth_amt"
  fi
}

# =========================
#   OPERATOR
# =========================
ensure_operator_up() {
  [[ "$SKIP_OPERATOR" == "1" ]] && { log "Bỏ qua Operator theo yêu cầu."; return 0; }

  log "Chuẩn bị Operator repo $ROOT/Drosera-Network ..."
  if [[ -d "$ROOT/Drosera-Network/.git" ]]; then
    (cd "$ROOT/Drosera-Network" && git fetch --all && git reset --hard origin/main) >>"$RUN_LOG" 2>&1 || true
  else
    git clone https://github.com/sdohuajia/Drosera-Network.git "$ROOT/Drosera-Network" >>"$RUN_LOG" 2>&1 || true
  fi

  cd "$ROOT/Drosera-Network"
  log "docker compose up -d ..."
  if docker compose up -d >>"$RUN_LOG" 2>&1; then
    :
  else
    # fallback docker-compose
    docker-compose up -d >>"$RUN_LOG" 2>&1 || die "Compose up thất bại"
  fi
}

operator_register() {
  [[ "$SKIP_OPERATOR" == "1" ]] && return 0

  log "Đăng ký operator (register)..."
  set +e
  docker run --rm \
    -e DRO__ETH__PRIVATE_KEY="$PK_0X" \
    "$OP_IMG:$OP_TAG" \
    register \
      --eth-chain-id "$CHAIN_ID" \
      --eth-rpc-url "$HOODI_RPC" \
      --drosera-address "$DROSERA_ADDRESS" \
      --eth-private-key "$PK_0X" 2>&1 | tee -a "$RUN_LOG"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "Register thất bại (có thể đã đăng ký trước). Bỏ qua."
  fi
}

operator_optin() {
  [[ "$SKIP_OPERATOR" == "1" ]] && return 0
  local trap_addr="$1"
  [[ "$trap_addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || { warn "Không có trapAddress hợp lệ → bỏ qua opt-in."; return 0; }

  log "Operator opt-in vào trap $trap_addr ..."
  set +e
  docker run --rm \
    -e DRO__ETH__PRIVATE_KEY="$PK_0X" \
    "$OP_IMG:$OP_TAG" \
    optin \
      --eth-rpc-url "$HOODI_RPC" \
      --trap-config-address "$trap_addr" \
      --eth-private-key "$PK_0X" 2>&1 | tee -a "$RUN_LOG"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    warn "Opt-in thất bại. Bạn có thể tự chạy lại lệnh opt-in sau."
  fi
}

# =========================
#   MAIN
# =========================
main() {
  umask 077
  touch "$RUN_LOG" || true

  ensure_packages
  ensure_docker
  ensure_bun
  ensure_foundry
  install_droseraup_and_cli
  force_drosera_bin

  # In địa chỉ ví từ PK
  if command -v cast >/dev/null 2>&1; then
    WALLET_ADDR="$(cast wallet address --private-key "$PK_0X" 2>/dev/null || true)"
    [[ -n "$WALLET_ADDR" ]] && log "Địa chỉ ví: $WALLET_ADDR"
  fi

  init_trap_repo
  apply_trap

  TRAP_ADDR="$(extract_trap_address || true)"
  if [[ -z "$TRAP_ADDR" ]]; then
    warn "Không trích được trapAddress tự động."
  else
    log "trapAddress: $TRAP_ADDR"
  fi

  # Top-up nếu user yêu cầu
  if [[ -n "$BOOST_ETH" && -n "$TRAP_ADDR" ]]; then
    maybe_bloomboost "$TRAP_ADDR" "$BOOST_ETH"
  fi

  ensure_operator_up
  operator_register
  operator_optin "${TRAP_ADDR:-}"

  # Summary
  cat >"$SUMMARY_JSON" <<JSON
{
  "wallet_address": "${WALLET_ADDR:-}",
  "trap_address": "${TRAP_ADDR:-}",
  "hoodi_rpc": "$HOODI_RPC",
  "drosera_relay_rpc": "$DROSERA_RELAY_RPC",
  "chain_id": "$CHAIN_ID",
  "operator_image": "$OP_IMG",
  "operator_tag": "$OP_TAG",
  "boost_eth": "${BOOST_ETH:-}"
}
JSON

  cat >"$STATE_JSON" <<JSON
{
  "run_log": "$RUN_LOG",
  "work_dir": "$WORK_DIR",
  "drosera_bin": "$DBIN",
  "drosera_home": "$DHOME"
}
JSON

  log "HOÀN TẤT."
  log "Summary JSON: $SUMMARY_JSON"
  log "State JSON  : $STATE_JSON"
  log "Log đầy đủ  : $RUN_LOG"
}

main "$@"
