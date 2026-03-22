#!/bin/bash
#
# EventToon 자동 업데이트 스크립트
# systemd ExecStartPre에서 실행 — 부팅 시 최신 버전 체크 + 업그레이드
#
# 사용법:
#   ./auto-update.sh              # 자동 업데이트 (최신 릴리즈)
#   ./auto-update.sh --check      # 업데이트 가능 여부만 확인
#   ./auto-update.sh --force      # 강제 재다운로드

set -euo pipefail

REPO="wizice/EventToon"
INSTALL_DIR="/usr/local/bin"
BINS="eventtoon eventtoon-display eventtoon-fetcher eventtoon-printer eventtoon-player"
VERSION_FILE="/var/spool/eventtoon/installed_version"
LOG_FILE="/var/log/eventtoon-update.log"
TIMEOUT=30

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 현재 설치된 버전
get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        # 바이너리에서 버전 추출 시도
        if [ -x "$INSTALL_DIR/eventtoon-display" ]; then
            "$INSTALL_DIR/eventtoon-display" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0"
        else
            echo "0.0.0"
        fi
    fi
}

# GitHub 최신 릴리즈 버전
get_latest_version() {
    curl -sSL --max-time "$TIMEOUT" \
        "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+' \
        || echo ""
}

# 버전 비교 (1=업데이트 필요, 0=최신)
version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" != "$2" ]
}

# 바이너리 다운로드 + 교체
do_update() {
    local version="$1"
    local download_url="https://github.com/$REPO/releases/download/v${version}"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/eventtoon-update-XXXXXX)

    log "다운로드 시작: v$version → $tmp_dir"

    local success=true
    for bin in $BINS; do
        local url="${download_url}/${bin}-arm64"
        local dest="${tmp_dir}/${bin}"

        log "  다운로드: $bin"
        if curl -sSL --max-time 120 -o "$dest" "$url" 2>/dev/null; then
            chmod +x "$dest"
            # 실행 가능한지 간단 체크
            if file "$dest" | grep -q "ELF.*aarch64"; then
                log "  ✓ $bin OK"
            else
                log "  ✗ $bin — 유효하지 않은 바이너리"
                success=false
                break
            fi
        else
            log "  ✗ $bin — 다운로드 실패 (릴리즈에 없을 수 있음, 스킵)"
            # 필수 바이너리가 아니면 스킵 허용
            if [ "$bin" = "eventtoon-display" ] || [ "$bin" = "eventtoon" ]; then
                success=false
                break
            fi
        fi
    done

    if [ "$success" = true ]; then
        # atomic 교체: 다운로드 성공한 것만 교체
        log "바이너리 교체 중..."
        for bin in $BINS; do
            if [ -f "${tmp_dir}/${bin}" ]; then
                # 기존 바이너리 백업
                if [ -f "${INSTALL_DIR}/${bin}" ]; then
                    cp "${INSTALL_DIR}/${bin}" "${INSTALL_DIR}/${bin}.bak"
                fi
                mv "${tmp_dir}/${bin}" "${INSTALL_DIR}/${bin}"
                log "  ✓ ${bin} 교체 완료"
            fi
        done

        echo "$version" > "$VERSION_FILE"
        log "업데이트 완료: v$version"
    else
        log "업데이트 실패 — 기존 버전 유지"
        # 백업에서 복원 (이미 교체된 게 있으면)
        for bin in $BINS; do
            if [ -f "${INSTALL_DIR}/${bin}.bak" ]; then
                mv "${INSTALL_DIR}/${bin}.bak" "${INSTALL_DIR}/${bin}"
            fi
        done
    fi

    # 백업 파일 정리
    for bin in $BINS; do
        rm -f "${INSTALL_DIR}/${bin}.bak"
    done
    rm -rf "$tmp_dir"

    [ "$success" = true ]
}

# ── 메인 ──

mkdir -p "$(dirname "$VERSION_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

CURRENT=$(get_current_version)
log "현재 버전: v$CURRENT"

# 네트워크 체크 (5초 대기)
if ! curl -sSL --max-time 5 "https://api.github.com" >/dev/null 2>&1; then
    log "네트워크 불가 — 업데이트 스킵"
    exit 0
fi

LATEST=$(get_latest_version)
if [ -z "$LATEST" ]; then
    log "최신 버전 조회 실패 — 업데이트 스킵"
    exit 0
fi

log "최신 버전: v$LATEST"

case "${1:-}" in
    --check)
        if version_gt "$LATEST" "$CURRENT"; then
            echo "업데이트 가능: v$CURRENT → v$LATEST"
            exit 0
        else
            echo "최신 버전입니다: v$CURRENT"
            exit 0
        fi
        ;;
    --force)
        log "강제 업데이트: v$LATEST"
        do_update "$LATEST"
        ;;
    *)
        if version_gt "$LATEST" "$CURRENT"; then
            log "업데이트 필요: v$CURRENT → v$LATEST"
            do_update "$LATEST"
        else
            log "최신 버전 — 업데이트 불필요"
        fi
        ;;
esac

exit 0
