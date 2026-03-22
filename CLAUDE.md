# EventToon 테스트 서버 작업 가이드

> 이 문서는 테스트 서버에서 Claude Code가 참조하는 작업 지침서입니다.

---

## 1. 역할

이 서버는 **EventToon 설치 검증 및 운영 테스트 전용 장비**이다.
개발 서버에서 빌드된 릴리즈를 이 서버에 설치하고, 정상 동작 여부를 검증한다.

---

## 2. 설치 테스트 절차

### 2.1 신규 설치

```bash
curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash -s -- --token YOUR_TOKEN
```

### 2.2 업데이트 설치

```bash
curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh | bash -s -- --token YOUR_TOKEN --update
```

### 2.3 설치 후 반드시 확인할 항목

| 순서 | 확인 항목 | 명령어 | 기대 결과 |
|------|-----------|--------|-----------|
| 1 | 바이너리 존재 | `ls -la /usr/local/bin/eventtoon*` | 5개 바이너리 존재, 실행 권한 있음 |
| 2 | 바이너리 유효성 | `file /usr/local/bin/eventtoon-display` | `ELF 64-bit LSB ... aarch64` |
| 3 | 버전 확인 | `cat /var/spool/eventtoon/installed_version` | 릴리즈 버전과 일치 |
| 4 | 서비스 등록 | `systemctl list-unit-files \| grep eventtoon` | 3개 서비스 enabled |
| 5 | 서비스 실행 | `systemctl is-active eventtoon eventtoon-display eventtoon-fetcher` | 모두 active |
| 6 | 디렉토리 구조 | `ls /var/spool/eventtoon/` | albums, done, pending 존재 |
| 7 | 스크립트 설치 | `ls /opt/eventtoon/scripts/` | auto-update.sh, services-toggle.sh, console-toggle.sh |
| 8 | 로그 확인 | `journalctl -u eventtoon-display --no-pager -n 20` | 에러 없이 시작됨 |
| 9 | 설치 로그 | `cat /var/log/eventtoon-install.log` | 모든 단계 완료, 에러 없음 |

---

## 3. 서비스 상태 점검

### 3.1 전체 상태 확인

```bash
bash /opt/eventtoon/scripts/services-toggle.sh status
```

### 3.2 개별 서비스 로그 확인

```bash
journalctl -u eventtoon-display --no-pager -n 50
journalctl -u eventtoon-fetcher --no-pager -n 50
journalctl -u eventtoon --no-pager -n 50
```

### 3.3 서비스 재시작 패턴 감지

```bash
journalctl -u eventtoon-display --since "1 hour ago" | grep -c "Started"
```

3회 이상 재시작이 발생하면 crash loop로 판단하고 원인을 분석한다.

---

## 4. 기능 테스트

### 4.1 API 연결 확인

```bash
curl -sSL --max-time 5 https://fit.wizice.com/api/docs
```

### 4.2 앨범 데이터 확인

```bash
ls -la /var/spool/eventtoon/albums/
```

### 4.3 프린터 확인 (CUPS)

```bash
systemctl is-active cups
lpstat -p 2>/dev/null || echo "프린터 없음"
```

### 4.4 Cloudflare Tunnel 확인

```bash
systemctl is-active cloudflared 2>/dev/null || echo "터널 미설정"
```

---

## 5. 자동 업데이트 검증

```bash
bash /opt/eventtoon/scripts/auto-update.sh --check
cat /var/log/eventtoon-update.log
```

---

## 6. 문제 발생 시 수집할 정보

```bash
echo "=== 시스템 정보 ==="
uname -a
cat /etc/os-release | head -3

echo "=== 서비스 상태 ==="
for svc in eventtoon eventtoon-display eventtoon-fetcher; do
    echo "$svc: $(systemctl is-active $svc)"
done

echo "=== 설치 버전 ==="
cat /var/spool/eventtoon/installed_version 2>/dev/null || echo "없음"

echo "=== 디스크 ==="
df -h / | tail -1

echo "=== 메모리 ==="
free -h | grep Mem

echo "=== 최근 에러 로그 ==="
journalctl -p err --no-pager -n 20 --unit 'eventtoon*'
```

---

## 7. 테스트 결과 보고 형식

```
## 테스트 결과 — YYYY-MM-DD

- 설치 방식: 신규 / 업데이트
- 릴리즈 버전: vX.Y.Z
- 서버: (hostname)
- OS: (uname -a 결과)

### 서비스 상태
| 서비스 | 상태 | 비고 |
|--------|------|------|
| eventtoon | active/failed | |
| eventtoon-display | active/failed | |
| eventtoon-fetcher | active/failed | |

### 확인 항목
- [ ] 바이너리 5개 설치됨
- [ ] 서비스 3개 active
- [ ] 설치 로그 에러 없음
- [ ] API 연결 정상
- [ ] 앨범 디렉토리 생성됨

### 발견된 이슈
(없으면 "없음")
```

---

## 8. 주의사항

- 이 서버에서 소스 코드를 수정하지 않는다. 코드 수정은 개발 서버에서만 수행한다.
- `git push --force` 절대 금지.
- 테스트 중 서비스가 비정상이면 로그를 먼저 확인하고, 무작정 재설치하지 않는다.
- 기존에 동작 중인 서비스(Docker, MariaDB 등)가 있을 수 있다. `services-toggle.sh stop`이 이를 중지하므로, 복원이 필요하면 `services-toggle.sh start`를 실행한다.
- Cloudflare Tunnel 토큰은 관리자에게 별도 요청한다.

---

## 9. 소스 및 배포

- 설치 가이드: https://github.com/wizice/EventToonSetup
- 설치 스크립트: `curl -sSL https://raw.githubusercontent.com/wizice/EventToonSetup/main/install.sh`
- API 문서: https://fit.wizice.com/api/docs
