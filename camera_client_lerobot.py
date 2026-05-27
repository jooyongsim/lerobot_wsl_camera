#!/usr/bin/env python
"""
[WSL(Ubuntu)에서 실행]  lerobot 의 ZMQCamera 로 스트림 수신 예제

lerobot 이 설치된 환경에서 ZMQCamera 클래스를 사용해 프레임을 읽는 방법입니다.
실제 로봇 학습/기록 파이프라인에서는 이 방식으로 카메라를 등록해 사용합니다.

사용 예:
    python camera_client_lerobot.py --host 172.19.32.1 --camera-name front
"""

import argparse
import subprocess
import time

from lerobot.cameras.zmq import ZMQCamera, ZMQCameraConfig


def detect_windows_host_ip() -> str:
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        return out.split()[2]
    except Exception:
        return "127.0.0.1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=None, help="Windows 호스트 IP (미지정 시 자동 감지)")
    parser.add_argument("--port", type=int, default=5555)
    parser.add_argument("--camera-name", default="front", help="서버 CONFIG 의 카메라 이름과 동일하게")
    args = parser.parse_args()

    host = args.host or detect_windows_host_ip()
    print(f"[lerobot] 접속 대상: tcp://{host}:{args.port} (camera_name='{args.camera_name}')")

    config = ZMQCameraConfig(
        server_address=host,
        port=args.port,
        camera_name=args.camera_name,
    )
    camera = ZMQCamera(config)
    camera.connect()
    print(f"[lerobot] 연결 완료. 해상도: {camera.width}x{camera.height}")

    try:
        for i in range(100):
            frame = camera.read()  # (H, W, 3) numpy 배열 (RGB)
            if i % 10 == 0:
                print(f"[lerobot] frame {i}: shape={frame.shape}, dtype={frame.dtype}")
            time.sleep(0.05)
    except KeyboardInterrupt:
        pass
    finally:
        camera.disconnect()
        print("[lerobot] 연결 해제")


if __name__ == "__main__":
    main()
