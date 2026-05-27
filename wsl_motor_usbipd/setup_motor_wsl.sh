#!/usr/bin/env bash
# ============================================================
# [WSL(Ubuntu)에서 실행]  attach 된 모터 시리얼 포트 확인 + 권한 설정
#
# 사용:
#   bash setup_motor_wsl.sh          # 포트 확인 + 일시적 권한(chmod) 부여
#   bash setup_motor_wsl.sh --group  # dialout 그룹에 추가(영구, 재로그인 필요)
# ============================================================
set -e

echo "=== 1) USB 장치 목록 (lsusb) ==="
lsusb || echo "lsusb 가 없으면: sudo apt install usbutils"

echo
echo "=== 2) 시리얼 포트 탐색 ==="
PORTS=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
if [ -z "$PORTS" ]; then
    echo "시리얼 포트(/dev/ttyUSB*, /dev/ttyACM*) 가 없습니다."
    echo " -> Windows 에서 bind_attach_motor.ps1 (또는 attach_motor.bat) 를 먼저 실행했는지 확인하세요."
    echo " -> 'usbipd list' 의 상태가 Attached 인지 확인하세요."
    exit 1
fi
echo "발견된 포트:"
for p in $PORTS; do echo "  $p"; done

echo
if [ "$1" == "--group" ]; then
    echo "=== 3) dialout 그룹에 현재 사용자 추가 (영구) ==="
    sudo usermod -aG dialout "$USER"
    echo "완료. 변경 적용을 위해 WSL 을 재시작하거나 다시 로그인하세요:"
    echo "  (Windows PowerShell) wsl --shutdown   후 WSL 재실행"
else
    echo "=== 3) 시리얼 포트 권한 부여 (일시적, 재연결 시 다시 필요) ==="
    for p in $PORTS; do
        sudo chmod 666 "$p"
        echo "  chmod 666 $p"
    done
    echo "영구적으로 하려면:  bash setup_motor_wsl.sh --group"
fi

echo
echo "=== 완료 ==="
echo "lerobot 사용 예:"
echo "  python -m lerobot.find_port            # 포트 자동 탐색"
echo "  ... --robot.port=/dev/ttyUSB0          # 위에서 찾은 포트로 지정"
