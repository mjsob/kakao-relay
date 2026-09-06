<#
  Check-Ready.ps1 - 실전 투입 전 점검
  통과하지 못한 항목만 고치면 된다.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. "$PSScriptRoot\Version.ps1"
try {
    $host.UI.RawUI.BackgroundColor = 'Black'
    $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(96, 32)
    Clear-Host
} catch { }

Write-Host ''
Write-Host "  카톡 릴레이 v$RelayVersion - 상태 점검" -ForegroundColor White
Write-Host '  ────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

. "$PSScriptRoot\KakaoCore.ps1"

<#
  설정 파일이 깨졌을 때 빨간 예외를 뱉고 죽으면 사용자는 원인을 알 수 없다.
  메모장에서 쉼표 하나 지운 것이 가장 흔한 원인이므로 그걸 짚어 준다.
#>
$cfgPath = Join-Path $PSScriptRoot 'config.json'
try {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host ' 문제 ' -ForegroundColor Red -NoNewline
    Write-Host '설정 파일을 읽지 못했습니다.'
    Write-Host '        -> [설정 편집]에서 마지막에 고친 부분을 되돌리세요. 쉼표나 따옴표가 빠졌을 수 있습니다.' -ForegroundColor DarkGray
    Write-Host "        -> $cfgPath" -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  엔터를 누르면 창이 닫힙니다'
    return
}

<#
  항목이 정해지는 즉시 찍는다.
  전에는 전부 모았다가 마지막에 한꺼번에 찍었는데, 그 앞에 방화벽 조회와
  예약 작업 조회 같은 느린 호출이 줄줄이 있어 몇 초 동안 빈 화면만 보였다.
#>
$todo = 0
function Chk([string]$name, [bool]$ok, [string]$detail, [string]$fix = '') {
    # 한글은 화면에서 두 칸을 먹으므로 글자 수로 채우면 세로줄이 어긋난다
    $w = 0
    foreach ($c in $name.ToCharArray()) { $w += if ([int]$c -gt 0x1100) { 2 } else { 1 } }
    $pad = ' ' * [Math]::Max(0, 22 - $w)

    $mark = if ($ok) { '  OK  ' } else { '할 일 ' }
    $col  = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host $mark -ForegroundColor $col -NoNewline
    Write-Host "$name$pad $detail"
    if (-not $ok) {
        $script:todo++
        if ($fix) { Write-Host ("        -> {0}" -f $fix) -ForegroundColor DarkGray }
    }
}

# --- PC / 카톡 ---
$kk = @(Get-KakaoProcessIds)
Chk '카카오톡 실행' ($kk.Count -gt 0) $(if($kk.Count){'실행 중'}else{'실행 안 됨'}) '카카오톡을 실행하고 로그인하세요'
$main = Get-KakaoMainWindow
Chk '카카오톡 메인창 인식' ($null -ne $main) $(if($main){'창 확인됨'}else{'못 찾음'}) '카카오톡 로그인 및 화면잠금 해제'

# --- 설정 ---
# 비밀번호는 requirePassword 가 켜져 있을 때만 의미가 있다.
# 꺼져 있는데 '기본값 그대로' 라고 경고하면 고칠 필요 없는 것을 고치라는 말이 된다.
$needPw = if ($cfg.PSObject.Properties.Name -contains 'requirePassword') { [bool]$cfg.requirePassword } else { $true }
if ($needPw) {
    Chk '비밀번호' ($cfg.password -ne 'CHANGE_ME' -and $cfg.password.Length -ge 4) `
        $(if($cfg.password -eq 'CHANGE_ME'){'기본값 그대로'}else{"설정됨 ($($cfg.password.Length)자)"}) `
        '[카톡 릴레이] > [설정 편집]에서 password 변경'
} else {
    Chk '비밀번호' $true '사용 안 함 (문자 형식: 채팅방 내용)' ''
}

$allow = @($cfg.allowFrom | Where-Object { $_ -and $_ -ne '010-0000-0000' })
Chk '허용 발신번호' ($allow.Count -gt 0) `
    $(if($allow.Count){$allow -join ', '}else{'예시 번호 그대로'}) `
    '[카톡 릴레이] > [설정 편집]에서 allowFrom에 문자를 보낼 번호를 넣으세요'

# 조작 창에 [시험 모드 해제] 버튼이 있다. 메모장으로 JSON 을 고치게 하면 안 된다.
Chk '시험 모드' (-not $cfg.dryRun) $(if($cfg.dryRun){'켜짐 - 카카오톡으로 실제 전송하지 않음'}else{'꺼짐'}) `
    '[카톡 릴레이] 창에서 [시험 모드 해제]를 누르세요'

<#
  sendMethod 가 enter 면 진짜 포커스가 있어야 전송된다.
  릴레이는 숨어서 도는데 다른 창이 앞에 있으면 Enter 가 그 창으로 가 버려,
  글자는 입력창에 들어갔는데 전송만 안 되는 상태가 된다. 원인을 찾기 매우 어렵다.
#>
<#
  릴레이가 접속을 거부할 때 '[상태 점검]으로 허용 대역 보기' 라고 안내한다.
  그런데 여기서 허용 대역을 보여 주지 않으면 그 안내가 막다른 길이 된다.
#>
$ips = @($cfg.allowIPs)
Chk '허용 접속 대역' ($ips.Count -gt 0) `
    $(if($ips.Count){$ips -join ', '}else{'비어 있음 - 모든 기기 허용'}) `
    '[카톡 릴레이] > [설정 편집]에서 allowIPs 에 중계 휴대폰이 속한 대역을 넣으세요'

$sm = if ($cfg.PSObject.Properties.Name -contains 'sendMethod') { [string]$cfg.sendMethod } else { 'auto' }
Chk '전송 방법' ($sm -ne 'enter') $sm `
    '[카톡 릴레이] > [설정 편집]에서 sendMethod 를 auto 로 바꾸세요. enter 는 다른 창이 앞에 있으면 실패합니다'

$aliasCount = @($cfg.aliases.PSObject.Properties).Count
# 별칭이 없어도 전체 채팅방 이름으로 보내면 되므로 실패로 취급하지 않는다
Chk '채팅방 별칭' $true $(if($aliasCount -gt 0){"$aliasCount 개 등록"}else{'없음 (전체 방 이름으로 보내면 됨)'}) ''

# --- 별칭이 가리키는 방이 실제로 열리는지 ---
foreach ($a in $cfg.aliases.PSObject.Properties) {
    $found = $null -ne (Find-KakaoRoomWindow -Room $a.Value)
    Chk "  별칭 '$($a.Name)'" $true "-> '$($a.Value)'$(if($found){' (창 열려 있음)'}else{' (자동열기로 처리)'})" ''
}

# --- 네트워크 ---
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.InterfaceAlias -notlike '*WSL*' -and $_.InterfaceAlias -notlike '*Default Switch*' -and
        $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress)
Chk 'LAN IP' ($null -ne $ip) $(if($ip){"$ip -> http://$ip`:$($cfg.port)/sms"}else{'못 찾음'}) '공유기에서 DHCP 고정 할당 권장'

$fw = Get-NetFirewallRule -DisplayName "KakaoRelay ($($cfg.port))" -ErrorAction SilentlyContinue
Chk '방화벽 인바운드' ($null -ne $fw) $(if($fw){'허용됨'}else{'규칙 없음'}) 'program 폴더의 Setup.ps1을 마우스 오른쪽 > PowerShell로 실행 (관리자 권한 필요)'

<#
  방화벽 규칙은 '개인' 프로필에만 만든다. 그래서 규칙이 있어도 지금 연결이
  '공용' 이면 폰에서 접속되지 않는다. 규칙 존재만 보면 통과로 뜨는데 실제로는
  안 열리는, 사용자가 스스로 빠져나올 수 없는 조합이라 따로 확인한다.
#>
$prof = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
$priv = @($prof | Where-Object { $_.NetworkCategory -eq 'Private' })
$profName = if ($prof) { ($prof | ForEach-Object { "$($_.InterfaceAlias)=$($_.NetworkCategory)" }) -join ', ' } else { '확인 불가' }
Chk '네트워크 프로필' ($priv.Count -gt 0) $profName '설정 > 네트워크 및 인터넷 > 속성 > 네트워크 프로필 유형을 [개인]으로 변경'

$listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $cfg.port }
Chk '카톡 릴레이 실행' ($null -ne $listening) $(if($listening){'동작 중'}else{'안 돌고 있음'}) '[카톡 릴레이] 창에서 [지금 켜기]를 누르세요'

<#
  일부러 꺼 둔 상태인지 고장인지 구분해서 보여 준다.
    paused.marker   일시 중지 (프로그램은 떠 있음)
    stopped.marker  프로그램을 끝냄 (컴퓨터를 다시 켜면 돌아온다)
#>
$paused  = Test-Path (Join-Path $PSScriptRoot 'paused.marker')
$stopped = Test-Path (Join-Path $PSScriptRoot 'stopped.marker')
if ($stopped) {
    Chk '문자 전달' $false '[카톡 릴레이]에서 프로그램을 끝낸 상태' '[카톡 릴레이] > [지금 켜기]'
} else {
    Chk '문자 전달' (-not $paused) $(if($paused){'일시 중지 - 문자를 받아도 전달하지 않음'}else{'전달 중'}) '[카톡 릴레이] > [문자 전달 다시 시작]'
}

$task  = Get-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue
$watch = Get-ScheduledTask -TaskName 'KakaoRelayWatchdog' -ErrorAction SilentlyContinue
$taskOk = ($null -ne $task) -and ($task.State -ne 'Disabled')
Chk '로그온 자동실행' $taskOk `
    $(if(-not $task){'등록 안 됨'}elseif($task.State -eq 'Disabled'){'비활성 (작업 스케줄러에서 꺼져 있음)'}else{$task.State}) `
    'program 폴더의 Setup.ps1을 마우스 오른쪽 > PowerShell로 실행'
$watchOk = ($null -ne $watch) -and ($watch.State -ne 'Disabled')
Chk '감시자' $watchOk `
    $(if(-not $watch){'등록 안 됨'}elseif($watch.State -eq 'Disabled'){'비활성 (작업 스케줄러에서 꺼져 있음)'}else{'동작 중'}) `
    'program 폴더의 Setup.ps1을 마우스 오른쪽 > PowerShell로 실행'

<#
  열려 있는 채팅방 목록.

  '채팅방을 찾지 못함' 은 대개 이름이 카카오톡에 보이는 것과 다르기 때문이다.
  예전에는 이걸 보려고 별도 진단 파일을 우클릭 실행해야 했다. 점검하러 들어온 사람에게
  또 다른 파일을 실행하라고 시킬 이유가 없어 여기로 합쳤다.
#>
$openRooms = @(Get-KakaoRoomWindows)
Write-Host ''
Write-Host '  열려 있는 채팅방' -ForegroundColor White
Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
if (-not $openRooms) {
    Write-Host '    없음' -ForegroundColor DarkGray
    Write-Host '    채팅방을 새 창으로 열어 두면 이름을 정확히 확인할 수 있습니다.' -ForegroundColor DarkGray
} else {
    foreach ($r in $openRooms) {
        $box  = Get-KakaoInputBox -RoomHwnd $r.Hwnd
        $mark = if ($box) { '보낼 수 있음' } else { '입력창을 찾지 못함' }
        $col  = if ($box) { 'Gray' } else { 'Yellow' }
        Write-Host ("    [{0}]  {1}" -f $r.Title, $mark) -ForegroundColor $col
    }
    Write-Host '    문자에는 위 대괄호 안의 이름을 그대로 쓰세요.' -ForegroundColor DarkGray
}

# --- 마무리 ---
Write-Host ''
if ($todo -eq 0) { Write-Host '모든 항목 통과. 문자만 들어오면 동작합니다.' -ForegroundColor Green }
else { Write-Host "할 일 $todo 개 - 위의 -> 표시를 따라 하세요." -ForegroundColor Yellow }
Write-Host ''
