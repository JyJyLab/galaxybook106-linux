# Galaxy Book 10.6 지원 묶음 (bundle)

대상: Samsung Galaxy Book 10.6 (SM-W627 LTE 실기 검증, SM-W620 Wi-Fi 미검증), Debian forky, Xfce 4.20 Wayland 세션(labwc 0.20).
설치 이미지에는 이미 들어 있음(`/opt/gbook/bundle`). 직접 설치할 때:

```
sudo ./install.sh [--user 이름] [--force] <accel|audio|desktop|greetd|power|camera|cover|all>
```

| 구성 | 내용 | 상태 |
|---|---|---|
| `accel-dkms/` | 가속도 센서(ACPI SAM0201) 연결 모듈 `st_accel_sam0201`(DKMS), 마운트 행렬 hwdb | 동작(4방향 회전) |
| `audio/` | 스피커·이어폰 초기화(ALC298 144d:c150). `upstream/` = DarrenBenson/galaxybook-10.6-audio 원본, 코덱 확인 가드·시스템 전역 WirePlumber 규칙 추가 | 동작 |
| `desktop/` | `gbook-display`(회전·배율·터치/펜 매핑), `gbook-autorotate`, `gbook-session`, labwc 설정, 회전 잠금·수동 회전 아이콘, `gbook-osd`(음량·밝기 표시), `gbook-osk`·`gbook-osk-auto`(커버 분리 시 화상 키보드 자동 표시, 숨긴 뒤 같은 입력칸 다시 누르면 재표시), `gbook-fit-active`(키보드가 뜰 때 활성 창 최대화 — 창을 가리지 않게), Firefox 시스템 제목 표시줄(터치로 창 이동), `gbook-touch-calibrate`(터치 방향 한 번 누름 점검), `gbook-panel-setup`(패널 구성) | 동작 |
| `osk/` | `wvkbd-gbook`: wvkbd 0.15 + 한글 두벌식 층·한/영 키·▼ 숨김 키(패치 포함) | 동작 |
| `greetd` | 자동 로그인(greetd + agreety) | 동작 |
| `power/` | 전원 버튼·커버 덮기 → 절전(logind, xfce4-power-manager 설정), 3시간 뒤 최대 절전(스왑 파일, 복귀 시 이전 화면 그대로), 최대 절전 복귀 시 전원 버튼 드라이버 재연결·thermald 재시작, 충전기 연결로 깨어나지 않음 | 동작 |
| `camera/` | 전면 카메라: IMX241 커널 모듈(DKMS `gbook-camera`, 7.2 커널), libcamera 0.7.2-1+gbook10(hold, 색 보정 포함), ImgU IOMMU 대책, PipeWire·Firefox 설정. 기본 좌우 반전 | 동작(Firefox 확인) |
| `cover/` | 키보드 커버 터치패드 재연결 보조(실험용, `all`에 미포함) | 미해결 |

## 설정 파일

- `/etc/gbook/display.conf`: `BASE_TRANSFORM`(SM-W627 = 90), `OFFSET_*`, `SCALE`, `AUTOROTATE`. 사용자별 `~/.config/gbook/display.conf`가 우선
- `/etc/udev/hwdb.d/61-sensor-galaxybook106.hwdb`: `ACCEL_MOUNT_MATRIX`. 변경 후 `sudo systemd-hwdb update && sudo udevadm trigger -s iio`
- `~/.config/xfce4/labwc/rc.xml`: 터치 보정 행렬, S펜 180도 회전, 키 바인딩
- 카메라 좌우 반전 끄기: `/etc/modprobe.d/`에 `options imx241 mirror=0`

## 명령

- `gbook-display status | init | next | lock | unlock | toggle-lock | set <normal|left-up|right-up|bottom-up>`
- `gbook-touch-calibrate` — 터치가 180도 반대로 인식되면 보정 행렬 전환
- `gbook-osk show | hide | toggle` — 화상 키보드
- `sudo galaxybook-audio-init` — 음향 초기화 재적용
- `monitor-sensor --accel` — 센서 방향 확인

## 출처·라이선스

- 가속도 모듈: 커널 `drivers/iio/accel/st_accel_i2c.c` 기반, GPL-2.0-only
- 카메라 모듈: `int3472`·`ipu-bridge`는 리눅스 7.2.15 원본 수정, `imx241.c`는 새 드라이버, GPL-2.0-only
- 음향: DarrenBenson/galaxybook-10.6-audio (GPL-2.0), 원 연구 Aurélien Croc
- 화상 키보드: wvkbd (GPL-3.0) + `osk/wvkbd-0.15-gbook.patch`(한글 층·한/영 키·▼ 숨김 키)
- libcamera 패키지: libcamera 0.7.2 (LGPL-2.1+) + `../camera/libcamera/libcamera-0.7.2-gbook10.patch`
- labwc 설정: Xfce 4.20 기본 `labwc-rc.xml` 기반
