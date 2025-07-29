#!/usr/bin/env bash
# drosera.sh - v1.2.2
# - Fix idempotent register: coi OperatorAlreadyRegistered là thành công, không retry
# - Skip register nếu đã đăng ký trước đó (state file + pk hash), hỗ trợ --force-register
# - Đợi container ổn định thực sự trước khi register
# - Multiaddr luôn UDP/QUIC v1, ưu tiên IPv4, dọn stack cũ an toàn, mở cổng UDP
# - Không source ~/.bashrc (tránh "PS1: unbound variable"); tolerate thiếu Drosera CLI

set -Eeuo pipefail

SCRIPT_VERSION="v1.2.2"
DEFAULT_P2P_PORT="${DEFAULT_P2P_PORT:-31313}"
DROSERA_REPO_URL="${DROSERA_REPO_URL:-https://github.com/laodauhgc/drosera-network}"
ROOT_DIR="${ROOT_DIR:-/root}"
BASE_DIR="${BASE_DIR:-$ROOT_DIR/drosera-network}"
ENV_FILE="$BASE_DIR/.env"
LOG_DIR="/var/log/drosera"
APPLY_LOG="$LOG_DIR/apply.log"
REGISTER_LOG="$LOG_DIR/register.log"
STATE_DIR="/var/lib/drosera"
PREFER_IPV6="${PREFER_IPV6:-0}"
NO_REGISTER="${NO_REGISTER:-0}"
CUSTOM_MADDR="${CUSTOM_MADDR:-}"
CUSTOM_PORT="${CUSTOM_PORT:-$DEFAULT_P2P_PORT}"
FORCE_REGISTER="0"

timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }
_log() { echo "$(timestamp)  $*"; }
info() { _log "$@"; }
warn() { _log "WARNING: $*"; }
err () { _log "ERROR: $*"; }
die () { err "$*"; exit 1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die "Vui lòng chạy bằng user root."; }

mask_pk() {
  local pk="${1:-}"
  [[ -z "$pk" ]] && { echo ""; return; }
  [[ "${#pk}" -le 10 ]] && { echo "$pk"; return; }
  echo "${pk:0:6}******${pk: -6}"
}

apt_install_base() {
  info "Updating apt & installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release git jq unzip \
    iproute2 dnsutils netcat-openbsd ufw iptables \
    apt-transport-https software-properties-common >/dev/null
}

ensure_docker() {
  info "Docker already installed. Upgrading if needed..."
  if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-plugin >/dev/null
  else
    apt-get install -y docker-compose-plugin >/dev/null || true
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true
}

ensure_bun() {
  if command -v bun >/dev/null 2>&1; then
    info "Bun already installed."
    return
  fi
  info "Installing Bun..."
  export BUN_INSTALL="$HOME/.bun"
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
  export PATH="$BUN_INSTALL/bin:$PATH"
}

ensure_foundry() {
  if command -v forge >/dev/null 2>&1; then
    info "Foundry already installed; running foundryup..."
    if [[ -x "$HOME/.foundry/bin/foundryup" ]]; then
      "$HOME/.foundry/bin/foundryup" >/dev/null 2>&1 || true
    fi
    return
  fi
  info "Installing Foundry..."
  curl -L https://foundry.paradigm.xyz | bash >/dev/null 2>&1 || true
  if [[ -x "$HOME/.foundry/bin/foundryup" ]]; then
    "$HOME/.foundry/bin/foundryup" >/dev/null 2>&1 || true
    export PATH="$HOME/.foundry/bin:$PATH"
  fi
}

check_drosera_cli() { command -v drosera >/dev/null 2>&1 && echo "1" || echo "0"; }

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS https://ifconfig.co || true)"
  echo "$ip" | trim
}

get_public_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS https://api64.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(dig +short -6 myip.opendns.com @resolver1.opendns.com || true)"
  [[ -z "$ip" ]] && ip="$(curl -6 -fsS https://ifconfig.co || true)"
  echo "$ip" | trim
}

build_multiaddr() {
  local ip="$1"; local port="${2:-$DEFAULT_P2P_PORT}"
  if [[ "$ip" == *:* ]]; then
    echo "/ip6/${ip}/udp/${port}/quic-v1"
  else
    echo "/ip4/${ip}/udp/${port}/quic-v1"
  fi
}

build_tcp_multiaddr() {
  local ip="$1"; local port="${2:-$DEFAULT_P2P_PORT}"
  if [[ "$ip" == *:* ]]; then
    echo "/ip6/${ip}/tcp/${port}"
  else
    echo "/ip4/${ip}/tcp/${port}"
  fi
}

pick_public_ip() {
  local ip4 ip6
  if [[ "${PREFER_IPV6}" == "1" ]]; then
    ip6="$(get_public_ipv6)"
    [[ -n "$ip6" ]] && { echo "$ip6"; return; }
    ip4="$(get_public_ipv4)"; echo "$ip4"; return
  else
    ip4="$(get_public_ipv4)"
    [[ -n "$ip4" ]] && { echo "$ip4"; return; }
    ip6="$(get_public_ipv6)"; echo "$ip6"; return
  fi
}

ensure_repo() {
  if [[ -d "$BASE_DIR/.git" ]]; then
    info "Syncing drosera-network at $BASE_DIR ..."
    (cd "$BASE_DIR" && git fetch --depth=1 origin main >/dev/null 2>&1 && git reset --hard origin/main >/dev/null 2>&1) || true
  else
    info "Cloning drosera-network into $BASE_DIR ..."
    rm -rf "$BASE_DIR" 2>/dev/null || true
    git clone --depth=1 "$DROSERA_REPO_URL" "$BASE_DIR" >/dev/null 2>&1 || mkdir -p "$BASE_DIR"
  fi
}

write_env() {
  local pk="$1"; local ip="$2"; local port="${3:-$DEFAULT_P2P_PORT}"; local maddr="$4"
  local tcp_maddr
  mkdir -p "$(dirname "$ENV_FILE")"
  [[ -n "$pk" && "$pk" != 0x* ]] && pk="0x$pk"

  if grep -q '^ETH_PRIVATE_KEY=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^ETH_PRIVATE_KEY=.*#ETH_PRIVATE_KEY=${pk}#g" "$ENV_FILE"
  else
    echo "ETH_PRIVATE_KEY=${pk}" >> "$ENV_FILE"
  fi
  info "Wrote ETH_PRIVATE_KEY=$(mask_pk "$pk") to $ENV_FILE"

  if grep -q '^DROSERA_PRIVATE_KEY=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^DROSERA_PRIVATE_KEY=.*#DROSERA_PRIVATE_KEY=${pk}#g" "$ENV_FILE"
  else
    echo "DROSERA_PRIVATE_KEY=${pk}" >> "$ENV_FILE"
  fi

  if grep -q '^VPS_IP=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^VPS_IP=.*#VPS_IP=${ip}#g" "$ENV_FILE"
  else
    echo "VPS_IP=${ip}" >> "$ENV_FILE"
  fi
  info "Wrote VPS_IP=${ip} to $ENV_FILE"

  if grep -q '^EXTERNAL_P2P_MADDR=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^EXTERNAL_P2P_MADDR=.*#EXTERNAL_P2P_MADDR=${maddr}#g" "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_MADDR=${maddr}" >> "$ENV_FILE"
  fi
  info "Wrote EXTERNAL_P2P_MADDR=${maddr} to $ENV_FILE"

  tcp_maddr="$(build_tcp_multiaddr "$ip" "$port")"
  if grep -q '^EXTERNAL_P2P_TCP_MADDR=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^EXTERNAL_P2P_TCP_MADDR=.*#EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}#g" "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}" >> "$ENV_FILE"
  fi
  info "Wrote EXTERNAL_P2P_TCP_MADDR=${tcp_maddr} to $ENV_FILE"
}

ensure_trap_project() {
  local trap_dir="$ROOT_DIR/my-drosera-trap"
  info "Initializing trap project at $trap_dir ..."
  if [[ ! -d "$trap_dir/.git" ]]; then
    mkdir -p "$trap_dir"
    (cd "$trap_dir" && git init >/dev/null 2>&1) || true
  else
    info "Found existing repo in $trap_dir; syncing deps..."
  fi
  if command -v bun >/dev/null 2>&1; then
    (cd "$trap_dir" && bun install >/dev/null 2>&1) || true
  fi
}

maybe_drosera_apply() {
  mkdir -p "$LOG_DIR"
  : > "$APPLY_LOG"
  if [[ "$(check_drosera_cli)" == "1" ]]; then
    info "Running: drosera apply (non-interactive)"
    (DROSERA_PRIVATE_KEY="${ETH_PK:-}" drosera apply -y) >>"$APPLY_LOG" 2>&1 || {
      warn "Apply failed. See $APPLY_LOG"
      return 0
    }
  else
    warn "Drosera CLI not found in PATH. If you have a local CLI, ensure it's installed."
    warn "Drosera CLI missing; skipped 'drosera apply'."
  fi
}

compose_down_safe() { (cd "$BASE_DIR" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true; }

remove_old_container_volume() {
  docker rm -f drosera-operator >/dev/null 2>&1 || true
  docker volume rm "${PWD##*/}_drosera_data" >/dev/null 2>&1 || true
  docker volume rm "drosera-network_drosera_data" >/dev/null 2>&1 || true
}

pull_operator_image() {
  info "Pulling latest operator image..."
  docker pull ghcr.io/drosera-network/drosera-operator:v1.20.0 >/dev/null 2>&1 || true
}

start_stack() {
  info "Starting operator stack..."
  (cd "$BASE_DIR" && docker compose up -d >/dev/null 2>&1) || die "Cannot start docker compose."
}

wait_container_stable() {
  local name="drosera-operator" timeout=120 elapsed=0
  info "Waiting up to ${timeout}s for container '${name}' to stabilize..."
  local last_restart=""; last_restart="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "")"
  while (( elapsed < timeout )); do
    local state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")"
    if [[ "$state" == "running" ]]; then
      # cần có log lắng nghe + không có invalid protocol gần đây
      if docker logs --since 10s "$name" 2>&1 | grep -qi "invalid protocol string"; then
        sleep 2; elapsed=$((elapsed+2)); continue
      fi
      if docker logs --since 20s "$name" 2>&1 | grep -qi "Listening on /ip"; then
        # giữ ổn định thêm 5s
        sleep 5
        local new_restart="$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "")"
        if [[ -n "$last_restart" && "$new_restart" == "$last_restart" ]]; then
          info "Container is running and appears stable."
          return 0
        fi
        last_restart="$new_restart"
      fi
    fi
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

mark_registered_ok() {
  local pk_clean="$1"
  mkdir -p "$STATE_DIR"
  local pk_hash; pk_hash="$(printf "%s" "$pk_clean" | sha256sum | awk '{print $1}')"
  echo "$pk_hash" > "$STATE_DIR/registered.ok"
}

was_registered_with_this_pk() {
  local pk_clean="$1"
  [[ -f "$STATE_DIR/registered.ok" ]] || { echo "0"; return; }
  local cur_hash; cur_hash="$(printf "%s" "$pk_clean" | sha256sum | awk '{print $1}')"
  local prev_hash; prev_hash="$(cat "$STATE_DIR/registered.ok" 2>/dev/null || echo "")"
  [[ "$cur_hash" == "$prev_hash" ]] && echo "1" || echo "0"
}

register_operator() {
  local name="drosera-operator"
  mkdir -p "$LOG_DIR"
  : > "$REGISTER_LOG"

  [[ "$NO_REGISTER" == "1" ]] && { info "NO_REGISTER=1 → skipping operator register."; return 0; }

  # Đã đăng ký với pk này trước đó?
  if [[ "$FORCE_REGISTER" != "1" ]]; then
    if [[ "$(was_registered_with_this_pk "$ETH_PK_CLEAN")" == "1" ]]; then
      info "Operator was already registered with this private key; skipping register."
      return 0
    fi
  fi

  # Container phải đang chạy
  if [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo)" != "running" ]]; then
    warn "Container not running; skip register. Check logs."
    return 0
  fi

  info "Registering Drosera Operator..."
  local delays=(10 20 40 80)
  local attempt=0
  for d in "${delays[@]}"; do
    attempt=$((attempt+1))
    # chạy và bắt output + exit code
    set +e
    local out
    out="$(docker exec "$name" /drosera-operator register 2>&1)"
    local rc=$?
    set -e
    echo "$out" >> "$REGISTER_LOG"

    # Nhận diện "OperatorAlreadyRegistered" => coi như thành công
    if echo "$out" | grep -qi "OperatorAlreadyRegistered"; then
      info "Operator is already registered on-chain. Treating as success."
      mark_registered_ok "$ETH_PK_CLEAN"
      return 0
    fi

    if [[ $rc -eq 0 ]]; then
      info "Register successful."
      mark_registered_ok "$ETH_PK_CLEAN"
      return 0
    fi

    # Nếu gặp lỗi rate limit / không sẵn sàng → retry
    if echo "$out" | grep -Eqi "rate limit|429|temporar|try again|timeout"; then
      warn "Register attempt $attempt failed due to rate/temporary error; retrying in ${d}s..."
      sleep "$d"
      # nếu container die trong lúc chờ thì dừng
      [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo)" == "running" ]] || { warn "Container not running; abort register retries."; break; }
      continue
    fi

    # Lỗi khác → không retry vô hạn, nhưng thử theo lịch delays
    warn "Register attempt $attempt failed; retrying in ${d}s..."
    sleep "$d"
    [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo)" == "running" ]] || { warn "Container not running; abort register retries."; break; }
  done

  warn "Register command failed; see $REGISTER_LOG"
  return 0
}

open_ports() {
  ufw allow "${CUSTOM_PORT}/udp" >/dev/null 2>&1 || true
  iptables -I INPUT -p udp --dport "${CUSTOM_PORT}" -j ACCEPT >/dev/null 2>&1 || true
}

ETH_PK=""
AUTO="0"

usage() {
  cat <<EOF
Usage: $0 [--auto] --pk <hex|0xhex> [--prefer-ipv6] [--maddr <multiaddr>] [--port <31313>]
       [--no-register] [--force-register]

Options:
  --auto            Chạy không hỏi (non-interactive).
  --pk <key>        Private key EVM (64 hex), có thể kèm '0x' hoặc không.
  --prefer-ipv6     Ưu tiên IPv6 (mặc định ưu tiên IPv4).
  --maddr <maddr>   Ghi đè EXTERNAL_P2P_MADDR (vd: /ip4/1.2.3.4/udp/31313/quic-v1).
  --port <p>        P2P port (mặc định 31313).
  --no-register     Không chạy bước register trong container.
  --force-register  Bỏ qua cache, buộc chạy register (dù pk cũ).
  -h|--help         Hiển thị trợ giúp.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO="1"; shift ;;
    --pk) ETH_PK="${2:-}"; shift 2 ;;
    --prefer-ipv6) PREFER_IPV6="1"; shift ;;
    --maddr) CUSTOM_MADDR="${2:-}"; shift 2 ;;
    --port) CUSTOM_PORT="${2:-$DEFAULT_P2P_PORT}"; shift 2 ;;
    --no-register) NO_REGISTER="1"; shift ;;
    --force-register) FORCE_REGISTER="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1. Use --help for usage." ;;
  esac
done

main() {
  require_root
  mkdir -p "$LOG_DIR" "$STATE_DIR"

  [[ -n "$ETH_PK" ]] || die "Thiếu --pk. Ví dụ: --pk 0b68ef...ef97fc"
  info "Using Private Key: $(mask_pk "$ETH_PK")"

  apt_install_base
  ensure_docker
  ensure_bun
  ensure_foundry

  local pub_ip
  pub_ip="$(pick_public_ip)"
  [[ -n "$pub_ip" ]] || die "Không xác định được Public IP (IPv4/IPv6). Hãy thử lại hoặc cung cấp --maddr."
  info "Using Public IP: ${pub_ip}"

  ensure_repo

  local maddr
  if [[ -n "$CUSTOM_MADDR" ]]; then
    maddr="$CUSTOM_MADDR"
  else
    maddr="$(build_multiaddr "$pub_ip" "$CUSTOM_PORT")"
  fi

  # Chuẩn hoá pk và lưu bản sạch (để hash)
  local ETH_PK_NORM="$ETH_PK"
  [[ "$ETH_PK_NORM" != 0x* ]] && ETH_PK_NORM="0x$ETH_PK_NORM"
  export ETH_PK="$ETH_PK_NORM"
  export ETH_PK_CLEAN="$ETH_PK_NORM"

  write_env "$ETH_PK_NORM" "$pub_ip" "$CUSTOM_PORT" "$maddr"
  open_ports
  ensure_trap_project
  ETH_PK="$ETH_PK_NORM" maybe_drosera_apply

  info "Resetting operator stack (container & volume)..."
  (cd "$BASE_DIR" && compose_down_safe)
  remove_old_container_volume
  pull_operator_image
  start_stack

  if ! wait_container_stable; then
    warn "Container not stable after 120s."
    warn "Operator not stable; you may check logs: docker logs -f drosera-operator"
    # Khi container chưa ổn định, không register để tránh lỗi thừa
    info "Skipping register because container isn't stable."
    info "Done."
    exit 0
  fi

  register_operator
  info "Done."
}

main "$@"
