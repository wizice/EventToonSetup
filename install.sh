#!/bin/bash
#
# EventToon ARM64 설치 스크립트
#
# 사용법:
#   curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash
#   bash install.sh                              # 신규 설치
#   bash install.sh --token TOKEN                # 토큰 포함 설치 (리포트에 토큰 첨부)
#   bash install.sh --update                     # 바이너리만 업데이트
#   bash install.sh --tunnel TUNNEL_TOKEN        # Cloudflare 터널 토큰 설정
#   bash install.sh --status                     # 상태 확인
#
set -euo pipefail

SETUP_BASE="https://raw.githubusercontent.com/wizice/EventToonSetup/main"
REPORT_BASE="https://fit.wizice.com/api/device"
VERSION="${EVENTTOON_VERSION:-latest}"
INSTALL_DIR="/usr/local/bin"
SPOOL_DIR="/var/spool/eventtoon"
SCRIPTS_DIR="/opt/eventtoon/scripts"
LOG_DIR="/var/log"
DEPLOY_TOKEN=""
MODE="install"

# 인자 파싱
while [ $# -gt 0 ]; do
    case "$1" in
        --token|-k)  DEPLOY_TOKEN="${2:-}"; shift 2 ;;
        --update|-u) MODE="update"; shift ;;
        --tunnel|-t) MODE="tunnel"; TUNNEL_TOKEN="${2:-}"; shift 2 ;;
        --status|-s) MODE="status"; shift ;;
        *)           shift ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_LOG="/var/log/eventtoon-install.log"
STEP_FILE="/var/spool/eventtoon/.install_step"
REPORT_URL="${REPORT_BASE}/install-report"
HOSTNAME_ID=$(hostname 2>/dev/null || echo "unknown")
mkdir -p "$(dirname "$INSTALL_LOG")" "$(dirname "$STEP_FILE")" 2>/dev/null || true

# 서버에 설치 상태 리포팅 (best effort)
report() {
    local status="$1"   # progress | success | failed
    local step_name="$2"
    local message="${3:-}"
    curl -sSL --max-time 5 -X POST "$REPORT_URL" \
        -H "Content-Type: application/json" \
        -d "{\"hostname\":\"$HOSTNAME_ID\",\"status\":\"$status\",\"step\":\"$step_name\",\"message\":\"$message\",\"token\":\"$DEPLOY_TOKEN\",\"timestamp\":\"$(date -Iseconds)\"}" \
        >/dev/null 2>&1 || true
}

log()   { echo -e "${GREEN}[EventToon]${NC} $*" | tee -a "$INSTALL_LOG"; }
warn()  { echo -e "${YELLOW}[경고]${NC} $*" | tee -a "$INSTALL_LOG"; }
error() {
    echo -e "${RED}[에러]${NC} $*" | tee -a "$INSTALL_LOG"
    local last_step=$(cat "$STEP_FILE" 2>/dev/null || echo "unknown")
    report "failed" "$last_step" "$*"
    echo "FAILED at $last_step: $*" >> "$STEP_FILE"
    exit 1
}
step()  {
    echo "$1" > "$STEP_FILE"
    log "── 단계: $1 ──"
    report "progress" "$1" ""
}

# ── 사전 확인 ──

check_prerequisites() {
    step "1/9 사전 확인"
    # root 확인
    [ "$(id -u)" -eq 0 ] || error "root 권한이 필요합니다. sudo bash install.sh"

    # 토큰 (선택사항 — 있으면 리포트에 포함)
    if [ -z "$DEPLOY_TOKEN" ]; then
        warn "토큰 미지정 — 설치 리포트에 토큰 없이 hostname만 전송됩니다."
    fi

    # 아키텍처 확인
    ARCH=$(uname -m)
    if [ "$ARCH" != "aarch64" ]; then
        error "ARM64 전용입니다. 현재: $ARCH"
    fi

    # GitHub 연결 확인
    if ! curl -sSL --max-time 5 "${SETUP_BASE}/VERSION" -o /dev/null 2>/dev/null; then
        error "GitHub 연결 실패 — 인터넷 상태를 확인하세요."
    fi

    log "사전 확인 완료 (ARM64, root, 네트워크 OK)"
}

# ── 의존성 설치 ──

install_dependencies() {
    step "3/9 의존성 설치"

    # 필수 저장소 활성화 (main restricted universe)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "focal")
    local sources_file="/etc/apt/sources.list"

    # main restricted가 없으면 추가
    if ! grep -qE "^deb .* ${codename} main" "$sources_file" 2>/dev/null; then
        echo "deb http://ports.ubuntu.com/ubuntu-ports ${codename} main restricted" >> "$sources_file"
        log "main restricted 저장소 추가"
    fi

    # universe 저장소 활성화
    if command -v add-apt-repository >/dev/null 2>&1; then
        add-apt-repository -y universe 2>/dev/null || true
    else
        apt-get install -y -qq software-properties-common 2>/dev/null || true
        add-apt-repository -y universe 2>/dev/null || true
    fi

    apt-get update -qq

    # ffmpeg (MP4 재생)
    apt-get install -y -qq ffmpeg libavcodec-dev libavformat-dev libavutil-dev \
        libswscale-dev libswresample-dev libavfilter-dev libavdevice-dev \
        libpostproc-dev 2>/dev/null

    # NTP 시간 동기화
    if ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        systemctl enable --now systemd-timesyncd 2>/dev/null || true
        log "NTP 시간 동기화 활성화"
    fi

    # CUPS (프린터)
    apt-get install -y -qq cups 2>/dev/null || true

    log "의존성 설치 완료"
}

# ── 바이너리 다운로드 ──

download_binaries() {
    step "4/9 바이너리 다운로드"

    local download_url="${SETUP_BASE}/binaries"

    local bins="eventtoon eventtoon-display eventtoon-fetcher eventtoon-printer eventtoon-player"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    for bin in $bins; do
        log "  다운로드: $bin"
        if curl -sSL --max-time 120 \
            -o "${tmp_dir}/${bin}" \
            "${download_url}/${bin}-arm64" 2>/dev/null; then
            if file "${tmp_dir}/${bin}" | grep -q "ELF.*aarch64"; then
                chmod +x "${tmp_dir}/${bin}"
            else
                warn "$bin — 유효하지 않은 바이너리 (스킵)"
                rm -f "${tmp_dir}/${bin}"
            fi
        else
            warn "$bin — 다운로드 실패 (스킵)"
        fi
    done

    # 교체
    for bin in $bins; do
        if [ -f "${tmp_dir}/${bin}" ]; then
            mv "${tmp_dir}/${bin}" "${INSTALL_DIR}/${bin}"
            log "  ✓ ${bin}"
        fi
    done

    rm -rf "$tmp_dir"

    # 버전 기록 (--version이 블로킹될 수 있으므로 timeout 사용)
    local ver
    ver=$(timeout 3 "${INSTALL_DIR}/eventtoon-display" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    if [ -z "$ver" ]; then
        # GitHub의 VERSION 파일에서 가져오기
        ver=$(curl -sSL --max-time 5 "${SETUP_BASE}/VERSION" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    fi
    echo "$ver" > "${SPOOL_DIR}/installed_version"
    log "바이너리 설치 완료 (v$ver)"
}

# ── 디렉토리 생성 ──

create_directories() {
    step "2/9 디렉토리 생성"
    mkdir -p "$SPOOL_DIR"/{albums,done,pending}
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$LOG_DIR"

    # 기본 config.toml 생성 (없으면) — fetcher가 [push_print] 없이 panic하는 것 방지
    if [ ! -f "${SPOOL_DIR}/config.toml" ]; then
        cat > "${SPOOL_DIR}/config.toml" << 'CONFIG'
# EventToon 설정 파일

[bixolon]
cups_printer_name = "SLP-DX423"
label_width = 1200
label_height = 1800
density = 14
speed = 3
gap = 20

[image_processing]
gamma = 0.8
contrast = 1.4
edge_strength = 1.2
enable_dithering = true
enable_edge_enhancement = true
skip_resize = false

[woosim]
max_image_width = 384
command_delay_ms = 150
image_delay_ms = 400
max_retry_count = 3

[push_print]
server_url = "https://smileprint-fcm-api.wizice100.workers.dev/api"
device_id = "CHANGE_ME"
location = "CHANGE_ME"
poll_interval_secs = 1
cooldown_ms = 500
CONFIG
        log "기본 config.toml 생성 (device_id, location 설정 필요)"
    fi

    log "디렉토리 생성 완료"
}

# ── 스크립트 설치 ──

install_scripts() {
    step "5/9 스크립트 설치"
    local scripts_url="https://raw.githubusercontent.com/wizice/EventToonSetup/main/scripts"

    for script in auto-update.sh services-toggle.sh console-toggle.sh; do
        log "  스크립트: $script"
        curl -sSL -o "${SCRIPTS_DIR}/${script}" "${scripts_url}/${script}" 2>/dev/null || true
        chmod +x "${SCRIPTS_DIR}/${script}" 2>/dev/null || true
    done

    # 설치 리포트용 토큰 저장 (있으면)
    if [ -n "$DEPLOY_TOKEN" ]; then
        echo "$DEPLOY_TOKEN" > "${SPOOL_DIR}/.deploy_token"
        chmod 600 "${SPOOL_DIR}/.deploy_token"
    fi

    log "스크립트 설치 완료"
}

# ── systemd 서비스 ──

install_services() {
    step "7/9 systemd 서비스 등록"

    # eventtoon (IPP 서버)
    cat > /etc/systemd/system/eventtoon.service << 'UNIT'
[Unit]
Description=EventToon IPP Print Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/spool/eventtoon
ExecStart=/usr/local/bin/eventtoon --ipp-port 9999
Restart=on-failure
RestartSec=3
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
UNIT

    # eventtoon-display
    cat > /etc/systemd/system/eventtoon-display.service << 'UNIT'
[Unit]
Description=EventToon Display UI
After=eventtoon-fetcher.service time-sync.target network-online.target

[Service]
Type=notify
User=root
WorkingDirectory=/var/spool/eventtoon
ExecStartPre=/opt/eventtoon/scripts/auto-update.sh
ExecStart=/usr/local/bin/eventtoon-display
ExecStopPost=/opt/eventtoon/scripts/console-toggle.sh on
Restart=on-failure
RestartSec=3
WatchdogSec=30
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
UNIT

    # eventtoon-fetcher
    cat > /etc/systemd/system/eventtoon-fetcher.service << 'UNIT'
[Unit]
Description=EventToon Print Job Fetcher
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/spool/eventtoon
ExecStart=/usr/local/bin/eventtoon-fetcher
Restart=on-failure
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable eventtoon eventtoon-display eventtoon-fetcher
    log "systemd 서비스 등록 완료"
}

# ── Cloudflare Tunnel ──

setup_tunnel() {
    local token="$1"

    # cloudflared 설치 (없으면)
    if ! command -v cloudflared >/dev/null 2>&1; then
        log "cloudflared 설치 중..."
        curl -sSL -o /tmp/cloudflared.deb \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" \
            && dpkg -i /tmp/cloudflared.deb \
            && rm /tmp/cloudflared.deb \
            || warn "cloudflared 설치 실패"
    fi

    if [ -n "$token" ]; then
        # 토큰 기반 서비스 등록
        cloudflared service install "$token" 2>/dev/null || true
        systemctl enable --now cloudflared 2>/dev/null || true
        log "Cloudflare Tunnel 설정 완료"
    else
        log "Cloudflare Tunnel: 토큰 없음 — 수동 설정 필요"
        log "  설정 방법: bash install.sh --tunnel YOUR_TOKEN"
    fi
}

# ── 서비스 시작 ──

start_services() {
    log "서비스 시작 중..."
    systemctl start eventtoon 2>/dev/null || warn "eventtoon 시작 실패"
    systemctl start eventtoon-fetcher 2>/dev/null || warn "eventtoon-fetcher 시작 실패"
    systemctl start eventtoon-display 2>/dev/null || warn "eventtoon-display 시작 실패"

    sleep 2
    echo ""
    log "═══════════════════════════════════════"
    log "  EventToon 설치 완료!"
    log "═══════════════════════════════════════"
    echo ""

    local ver
    ver=$(cat "${SPOOL_DIR}/installed_version" 2>/dev/null || echo "unknown")
    log "버전: v$ver"
    log "설정: 키보드 S키 → 설정 화면"
    echo ""

    # 상태 표시
    for svc in eventtoon eventtoon-display eventtoon-fetcher; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        if [ "$state" = "active" ]; then
            log "  ✓ $svc — 실행 중"
        else
            warn "  ✗ $svc — $state"
        fi
    done
    echo ""
}

# ── 메인 ──

case "$MODE" in
    update)
        check_prerequisites
        create_directories
        download_binaries
        install_scripts
        install_services
        log "서비스 재시작..."
        systemctl restart eventtoon-display eventtoon-fetcher eventtoon 2>/dev/null || true
        log "업데이트 완료!"
        ;;

    tunnel)
        if [ -z "${TUNNEL_TOKEN:-}" ]; then
            error "토큰을 지정하세요: bash install.sh --tunnel YOUR_TOKEN"
        fi
        setup_tunnel "$TUNNEL_TOKEN"
        ;;

    status)
        for svc in eventtoon eventtoon-display eventtoon-fetcher cloudflared; do
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            printf "%-25s %s\n" "$svc" "$state"
        done
        ver=$(cat "${SPOOL_DIR}/installed_version" 2>/dev/null || echo "unknown")
        echo "버전: v$ver"
        ;;

    install)
        check_prerequisites
        create_directories
        install_dependencies
        download_binaries
        install_scripts

        # 기존 서비스 중지 (Docker, MariaDB, Apache, crontab 등)
        step "6/9 기존 서비스 중지"
        if [ -x "${SCRIPTS_DIR}/services-toggle.sh" ]; then
            "${SCRIPTS_DIR}/services-toggle.sh" stop || true
        fi

        install_services

        step "8/9 Cloudflare Tunnel"
        setup_tunnel ""

        step "9/9 서비스 시작"
        start_services

        # 설치 성공 리포팅
        ver=$(cat "${SPOOL_DIR}/installed_version" 2>/dev/null || echo "unknown")
        report "success" "완료" "v${ver} 설치 성공"
        ;;

    *)
        echo "사용법:"
        echo "  curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash"
        echo ""
        echo "  --token TOKEN    리포트용 토큰 (선택, 없으면 hostname만 전송)"
        echo "  --update         바이너리만 업데이트"
        echo "  --tunnel TOKEN   Cloudflare 터널 설정"
        echo "  --status         상태 확인"
        exit 1
        ;;
esac
