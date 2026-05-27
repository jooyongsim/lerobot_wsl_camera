#!/usr/bin/env python
"""
[WSL(Ubuntu)에서 실행]  ZMQ 스트림 수신 테스트 클라이언트 (lerobot 불필요)

Windows 호스트의 camera_server_windows.py 가 송출하는 프레임을 받아
화면에 표시하거나(--show), 파일로 저장합니다(--save).

사용 예:
    # Windows 호스트 IP 자동 감지 후 화면 표시 (WSLg 필요)
    python camera_client_wsl.py --show

    # 호스트 IP를 직접 지정
    python camera_client_wsl.py --host 172.19.32.1 --show

    # 화면 대신 받은 프레임을 frames/ 폴더에 저장
    python camera_client_wsl.py --save
"""

import argparse
import base64
import json
import subprocess
import time
from pathlib import Path

import cv2
import numpy as np
import zmq


def detect_windows_host_ip() -> str:
    """WSL2(NAT)에서 Windows 호스트 IP를 기본 게이트웨이로부터 추정."""
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        # 예: "default via 172.19.32.1 dev eth0 ..."
        return out.split()[2]
    except Exception:
        # mirrored networking 모드면 localhost 로 접속 가능
        return "127.0.0.1"


def main():
    parser = argparse.ArgumentParser(description="WSL ZMQ camera client")
    parser.add_argument("--host", default=None, help="Windows 호스트 IP (미지정 시 자동 감지)")
    parser.add_argument("--port", type=int, default=5555)
    parser.add_argument("--show", action="store_true", help="cv2 창으로 표시 (WSLg 필요)")
    parser.add_argument("--save", action="store_true", help="frames/ 폴더에 프레임 저장")
    args = parser.parse_args()

    host = args.host or detect_windows_host_ip()
    print(f"[client] 접속 대상: tcp://{host}:{args.port}")

    context = zmq.Context()
    socket = context.socket(zmq.SUB)
    socket.setsockopt_string(zmq.SUBSCRIBE, "")
    socket.setsockopt(zmq.CONFLATE, True)       # 항상 최신 프레임만
    socket.setsockopt(zmq.RCVTIMEO, 5000)       # 5초 수신 타임아웃
    socket.connect(f"tcp://{host}:{args.port}")

    save_dir = Path("frames")
    if args.save:
        save_dir.mkdir(exist_ok=True)

    frame_count = 0
    t_start = time.time()
    try:
        while True:
            try:
                message = socket.recv_string()
            except zmq.Again:
                print("[client] 수신 타임아웃 — 서버가 실행 중인지, IP/포트가 맞는지 확인하세요.")
                continue

            data = json.loads(message)
            images = data.get("images", {})
            if not images:
                continue

            for name, img_b64 in images.items():
                img_bytes = base64.b64decode(img_b64)
                frame = cv2.imdecode(np.frombuffer(img_bytes, np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    continue

                frame_count += 1
                if frame_count % 30 == 0:
                    fps = frame_count / (time.time() - t_start)
                    print(f"[client] '{name}' 수신 중... {frame.shape[1]}x{frame.shape[0]} | {fps:.1f} FPS")

                if args.show:
                    cv2.imshow(name, frame)
                    if cv2.waitKey(1) & 0xFF == ord("q"):
                        raise KeyboardInterrupt
                if args.save and frame_count % 30 == 0:
                    cv2.imwrite(str(save_dir / f"{name}_{frame_count:06d}.jpg"), frame)
                    print(f"[client] 저장: {save_dir}/{name}_{frame_count:06d}.jpg")

            if not args.show and not args.save:
                # 옵션 없이 실행하면 수신 확인만
                pass
    except KeyboardInterrupt:
        print("\n[client] 종료")
    finally:
        if args.show:
            cv2.destroyAllWindows()
        socket.close()
        context.term()


if __name__ == "__main__":
    main()
