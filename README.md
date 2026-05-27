# WSL에서 카메라 연결하기 튜토리얼

Windows에 연결된 USB 카메라 영상을 **WSL(Ubuntu)** 안에서 받아 쓰는 방법입니다.

## 왜 이렇게 하나요?

WSL2는 USB 카메라에 직접 접근하기 어렵습니다. 그래서 다음 구조를 사용합니다.

```
┌─────────────────────────┐         ZMQ (TCP, 포트 5555)        ┌──────────────────────┐
│  Windows 호스트          │  ────────  JPEG 스트림  ───────▶   │   WSL (Ubuntu)        │
│  USB 카메라 캡처 + 송출   │                                     │   프레임 수신 + 디코딩 │
│  camera_server_windows  │                                     │   camera_client_*     │
└─────────────────────────┘                                     └──────────────────────┘
```

- **Windows**가 카메라를 열어 JPEG로 인코딩 후 네트워크로 송출합니다.
- **WSL**은 TCP로 접속해 프레임을 받습니다.
- 카메라는 `usbipd`로 넘길 필요가 **없습니다**. (usbipd는 로봇 시리얼 장치(CH343 등)용이고, 카메라는 네트워크 스트리밍으로 처리합니다.)

## 폴더 구성

| 파일 | 실행 위치 | 설명 |
|------|-----------|------|
| `camera_server_windows.py` | Windows | 카메라 캡처 후 ZMQ로 송출하는 서버 |
| `camera_client_wsl.py` | WSL | 수신 테스트용 클라이언트 (lerobot 불필요) |
| `camera_client_lerobot.py` | WSL | lerobot `ZMQCamera`를 쓰는 예제 |

---

## 사전 준비

### Windows 쪽 (control2025 conda 환경)

필요한 라이브러리: `opencv`, `pyzmq` (control2025 환경에 이미 설치되어 있어야 합니다)

```bat
conda activate control2025
pip install opencv-python pyzmq   :: 없을 때만
```

### WSL(Ubuntu) 쪽

```bash
pip install opencv-python pyzmq numpy
# lerobot 예제(camera_client_lerobot.py)를 쓰려면 lerobot도 설치
# pip install -e /path/to/lerobot
```

> `camera_client_wsl.py --show`로 화면을 띄우려면 **WSLg**가 필요합니다.
> Windows 11 + 최신 WSL이면 기본 포함되어 있습니다. (`wsl --update`)

---

## 실행 순서

### 1단계 — Windows에서 카메라 서버 실행

```bat
conda activate control2025
cd C:\claude_code_projects\18_lerobot\wsl_camera_tutorial
python camera_server_windows.py
```

성공하면 다음과 같은 로그가 나옵니다.

```
카메라 'front' 준비됨 (device_id=1)
ImageServer 가 포트 5555 에서 송출을 시작합니다.
카메라 'front' 첫 프레임 수신 완료
스트리밍 시작 (종료: Ctrl+C)
```

> **카메라가 안 열리면?** `camera_server_windows.py` 상단 `CONFIG`의
> `device_id`를 `0`, `1`, `2` ... 로 바꿔가며 다시 실행하세요.

### 2단계 — WSL에서 수신 확인

새 WSL 터미널에서:

```bash
cd /mnt/c/claude_code_projects/18_lerobot/wsl_camera_tutorial   # 또는 파일을 복사한 위치

# 화면으로 보기 (WSLg)
python camera_client_wsl.py --show

# 화면이 안 되면 파일로 저장해서 확인
python camera_client_wsl.py --save
```

정상이면 다음처럼 출력됩니다.

```
[client] 접속 대상: tcp://172.19.32.1:5555
[client] 'front' 수신 중... 640x480 | 14.8 FPS
```

`q` 키를 누르면 창이 닫힙니다.

### 3단계 (선택) — lerobot ZMQCamera로 사용

```bash
python camera_client_lerobot.py --camera-name front
```

---

## Windows 호스트 IP 알아내기

클라이언트는 기본적으로 호스트 IP를 자동 감지하지만, 안 되면 직접 지정하세요.

**WSL에서 확인:**
```bash
ip route show default | awk '{print $3}'    # 예: 172.19.32.1
```

**직접 지정해서 실행:**
```bash
python camera_client_wsl.py --host 172.19.32.1 --show
```

> WSL이 **mirrored networking** 모드면 호스트를 `127.0.0.1`(localhost)로 접속합니다.

---

## 자주 막히는 부분 (Troubleshooting)

| 증상 | 원인 / 해결 |
|------|-------------|
| `수신 타임아웃` | 서버가 안 켜져 있거나 IP/포트 불일치. 1단계 로그 확인, `--host`로 IP 직접 지정 |
| 카메라가 안 열림 (`열 수 없습니다`) | `CONFIG`의 `device_id`를 0/1/2로 바꿔보기. 다른 앱(Zoom 등)이 카메라 점유 중인지 확인 |
| `--show`인데 창이 안 뜸 | WSLg 미설치/구버전. PowerShell에서 `wsl --update` 후 WSL 재시작 |
| WSL에서 host IP 접속 실패 | Windows **방화벽**이 포트 5555 인바운드 차단. 방화벽 규칙 추가 또는 일시 해제 |
| 영상이 끊김/지연 | 서버 `CONFIG`의 `fps`를 낮추거나, `encode_image`의 `quality`(기본 80) 조정 |

### Windows 방화벽 포트 열기 (필요 시, 관리자 PowerShell)

```powershell
New-NetFirewallRule -DisplayName "ZMQ Camera 5555" -Direction Inbound -LocalPort 5555 -Protocol TCP -Action Allow
```

---

## 전송 프로토콜 (참고)

서버는 아래 형식의 JSON 문자열을 ZMQ PUB 소켓으로 보냅니다.

```json
{
  "timestamps": { "front": 1716800000.123 },
  "images":     { "front": "<base64-인코딩된 JPEG>" }
}
```

여러 카메라를 등록하면 `images`에 카메라 이름별로 여러 개가 담깁니다.
