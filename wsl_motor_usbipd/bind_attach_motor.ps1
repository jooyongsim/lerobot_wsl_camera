<#
.SYNOPSIS
    Windows USB 모터(시리얼 장치)를 WSL(Ubuntu)에 자동으로 bind + attach 합니다.

.DESCRIPTION
    lerobot 모터(SO-100/SO-101 등)는 USB-시리얼 어댑터(CH343 등)로 연결됩니다.
    WSL2는 USB에 직접 접근할 수 없으므로 usbipd-win 으로 장치를 WSL에 넘겨줘야 합니다.

    이 스크립트는:
      1) usbipd 설치 여부 확인
      2) 관리자 권한이 아니면 자동으로 권한 상승(UAC)
      3) VID:PID 로 모터 장치를 자동 탐지 (BUSID 는 재연결 시 바뀌므로)
      4) bind (공유) — 한 번만 필요, 영구 적용. 실패 시 --force 재시도
      5) attach (WSL 연결) — 재연결/재부팅 후 매번 필요
      6) WSL 안에서 /dev/ttyUSB* 등으로 인식됐는지 검증

.PARAMETER VidPid
    대상 장치의 VID:PID. 기본값은 CH343 어댑터(1a86:55d3).
    'usbipd list' 로 본인 장치의 VID:PID 를 확인해 바꾸세요.

.PARAMETER BusId
    BUSID 를 직접 지정 (예: "1-7"). 지정하면 VID:PID 자동탐지를 건너뜁니다.

.PARAMETER Distribution
    대상 WSL 배포판 이름 (예: "Ubuntu-22.04"). 비우면 usbipd 가 자동 선택.

.PARAMETER Detach
    연결을 해제(detach)만 하고 종료합니다.

.PARAMETER NoPause
    종료 시 "Enter 키 대기" 없이 바로 닫습니다. (배치/자동화용)

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1 -VidPid "1a86:55d3" -Distribution "Ubuntu-22.04"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bind_attach_motor.ps1 -Detach
#>

[CmdletBinding()]
param(
    [string]$VidPid = "1a86:55d3",
    [string]$BusId = "",
    [string]$Distribution = "",
    [switch]$Detach,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }
function Write-Err2($msg)  { Write-Host "    [X] $msg" -ForegroundColor Red }

function Pause-IfNeeded {
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "끝났습니다. Enter 키를 누르면 창이 닫힙니다"
    }
}

# ------------------------------------------------------------------
# 0) 관리자 권한 확인 + 자동 상승
# ------------------------------------------------------------------
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "관리자 권한이 필요합니다. UAC 창에서 '예'를 눌러주세요..." -ForegroundColor Yellow
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-VidPid", "`"$VidPid`""
    )
    if ($BusId)        { $argList += @("-BusId", "`"$BusId`"") }
    if ($Distribution) { $argList += @("-Distribution", "`"$Distribution`"") }
    if ($Detach)       { $argList += "-Detach" }
    # 새 관리자 창은 자동으로 닫히지 않도록 NoPause 는 전달하지 않음
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

# ------------------------------------------------------------------
# 1) usbipd 설치 확인
# ------------------------------------------------------------------
Write-Step "usbipd 설치 확인"
if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) {
    Write-Err2 "usbipd 가 설치되어 있지 않습니다."
    Write-Host "    설치: winget install --interactive --exact dotnet-runtime-8 ; winget install usbipd" -ForegroundColor Gray
    Write-Host "    또는: https://github.com/dorssel/usbipd-win/releases" -ForegroundColor Gray
    Pause-IfNeeded
    exit 1
}
Write-Ok "usbipd 사용 가능"

# ------------------------------------------------------------------
# 2) 대상 장치 탐지 (BUSID 직접 지정 or VID:PID 자동탐지)
# ------------------------------------------------------------------
function Find-UsbDevice {
    param([string]$VidPid)
    $output = & usbipd list
    $inConnected = $false
    foreach ($line in $output) {
        if ($line -match '^Connected:') { $inConnected = $true; continue }
        if ($line -match '^Persisted:') { $inConnected = $false; continue }
        if (-not $inConnected) { continue }
        if ($line -match '^\s*(?<busid>\d+-\d+)\s+(?<vidpid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(?<rest>.+)$') {
            # 아래 state 탐지에서 -match 가 $matches 를 덮어쓰므로 먼저 지역 변수에 저장
            $foundBusId  = $matches.busid
            $foundVidPid = $matches.vidpid
            $rest        = $matches.rest.Trim()
            if ($foundVidPid -ieq $VidPid) {
                $state = 'Unknown'
                foreach ($s in @('Not shared', 'Shared (forced)', 'Shared', 'Attached')) {
                    if ($rest -match ([Regex]::Escape($s) + '\s*$')) { $state = $s; break }
                }
                return [PSCustomObject]@{
                    BusId  = $foundBusId
                    VidPid = $foundVidPid
                    State  = $state
                }
            }
        }
    }
    return $null
}

Write-Step "대상 장치 탐지"
if ($BusId) {
    $busid = $BusId
    Write-Ok "BUSID 직접 지정: $busid"
} else {
    $dev = Find-UsbDevice -VidPid $VidPid
    if (-not $dev) {
        Write-Err2 "VID:PID '$VidPid' 장치를 찾지 못했습니다. 케이블/전원 연결을 확인하세요."
        Write-Host "    현재 연결된 장치 목록:" -ForegroundColor Gray
        & usbipd list
        Pause-IfNeeded
        exit 1
    }
    $busid = $dev.BusId
    Write-Ok "장치 발견: BUSID=$busid  VID:PID=$($dev.VidPid)  상태=$($dev.State)"
}

# ------------------------------------------------------------------
# Detach 모드: 연결 해제 후 종료
# ------------------------------------------------------------------
if ($Detach) {
    Write-Step "WSL 연결 해제 (detach)"
    & usbipd detach --busid $busid
    Write-Ok "BUSID $busid detach 완료"
    Pause-IfNeeded
    exit 0
}

# ------------------------------------------------------------------
# 3) bind (공유) — 이미 공유면 건너뜀, 실패 시 --force 재시도
# ------------------------------------------------------------------
Write-Step "장치 공유 (bind)"
$dev = Find-UsbDevice -VidPid $VidPid
if ($dev -and $dev.State -eq 'Not shared') {
    & usbipd bind --busid $busid
    Start-Sleep -Milliseconds 500
    $dev = Find-UsbDevice -VidPid $VidPid
    if ($dev -and $dev.State -eq 'Not shared') {
        Write-Warn2 "일반 bind 실패 — 'bind --force' 로 재시도합니다 (USB 필터 존재 가능성)."
        & usbipd bind --force --busid $busid
    }
    Write-Ok "bind 완료 (영구 설정 — 다음부터는 attach 만 필요)"
} else {
    Write-Ok "이미 공유됨 — bind 건너뜀 (상태: $($dev.State))"
}

# ------------------------------------------------------------------
# 4) attach (WSL 연결)
# ------------------------------------------------------------------
Write-Step "WSL 에 연결 (attach)"
$dev = Find-UsbDevice -VidPid $VidPid
if ($dev -and $dev.State -eq 'Attached') {
    Write-Ok "이미 WSL 에 연결되어 있습니다."
} else {
    $attachArgs = @('attach', '--wsl', '--busid', $busid)
    if ($Distribution) { $attachArgs += @('--distribution', $Distribution) }
    & usbipd @attachArgs
    Write-Ok "attach 완료"
}

# ------------------------------------------------------------------
# 5) WSL 안에서 인식 확인
# ------------------------------------------------------------------
Write-Step "WSL 안에서 장치 인식 확인"
$checkCmd = 'echo "--- lsusb ---"; lsusb; echo "--- serial ports ---"; ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "시리얼 포트(/dev/ttyUSB*, /dev/ttyACM*) 가 아직 없습니다."'
if ($Distribution) {
    & wsl -d $Distribution -- bash -lc $checkCmd
} else {
    & wsl -- bash -lc $checkCmd
}

Write-Host ""
Write-Ok "완료! WSL 에서 보통 /dev/ttyUSB0 으로 인식됩니다."
Write-Host "    lerobot 예: --robot.port=/dev/ttyUSB0" -ForegroundColor Gray
Write-Host "    권한 오류 시 WSL 에서: sudo chmod 666 /dev/ttyUSB0  (또는 setup_motor_wsl.sh 실행)" -ForegroundColor Gray

Pause-IfNeeded
