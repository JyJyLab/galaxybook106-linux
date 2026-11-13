# Galaxy Book 10.6 Linux

삼성 갤럭시 북 10.6(SM-W627 LTE / SM-W620 Wi-Fi, 2017)용 Debian 리눅스 빌드.
Debian forky(testing) + Xfce 4.20 Wayland 세션(labwc), 태블릿 사용에 맞춘 회전·터치·화상 키보드·절전·전면 카메라 지원.

Debian Linux build for the Samsung Galaxy Book 10.6 tablet — see [English summary](#english-summary).

> 설치하면 내장 eMMC 전체가 지워짐(Windows 포함). 되돌리려면 Windows 복구 수단이 따로 필요함.

## 동작 현황

SM-W627NZKFKOO(LTE 모델) 실기 기준. SM-W620(Wi-Fi 모델)은 미검증 — 화면 기본 방향(`BASE_TRANSFORM`)이 다를 수 있음.

| 항목 | 상태 | 비고 |
|---|---|---|
| 그래픽·영상 가속 | 동작 | i915, Mesa, VA-API(H.264·HEVC·VP9) |
| 자동 회전 | 동작 | 가속도 센서 SAM0201 연결 모듈(DKMS), 4방향 |
| 터치·S펜 | 동작 | 회전에 맞춰 정합, `gbook-touch-calibrate`로 점검 |
| 스피커·이어폰 | 동작 | ALC298 앰프 초기화(DarrenBenson/galaxybook-10.6-audio) |
| 볼륨·전원 버튼 | 동작 | 화면 표시(`gbook-osd`) |
| 화상 키보드 | 동작 | 커버 분리 시 입력란 누르면 자동 표시, 한글 두벌식·한/영 키, ▼ 숨김 키, 키보드가 뜨면 활성 창 자동 최대화 |
| 키보드 커버 | 키보드 동작 | 켜진 상태에서 다시 붙이면 터치패드 미동작 → 절전·복귀 한 번으로 해결(미해결 과제) |
| 절전 | 동작 | 전원 버튼·커버 덮기 → s2idle, 3시간 뒤 최대 절전(복귀 시 작업 그대로) |
| Wi-Fi·블루투스 | 동작 | |
| 전면 카메라 | 동작 | Sony IMX241, 새 커널 드라이버 + libcamera 패치, Firefox 확인. 기본 좌우 반전. Windows 튜닝 데이터 기반 색 보정(렌즈 음영·색 행렬·화이트밸런스) |
| 후면 카메라 | 미확인 | |
| LTE 모뎀·GPS | 미지원 | |
| 조도·그립 센서 | 미지원 | |

## 설치

### 준비물

- 4 GB 이상 USB 메모리, USB-C 젠더 또는 허브
- 키보드 커버(BIOS 조작용, 없으면 볼륨 버튼으로 일부 가능)
- 충전기(짧은 케이블 권장 — 긴 케이블에서 충전 인식이 끊기는 사례 있음)
- (권장) 지우기 전에 Windows에서 Samsung Update로 BIOS 최신화

### 1. USB 메모리 만들기

[Releases](../../releases)에서 `galaxybook106-linux-installer-<날짜>.img.xz.001`, `.002`, `SHA256SUMS`를 받음(GitHub 파일당 2 GB 제한으로 분할).

리눅스:

```sh
cat galaxybook106-linux-installer-*.img.xz.0* > installer.img.xz
xz -d installer.img.xz
sha256sum installer.img        # SHA256SUMS 의 .img 값과 비교
sudo dd if=installer.img of=/dev/sdX bs=4M conv=fsync status=progress   # sdX = USB 메모리
```

Windows: 7-Zip으로 `.001` 파일을 열면 분할본이 합쳐져 `.img`가 풀림 → Rufus(DD 모드) 또는 balenaEtcher로 씀.

### 2. BIOS 설정

1. 전원을 켠 직후 키보드 커버의 F2 연타 → BIOS 진입
2. Secure Boot Control 끄기, Fast BIOS Mode 항목이 있으면 끄기 → 저장

### 3. 설치

1. USB 메모리를 연결하고 전원을 켬 → 삼성 로고에서 F10 → USB 선택
2. 부팅 메뉴는 세로로 표시됨, 5초 뒤 자동 진행
3. Wi-Fi 목록이 나오면 번호와 비밀번호 입력(설치 후 그대로 이관됨, 건너뛰기 가능)
4. `gbook-install` 실행
   - 데스크톱 사용자 `gbook`의 비밀번호 입력(두 번, 4자 이상. sudo에 필요)
   - 대상 디스크 확인 후 `ERASE` 입력 → 약 1분
5. `reboot`, 화면이 꺼지면 USB 메모리 분리 → 자동 로그인으로 바탕화면 시작

설치 기록: 라이브 시스템의 `/root/gbook-install.log`.

## 설치 후

- 언어·시간대: 한국어(ko_KR.UTF-8), Asia/Seoul. 입력기 fcitx5(한글), 한/영 키 전환
- 사용자 `gbook`, 자동 로그인, sudo는 설치 때 정한 비밀번호. SSH 서버는 꺼져 있음(`sudo systemctl enable --now ssh`)
- 상단 패널: 화상 키보드·회전 잠금·90도 회전·음량·배터리
- 메뉴 "터치 보정": 화면의 원을 한 번 눌러 터치 방향 점검, 180도 반대면 자동 수정
- 지원 묶음 원본: `/opt/gbook/bundle`(다시 설치: `sudo /opt/gbook/bundle/install.sh all`)
- libcamera 패키지 5개는 apt hold 상태(Debian 업데이트로 덮이지 않게). 카메라 커널 모듈은 7.2 커널 전용(DKMS)
- 하드웨어 보고서: `sudo /opt/gbook/tools/gbook-diag.sh`

### 알려진 문제

- 키보드 커버를 켜진 상태에서 다시 붙이면 터치패드가 동작하지 않음 → 전원 버튼으로 절전, 다시 눌러 복귀
- 웹캠 시험 사이트에서 카메라가 "0 FPS"로 표시되나 실제 30 fps(PipeWire libcamera 플러그인이 프레임 속도를 알리지 않는 표시 문제)
- 커널이 7.2 계열을 벗어나면 카메라 DKMS 모듈은 빌드되지 않음(이식 필요)
- 절전 중 커버 키보드 입력으로 깨어날 수 있음(커버가 닫혀 있으면 5초 뒤 다시 절전)

### 최신 변경 적용 (2026-11-10 이미지로 설치한 경우)

설치 이미지는 2026-11-10판. 이후 변경(아래 변경 기록)은 저장소의 묶음으로 적용:

```sh
git clone https://github.com/JyJyLab/galaxybook106-linux && cd galaxybook106-linux
sudo bundle/install.sh desktop power camera    # 또는 all
sudo rm -rf /opt/gbook/bundle && sudo cp -a bundle /opt/gbook/bundle   # 기기 안 원본도 갱신(선택)
```
재부팅 후 반영. 카메라를 쓰는 앱은 재시작(또는 `systemctl --user restart pipewire wireplumber`).

## 변경 기록

- **2026-11-13**
  - 전면 카메라 색 보정: libcamera 0.7.2-1+gbook10. Windows 드라이버의 카메라 모듈 특성 데이터(Intel AIQB)를 해독해 IPU3 처리에 적용 — 색온도별 렌즈 음영 보정, 색 보정 행렬, 화이트밸런스 궤적, sRGB 출력. 흑 레벨·음영 이득 형식은 실기 측정으로 확정. 이전의 청록빛·뿌연 화면·어두운 모서리 해소. 자세한 내용 [camera/README.md](camera/README.md)
  - 최대 절전에서 복귀하면 thermald가 CPU 한 코어를 계속 점유해 배터리가 빨리 닳는 문제 → 복귀 시 thermald 재시작(`gbook-thermald-resume`)
- **2026-11-11**
  - 절전 3시간 뒤 최대 절전(스왑 파일 4.5 GB, 복귀 시 이전 화면 그대로). 이 기기는 S0ix에 들어가지 않아 일반 절전이 시간당 약 1.6% 소모
  - 최대 절전 복귀 후 전원 버튼이 반응하지 않는 문제 → 복귀 시 버튼 드라이버 재연결(`gbook-vbtn-resume`)
  - 화상 키보드: ▼ 숨김 키, 숨긴 뒤 같은 입력칸 다시 누르면 재표시, 키보드가 뜨면 활성 창 최대화(`gbook-fit-active`)
  - Firefox 시스템 제목 표시줄(터치로 창 이동)
- **2026-11-10** 첫 공개(설치 이미지 v2026.11.10)

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `bundle/` | 기기 지원 묶음과 설치기 `install.sh`(구성: accel audio desktop greetd power camera cover). 자세한 내용 [bundle/README.md](bundle/README.md) |
| `camera/` | 전면 카메라 개발 기록([camera/README.md](camera/README.md)), libcamera 패치, Windows 튜닝 파일 해독·변환 도구(`cmc/`), RAW 해독 도구 |
| `install/` | 루트 이미지 빌드: `build-rootfs.sh`, `chroot-setup.sh`, `pkglist.txt` |
| `live/` | 설치 USB: `make-usb.sh`(SystemRescue 13.03 기반), 라이브 도우미, 설치기 `gbook-install.sh` |
| `tools/` | `gbook-diag.sh`(읽기 전용 하드웨어 보고서), chroot 실행 도구 |

## 직접 빌드

Debian/Ubuntu 빌드 PC, sudo, 인터넷 연결 필요.

```sh
# 1. 루트 이미지 (공식 Debian forky rootfs + chroot 설정)
install/build-rootfs.sh /var/tmp/gbook-build image/gbook-forky-rootfs.tar.zst
# 2. 설치 USB (SystemRescue 13.03 ISO를 live/iso/ 에 둠)
live/make-usb.sh stage
live/make-usb.sh write /dev/disk/by-id/usb-...      # 또는: live/make-usb.sh image installer.img
```

- 기본은 공개 빌드(`GB_PUBLIC=1`): 사용자 `gbook`, SSH 키 없음, 비밀번호는 설치 때 입력
- 개인 빌드(`GB_PUBLIC=0`): `PUBKEY`(기본 `~/.ssh/id_ed25519.pub`)로 SSH 접속, sudo 암호 없음. 라이브 설정은 `live/sysrescue.d/500-gbook-ssh.yaml.example`을 `500-gbook.yaml`로 복사해 키 입력
- 사용자 이름 `GB_USER`, 호스트 이름 `GB_HOSTNAME`
- libcamera 패키지 다시 빌드: Debian `libcamera` 0.7.2-1 소스에 `camera/libcamera/libcamera-0.7.2-gbook10.patch` 적용 후 `DEB_BUILD_PROFILES="nodoc nocheck" dpkg-buildpackage -b`(Debian forky chroot 권장). 카메라 튜닝 파일은 `camera/cmc/gen_yaml.py`로 Windows 튜닝 파일에서 재생성 가능
- 화상 키보드 다시 빌드: [bundle/osk/README](bundle/osk/README)

## 라이선스·출처

- 이 저장소의 스크립트·설정: GPL-2.0-or-later. 커널 모듈(`bundle/accel-dkms`, `bundle/camera/gbook-camera-0.1`): GPL-2.0-only. 전문 [LICENSE](LICENSE)
- `bundle/audio/upstream/`: [DarrenBenson/galaxybook-10.6-audio](https://github.com/DarrenBenson/galaxybook-10.6-audio) (GPL-2.0), 원 연구 Aurélien Croc
- `bundle/osk/wvkbd-gbook`: [wvkbd](https://github.com/jjsullivan5196/wvkbd) 0.15 (GPL-3.0) + 한글 패치
- `bundle/camera/debs/`: [libcamera](https://libcamera.org) 0.7.2 (LGPL-2.1-or-later) + 패치
- 카메라 모듈 `int3472`·`ipu-bridge`: 리눅스 7.2.15 원본 수정. `imx241` 센서 설정값은 Windows 드라이버 동작 분석에서 얻음(드라이버 파일은 포함하지 않음)
- 카메라 색 보정값(libcamera `imx241.yaml`): Windows 드라이버 패키지의 카메라 모듈 특성 파일에서 변환(원본 파일은 포함하지 않음). 레코드 형식은 ChromiumOS `ia_cmc_types.h`(Apache-2.0) 참고
- 설치 USB: [SystemRescue](https://www.system-rescue.org) 13.03 (GPL), Debian 패키지(각 패키지 라이선스)

삼성·Sony·Intel과 무관한 비공식 프로젝트. 사용에 따른 책임은 사용자에게 있음.

## English summary

Unofficial Debian forky build for the Samsung Galaxy Book 10.6 (SM-W627 LTE verified; SM-W620 Wi-Fi untested), Xfce 4.20 on Wayland (labwc).

- Working: graphics and VA-API, auto-rotation (accelerometer glue module), touch and S Pen aligned with the rotation, speakers and headphone jack, volume/power buttons, on-screen keyboard that pops up when the keyboard cover is detached (Korean 2-set layer), sleep on power button and lid with hibernation after 3 hours, Wi-Fi, Bluetooth, front camera (new Sony IMX241 driver, patched libcamera with colour tuning converted from the Windows camera module data — lens shading, colour matrices, AWB locus — works in Firefox, mirrored by default).
- Known issues: keyboard cover touchpad stays dead after hot re-attach (one suspend/resume fixes it); camera DKMS module builds for 7.2 kernels only; LTE modem, GPS and ambient light sensor unsupported.
- Install: join the release parts (`cat *.img.xz.0* > installer.img.xz`), decompress, write to a USB stick, disable Secure Boot (F2), boot it (F10), run `gbook-install`. **This erases the whole internal eMMC, Windows included.** The installer asks for the password of the desktop user `gbook`; the desktop logs in automatically.
- Build it yourself: `install/build-rootfs.sh` then `live/make-usb.sh`.
- Updates after the 2026-11-10 image (hibernation, on-screen keyboard improvements, thermald fix after resume, camera colour tuning): clone this repository and run `sudo bundle/install.sh desktop power camera`, then reboot.
