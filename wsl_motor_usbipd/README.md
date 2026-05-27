# WSL에서 lerobot 모터 연결하기 (usbipd 자동화)

Windows에 연결된 USB 모터(SO-100/SO-101 등, USB-시리얼 어댑터)를 **WSL(Ubuntu)** 안의 lerobot에서 쓰려면, `usbipd-win`으로 장치를 WSL에 넘겨줘야 합니다. 이 폴더의 스크립트가 그 과정을 **자동화**합니다.

## 왜 필요한가요?

WSL2는 USB 장치에 직접 접근하지 못합니다. 그래서:

```
Windows USB 모터  ──(usbipd bind+attach)──▶  WSL /dev/ttyUSB0  ──▶  lerobot
```

- **bind**: 장치를 "공유 가능" 상태로 등록. **한 번만** 하면 됩니다(영구, 관리자 권한 필요).
- **attach**: 공유된 장치를 실제로 WSL에 연결. **재연결/재부팅 때마다** 필요합니다.

> 📷 카메라는 이 방식이 **아니라** 네트워크 스트리밍(ZMQ)을 씁니다 → `../wsl_camera_tutorial/` 참고.
> usbipd는 **모터 같은 시리얼 장치**에만 사용합니다.

## 폴더 구성

| 파일 | 실행 위치 | 설명 |
|------|-----------|------|
| `attach_motor.bat` | Windows | **더블클릭 실행용** 래퍼 (실행정책 우회 + 권한상승) |
| `bind_attach_motor.ps1` | Windows | 핵심 스크립트: 장치 자동탐지 → bind → attach → 검증 |
| `setup_motor_wsl.sh` | WSL | attach된 포트 확인 + 시리얼 권한 설정 |

---

## 사전 준비 (최초 1회)

### Windows에 usbipd-win 설치
```powershell
winget install usbipd
```
또는 https://github.com/dorssel/usbipd-win/releases 에서 설치.

설치 후 PowerShell/터미널을 새로 엽니다.

---

## 사용법

### 방법 A — 더블클릭 (가장 쉬움)

1. 모터 USB를 Windows에 연결
2. `attach_motor.bat` **더블클릭**
3. UAC(관리자 권한) 창이 뜨면 **예** 클릭
4. 자동으로 bind → attach → WSL 인식 확인까지 진행됩니다

### 방법 B — PowerShell에서 실행

```powershell
cd C:\claude_code_projects\18_lerobot\wsl_motor_usbipd
powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1
```

> 본 PC는 스크립트 실행 정책이 막혀 있을 수 있어 `-ExecutionPolicy Bypass`가 필요합니다.
> 스크립트가 관리자 권한이 아니면 자동으로 UAC 권한 상승을 요청합니다.

성공 시 출력 예:
```
==> 대상 장치 탐지
    [OK] 장치 발견: BUSID=1-7  VID:PID=1a86:55d3  상태=Not shared
==> 장치 공유 (bind)
    [OK] bind 완료 (영구 설정 — 다음부터는 attach 만 필요)
==> WSL 에 연결 (attach)
    [OK] attach 완료
==> WSL 안에서 장치 인식 확인
    --- serial ports ---
    crw-rw-rw- 1 root dialout 188, 0 ... /dev/ttyUSB0
    [OK] 완료! WSL 에서 보통 /dev/ttyUSB0 으로 인식됩니다.
```

### WSL 쪽 — 포트 확인 & 권한 설정

WSL(Ubuntu) 터미널에서:
```bash
cd /mnt/c/claude_code_projects/18_lerobot/wsl_motor_usbipd
bash setup_motor_wsl.sh            # 포트 확인 + 임시 권한(chmod 666)
# 매번 chmod 하기 싫으면 (영구, 재로그인 필요):
bash setup_motor_wsl.sh --group
```

이후 lerobot에서:
```bash
python -m lerobot.find_port                 # 포트 자동 탐색
# 예: SO-101 팔로워 텔레오퍼레이션
... --robot.port=/dev/ttyUSB0
```

---

## 옵션 (bind_attach_motor.ps1)

| 옵션 | 설명 | 예시 |
|------|------|------|
| `-VidPid` | 대상 장치 VID:PID (기본 `1a86:55d3` = CH343) | `-VidPid "0403:6014"` |
| `-BusId` | BUSID 직접 지정 (자동탐지 건너뜀) | `-BusId "1-7"` |
| `-Distribution` | 대상 WSL 배포판 | `-Distribution "Ubuntu-22.04"` |
| `-Detach` | WSL 연결 해제만 수행 | `-Detach` |
| `-NoPause` | 종료 시 Enter 대기 없음(자동화용) | `-NoPause` |

**예시 — 다른 어댑터, 특정 배포판:**
```powershell
powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1 -VidPid "0403:6014" -Distribution "Ubuntu-22.04"
```

**예시 — 연결 해제:**
```powershell
powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1 -Detach
```

---

## 스크립트가 하는 일 (동작 설명)

`bind_attach_motor.ps1` 흐름:

1. **권한 상승** — 관리자가 아니면 UAC로 자기 자신을 재실행 (bind에 관리자 권한 필요).
2. **usbipd 확인** — 미설치면 설치 안내 후 종료.
3. **장치 탐지** — `usbipd list`를 파싱해 **VID:PID로 BUSID를 자동 검색**.
   BUSID는 USB 포트를 바꾸거나 재연결하면 달라지므로, VID:PID 기준이 안정적입니다.
4. **bind** — 상태가 `Not shared`면 `usbipd bind` 실행. 실패하면(USB 필터 등)
   `usbipd bind --force`로 재시도. 이미 공유됐으면 건너뜀.
5. **attach** — 상태가 `Attached`가 아니면 `usbipd attach --wsl`로 WSL에 연결.
6. **검증** — `wsl -- bash -lc "lsusb; ls /dev/ttyUSB* /dev/ttyACM*"`로 인식 확인.

`setup_motor_wsl.sh` 흐름: `lsusb`로 장치 확인 → 시리얼 포트 탐색 →
`chmod 666`(임시) 또는 `dialout` 그룹 추가(영구)로 접근 권한 부여.

---

## 자주 막히는 부분 (Troubleshooting)

| 증상 | 원인 / 해결 |
|------|-------------|
| `usbipd 가 설치되어 있지 않습니다` | `winget install usbipd` 후 터미널 재시작 |
| `VID:PID ... 장치를 찾지 못했습니다` | 케이블/전원 확인. `usbipd list`로 실제 VID:PID 확인 후 `-VidPid`로 지정 |
| bind는 됐는데 attach 실패 | WSL이 꺼져 있을 수 있음. WSL 터미널을 한 번 열고 다시 실행 |
| `bind --force may be required` 경고 | 스크립트가 자동으로 `--force` 재시도함. 벤더 USB 필터(nxusbf 등) 때문 |
| WSL에 `/dev/ttyUSB*`가 안 보임 | `usbipd list` 상태가 `Attached`인지 확인. 아니면 스크립트 재실행 |
| lerobot에서 `Permission denied` | WSL에서 `bash setup_motor_wsl.sh` (chmod) 또는 `--group`(dialout) 실행 |
| 재부팅/USB 재연결 후 안 됨 | bind는 유지되지만 **attach는 다시** 해야 함 → `attach_motor.bat` 다시 실행 |
| 포트가 `ttyACM0`로 잡힘 | 정상. lerobot에 `--robot.port=/dev/ttyACM0`로 지정 |

---

## 핵심 요약

- **최초 1회**: usbipd 설치 → `attach_motor.bat` (bind + attach)
- **재부팅/재연결마다**: `attach_motor.bat` 다시 실행 (attach만 다시 됨)
- **WSL 권한 오류 시**: `bash setup_motor_wsl.sh`
- **lerobot**: `--robot.port=/dev/ttyUSB0`
