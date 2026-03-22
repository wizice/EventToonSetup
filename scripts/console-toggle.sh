#!/bin/bash
# EventToon 콘솔 토글 스크립트
# 사용법: console-toggle.sh off  — 콘솔 끄고 display UI만 표시
#         console-toggle.sh on   — 콘솔 복원 (디버깅용)
#         console-toggle.sh      — 현재 상태 표시

case "$1" in
  off)
    echo "콘솔 OFF — EventToon UI 전용 모드"
    systemctl stop getty@tty1 2>/dev/null
    systemctl disable getty@tty1 2>/dev/null
    echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null
    setterm --cursor off --blank 0 > /dev/tty1 2>/dev/null
    sysctl -w kernel.printk="1 1 1 1" > /dev/null 2>&1
    # 화면 다시 그리기
    systemctl restart eventtoon-display 2>/dev/null
    echo "완료: getty 중지, 커서 OFF, 커널 메시지 OFF"
    ;;
  on)
    echo "콘솔 ON — 디버깅 모드 (TTY 로그인 복원)"
    systemctl enable getty@tty1 2>/dev/null
    systemctl start getty@tty1 2>/dev/null
    echo 1 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null
    setterm --cursor on > /dev/tty1 2>/dev/null
    sysctl -w kernel.printk="4 4 1 7" > /dev/null 2>&1
    echo "완료: getty 시작, 커서 ON, 커널 메시지 ON"
    ;;
  *)
    # 현재 상태 표시
    GETTY=$(systemctl is-active getty@tty1 2>/dev/null)
    if [ "$GETTY" = "active" ]; then
      echo "콘솔: ON (getty 활성)"
    else
      echo "콘솔: OFF (getty 비활성)"
    fi
    echo "사용법: $0 [on|off]"
    ;;
esac
