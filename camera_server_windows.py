#!/usr/bin/env python
"""
[Windows 호스트에서 실행]  카메라 -> ZMQ 스트리밍 서버

Windows에 연결된 USB 카메라를 OpenCV로 열어 JPEG로 인코딩한 뒤,
ZMQ PUB 소켓으로 송출합니다. WSL(Ubuntu) 쪽 클라이언트가 이 스트림을 구독합니다.

전송 메시지 형식 (JSON 문자열):
    {
        "timestamps": {"front": 1716800000.123},
        "images":     {"front": "<base64-jpeg>"}
    }

실행:
    conda activate control2025
    python camera_server_windows.py
"""

import base64
import contextlib
import json
import logging
import threading
import time

import cv2
import zmq

logger = logging.getLogger(__name__)

# ============================================================
# 설정 (학생용: 여기만 수정하면 됩니다)
# ============================================================
CONFIG = {
    "port": 5555,        # ZMQ 송출 포트 (클라이언트와 동일해야 함)
    "fps": 15,           # 송출 프레임 레이트
    "cameras": {
        "front": {
            "device_id": 1,        # Windows 카메라 번호 (0, 1, 2 ... 바꿔가며 확인)
            "width": 640,
            "height": 480,
        },
        # 카메라를 추가하려면 아래처럼 항목을 더 넣으면 됩니다.
        # "wrist": {"device_id": 2, "width": 640, "height": 480},
    },
}
# ============================================================


def encode_image(image, quality: int = 80) -> str:
    """BGR 이미지를 base64 JPEG 문자열로 인코딩."""
    _, buffer = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    return base64.b64encode(buffer).decode("utf-8")


class CameraCaptureThread:
    """카메라에서 프레임을 계속 읽어 JPEG로 인코딩해두는 백그라운드 스레드."""

    def __init__(self, cap: cv2.VideoCapture, name: str):
        self.cap = cap
        self.name = name
        self.latest_encoded: str | None = None
        self.latest_timestamp: float = 0.0
        self.lock = threading.Lock()
        self.running = False
        self.thread: threading.Thread | None = None

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        if self.thread:
            self.thread.join(timeout=1.0)

    def _loop(self):
        while self.running:
            ok, frame = self.cap.read()
            if not ok:
                time.sleep(0.01)
                continue
            encoded = encode_image(frame)
            with self.lock:
                self.latest_encoded = encoded
                self.latest_timestamp = time.time()

    def get_latest(self) -> tuple[str | None, float]:
        with self.lock:
            return self.latest_encoded, self.latest_timestamp


class ImageServer:
    def __init__(self, config: dict):
        self.fps = config.get("fps", 15)
        self.port = config.get("port", 5555)
        self.captures: dict[str, CameraCaptureThread] = {}
        self.caps: dict[str, cv2.VideoCapture] = {}

        for name, cam in config.get("cameras", {}).items():
            cap = cv2.VideoCapture(cam.get("device_id", 0))
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, cam.get("width", 640))
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, cam.get("height", 480))
            cap.set(cv2.CAP_PROP_FPS, self.fps)
            if not cap.isOpened():
                raise RuntimeError(
                    f"카메라 '{name}' (device_id={cam.get('device_id')}) 를 열 수 없습니다. "
                    f"device_id 를 0, 1, 2 ... 로 바꿔보세요."
                )
            self.caps[name] = cap
            self.captures[name] = CameraCaptureThread(cap, name)
            logger.info(f"카메라 '{name}' 준비됨 (device_id={cam.get('device_id')})")

        # ZMQ PUB 소켓
        self.context = zmq.Context()
        self.socket = self.context.socket(zmq.PUB)
        self.socket.setsockopt(zmq.SNDHWM, 20)   # 송신 버퍼 한도
        self.socket.setsockopt(zmq.LINGER, 0)
        self.socket.bind(f"tcp://*:{self.port}")
        logger.info(f"ImageServer 가 포트 {self.port} 에서 송출을 시작합니다.")

    def run(self):
        last_ts: dict[str, float] = {}

        for cap in self.captures.values():
            cap.start()

        logger.info("카메라 캡처 대기 중...")
        for name, cap in self.captures.items():
            while cap.get_latest()[0] is None:
                time.sleep(0.01)
            logger.info(f"카메라 '{name}' 첫 프레임 수신 완료")

        logger.info("스트리밍 시작 (종료: Ctrl+C)")
        try:
            while True:
                t0 = time.time()
                message = {"timestamps": {}, "images": {}}
                for name, cap in self.captures.items():
                    encoded, ts = cap.get_latest()
                    if encoded is not None and ts > last_ts.get(name, 0.0):
                        message["timestamps"][name] = ts
                        message["images"][name] = encoded
                        last_ts[name] = ts

                with contextlib.suppress(zmq.Again):
                    self.socket.send_string(json.dumps(message), zmq.NOBLOCK)

                sleep = (1.0 / self.fps) - (time.time() - t0)
                if sleep > 0:
                    time.sleep(sleep)
        except KeyboardInterrupt:
            logger.info("종료 중...")
        finally:
            for cap in self.captures.values():
                cap.stop()
            for cap in self.caps.values():
                cap.release()
            self.socket.close()
            self.context.term()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ImageServer(CONFIG).run()
