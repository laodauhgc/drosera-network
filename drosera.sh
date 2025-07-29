#!/usr/bin/env bash
# drosera.sh - v1.2.1
# - Sửa lỗi EXTERNAL_P2P_MADDR sai giao thức → luôn UDP/QUIC v1
# - Ưu tiên IPv4 khi lấy public IP (fallback IPv6 hoặc --prefer-ipv6)
# - Reset stack an toàn, xoá container/volume cũ nếu tồn tại
# - Ghi ETH_PRIVATE_KEY, DROSERA_PRIVATE_KEY, VPS_IP, EXTERNAL_P2P_MADDR
# - Không phụ thuộc việc source ~/.bashrc (tránh "PS1: unbound variable")
# - Chịu lỗi thiếu Drosera CLI (skip apply) nhưng vẫn khởi chạy operator

set -Eeuo pipefail

SCRIPT_VERSION="v1.2.1"
DEFAULT_P2P_PORT="${DEFAULT_P2P_PORT:-31313}"
DROSERA_REPO_URL="${DROSERA_REPO_URL:-https://github.com/laodauhgc/drosera-network}"
ROOT_DIR="${ROOT_DIR:-/root}"
BASE_DIR="${BASE_DIR:-$ROOT_DIR/drosera-network}"
ENV_FILE="$BASE_DIR/.env"
LOG_DIR="/var/log/drosera"
APPLY_LOG="$LOG_DIR/apply.log"
REGISTER_LOG="$LOG_DIR/register.log"
PREFER_IPV6="${PREFER_IPV6:-0}"
NO_REGISTER="${NO_REGISTER:-0}"
CUSTOM_MADDR="${CUSTOM_MADDR:-}"
CUSTOM_PORT="${CUSTOM_PORT:-$DEFAULT_P2P_PORT}"

# ---------- utils ----------
timestamp() { date +"%Y-%m-%dT%H:%M:%S%z"; }
_log() { echo "$(timestamp)  $*"; }
info() { _log "$@"; }
warn() { _log "WARNING: $*"; }
err () { _log "ERROR: $*"; }
die () { err "$*"; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Vui lòng chạy bằng user root."
  fi
}

mask_pk() {
  local pk="$1"
  if [[ -z "$pk" ]]; then echo ""; return; fi
  if [[ "${#pk}" -le 10 ]]; then echo "$pk"; return; fi
  echo "${pk:0:6}******${pk: -6}"
}

# ---------- deps ----------
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
  command -v bun >/dev/null 2>&1 || warn "Bun install may have failed; continuing."
}

ensure_foundry() {
  if command -v forge >/dev/null 2>&1; then
    info "Foundry already installed; running foundryup..."
    # Không source ~/.bashrc để tránh 'PS1: unbound variable'
    if [[ -x "$HOME/.foundry/bin/foundryup" ]]; then
      "$HOME/.foundry/bin/foundryup" >/dev/null 2>&1 || true
    else
      warn "foundryup not found; skipping update."
    fi
    return
  fi
  info "Installing Foundry..."
  curl -L https://foundry.paradigm.xyz | bash >/dev/null 2>&1 || true
  if [[ -x "$HOME/.foundry/bin/foundryup" ]]; then
    "$HOME/.foundry/bin/foundryup" >/dev/null 2>&1 || true
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    warn "Foundry install may have failed; continuing."
  fi
}

check_drosera_cli() {
  if command -v drosera >/dev/null 2>&1; then
    echo "1"
  else
    echo "0"
  fi
}

# ---------- IP & multiaddr ----------
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

get_public_ipv4() {
  local ip=""
  ip="$(curl -4 -fsS https://api.ipify.org || true)"
  if [[ -z "$ip" ]]; then ip="$(dig +short -4 myip.opendns.com @resolver1.opendns.com || true)"; fi
  if [[ -z "$ip" ]]; then ip="$(curl -4 -fsS https://ifconfig.co || true)"; fi
  echo "$ip" | trim
}

get_public_ipv6() {
  local ip=""
  ip="$(curl -6 -fsS https://api64.ipify.org || true)"
  if [[ -z "$ip" ]]; then ip="$(dig +short -6 myip.opendns.com @resolver1.opendns.com || true)"; fi
  if [[ -z "$ip" ]]; then ip="$(curl -6 -fsS https://ifconfig.co || true)"; fi
  echo "$ip" | trim
}

build_multiaddr() {
  local ip="$1"; local port="${2:-$DEFAULT_P2P_PORT}"
  if [[ "$ip" == *:* ]]; then
    # IPv6
    echo "/ip6/${ip}/udp/${port}/quic-v1"
  else
    # IPv4
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
  if [[ "$PREFER_IPV6" == "1" ]]; then
    ip6="$(get_public_ipv6)"
    if [[ -n "$ip6" ]]; then echo "$ip6"; return; fi
    ip4="$(get_public_ipv4)"
    echo "$ip4"; return
  else
    ip4="$(get_public_ipv4)"
    if [[ -n "$ip4" ]]; then echo "$ip4"; return; fi
    ip6="$(get_public_ipv6)"
    echo "$ip6"; return
  fi
}

# ---------- repo sync ----------
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

# ---------- .env writer ----------
write_env() {
  local pk="$1"; local ip="$2"; local port="${3:-$DEFAULT_P2P_PORT}"; local maddr="$4"
  local tcp_maddr
  mkdir -p "$(dirname "$ENV_FILE")"

  # chuẩn hoá private key
  if [[ -n "$pk" && "$pk" != 0x* ]]; then pk="0x$pk"; fi

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

  # Tuỳ chọn: ghi thêm TCP maddr (một số tool nội bộ có thể cần)
  tcp_maddr="$(build_tcp_multiaddr "$ip" "$port")"
  if grep -q '^EXTERNAL_P2P_TCP_MADDR=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s#^EXTERNAL_P2P_TCP_MADDR=.*#EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}#g" "$ENV_FILE"
  else
    echo "EXTERNAL_P2P_TCP_MADDR=${tcp_maddr}" >> "$ENV_FILE"
  fi
  info "Wrote EXTERNAL_P2P_TCP_MADDR=${tcp_maddr} to $ENV_FILE"
}

# ---------- trap project (best-effort) ----------
ensure_trap_project() {
  local trap_dir="$ROOT_DIR/my-drosera-trap"
  info "Initializing trap project at $trap_dir ..."
  if [[ -d "$trap_dir/.git" ]]; then
    info "Found existing repo in $trap_dir; syncing deps..."
  else
    mkdir -p "$trap_dir"
    (cd "$trap_dir" && git init >/dev/null 2>&1) || true
  fi

  # try bun install (best-effort)
  if command -v bun >/dev/null 2>&1; then
    (cd "$trap_dir" && bun install >/dev/null 2>&1) || true
  fi
}

maybe_drosera_apply() {
  mkdir -p "$LOG_DIR"
  : > "$APPLY_LOG"
  if [[ "$(check_drosera_cli)" == "1" ]]; then
    info "Running: drosera apply (non-interactive)"
    # Truyền private key vào env cho CLI
    (DROSERA_PRIVATE_KEY="${ETH_PK:-}" drosera apply -y) >>"$APPLY_LOG" 2>&1 || {
      warn "Apply failed. See $APPLY_LOG"
      return 0
    }
  else
    warn "Drosera CLI not found in PATH. If you have a local CLI, ensure it's installed."
    warn "Drosera CLI missing; skipped 'drosera apply'."
  fi
}

# ---------- docker stack ----------
compose_down_safe() {
  (cd "$BASE_DIR" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
}

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
  while (( elapsed < timeout )); do
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")"
    if [[ "$state" == "running" ]]; then
      # nhanh kiểm tra lỗi invalid protocol string trong log gần đây
      if docker logs --since 5s "$name" 2>&1 | grep -qi "invalid protocol string"; then
        warn "Detected 'invalid protocol string' in logs; container may restart."
      else
        return 0
      fi
    fi
    sleep 2; elapsed=$((elapsed+2))
  done
  return 1
}

register_operator() {
  local name="drosera-operator"
  mkdir -p "$LOG_DIR"
  : > "$REGISTER_LOG"

  if [[ "$NO_REGISTER" == "1" ]]; then
    info "NO_REGISTER=1 → skipping operator register."
    return 0
  fi

  if [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo)" != "running" ]]; then
    warn "Container not running; skip register. Check logs."
    return 0
  fi

  info "Registering Drosera Operator..."
  local tries=(10 20 40 80)
  for d in "${tries[@]}"; do
    if docker exec "$name" /drosera-operator register >>"$REGISTER_LOG" 2>&1; then
      info "Register successful."
      return 0
    else
      warn "Register attempt failed; retrying in ${d}s..."
      sleep "$d"
      if [[ "$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo)" != "running" ]]; then
        warn "Container not running; aborting register retries."
        break
      fi
    fi
  done
  warn "Register command failed; see $REGISTER_LOG"
  return 0
}

open_ports() {
  # best-effort mở port UDP 31313
  ufw allow "${CUSTOM_PORT}/udp" >/dev/null 2>&1 || true
  iptables -I INPUT -p udp --dport "${CUSTOM_PORT}" -j ACCEPT >/dev/null 2>&1 || true
}

# ---------- argument parsing ----------
ETH_PK=""
AUTO="0"

usage() {
  cat <<EOF
Usage: $0 [--auto] --pk <hex|0xhex> [--prefer-ipv6] [--maddr <multiaddr>] [--port <31313>]
       [--no-register]

Options:
  --auto            Chạy không hỏi (non-interactive).
  --pk <key>        Private key EVM (64 hex), có thể kèm '0x' hoặc không.
  --prefer-ipv6     Ưu tiên IPv6 (mặc định ưu tiên IPv4).
  --maddr <maddr>   Ghi đè EXTERNAL_P2P_MADDR (vd: /ip4/1.2.3.4/udp/31313/quic-v1).
  --port <p>        P2P port (mặc định 31313).
  --no-register     Không chạy bước register trong container.
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
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1. Use --help for usage." ;;
  esac
done

main() {
  require_root
  mkdir -p "$LOG_DIR"

  if [[ "$AUTO" != "1" && -z "$ETH_PK" ]]; then
    warn "Bạn chưa cung cấp --pk. Chạy với --auto --pk <hex> để tự động."
  fi
  if [[ -z "$ETH_PK" ]]; then
    die "Thiếu --pk. Ví dụ: --pk 0b68ef...ef97fc"
  fi

  info "Using Private Key: $(mask_pk "$ETH_PK")"

  apt_install_base
  ensure_docker
  ensure_bun
  ensure_foundry

  # Lấy public IP (ưu tiên IPv4)
  local pub_ip
  pub_ip="$(pick_public_ip)"
  if [[ -z "$pub_ip" ]]; then
    die "Không xác định được Public IP (IPv4/IPv6). Hãy thử lại hoặc cung cấp --maddr."
  fi
  info "Using Public IP: ${pub_ip}"

  ensure_repo

  # Xây multiaddr (UDP/QUIC v1) hoặc dùng override
  local maddr
  if [[ -n "$CUSTOM_MADDR" ]]; then
    maddr="$CUSTOM_MADDR"
  else
    maddr="$(build_multiaddr "$pub_ip" "$CUSTOM_PORT")"
  fi

  # Ghi .env
  write_env "$ETH_PK" "$pub_ip" "$CUSTOM_PORT" "$maddr"

  # Trap project (best-effort)
  ensure_trap_project

  # drosera apply (nếu có CLI)
  ETH_PK="$ETH_PK" maybe_drosera_apply

  # Reset & khởi chạy stack
  info "Resetting operator stack (container & volume)..."
  (cd "$BASE_DIR" && compose_down_safe)
  remove_old_container_volume
  pull_operator_image
  start_stack

  if ! wait_container_stable; then
    warn "Container not stable after 120s."
    warn "Operator not stable; you may check logs: docker logs -f drosera-operator"
  fi

  # Đăng ký operator (nếu container running)
  register_operator

  info "Done."
}

main "$@"
