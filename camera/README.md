# 갤럭시 북 10.6 전면 카메라 (Sony IMX241) — 드라이버 개발 기록

## 하드웨어 (SM-W627, 2026-11-10 실측)
- 센서: Sony IMX241 (5 MP), ACPI `INT347F` (`\_SB.PCI0.LNK1`), 모듈 이름(_DSM) `START2FRONT`, 윈도 드라이버 `imx241.sys`
- I2C: `\_SB.PCI0.I2C2` = 리눅스 `i2c-4`, 센서 0x37(모델 ID 레지스터 0x0000 = 0x0241 확인), EEPROM 0x51
- MIPI CSI-2: 2레인, CIO2 포트 1 (SSDB link=1, lanes=2), 회전 0
- 클럭: 26 MHz (SSDB mclkspeed = 26,000,000), `clk-enable` GPIO로 켬
- 제어 로직: INT3472 `DSC1`(discrete). GPIO(_DSM 79234640-…): RESET 0x68, 유형 0x0f 0x4b, DOVDD(0x10) 0x48, 유형 0x11 0x55, CLK_ENABLE(0x0c) 0x65 — 모두 켜짐 값 1. 리눅스 7.2 int3472는 0x0f·0x11을 모름("GPIO type unknown")
- 전원을 손으로 넣는 시험(int3472 해제 후 gpioset): 4개 전원선 + 리셋 해제로 센서 응답 확인

## 윈도 드라이버에서 얻은 것 (`imx241.sys` 분석, 드라이버 파일은 저장소에 미포함)
- 모드 표 6개(16바이트 레코드 {type, reg, val, 0}). 19.2 MHz용 4개, 26 MHz용 2개(PLL 사전분주 3, 배수 115, 단일 PLL)
- 26 MHz 표: 2592×1944 @30 (frame 2281, line 1456), 1296×972 @30 (H 비닝 0x3048=0x25, V 1/2, frame 2076, line 1600)
- PLL 996.67 MHz → 링크 498.33 MHz(DDR), 픽셀 속도 199.33 Mpx/s, LINE_LENGTH 단위 = 2픽셀
- 모드 목록 구조체: 1296×972@30, 1296×972@60, 2592×1944@30 (모듈 4종 동일)

## 리눅스 드라이버 (`dkms/gbook-camera-0.1`, DKMS 패키지 `gbook-camera`)
- `int3472/`: intel_skl_int3472_discrete(7.2.15 원본) + 유형 0x0f→`avdd`, 0x11→`dvdd` 레귤레이터
- `ipu-bridge/`: ipu-bridge(7.2.15 원본) + `IPU_SENSOR_CONFIG("INT347F", 1, 498333333)`
- `imx241/imx241.c`: 새 센서 드라이버(v4l2-cci, 2모드, 노출·아날로그/디지털 게인·VBLANK·플립·시험 패턴·선택 영역)
- 빌드·설치: 태블릿 `/usr/src/gbook-camera-0.1`, `dkms install gbook-camera/0.1`, 재부팅

## 확인된 것 (2026-11-10)
- 부팅 시 `ipu3-cio2: Found supported sensor INT347F:00`, `imx241 … Sony IMX241 found`, 전원 신호 경고 사라짐
- media-ctl: `imx241 4-0037` → `ipu3-csi2 1` → `/dev/video11`
- 2592×1944 RAW10(IPU3 packed `ip3r`) 29.9 fps 수신, 시험 패턴(색 막대) 정확, 실제 영상: 색 배열 RGGB·초점·방향 정상
- 미가공 영상 해독 도구: `tools/ipu3raw.py`

## 앱에서 쓰기까지 (2026-11-10)
- libcamera 0.7.2(Debian): IMX241용 센서 도우미가 없어 IPU3 파이프라인이 카메라를 거부 → 소스에 `CameraSensorHelperImx241`(흑 레벨 64@10비트, 게인 256/(256−코드))와 센서 속성(단위 셀 1.12 µm, 시험 패턴 0~4) 추가, `0.7.2-1+gbook1`로 다시 빌드(Debian forky chroot, 4분, 패치는 현재 `libcamera/libcamera-0.7.2-gbook10.patch`에 포함). 묶음 `bundle/camera/debs/`, 기기에서 apt hold
- 게인 실측: 코드 128 → 2.0배, 192 → 4.0배, 디지털 게인 512 → 2.0배, 노출 선형
- 1296×972 모드 실기 확인(30 fps, 시험 패턴 정상)
- **시스템 멈춤 원인**: ImgU(00:05.0)가 IOMMU 변환(DMA-FQ) 아래에서 전원을 켤 때 매핑되지 않은 메모리를 읽음(`DMAR: DMA Read … PTE Read access is not set`) → 기기 전체 멈춤·화면 줄무늬. 대책: ImgU 단독 IOMMU 그룹을 identity로(`gbook-imgu-identity`, modprobe install 훅 `/etc/modprobe.d/gbook-imgu.conf`). 다른 장치 보호는 유지
- 처리된 영상(NV12) 640×480·1280×960 30 fps, 자동 노출·화이트밸런스 동작(보정 파일 없음, 약간 청록)
- libcamera 버그 수정(0.7.2-1+gbook2): IPU3 `calculateBDSHeight()`에서 입력 높이가 IF 최대 자르기(540줄)보다 작을 때 `iif.height - 540`이 부호 없는 정수로 넘쳐 `std::clamp(lo > hi)` → `_GLIBCXX_ASSERTIONS`로 프로세스 강제 종료. 1296×972 센서 모드에서 화면비가 다른 출력(Firefox 16:9 1024×576)을 요청하면 WirePlumber가 죽고 Firefox 영상이 몇 초 뒤 멈췄음. 0 하한으로 고침, 1024×576·1280×720 30 fps 확인
- PipeWire: libcamera 장치 1개 "전면 카메라", IPU3 원시 V4L2 노드 14개 숨김(WirePlumber `60-gbook-camera.conf`). GStreamer `pipewiresrc`로 프레임 수신 확인
- Firefox: `media.webrtc.camera.allow-pipewire` true(`/etc/firefox-esr/firefox-esr.js`)
- 프레임 검증(2026-11-10): PipeWire 단독 25초 744프레임(640×480·1280×720 모두 ≈30 fps). 별도 프로필 Firefox 시험 페이지(getUserMedia + requestVideoFrameCallback + 화소 해시): 30초 동안 2초마다 약 60프레임, 화면 내용 매번 변함, PipeWire 링크 NV12 640×480 30/1 active
- 해상도 문제(0.7.2-1+gbook3): IPU3 파이프라인이 출력 크기를 범위(2×2~1280×720, 간격 1)로 알려 PipeWire가 800×600·854×480 같은 표준 크기를 광고 → ImgU는 가로 64·세로 4 단위만 가능해 libcamera가 몰래 조정 → PipeWire 버퍼 할당 -EINVAL, 영상 멈춤(웹캠 사이트의 최대 해상도 탐색 때). 범위를 64×4 단위로 알리도록 수정 → 광고 크기 320×240~1280×720 9종, Firefox 18개 해상도 요청 모두 ≈30 fps
- 웹캠 사이트의 "Frame rate: 0 FPS"는 `track.getSettings().frameRate`(=0) 표시값. PipeWire 1.6.9 libcamera 플러그인의 EnumFormat에 framerate 항목이 없어 Firefox가 0으로 보고. 실제 전송 속도와 무관(표시 문제, 미수정)
- 설치기 구성 요소 `camera`(`install.sh all`에 포함): DKMS, ImgU 대책, libcamera 패키지, PipeWire·Firefox 설정. 재부팅 후 동작 확인
- 진단 기법: 멈춤 재현 시 `ssh 태블릿 'sudo dmesg -w'`로 커널 기록을 다른 PC에 실시간 저장(디스크 기록은 멈출 때 사라짐), `dyndbg`로 ipu3_imgu 상세 출력

## 좌우 반전 (사용자 요청, 2026-11-10)
- imx241 모듈 매개변수 `mirror`(기본 켬): HFLIP 컨트롤이 0일 때 센서 거울상 출력, 색 배열 GRBG로 보고. libcamera는 설정 때마다 flip 컨트롤을 0으로 되돌리므로 컨트롤 기본값으로는 안 됨. 끄려면 `options imx241 mirror=0`

## 색 보정 (gbook10, 2026-11-13) — 윈도우 튜닝 데이터 적용
- 근거: 삼성 윈도우 드라이버 패키지의 카메라 튜닝 파일 `IMX241_START2FRONT_SKY.cpf`(Intel AIQB CMC, 저장소에 미포함) 해독 → [cmc/README.md](cmc/README.md). `cmc/gen_yaml.py`가 libcamera 튜닝 파일 `imx241.yaml` 생성(생성 결과는 패치에 포함)
- libcamera 0.7.2-1+gbook10(`libcamera/libcamera-0.7.2-gbook10.patch` = Debian 원본 대비 전체 변경, gbook3 내용 포함). 묶음 `bundle/camera/debs/`, 기기에서 apt hold
- IPU3 IPA 추가·수정:
  - `Ccm`: 광원 4종 색 보정 행렬을 AWB 색온도로 mired 보간(ImgU 8192=1.0)
  - `LensShadingCorrection`: 41×31 음영 격자 4종(A·F2·D50·D65)을 색온도로 보간 → BDS 출력 좌표로 변환(IF 자르기·센서 binning·좌우 반전 반영) → ImgU SHD
  - `Awb`: 회색 세계 추정을 모듈 색 응답 궤적(2300~6400K)에 투영해 색온도 산출, 궤적에서 0.06 이내로 제한
  - `BlackLevelCorrection`: 튜닝 파일 `level`(IMX241 128)
  - `ToneMapping`: sRGB 출력 곡선(`srgb: true`)
- 실측으로 확정한 값:
  - ImgU SHD 이득 = 1 + (lut << gain_factor) / 1024, LUT 12비트(4095 초과 시 넘침 → 모서리 고리 무늬). 노출·WB 고정 상태에서 보정 전후 프레임 비율로 측정, 윈도우 표와 오차 약 10%
  - OBGRID 흑 레벨 = 10비트 값의 2배(128). 렌즈를 가린 프레임에서 64는 바닥 약 27/255 잔류, 128에서 G·B 0. 64일 때는 흑 잔류로 통계 색비가 1 쪽으로 눌려 AWB 궤적과 0.28 어긋났음 → 128에서 0.06
  - 천장(백색) 위치별 색 편차로 음영 표의 색 보정 강도 검증(표 그대로가 최적에 근접)
- 결과: 화면 전체 밝기 균일, 흰 천장·벽 중립, 대비 회복(이전 청록·뿌연 화면 해소). PipeWire 경로 640×480 30 fps 확인
- 측정용 환경 변수(그대로 둠): `GBOOK_NO_LSC`, `GBOOK_NO_CCM`, `GBOOK_NO_LOCUS`, `GBOOK_LINEAR`(선형 출력·CCM 끔), `GBOOK_FREEZE_AT=<프레임>`(AE·AWB 고정), `GBOOK_LSC_FROM=<프레임>`, `GBOOK_OB=<값>`
- 빌드: Debian forky chroot(`debootstrap --variant=buildd forky`) → `apt-get build-dep libcamera`(프로필 nodoc nocheck) → Debian `libcamera_0.7.2-1` 소스에 패치 적용 → `DEB_BUILD_PROFILES="nodoc nocheck" dpkg-buildpackage -b`, 4코어 약 3분 20초

## 남은 일
1. 차트 기반 색 정확도 정량 평가(휴대폰 화면 차트는 노출 과다·화면 감마로 부정확했음 — 인쇄 차트 권장)
2. 커널이 7.2가 아니게 되면 DKMS 패키지 이식 필요(`BUILD_EXCLUSIVE_KERNEL="^7\.2\."`)
3. 아날로그 게인 최대값(현재 224=8배)·노출 여유(5줄) 정밀 확인
4. 웹캠 시험 사이트의 "0 FPS" 표시(PipeWire libcamera 플러그인이 framerate를 알리지 않음, 표시 문제)
5. 상류 AGC 버그 메모: `agc.cpp` process()에서 gGain_/bGain_에 blue/green이 뒤바뀌어 들어감(미수정)
