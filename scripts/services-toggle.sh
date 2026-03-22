#!/bin/bash
#
# EventToon 전용 모드 전환 스크립트
# 사용법:
#   ./services-toggle.sh stop   — 기존 서비스 중지 (EventToon만 실행)
#   ./services-toggle.sh start  — 기존 서비스 복원
#   ./services-toggle.sh status — 현재 상태 확인

# === 중지/시작 대상 ===

# systemd 서비스
SERVICES=(
    apache2
    mariadb
    docker
    containerd
)

# root crontab에서 매분 실행되는 배치들
# (cron 자체를 끄지 않고, 개별 스크립트를 제어)
ROOT_CRON_LOCK="/var/run/eventtoon-cron-disabled"

# Electron (이미 inactive이지만 혹시 모르니)
ELECTRON_SERVICE="myelectronapp"

# Docker 컨테이너
DOCKER_CONTAINER="wizice_iot_gw"

case "$1" in
    stop)
        echo "=== 기존 서비스 중지 (EventToon 전용 모드) ==="

        # 1. root crontab 먼저 비활성화 (배치가 서비스 재시작하는 것 방지)
        echo "[1/4] root crontab 비활성화..."
        if [ ! -f "$ROOT_CRON_LOCK" ]; then
            crontab -l > /var/spool/eventtoon/crontab_root_backup.txt 2>/dev/null
            crontab -r 2>/dev/null
            touch "$ROOT_CRON_LOCK"
            echo "  ✓ crontab 백업 후 비활성화"
        else
            echo "  - 이미 비활성화 상태"
        fi

        # 2. Docker 컨테이너 중지 (docker 엔진보다 먼저)
        echo "[2/4] Docker 컨테이너 중지..."
        docker stop $DOCKER_CONTAINER 2>/dev/null && echo "  ✓ $DOCKER_CONTAINER 중지" || echo "  - $DOCKER_CONTAINER (이미 중지)"

        # 3. systemd 서비스 중지
        echo "[3/4] systemd 서비스 중지..."
        for svc in "${SERVICES[@]}"; do
            systemctl stop "$svc" 2>/dev/null && echo "  ✓ $svc 중지" || echo "  - $svc (이미 중지)"
        done
        systemctl stop "$ELECTRON_SERVICE" 2>/dev/null

        # 4. 잔여 프로세스 정리 (dcli, iotgwcli, rtucli)
        echo "[4/4] 잔여 배치 프로세스 정리..."
        pkill -f "dcli tcpserver" 2>/dev/null && echo "  ✓ dcli 종료" || echo "  - dcli (없음)"
        pkill -f "iotgwcli" 2>/dev/null && echo "  ✓ iotgwcli 종료" || echo "  - iotgwcli (없음)"
        pkill -f "rtucli" 2>/dev/null && echo "  ✓ rtucli 종료" || echo "  - rtucli (없음)"
        pkill -f "check_dcli_tcpserver" 2>/dev/null
        pkill -f "check_iotgwcli_tcpserver" 2>/dev/null
        pkill -f "run_get_rtu" 2>/dev/null
        pkill -f "route_check_and_run" 2>/dev/null
        pkill -f "checkntp" 2>/dev/null
        pkill -f "check_version" 2>/dev/null
        pkill -f "get_sshinfo" 2>/dev/null
        pkill -f "monitor_ssl_check_and_run" 2>/dev/null
        pkill -f "run_cloudflared" 2>/dev/null

        echo ""
        echo "완료. EventToon 전용 모드 활성화."
        $0 status
        ;;

    start)
        echo "=== 기존 서비스 복원 ==="

        # 1. root crontab 복원
        echo "[1/3] root crontab 복원..."
        if [ -f "$ROOT_CRON_LOCK" ]; then
            if [ -f /var/spool/eventtoon/crontab_root_backup.txt ]; then
                crontab /var/spool/eventtoon/crontab_root_backup.txt
                echo "  ✓ crontab 복원"
            else
                echo "  ! 백업 파일 없음 — 수동 복원 필요"
            fi
            rm -f "$ROOT_CRON_LOCK"
        else
            echo "  - crontab 이미 활성 상태"
        fi

        # 2. systemd 서비스 시작
        echo "[2/3] systemd 서비스 시작..."
        for svc in "${SERVICES[@]}"; do
            systemctl start "$svc" 2>/dev/null && echo "  ✓ $svc 시작" || echo "  ! $svc 시작 실패"
        done

        # 3. Docker 컨테이너 시작
        echo "[3/3] Docker 컨테이너 시작..."
        docker start $DOCKER_CONTAINER 2>/dev/null && echo "  ✓ $DOCKER_CONTAINER 시작" || echo "  ! $DOCKER_CONTAINER 시작 실패"

        echo ""
        echo "완료. 기존 서비스 복원됨."
        $0 status
        ;;

    status)
        echo ""
        echo "=== 서비스 상태 ==="
        printf "%-25s %s\n" "서비스" "상태"
        echo "----------------------------------------"

        for svc in "${SERVICES[@]}"; do
            state=$(systemctl is-active "$svc" 2>/dev/null)
            printf "%-25s %s\n" "$svc" "$state"
        done

        # Docker 컨테이너
        dstate=$(docker inspect -f '{{.State.Status}}' $DOCKER_CONTAINER 2>/dev/null || echo "없음")
        printf "%-25s %s\n" "$DOCKER_CONTAINER (docker)" "$dstate"

        # EventToon
        for svc in eventtoon eventtoon-display eventtoon-fetcher eventtoon-printer; do
            state=$(systemctl is-active "$svc" 2>/dev/null)
            printf "%-25s %s\n" "$svc" "$state"
        done

        # crontab
        if [ -f "$ROOT_CRON_LOCK" ]; then
            printf "%-25s %s\n" "root crontab" "비활성화"
        else
            printf "%-25s %s\n" "root crontab" "활성"
        fi

        echo ""
        echo "=== 리소스 ==="
        echo "CPU: $(top -bn1 | grep 'Cpu(s)' | awk '{printf "%.0f%% 사용", 100-$8}')"
        echo "RAM: $(free -h | awk '/Mem:/{printf "%s / %s 사용", $3, $2}')"
        echo ""
        ;;

    *)
        echo "사용법: $0 {stop|start|status}"
        echo ""
        echo "  stop   — 기존 서비스 중지 (EventToon 전용 모드)"
        echo "  start  — 기존 서비스 복원"
        echo "  status — 현재 상태 확인"
        exit 1
        ;;
esac
