#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
#  Drosera All-in-One Installer
#  v1.2.1 (robust apt, no early-exit, adaptive)
# ==============================

# -------- Config mặc định (override bằng ENV nếu cần) --------
DROSERA_OPERATOR_IMAGE="${DROSERA_OPERATOR_IMAGE:-ghcr.io/drosera-network/drosera-operator:v1.20.0}"
TRAP_PROJECT_DIR="${TRAP_PROJECT_DIR:-/root/my-drosera-trap}"
NETWORK_REPO_DIR="${NETWORK_REPO_DIR:-/root/drosera-network}"
ENV_FILE="$NETWORK_REPO_DIR/.env"
LOG_DIR="/var/log/drosera"
APPLY_LOG="$LOG_DIR/apply.log"
REGISTER_LOG="$LOG_DIR/register.log"
INSTALL_LOG="$LOG_DIR/install.log"
STATE_DIR="/var/lib/drosera"
mkdir -p "$LOG_DIR" "$STATE_DIR"

# Multi-addr ports
P2P_TCP_PORT="${P2P_TCP_PORT:-31313}"
P2P_UDP_PORT="${P2P_UDP_PORT:-31313}"

# Hành vi mặc định
DO_FULL="${DO_FULL:-1}"          # 1 = cài mọi thứ + trap + optin
DO_OPERATOR_ONLY="${DO_OPERATOR_ONLY:-0}"
DO_TRAP="${DO_TRAP:-1}"
DO_OPTIN="${DO_OPTIN:-1}"
AUTO_MODE="${AUTO_MODE:-0}"      # 1 = không hỏi, tự chạy
SHOW_MENU="${SHOW_MENU:-0}"

# Cài Drosera CLI bằng cargo nếu thiếu?
INSTALL_CLI_WITH_CARGO="${INSTALL_CLI_WITH_CARGO:-1}"

# Màu xuất log
c_green="\e[32m"; c_yellow="\e[33m"; c_red="\e[31m"; c_cyan="\e[36m"; c_reset="\e[0m"

ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo -e "$(ts)  $*"; }
info() { log "${c_cyan}$*${c_reset}"; }
warn() { log "${c_yellow}WARNING:${c_reset} $*"; }
err()  { log "${c_red}ERROR:${c_reset} $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Vui lòng chạy bằng root."
    exit 1
  fi
}

usage() {
cat <<'USAGE'
Usage:
  ./drosera.sh --pk <hex_privkey> [--auto] [--menu]
  Tuỳ chọn:
    --pk <hex>          Private key (không có '0x'). BẮT BUỘC (trừ khi đã có ENV ETH_PRIVATE_KEY trong .env).
    --auto              Tự chạy không hỏi (mặc định FULL: cài mọi thứ + trap + opt-in + operator).
    --menu              Mở menu tác vụ.
    --operator-only     Chỉ chạy Operator (không tạo trap/opt-in).
    --no-trap           Không tạo trap (giữ nguyên/skip apply).
    --no-optin          Không opt-in trap.
    --image <ref>       Thay operator image (mặc định ghcr.io/...:v1.20.0)
    --help              In hướng dẫn.

ENV hữu ích:
  DROSERA_OPERATOR_IMAGE, TRAP_PROJECT_DIR, NETWORK_REPO_DIR, P2P_TCP_PORT, P2P_UDP_PORT,
  INSTALL_CLI_WITH_CARGO=0/1 (mặc định 1), DO_FULL=0/1
USAGE
}

# -------- Parse args --------
PK_HEX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pk) PK_HEX="$2"; shift 2;;
    --auto) AUTO_MODE=1; SHOW_MENU=0; shift;;
    --menu) SHOW_MENU=1; AUTO_MODE=0; shift;;
    --operator-only) DO_OPERATOR_ONLY=1; DO_TRAP=0; DO_OPTIN=0; shift;;
    --no-trap) DO_TRAP=0; shift;;
    --no-optin) DO_OPTIN=0; shift;;
    --image) DROSERA_OPERATOR_IMAGE="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) err "Unknown arg: $1. Use --help for usage."; exit 2;;
  esac
done

if [[ "$DO_OPERATOR_ONLY" == "1" ]]; then
  DO_TRAP=0; DO_OPTIN=0; DO_FULL=0
fi

require_root

# -------- APT helpers (có retry & không làm script thoát sớm) --------
apt_retry() {
  # $1... = full apt-get args (e.g. update) hoặc "install pkg ..."
  local tries=12
  local delay=5
  local cmd=(apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@")
  # special for 'update': remove -y
  if [[ "$1" == "update" ]]; then
    cmd=(apt-get update)
  fi
  : >>"$INSTALL_LOG"
  for i in $(seq 1 $tries); do
    set +e
    DEBIAN_FRONTEND=noninteractive "${cmd[@]}" >>"$INSTALL_LOG" 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    if grep -Eqi "Could not get lock|dpkg was interrupted|front-end lock" "$INSTALL_LOG"; then
      warn "apt đang bị khoá; thử lại trong ${delay}s... (attempt $i/$tries)"
      sleep "$delay"
      if (( delay < 60 )); then delay=$((delay*2)); fi
      continue
    fi
    warn "apt-get $* lỗi (rc=$rc); xem $INSTALL_LOG"
    return $rc
  done
  warn "apt-get $* vẫn lỗi sau $tries lần; xem $INSTALL_LOG"
  return 1
}

apt_update() { apt_retry update || true; }
apt_install() { apt_retry install "$@" || true; }

ensure_base() {
  info "Updating apt & installing base packages..."
  apt_update
  apt_install curl ca-certificates gnupg lsb-release jq git unzip net-tools dnsutils iproute2 coreutils
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker already installed. Skipping re-install."
  else
    info "Installing Docker..."
    apt_install docker.io
  fi
  # start docker service nếu có systemctl
  if command -v systemctl >/dev/null 2>&1; then
    set +e
    systemctl enable --now docker >>"$INSTALL_LOG" 2>&1
    set -e
  fi
}

ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    info "Bun already installed."
    return
  fi
  info "Installing Bun..."
  set +e
  curl -fsSL https://bun.sh/install | bash >>"$INSTALL_LOG" 2>&1
  rc=$?; set -e
  export BUN_INSTALL="${BUN_INSTALL:-/root/.bun}"
  export PATH="$BUN_INSTALL/bin:$PATH"
  if [[ $rc -ne 0 ]]; then warn "Cài Bun lỗi; tiếp tục."; fi
}

ensure_foundry() {
  if command -v forge >/dev/null 2>&1; then
    info "Foundry already installed; running foundryup..."
    if [[ -x "/root/.foundry/bin/foundryup" ]]; then
      set +e; "/root/.foundry/bin/foundryup" >>"$INSTALL_LOG" 2>&1; set -e
    fi
  else
    info "Installing Foundry..."
    set +e
    curl -fsSL https://foundry.paradigm.xyz | bash >>"$INSTALL_LOG" 2>&1
    rc=$?
    set -e
    export PATH="/root/.foundry/bin:$PATH"
    if [[ $rc -eq 0 && -x "/root/.foundry/bin/foundryup" ]]; then
      set +e; "/root/.foundry/bin/foundryup" >>"$INSTALL_LOG" 2>&1; set -e
    else
      warn "Cài Foundry lỗi; tiếp tục."
    fi
  fi
  export PATH="/root/.foundry/bin:$PATH"
}

get_public_ipv4() {
  local ip=""
  set +e
  ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com 2>/dev/null)"
  if [[ -z "$ip" ]]; then ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null)"; fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"
  fi
  set -e
  echo -n "$ip"
}

write_env_file() {
  mkdir -p "$NETWORK_REPO_DIR"
  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"
  local pk_line="ETH_PRIVATE_KEY=0x${PK_HEX}"
  local ipv4="$1"
  local udp_maddr="/ip4/${ipv4}/udp/${P2P_UDP_PORT}/quic-v1"
  local tcp_maddr="/ip4/${ipv4}/tcp/${P2P_TCP_PORT}"

  grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE" && sed -i "s#^ETH_PRIVATE_KEY=.*#${pk_line}#g" "$ENV_FILE" || echo "$pk_line" >>"$ENV_FILE"
  grep -q '^VPS_IP=' "$ENV_FILE" && sed -i "s#^VPS_IP=.*#VPS_IP=${ipv4}#g" "$ENV_FILE" || echo "VPS_IP=${ipv4}" >>"$ENV_FILE"
  grep -q '^EXTERNAL_P2P_MADDR=' "$ENV_FILE" && sed -i "s#^EXTERNAL_P2P_MADDR=.*#EXTERNAL_P2P_MADDR=${udp_maddr}#g" "$ENV_FILE" || echo "EXTERNAL_P2P_MADDR=${udp_maddr}" >>"$ENV_FILE"
  grep -q '^EXTERNAL_P2P_TCP_MADDR=' "$ENV_FILE" && sed -i "s#^EXTERNAL_P2P_TCP_MADDR=.*#EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}#g" "$ENV_FILE" || echo "EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}" >>"$ENV_FILE"

  info "Using Public IP: ${ipv4}"
  info "Wrote ETH_PRIVATE_KEY=0x${PK_HEX:0:4}******${PK_HEX: -6} to $ENV_FILE"
  info "Wrote EXTERNAL_P2P_MADDR=${udp_maddr}"
  info "Wrote EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}"
}

ensure_cli() {
  if command -v drosera >/dev/null 2>&1; then
    info "Drosera CLI present."
    return 0
  fi
  warn "Drosera CLI not found in PATH."
  if [[ "${INSTALL_CLI_WITH_CARGO}" != "1" ]]; then
    return 1
  fi

  info "Attempting to install Drosera CLI via cargo..."
  apt_install build-essential pkg-config libssl-dev cmake clang llvm-dev libclang-dev
  if ! command -v cargo >/dev/null 2>&1; then
    set +e; curl -fsSL https://sh.rustup.rs | sh -s -- -y >>"$INSTALL_LOG" 2>&1; set -e
    export PATH="/root/.cargo/bin:$PATH"
  else
    export PATH="/root/.cargo/bin:$PATH"
  fi

  # Thử nhiều tên crate có thể dùng
  local ok=0
  for crate in "${DROSERA_CLI_CRATE:-drosera-cli}" drosera "drosera_operator_cli"; do
    set +e
    cargo install "$crate" >>"$INSTALL_LOG" 2>&1
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then ok=1; break; fi
  done

  hash -r || true
  if [[ $ok -eq 1 ]] && command -v drosera >/dev/null 2>&1; then
    info "Drosera CLI installed successfully."
    return 0
  fi

  # Cho phép override thủ công
  if [[ -n "${DROSERA_CLI_BIN:-}" && -x "$(command -v "${DROSERA_CLI_BIN}")" ]]; then
    info "Using CLI binary from DROSERA_CLI_BIN=${DROSERA_CLI_BIN}."
    return 0
  fi

  err "Không cài được Drosera CLI qua cargo. Bạn có thể set DROSERA_CLI_CRATE/DROSERA_CLI_BIN."
  return 1
}

ensure_trap_project() {
  info "Initializing trap project at $TRAP_PROJECT_DIR ..."
  if [[ -d "$TRAP_PROJECT_DIR/.git" ]]; then
    info "Found existing repo in $TRAP_PROJECT_DIR; syncing deps..."
    set +e; (cd "$TRAP_PROJECT_DIR" && bun install) >>"$INSTALL_LOG" 2>&1; set -e
    return
  fi
  if [[ -n "${TRAP_TEMPLATE_GIT:-}" ]]; then
    set +e; git clone --depth=1 "$TRAP_TEMPLATE_GIT" "$TRAP_PROJECT_DIR" >>"$INSTALL_LOG" 2>&1; set -e
  else
    mkdir -p "$TRAP_PROJECT_DIR"
    echo '{}' > "$TRAP_PROJECT_DIR/package.json"
  fi
  set +e; (cd "$TRAP_PROJECT_DIR" && bun install) >>"$INSTALL_LOG" 2>&1; set -e
}

drosera_apply_trap() {
  : >"$APPLY_LOG"
  info "Running: drosera apply"
  local cli="${DROSERA_CLI_BIN:-drosera}"
  set +e
  "$cli" apply --private-key "0x${PK_HEX}" --yes >>"$APPLY_LOG" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    err "Apply config failed. See $APPLY_LOG"
    return 1
  fi
  local trap_addr=""
  trap_addr="$(grep -Eoi '0x[a-f0-9]{40}' "$APPLY_LOG" | tail -1 || true)"
  if [[ -n "$trap_addr" ]]; then
    echo -n "$trap_addr" > "$STATE_DIR/trap_address"
    info "Detected trap address: $trap_addr"
  else
    warn "Could not detect trap address from apply log."
  fi
  if grep -qi 'trap_config' "$APPLY_LOG"; then
    awk '/trap_config/ {injson=1} injson {print}' "$APPLY_LOG" > "$STATE_DIR/trap_config.raw" || true
  fi
  return 0
}

drosera_opt_in() {
  [[ "$DO_OPTIN" == "1" ]] || return 0
  local trap_addr="${1:-}"
  if [[ -z "$trap_addr" && -f "$STATE_DIR/trap_address" ]]; then
    trap_addr="$(cat "$STATE_DIR/trap_address")"
  fi
  if [[ -z "$trap_addr" ]]; then
    warn "No trap address to opt-in. Skipping."
    return 0
  fi

  info "Opting-in operator to trap: $trap_addr"
  : >"$LOG_DIR/optin.log"
  local cli="${DROSERA_CLI_BIN:-drosera}"
  set +e
  "$cli" operator opt-in --trap "$trap_addr" --private-key "0x${PK_HEX}" >>"$LOG_DIR/optin.log" 2>&1 \
  || "$cli" opt-in --trap "$trap_addr" --private-key "0x${PK_HEX}" >>"$LOG_DIR/optin.log" 2>&1 \
  || "$cli" trap opt-in "$trap_addr" --private-key "0x${PK_HEX}" >>"$LOG_DIR/optin.log" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'already opted' "$LOG_DIR/optin.log"; then
      info "Operator already opted-in to trap."
      return 0
    fi
    warn "Opt-in may have failed. See $LOG_DIR/optin.log"
    return 1
  fi
  info "Opt-in successful."
  return 0
}

reset_operator_stack() {
  info "Resetting operator stack (container & volume)..."
  set +e
  docker rm -f drosera-operator >/dev/null 2>&1
  docker volume rm -f drosera-network_drosera_data >/dev/null 2>&1
  set -e
}

start_operator() {
  info "Pulling latest operator image..."
  set +e; docker pull "$DROSERA_OPERATOR_IMAGE" >>"$INSTALL_LOG" 2>&1; set -e

  info "Starting operator stack..."
  docker volume create drosera-network_drosera_data >/dev/null

  set -a
  source "$ENV_FILE"
  set +a

  set +e
  docker run -d \
    --name drosera-operator \
    --restart unless-stopped \
    -p "${P2P_TCP_PORT}:${P2P_TCP_PORT}/tcp" \
    -p "${P2P_UDP_PORT}:${P2P_UDP_PORT}/udp" \
    -v drosera-network_drosera_data:/data \
    --env-file "$ENV_FILE" \
    "$DROSERA_OPERATOR_IMAGE" >/dev/null 2>&1
  set -e

  info "Waiting up to 180s for container 'drosera-operator' to stabilize..."
  local ok=0
  for i in {1..36}; do
    if ! docker ps --format '{{.Names}} {{.Status}}' | grep -q '^drosera-operator .*Up'; then
      sleep 5; continue
    fi
    if docker logs --since=30s drosera-operator 2>/dev/null | grep -q 'Operator Node successfully spawned'; then
      ok=1; break
    fi
    if docker logs --since=10s drosera-operator 2>/dev/null | grep -qi 'invalid protocol string'; then
      warn "Operator reports invalid protocol string; kiểm tra EXTERNAL_P2P_* trong $ENV_FILE."
    fi
    sleep 5
  done
  if [[ "$ok" != "1" ]]; then
    warn "Container not stable after 180s."
    return 1
  fi
  info "Container is running and appears stable."
  return 0
}

register_operator() {
  info "Registering Drosera Operator..."
  : >"$REGISTER_LOG"
  set +e
  docker exec drosera-operator /bin/sh -lc 'drosera-operator register' >>"$REGISTER_LOG" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if grep -qi 'OperatorAlreadyRegistered' "$REGISTER_LOG"; then
      info "Operator was already registered with this private key; skipping register."
      return 0
    fi
    local delay=10
    for n in 1 2 3 4; do
      warn "Register attempt failed; retrying in ${delay}s..."
      sleep "$delay"
      set +e
      docker exec drosera-operator /bin/sh -lc 'drosera-operator register' >>"$REGISTER_LOG" 2>&1
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then break; fi
      delay=$((delay*2))
    done
    if [[ $rc -ne 0 ]]; then
      warn "Register command failed; see $REGISTER_LOG"
      return 1
    fi
  fi
  info "Register successful."
  return 0
}

show_menu() {
  while :; do
    echo
    echo "=== Drosera Menu ==="
    echo "1) Install/Update dependencies (Docker, Bun, Foundry, CLI)"
    echo "2) Create/Apply Trap"
    echo "3) Opt-in Operator to Trap"
    echo "4) Reset & Start Operator"
    echo "5) Register Operator"
    echo "6) Show Operator logs (tail -f)"
    echo "7) Exit"
    echo -n "Select (1-7): "
    read -r sel
    case "$sel" in
      1) ensure_base; ensure_docker; ensure_bun; ensure_foundry; ensure_cli || true;;
      2) ensure_trap_project; ( cd "$TRAP_PROJECT_DIR" && drosera_apply_trap ) || true;;
      3) drosera_opt_in "" || true;;
      4) reset_operator_stack; start_operator || true;;
      5) register_operator || true;;
      6) docker logs -f drosera-operator;;
      7) exit 0;;
      *) echo "Invalid choice";;
    esac
  done
}

# -------------------- MAIN FLOW --------------------
main() {
  info "Starting setup..."

  ensure_base
  ensure_docker
  ensure_bun
  ensure_foundry

  local ipv4; ipv4="$(get_public_ipv4)"
  if [[ -z "$ipv4" ]]; then
    err "Không lấy được Public IPv4. Kiểm tra mạng/Firewall."
    exit 1
  fi

  if [[ -z "$PK_HEX" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
      local prev_pk
      prev_pk="$(grep -E '^ETH_PRIVATE_KEY=' "$ENV_FILE" | sed -E 's/^ETH_PRIVATE_KEY=0x//' || true)"
      [[ -n "$prev_pk" ]] && PK_HEX="$prev_pk"
    fi
  fi
  if [[ -z "$PK_HEX" ]]; then
    err "Thiếu private key. Dùng --pk <hex>."
    exit 2
  fi

  mkdir -p "$NETWORK_REPO_DIR"
  write_env_file "$ipv4"

  if [[ "$SHOW_MENU" == "1" ]]; then
    show_menu; exit 0
  fi

  if [[ "$DO_TRAP" == "1" || "$DO_OPTIN" == "1" ]]; then
    if ! ensure_cli; then
      if [[ "$AUTO_MODE" == "1" ]]; then
        err "Drosera CLI thiếu và không cài được (AUTO mode). Dừng để tránh trạng thái nửa vời."
        exit 3
      else
        read -r -p "CLI chưa sẵn sàng. (R)etry cài, (O)perator-only, (E)xit? [R/O/E]: " ans
        case "${ans^^}" in
          R) ensure_cli || { err "Cài CLI thất bại."; exit 3; };;
          O) DO_TRAP=0; DO_OPTIN=0;;
          *) exit 3;;
        esac
      fi
    fi
  fi

  if [[ "$DO_TRAP" == "1" ]]; then
    ensure_trap_project
    ( cd "$TRAP_PROJECT_DIR" && drosera_apply_trap ) || {
      err "drosera apply thất bại."
      exit 4
    }
  fi

  if [[ "$DO_OPTIN" == "1" ]]; then
    drosera_opt_in "" || warn "Opt-in có thể chưa hoàn tất; xem $LOG_DIR/optin.log"
  fi

  reset_operator_stack || true
  start_operator || warn "Operator chưa ổn định; xem: docker logs -f drosera-operator"

  register_operator || true

  info "Done."
}

main "$@"
