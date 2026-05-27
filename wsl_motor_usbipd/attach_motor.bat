@echo off
REM ============================================================
REM  모터 USB 를 WSL 에 연결 (더블클릭 실행용)
REM  - 실행 정책(ExecutionPolicy)을 우회하고 bind_attach_motor.ps1 실행
REM  - ps1 스크립트가 알아서 관리자 권한(UAC)으로 상승합니다
REM ============================================================
echo 모터 USB 를 WSL 에 연결합니다...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bind_attach_motor.ps1" %*
