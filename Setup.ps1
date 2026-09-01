<#
  Setup.ps1 - 새 PC에서 카톡 릴레이를 한 번에 세팅한다.

    .\Setup.ps1                       대화형으로 설정값을 묻는다
    .\Setup.ps1 -Phone "01012345678"  발신번호를 인자로 지정
    .\Setup.ps1 -SkipTasks            작업 스케줄러 등록은 건너뜀

  이 스크립트는 config.json 을 덮어쓰지 않는다. 이미 있으면 그대로 쓴다.
#>
param(
    [string]$Phone,
    [int]$Port = 0,
    [switch]$SkipTasks
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Step([string]$m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }

Say ''
Say '  카톡 릴레이 설치' 'White'
Say '  ------------------------------------' 'DarkGray'

# ---------- 1. 사전 조건 ----------
Step '사전 조건 확인'

$psv = $PSVersionTable.PSVersion
Say ("  PowerShell {0}" -f $psv) $(if ($psv.Major -ge 5) { 'Green' } else { 'Red' })
if ($psv.Major -lt 5) { Say '  PowerShell 5.1 이상이 필요합니다.' 'Red'; return }

$kkExe = @(
    'C:\Program Files\Kakao\KakaoTalk\KakaoTalk.exe',
    'C:\Program Files (x86)\Kakao\KakaoTalk\KakaoTalk.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($kkExe) { Say "  카카오톡: $kkExe" 'Green' }
else { Say '  카카오톡을 찾을 수 없습니다. 설치 후 다시 실행하세요.' 'Red'; return }

$kkRunning = @(Get-Process -Name KakaoTalk -ErrorAction SilentlyContinue).Count -gt 0
Say ("  카카오톡 실행: {0}" -f $(if ($kkRunning) { '실행 중' } else { '꺼져 있음 (실행하고 로그인해 두세요)' })) `
    $(if ($kkRunning) { 'Green' } else { 'Yellow' })

# ---------- 2. LAN IP ----------
Step '네트워크 확인'

$ipInfo = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.InterfaceAlias -notlike '*WSL*' -and $_.InterfaceAlias -notlike '*Default Switch*' -and
    $_.InterfaceAlias -notlike '*Loopback*' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'
} | Select-Object -First 1

if (-not $ipInfo) { Say '  LAN IP 를 찾지 못했습니다. 유선/무선 연결을 확인하세요.' 'Red'; return }
$ip     = $ipInfo.IPAddress
$subnet = ($ip -replace '\.\d+$', '.*')
Say "  이 PC의 LAN IP : $ip  (인터페이스: $($ipInfo.InterfaceAlias))" 'Green'
Say "  허용할 대역     : $subnet" 'Green'

$profileName = (Get-NetConnectionProfile -InterfaceAlias $ipInfo.InterfaceAlias -ErrorAction SilentlyContinue).NetworkCategory
Say ("  네트워크 프로필 : {0}" -f $profileName) $(if ($profileName -eq 'Private') { 'Green' } else { 'Yellow' })
if ($profileName -ne 'Private') {
    Say '     집 네트워크라면 관리자 PowerShell 에서 아래를 실행하는 것을 권장합니다:' 'DarkGray'
    Say ("     Set-NetConnectionProfile -InterfaceAlias `"{0}`" -NetworkCategory Private" -f $ipInfo.InterfaceAlias) 'DarkGray'
}

# ---------- 3. config.json ----------
Step '설정 파일'

$cfgPath    = Join-Path $PSScriptRoot 'config.json'
$samplePath = Join-Path $PSScriptRoot 'config.sample.json'

if (Test-Path $cfgPath) {
    Say '  config.json 이 이미 있습니다. 그대로 사용합니다 (덮어쓰지 않음).' 'Yellow'
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    if (-not (Test-Path $samplePath)) { Say '  config.sample.json 이 없습니다.' 'Red'; return }
    $cfg = Get-Content $samplePath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not $Phone) {
        Write-Host ''
        $Phone = Read-Host '  문자를 보낼 폰 번호 (예: 01012345678)'
    }
    if ($Phone) { $cfg.allowFrom = @($Phone) }
    $cfg.allowIPs = @('127.0.0.1', $subnet)
    if ($Port -gt 0) { $cfg.port = $Port }

    $cfg.PSObject.Properties.Remove('_설명')
    $cfg | ConvertTo-Json -Depth 6 | Set-Content $cfgPath -Encoding UTF8
    Say '  config.json 생성 완료' 'Green'
}

Say ("  포트          : {0}" -f $cfg.port)
Say ("  허용 발신번호 : {0}" -f (($cfg.allowFrom) -join ', '))
Say ("  허용 IP       : {0}" -f (($cfg.allowIPs) -join ', '))
Say ("  dryRun        : {0}" -f $cfg.dryRun) $(if ($cfg.dryRun) { 'Yellow' } else { 'Green' })

# ---------- 4. 방화벽 ----------
Step '방화벽'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$ruleName = "KakaoRelay ($($cfg.port))"
$rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($rule) {
    Say '  방화벽 규칙이 이미 있습니다.' 'Green'
} elseif ($isAdmin) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $cfg.port -Profile Private | Out-Null
    Say '  방화벽 규칙 추가 완료' 'Green'
} else {
    Say '  관리자 권한이 아니라 방화벽 규칙을 추가하지 못했습니다.' 'Yellow'
    Say '  관리자 PowerShell 에서 아래 한 줄을 실행하세요:' 'DarkGray'
    Say ("  New-NetFirewallRule -DisplayName `"$ruleName`" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($cfg.port) -Profile Private") 'White'
}

# ---------- 5. 작업 스케줄러 ----------
Step '실행 파일 빌드'
# 서명 없는 exe 를 배포하면 SmartScreen 경고가 뜨므로, 배포본에 넣지 않고 설치할 때 만든다.
# Windows 에 내장된 csc.exe 를 쓰므로 따로 설치할 것은 없다.
try {
    & (Join-Path $PSScriptRoot 'Build-Exe.ps1')
} catch {
    Say "  빌드 실패(무시하고 계속): $($_.Exception.Message)" 'Yellow'
    Say '  전용 실행 파일 없이도 동작합니다. 작업관리자에 Windows PowerShell 로 표시될 뿐입니다.' 'DarkGray'
}

if (-not $SkipTasks) {
    Step '자동 실행 등록'
    & (Join-Path $PSScriptRoot 'Install-Autostart.ps1')
    Start-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8
}

<#
  ---------- 6. 바탕 화면 바로가기 ----------

  릴레이를 완전히 끄면 알림 영역 아이콘이 사라진다. 그때 다시 켜는 통로가
  압축을 푼 폴더 안의 [시작중지] 하나뿐이라, 그 폴더를 못 찾으면 손을 쓸 수 없다.
  자동 복구 작업은 1분마다 깨었다 죽는 작업이라 아이콘을 대신 들고 있을 수 없으므로,
  바탕 화면에 바로가기를 둬서 항상 보이게 한다.
#>
Step '바로가기'

$rootDir = Split-Path $PSScriptRoot -Parent
$batPath = Join-Path $rootDir 'KakaoRelay.bat'
if (Test-Path $batPath) {
    try {
        $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '카톡 릴레이.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $batPath
        $lnk.WorkingDirectory = $rootDir
        $lnk.Description      = '카톡 릴레이를 켜거나 끕니다'
        $ico = Join-Path $PSScriptRoot 'relay.ico'
        if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
        $lnk.Save()
        Say "  바탕 화면에 [카톡 릴레이] 바로가기를 만들었습니다." 'Green'
    } catch {
        Say "  바로가기를 만들지 못했습니다(무시해도 됩니다): $($_.Exception.Message)" 'Yellow'
    }
} else {
    Say '  KakaoRelay.bat 을 찾지 못해 바로가기를 건너뜁니다.' 'DarkGray'
}

# ---------- 7. 결과 확인 ----------
Step '결과'

try {
    $h = (Invoke-WebRequest -Uri "http://127.0.0.1:$($cfg.port)/health" -UseBasicParsing -TimeoutSec 10).Content
    Say "  릴레이 응답: $h" 'Green'
} catch {
    Say '  릴레이가 아직 응답하지 않습니다. Check-Ready.ps1 로 확인하세요.' 'Yellow'
}

<#
  ---------- 8. 결과를 남기고 돌려보내기 ----------

  이 안내는 콘솔 스크롤백에만 있었다. 창을 닫는 순간 폰에 넣을 URL 까지 사라져
  사용자는 아무 창도 없는 상태에서 바탕 화면을 뒤져야 했다.
  그래서 (1) 파일로 남기고 (2) 메모장으로 띄우고 (3) 조작 창을 다시 열어 준다.
#>
$guide = @"
카톡 릴레이 - 설치 결과
=======================================

폰(MacroDroid)에 넣을 값
---------------------------------------
  트리거       : 알림 (Notification) - 기본 문자 메시지 앱
  URL          : http://$ip`:$($cfg.port)/sms?from={not_title}
  Method       : POST
  Content Type : text/plain
  Body         : {notification}

문자 보내는 형식
---------------------------------------
  채팅방 내용            (예: 엄마 오늘 늦어요)
  채팅방/내용            (채팅방 이름에 띄어쓰기가 있으면 이쪽)

확인할 것
---------------------------------------
  Wi-Fi 가 [공용 네트워크] 로 되어 있으면 폰에서 접속되지 않습니다.
  설정 > 네트워크 및 인터넷 > 속성 > 네트워크 프로필 유형에서 [개인] 을 선택하세요.
  PC 주소가 바뀌지 않도록 공유기에서 이 PC 에 고정 IP 를 할당해 두면 좋습니다.

남은 할 일
---------------------------------------
  1) 카카오톡을 실행하고 로그인한 뒤 화면잠금을 끕니다
  2) [카톡 릴레이] > [설정 편집] 에서 자주 쓸 채팅방을 aliases 에 등록합니다
  3) 위 URL 을 폰 MacroDroid 에 입력합니다
  4) 시험 삼아 문자를 한 통 보냅니다
     처음에는 시험 모드라 카카오톡으로 실제 전송되지 않습니다.
     [카톡 릴레이] 창에서 어느 채팅방으로 갈 뻔했는지 확인한 뒤 시험 모드를 해제하세요.
  5) 문제가 있으면 [카톡 릴레이] > [상태 점검] 을 누릅니다

켜고 끄기, 점검, 설정은 모두 바탕 화면의 [카톡 릴레이] 에서 합니다.
"@
$guidePath = Join-Path (Split-Path $PSScriptRoot -Parent) '설치결과.txt'
try {
    [IO.File]::WriteAllText($guidePath, $guide, (New-Object Text.UTF8Encoding $true))
} catch { $guidePath = $null }

Write-Host ''
Write-Host $guide
Write-Host ''
if ($guidePath) { Say "  이 내용은 $guidePath 에도 저장했습니다." 'DarkGray' }
Write-Host ''

Read-Host '  엔터를 누르면 [카톡 릴레이] 창이 열립니다'
if ($guidePath) { Start-Process notepad.exe $guidePath }
$bat = Join-Path (Split-Path $PSScriptRoot -Parent) 'KakaoRelay.bat'
if (Test-Path $bat) { Start-Process $bat -WorkingDirectory (Split-Path $bat -Parent) }
