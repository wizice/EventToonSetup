# EventToon 설치 가이드

EventToon ARM64 Linux 장비 설치 및 운영 가이드

---

## 사전 요구사항

| 항목 | 요구 |
|------|------|
| OS | Ubuntu 20.04+ (ARM64) |
| 아키텍처 | aarch64 (ODROID, Raspberry Pi 등) |
| 커널 | 5.x+ (framebuffer 지원) |
| 화면 | HDMI 또는 DSI (`/dev/fb0`) |
| 네트워크 | 인터넷 필수 (API 통신, 앨범 다운로드) |
| 프린터 (선택) | Bixolon SLCS 호환 (CUPS 경유) |
| 디스크 | 최소 2GB 여유 |
| RAM | 최소 1GB |

---

## 설치

슈퍼관리자 토큰이 필요합니다. 관리자에게 요청하세요.

### 신규 설치

```bash
curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash -s -- --token YOUR_TOKEN
```

### 업데이트

```bash
curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash -s -- --token YOUR_TOKEN --update
```

### Cloudflare Tunnel 설정

```bash
bash install.sh --tunnel YOUR_TUNNEL_TOKEN
```

### 상태 확인

```bash
bash install.sh --status
```

---

## 설치 구성물

| 파일 | 설명 | 경로 |
|------|------|------|
| `eventtoon` | IPP 서버 (인쇄 수신) | `/usr/local/bin/` |
| `eventtoon-display` | 디스플레이 UI (framebuffer) | `/usr/local/bin/` |
| `eventtoon-fetcher` | 인쇄 작업 폴링 | `/usr/local/bin/` |
| `eventtoon-printer` | 프린터 제어 | `/usr/local/bin/` |
| `eventtoon-player` | MP4 동영상 재생 | `/usr/local/bin/` |

---

## 서비스 관리

```bash
# 서비스 상태
systemctl status eventtoon-display

# 로그 확인
journalctl -u eventtoon-display --no-pager -n 50
journalctl -u eventtoon-fetcher --no-pager -n 50
journalctl -u eventtoon --no-pager -n 50

# 전체 상태 (EventToon + 기존 서비스)
bash /opt/eventtoon/scripts/services-toggle.sh status
```

---

## 제거

```bash
systemctl stop eventtoon eventtoon-display eventtoon-fetcher eventtoon-printer
systemctl disable eventtoon eventtoon-display eventtoon-fetcher eventtoon-printer
rm -f /usr/local/bin/eventtoon*
rm -f /etc/systemd/system/eventtoon*.service
systemctl daemon-reload
# 데이터는 수동 삭제: rm -rf /var/spool/eventtoon/
```

---

## 문제 해결

| 증상 | 원인 | 해결 |
|------|------|------|
| 화면이 안 나옴 | framebuffer 없음 | `ls /dev/fb0`, 커널 설정 확인 |
| MP4 재생 안 됨 | ffmpeg 미설치 | `apt install ffmpeg` |
| 키보드 입력 안 됨 | EVIOCGRAB 실패 | `ls -la /dev/input/event*` 권한 확인 |
| 앨범 로드 실패 | API 접근 불가 | `curl https://fit.wizice.com/api/docs` |
| 서비스 재시작 반복 | 설정 파일 손상 | `rm /var/spool/eventtoon/display_settings.json` |
| 인증 실패 | 토큰 만료/오류 | 관리자에게 새 토큰 요청 |
