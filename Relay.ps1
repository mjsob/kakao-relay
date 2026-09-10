<#
  Relay.ps1 - 문자 -> PC 카카오톡 릴레이 서버
  관리자 권한 불필요 (TcpListener 사용, netsh urlacl 필요 없음)

  사용법:  powershell -ExecutionPolicy Bypass -File Relay.ps1
#>
param(
    [string]$ConfigPath,
    [switch]$ForceDryRun
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('WinCon' -as [type])) {
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class WinCon {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll")] public static extern bool FreeConsole();
  [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr h, int c);
}
'@
}
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
. "$PSScriptRoot\KakaoCore.ps1"
. "$PSScriptRoot\Version.ps1"

# ---------- 설정 ----------
if (-not (Test-Path $ConfigPath)) { throw "설정 파일 없음: $ConfigPath" }
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($ForceDryRun) { $cfg.dryRun = $true }

# ---------- 창 모드 ----------
#   tray    : 콘솔을 떼어내고 트레이 아이콘으로 상주 (기본)
#   hidden  : 콘솔도 트레이도 없이 완전히 보이지 않게
#   console : 콘솔 창을 그대로 띄워둠 (디버깅용)
#
# 이 처리는 어떤 출력보다 먼저 해야 한다.
# 배너를 찍은 뒤에 숨기면 부팅할 때마다 창이 잠깐 보였다 사라진다.
$winMode = if ($cfg.PSObject.Properties.Name -contains 'windowMode' -and $cfg.windowMode) { [string]$cfg.windowMode } else { 'tray' }
$con = [WinCon]::GetConsoleWindow()
if ($con -eq [IntPtr]::Zero) {
    # 콘솔이 애초에 없는 환경(exe 로 빌드된 경우). Write-Host 를 호출하면 예외가 난다.
    $script:noConsole = $true
}
if ($winMode -ne 'console') {
    if ($con -ne [IntPtr]::Zero) {
        [void][WinCon]::ShowWindow($con, 0)      # SW_HIDE
        # 숨기기만 하면 콘솔 종료 신호(CTRL_CLOSE_EVENT)를 그대로 받아 같이 죽는다.
        # 아예 떼어내면 그 신호가 도달할 수 없다. 대신 화면 출력이 불가하므로 로그 파일에만 쓴다.
        [void][WinCon]::FreeConsole()
        $script:noConsole = $true
    }
}
$LogFile = Join-Path $PSScriptRoot 'relay.log'

<#
  꺼짐 표시 파일.

  예전에는 '완전히 중지' 가 예약 작업을 비활성화하고 프로세스를 죽였다.
  그러면 트레이 아이콘까지 사라져서 다시 켤 수단이 없어졌다.

  이제는 프로세스와 트레이 아이콘을 그대로 두고 문자 전달만 멈춘다.
  상태를 파일로 두면 재시작해도 유지되고, 조작 창에서 파일만 만들거나 지우면 되므로
  프로세스 사이에 별도 통신이 필요 없다.
#>
<#
  '프로그램 완전히 끝내기' 로 남은 표시는 시작하면서 지운다.
  그래야 컴퓨터를 다시 켰을 때 감시자가 정상으로 돌아온다.
#>
Remove-Item (Join-Path $PSScriptRoot 'stopped.marker') -Force -ErrorAction SilentlyContinue

$PauseFile = Join-Path $PSScriptRoot 'paused.marker'
<#
  일하는 중임을 알리는 표시.

  릴레이는 요청을 하나씩 처리한다. 카카오톡이 로그인 화면이거나 준비 중이면
  한 통 처리에 90초까지 걸리는데, 그동안 /health 에 답하지 못한다.
  감시자는 75초 무응답이면 좀비로 보고 죽이므로, 멀쩡히 일하는 릴레이가
  강제 종료되고 그 문자는 사라진다. 죽는 순간 카톡 창 정리도 못 해
  열린 채팅방이 그대로 남는다.

  그래서 문자를 처리하는 동안에는 이 파일의 시각을 갱신해 둔다.
  감시자는 이 시각이 최근이면 죽이지 않는다.
#>
$BusyFile  = Join-Path $PSScriptRoot 'busy.marker'
function Test-Paused { Test-Path $PauseFile }

<#
  기록 파일이 너무 커지지 않게 한다.
  /health 를 안 적게 되어 증가 속도는 크게 줄었지만, 몇 년을 두면 결국 커진다.
  1MB 를 넘으면 relay.log.old 로 한 번 밀어 두고 새로 시작한다. 보관은 한 세대면 충분하다.
#>
$script:logRollAt = [datetime]::MinValue
function Invoke-LogRoll {
    param([string]$path)
    try {
        $now = Get-Date
        if (($now - $script:logRollAt).TotalMinutes -lt 5) { return }   # 매 줄마다 파일 크기를 볼 이유는 없다
        $script:logRollAt = $now
        $f = Get-Item $path -ErrorAction SilentlyContinue
        if ($f -and $f.Length -gt 1MB) {
            Move-Item $path "$path.old" -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

<#
  기록 한 줄은 반드시 한 줄이어야 한다.

  문자 본문이 그대로 들어오는 자리가 여럿인데, 본문에 줄바꿈이 있으면
  기록이 여러 줄로 쪼개진다. 그러면 Show-Log 의 색칠이 첫 줄에만 걸려
  나머지가 시간도 등급도 없이 흘러나오고, 본문에 가짜 기록 줄을 적어 넣어
  있지도 않은 '전송 성공' 을 남길 수도 있다.
#>
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $Msg  = ($Msg -replace "`r", '') -replace "`n", ' / '
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
    if (-not $script:noConsole) {
        $color = switch ($Level) { 'ERR' {'Red'} 'WARN' {'Yellow'} 'SEND' {'Green'} default {'Gray'} }
        try { Write-Host $line -ForegroundColor $color } catch { $script:noConsole = $true }
    }
    <#
      로그 기록이 실패해도 전송은 계속되어야 한다.
      메모장으로 relay.log 를 열어 두거나 백신이 검사하는 순간 파일이 잠기는데,
      예전에는 여기서 예외가 나 요청 처리 자체가 죽었다.
    #>
    Invoke-LogRoll $LogFile
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 120 }
    }
}

# ---------- 유틸 ----------
function Normalize-Phone {
    param([string]$p)
    if (-not $p) { return '' }
    $d = ($p -replace '[^\d]', '')
    if ($d.StartsWith('82')) { $d = '0' + $d.Substring(2) }
    return $d
}

<#
  이름 비교용 정리.
  알림에서 온 발신자 이름에는 눈에 안 보이는 방향 제어 문자가 섞여 있다
  (U+2066~U+2069). 그대로 비교하면 같은 이름인데도 다르다고 나온다.
#>
function Normalize-Name {
    param([string]$s)
    if (-not $s) { return '' }
    $t = $s -replace '[\u200B-\u200F\u2066-\u2069\uFEFF]', ''
    return ($t -replace '\s+', '').Trim()
}

<#
  발신자를 구분하는 열쇠.

  Normalize-Phone 은 숫자만 남기므로 이름으로 오는 발신자는 전부 빈 문자열이 된다.
  알림 트리거는 번호를 못 보내고 이름만 보내므로, 그대로 쓰면 서로 다른 사람이
  같은 열쇠를 갖게 되어 고정 대상과 중복 차단이 섞인다.
  번호가 있으면 번호를, 없으면 이름을 쓴다.
#>
function Get-SenderKey {
    param([string]$from)
    $d = Normalize-Phone $from
    if ($d) { return $d }
    return 'name:' + (Normalize-Name $from)
}

<#
  발신자 허용 여부.
  allowFrom 에는 전화번호도, 이름도 넣을 수 있다.
  알림 트리거에는 번호가 없어 이름({not_title})밖에 보낼 수 없기 때문이다.
#>
function Test-AllowedSender {
    param([string]$from)
    <#
      비어 있으면 전체 허용이다. 값을 지운 것을 '아무도 못 보낸다' 로 오해하기 쉬운데
      실제로는 정반대라, 같은 공유기의 아무 기기나 문자를 밀어 넣을 수 있다.
      조용히 넘기지 않고 기록에 남긴다.
    #>
    $allow = @($cfg.allowFrom)
    if ($allow.Count -eq 0) {
        if (-not $script:warnedEmptyAllow) {
            Write-Log 'allowFrom 이 비어 있어 모든 발신자를 허용합니다. 설정에 번호를 넣으세요.' 'WARN'
            $script:warnedEmptyAllow = $true
        }
        return $true
    }
    if (-not $from) { return $false }

    $n     = Normalize-Phone $from
    $fname = Normalize-Name  $from

    foreach ($a in $allow) {
        if (-not $a) { continue }
        $an = Normalize-Phone $a

        if ($an) {
            # 등록값이 번호인 경우
            if (-not $n) { continue }
            if ($n -eq $an) { return $true }
            # 국가번호/앞자리 차이를 흡수하기 위해 뒤 8자리 비교
            if ($n.Length -ge 8 -and $an.Length -ge 8 -and
                $n.Substring($n.Length-8) -eq $an.Substring($an.Length-8)) { return $true }
        } else {
            # 등록값이 이름인 경우
            if ($fname -and (Normalize-Name $a) -eq $fname) { return $true }
        }
    }
    return $false
}

<#
  접속 IP 화이트리스트.
  allowFrom(발신번호)은 요청을 보내는 쪽이 값을 정하므로 위조가 가능하다.
  네트워크 레벨에서 한 번 더 거른다.
  형식: 정확한 IP('192.168.0.50') 또는 끝자리 와일드카드('192.168.0.*')
#>
function Test-AllowedIP {
    param([string]$Peer)
    $allow = @($cfg.allowIPs)
    if ($allow.Count -eq 0) { return $true }          # 비어있으면 제한 없음

    $ip = ($Peer -split ':')[0]                        # "192.168.0.50:54321" -> IP
    if ($ip -eq '::1') { $ip = '127.0.0.1' }
    foreach ($a in $allow) {
        if (-not $a) { continue }
        if ($a -eq $ip) { return $true }
        if ($a.EndsWith('*')) {
            $prefix = $a.Substring(0, $a.Length - 1)
            if ($ip.StartsWith($prefix)) { return $true }
        }
    }
    return $false
}

<#
  별칭을 실제 채팅방 이름으로 바꾼다.
  별칭 값이 비어 있으면(설정 오타) 원래 이름을 그대로 쓴다.
  null 을 돌려주면 뒤쪽 Mandatory 매개변수 바인딩에서 종료 오류가 난다.
#>
function Resolve-Room {
    param([string]$name)
    if (-not $name) { return $null }
    $name = $name.Trim()
    if ($cfg.aliases -and $cfg.aliases.PSObject.Properties.Name -contains $name) {
        $v = [string]$cfg.aliases.$name
        if ($v) { return $v }
    }
    return $name
}

<#
  문자 본문 파싱.

  구분자는 맨 처음 띄어쓰기 하나뿐이다.
  requirePassword = true   ->  <비밀번호> <채팅방> <내용>   (defaultRoom 있으면 <비밀번호> <내용>)
  requirePassword = false  ->  <채팅방> <내용>              (defaultRoom 있으면 <내용> 만으로도 가능)
#>
<#
  MMS 알림은 문자앱이 본문 앞에 요약을 붙여 보낸다.
      <제목: 방이름/내용 앞부분>
      방이름/실제 내용
  첫 줄이 통째로 <...> 로 감싸인 요약이면 떼어낸다. 폰에서는 뺄 수 없는 부분이다.
#>
function Remove-MmsSubjectLine {
    param([string]$body)
    $lines = $body -split "`r?`n"
    if ($lines.Count -lt 2) { return $body }
    if ($lines[0].Trim() -match '^<[^>]*>$') {
        return (($lines[1..($lines.Count-1)]) -join "`n").Trim()
    }
    return $body
}

<#
  '방이름' 과 '내용' 을 가른다.

  규칙은 하나다. **맨 처음 띄어쓰기까지가 채팅방 이름, 그 뒤가 보낼 내용.**

      엄마 오늘 좀 늦어요        -> [엄마] 오늘 좀 늦어요
      엄마 3/4일에 만나요        -> [엄마] 3/4일에 만나요
      엄마 http://a.com/b       -> [엄마] http://a.com/b

  예전에는 '/' 도 구분자로 받고, 별칭이나 열려 있는 창 제목이 앞에 통째로 붙었는지도
  살펴서 공백이 든 방 이름까지 알아내려 했다. 그런데 그 규칙은
    - 내용에 든 슬래시(날짜 3/4, 주소 http://)를 구분자로 오해했고
    - 같은 문자가 창이 열려 있느냐에 따라 다르게 해석돼 예측이 안 됐다.
  규칙이 하나면 사용자가 외울 것도 하나고, 어긋날 구석도 없다.

  대신 이름에 띄어쓰기가 있는 방은 별칭을 등록해야 한다. 그건 설명서에서 크게 알린다.
#>
<#
  대상 고정.

  '@엄마' 처럼 보내면 그 뒤로는 방 이름 없이 내용만 보내도 계속 그 방으로 간다.
  매번 방 이름을 앞에 치는 것이 번거롭기 때문이다.

  발신자마다 따로 기억한다. 같은 릴레이를 여러 사람이 쓸 때 서로 대상이 섞이면 안 된다.
  파일에 적어 두므로 릴레이를 다시 켜도 유지된다.
#>
$PinFile = Join-Path $PSScriptRoot 'pinned.json'
$script:pins = @{}
try {
    if (Test-Path $PinFile) {
        $j = Get-Content $PinFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $j.PSObject.Properties.Name) { $script:pins[$k] = [string]$j.$k }
    }
} catch {
    # 조용히 넘기면 고정이 사라진 것을 아무도 모른다
    $script:pins = @{}
    Write-Log "고정 대상 파일을 읽지 못해 초기화함: $($_.Exception.Message)" 'WARN'
}

<#
  고정 대상을 파일에 남긴다.

  바로 덮어쓰면 쓰는 도중에 프로세스가 죽었을 때 잘린 JSON 이 남는다.
  다음 시작 때 읽기가 실패하고, 고정이 조용히 전부 사라진다.
  임시 파일에 다 쓴 뒤 이름을 바꿔치기하면 그런 중간 상태가 생기지 않는다.
#>
function Save-Pins {
    try {
        $o = [pscustomobject]@{}
        foreach ($k in $script:pins.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $script:pins[$k] }
        $tmp = "$PinFile.tmp"
        $o | ConvertTo-Json -Depth 3 | Set-Content $tmp -Encoding UTF8
        Move-Item $tmp $PinFile -Force
    } catch { Write-Log "대상 저장 실패(무시): $($_.Exception.Message)" 'WARN' }
}

function Get-Pin  { param([string]$from) $k = Get-SenderKey $from; if ($script:pins.ContainsKey($k)) { $script:pins[$k] } else { $null } }
function Set-Pin  { param([string]$from,[string]$room) $script:pins[(Get-SenderKey $from)] = $room; Save-Pins }
function Clear-Pin{ param([string]$from) $k = Get-SenderKey $from; if ($script:pins.ContainsKey($k)) { $script:pins.Remove($k); Save-Pins } }

function Split-RoomAndText {
    param([string]$s)
    $s = $s.Trim()
    $sp = $s.IndexOf(' ')
    if ($sp -lt 1) { return @{ room = $null; text = $s } }
    return @{ room = (Resolve-Room $s.Substring(0, $sp)); text = $s.Substring($sp + 1) }
}

function Parse-Command {
    param([string]$body, [string]$from)
    $script:parseFrom = $from
    $body = (Remove-MmsSubjectLine $body).Trim()
    if (-not $body) { return @{ ok=$false; error="내용 없음`n문자가 비어 있음" } }

    $needPw = if ($cfg.PSObject.Properties.Name -contains 'requirePassword') { [bool]$cfg.requirePassword } else { $true }
    $fmt    = if ($needPw) { '비밀번호 채팅방 내용' } else { '채팅방 내용' }

    if ($needPw) {
        $i = $body.IndexOf(' ')
        if ($i -lt 1) { return @{ ok=$false; error="요청 거부`n원인: 형식 오류`n형식: $fmt" } }
        # -ne 는 대소문자를 무시한다. 비밀번호는 구분해야 하므로 -cne 를 쓴다.
        if ($body.Substring(0, $i).Trim() -cne $cfg.password) { return @{ ok=$false; error='요청 거부' + [char]10 + '원인: 비밀번호 불일치' } }
        $body = $body.Substring($i + 1).Trim()
        if (-not $body) { return @{ ok=$false; error="요청 거부`n원인: 내용 없음`n형식: $fmt" } }
    }

    <#
      '@' 로 시작하면 대상을 바꾸는 명령이다.
        @엄마        대상만 고정하고 아무것도 보내지 않는다
        @엄마 안녕    고정한 뒤 그 내용을 바로 보낸다
        @            고정을 푼다
    #>
    <#
      '@@' 로 시작하면 '@' 한 글자로 낮춰 내용으로 본다.

      카카오톡 단톡방에서 '@everyone' 이나 '@홍길동' 같은 멘션은 늘 쓰는 기능인데,
      '@' 를 대상 지정 명령으로만 읽으면 그런 문장을 보낼 방법이 아예 없어진다.
      게다가 '@everyone' 은 'everyone' 이라는 방을 찾다 실패하므로,
      사용자는 방 이름을 잘못 적은 줄 알고 헤매게 된다.
    #>
    if ($body.StartsWith('@@')) {
        $body = $body.Substring(1)
    }
    elseif ($body.StartsWith('@')) {
        $rest = $body.Substring(1).Trim()
        if (-not $rest) { return @{ ok=$true; pinAction='clear' } }
        $sp   = $rest.IndexOf(' ')
        $name = if ($sp -lt 1) { $rest } else { $rest.Substring(0, $sp) }
        $tail = if ($sp -lt 1) { '' }   else { $rest.Substring($sp + 1).Trim() }
        return @{ ok=$true; pinAction='set'; room=(Resolve-Room $name); text=$tail }
    }

    <#
      대상이 고정돼 있거나 defaultRoom 이 정해져 있으면 방 이름을 적지 않는다.
      본문 전체가 내용이다. 첫 단어를 방 이름으로 떼어내면 문장의 첫 단어가 사라진다.
    #>
    $pinned = Get-Pin $script:parseFrom
    if ($pinned) {
        $room = $pinned
        $text = $body
    } elseif ($cfg.defaultRoom) {
        $room = Resolve-Room $cfg.defaultRoom
        $text = $body
    } else {
        <#
          띄어쓰기가 없으면 방 이름만 온 것이다.
          예전에는 '채팅방 이름 없음' 이라고 답했는데, 이름은 있고 내용이 없는 것이라
          사실과 반대였다. 사용자는 멀쩡한 이름을 의심하게 된다.
        #>
        if ($body -notmatch '\s') {
            return @{ ok=$false; error="요청 거부`n원인: 내용 없음`n형식: 채팅방 내용" }
        }
        $r = Split-RoomAndText $body
        if (-not $r.room) {
            return @{ ok=$false; error="요청 거부`n원인: 형식 오류`n형식: 채팅방 내용" }
        }
        $room = $r.room
        $text = $r.text
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return @{ ok=$false; error="요청 거부`n원인: 내용 없음`n형식: 채팅방 내용" } }
    return @{ ok=$true; room=$room; text=$text.Trim() }
}

# ---------- 중복 제거 ----------
<#
  중복 차단.
  주의: '전송에 성공한' 메시지만 기록해야 한다.
  SMS 포워더 앱은 200 이 아니면 최대 10회까지 재전송하는데,
  실패한 시도까지 기록해버리면 앱의 재시도가 전부 '중복'으로 씹혀서 영영 전달되지 않는다.
#>
<#
  조각 이어붙이기.

  장문을 여러 통의 SMS 로 나눠 보내면 첫 조각에만 '방이름/' 이 붙고
  뒤 조각은 본문만 온다. 그대로 두면 형식 오류로 거부된다.
  첫 조각을 잠시 붙들고 있다가, 창 안에 뒤 조각이 오면 이어붙여 한 번에 보낸다.
  joinWindowMs 가 0 이면 이 동작은 꺼진다 (받는 즉시 전송).
#>
$script:pending = @{}

$script:recent = @{}
function Remove-ExpiredDedupe {
    $now = Get-Date
    $win = [int]$cfg.dedupeSeconds
    foreach ($k in @($script:recent.Keys)) {
        if (($now - $script:recent[$k]).TotalSeconds -gt $win) { $script:recent.Remove($k) }
    }
}
<#
  중복 판정용 열쇠를 만든다.

  같은 문자가 'SMS 수신' 과 '알림' 두 경로로 들어올 수 있는데,
  알림 쪽은 줄바꿈이나 공백이 조금 다르게 오는 경우가 있다.
  그대로 비교하면 다른 메시지로 보고 카톡을 두 번 보내게 되므로,
  공백을 모두 지우고 비교한다.
#>
function Get-DedupeKey {
    param([string]$From, [string]$Text)
    $flat = ($Text -replace '\s+', '')
    return (Get-SenderKey $From) + '|' + $flat
}

function Test-AlreadySent {
    param([string]$key)
    Remove-ExpiredDedupe
    return $script:recent.ContainsKey($key)
}
function Set-Delivered {
    param([string]$key)
    $script:recent[$key] = Get-Date
}

# ---------- HTTP 파싱 ----------
function Read-HttpRequest {
    param([System.Net.Sockets.TcpClient]$client)

    $stream = $client.GetStream()
    $client.ReceiveTimeout = 15000
    $buf  = New-Object byte[] 8192
    $mem  = New-Object System.IO.MemoryStream
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $mem.Write($buf, 0, $n)
        $bytes = $mem.ToArray()
        for ($i = 3; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i-3] -eq 13 -and $bytes[$i-2] -eq 10 -and $bytes[$i-1] -eq 13 -and $bytes[$i] -eq 10) {
                $headerEnd = $i + 1; break
            }
        }
        if ($mem.Length -gt 262144) { break }
    }
    if ($headerEnd -lt 0) { return $null }

    $all        = $mem.ToArray()
    $headerText = [Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines      = $headerText -split "`r`n"
    $reqLine    = $lines[0] -split ' '
    $method     = $reqLine[0]
    $rawUrl     = if ($reqLine.Count -gt 1) { $reqLine[1] } else { '/' }

    $headers = @{}
    foreach ($l in $lines[1..($lines.Count-1)]) {
        if ($l -match '^\s*([^:]+):\s*(.*)$') { $headers[$matches[1].ToLower()] = $matches[2] }
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$contentLength) }

    # Expect: 100-continue 처리.
    # 안드로이드/자바 HTTP 클라이언트는 POST 본문을 보내기 전에 서버의 '100 Continue' 를 기다리는 경우가 있다.
    # 이걸 안 보내주면 서로 기다리다가 본문 읽기가 타임아웃난다.
    if ($headers.ContainsKey('expect') -and $headers['expect'] -match '100-continue') {
        $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($cont, 0, $cont.Length)
        $stream.Flush()
    }

    <#
      본문 크기에 상한을 둔다.
      Content-Length 를 그대로 믿으면 한 연결이 메모리를 계속 먹으며 릴레이를 붙잡는다.
      수락 루프가 한 줄이라 그동안 진짜 문자는 하나도 못 받는다.
      문자는 아무리 길어도 몇 KB 다.
    #>
    $maxBody = 64KB
    if ($contentLength -gt $maxBody) { $contentLength = $maxBody }

    $bodyBytes = New-Object System.Collections.Generic.List[byte]
    $already = $all.Length - $headerEnd
    if ($already -gt 0) { $bodyBytes.AddRange([byte[]]($all[$headerEnd..($all.Length-1)])) }
    while ($bodyBytes.Count -lt $contentLength) {
        $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $contentLength - $bodyBytes.Count))
        if ($n -le 0) { break }
        $bodyBytes.AddRange([byte[]]($buf[0..($n-1)]))
    }
    $body = [Text.Encoding]::UTF8.GetString($bodyBytes.ToArray())

    return [pscustomobject]@{
        Method = $method; Url = $rawUrl; Headers = $headers; Body = $body; Stream = $stream
    }
}

<#
  응답을 평문으로도 돌려줄 수 있게 한다.

  중계 휴대폰이 답장 문자를 보내려면 응답을 그대로 문자 본문에 넣을 수 있어야 한다.
  JSON 을 그대로 넣으면 중괄호가 잔뜩 붙은 문자가 가므로, 주소에 reply=text 를 붙이면
  사람이 읽을 한 문장만 돌려준다. 할 말이 없으면 빈 응답이라 문자를 보내지 않게 된다.
#>
# 답장 문자 앞에 붙는 표식. 중계 휴대폰이 릴레이의 답인지 가리는 데 쓴다.
$Script:ReplyTag = '[카톡]'

<#
  방금 내보낸 답장을 기억해 둔다.

  답장이 되돌아오면 무시해야 하는데, '[카톡] 으로 시작하면 버린다' 로 판정하면
  사람이 실제로 보내려던 '[카톡] 공지 확인' 같은 문자까지 조용히 삼킨다.
  우리가 정말로 보낸 문장과 똑같을 때만 버리면 그런 오해가 없다.
#>
$Script:SentReplies = New-Object System.Collections.Generic.Queue[string]

function Register-SentReply {
    param([string]$body)
    if (-not $body) { return }
    $Script:SentReplies.Enqueue($body)
    while ($Script:SentReplies.Count -gt 30) { [void]$Script:SentReplies.Dequeue() }
}

function Test-IsEchoOfReply {
    param([string]$text)
    if (-not $text) { return $false }
    $t = $text.Trim()
    foreach ($r in $Script:SentReplies) { if ($r.Trim() -eq $t) { return $true } }
    return $false
}

<#
  답장 문자를 보낼지 여부. 설정의 smsReply 로 끌 수 있다(기본 켜짐).

  답장 한 통마다 문자 요금이 든다. 요금이 부담이면 여기서 끈다.
  끄면 릴레이는 언제나 '[카톡] OK' 만 돌려주므로 중계 휴대폰이 문자를 보내지 않는다.
  대신 대상이 무엇으로 지정됐는지, 전달에 실패했는지를 문자로는 알 수 없게 된다.
#>
$Script:SmsReplyOn = if ($cfg.PSObject.Properties.Name -contains 'smsReply') { [bool]$cfg.smsReply } else { $true }

<#
  답장 문자에 넣을 채팅방 이름을 줄인다.

  단문 한 통은 90바이트(한글 45자)다. 넘으면 조용히 장문 요금이 붙는다.
  카카오톡이 돌려주는 실제 방 이름은 '2026 신입 환영회 준비방' 처럼 길 수 있고,
  대상을 바꿀 때는 이름이 두 개 들어가므로 금방 한도를 넘는다.
#>
function Format-RoomForSms {
    param([string]$room)
    if (-not $room) { return '' }
    if ($room.Length -le 12) { return $room }
    return $room.Substring(0, 12) + '…'
}

function Send-HttpResponse {
    param([System.Net.Sockets.NetworkStream]$stream, [int]$Status = 200, [hashtable]$Payload, [switch]$PlainText)
    if ($PlainText) {
        <#
          알려줄 말이 없을 때도 OK 한 마디는 돌려준다.
          그리고 모든 답장 앞에 표식을 붙인다.

          PC 가 꺼져 있거나 Wi-Fi 가 끊기면 중계 휴대폰의 HTTP 요청이 실패하는데,
          그때 MacroDroid 는 응답 변수를 비워 두는 것이 아니라
          'java.net.SocketException ...' 같은 제 예외 메시지로 덮어쓴다.
          그대로 두면 그 문장이 문자로 나간다.

          표식이 있으면 중계 휴대폰이 '릴레이가 준 답' 과 '릴레이에 닿지 못함' 을
          확실히 가를 수 있다. 표식이 없는 값은 무조건 닿지 못한 것이다.
        #>
        $body = if ($Script:SmsReplyOn) { [string]$Payload['reply'] } else { '' }
        if (-not $body) { $body = 'OK' }
        $body = $Script:ReplyTag + ' ' + $body
        # 이 문장이 문자로 되돌아오면 버릴 수 있게 기억해 둔다
        Register-SentReply $body
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $text  = switch ($Status) { 200 { 'OK' } 400 { 'Bad Request' } 403 { 'Forbidden' } 404 { 'Not Found' } 503 { 'Service Unavailable' } default { 'OK' } }
        $head  = "HTTP/1.1 $Status $text`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
        $hb    = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        return
    }
    $json  = ($Payload | ConvertTo-Json -Compress -Depth 5)
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $text  = switch ($Status) { 200 { 'OK' } 400 { 'Bad Request' } 403 { 'Forbidden' } 404 { 'Not Found' } 503 { 'Service Unavailable' } default { 'Error' } }
    $head  = "HTTP/1.1 $Status $text`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $hb    = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Parse-KeyValues {
    param([string]$s)
    $h = @{}
    if (-not $s) { return $h }
    foreach ($pair in ($s -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        $k = [Uri]::UnescapeDataString($kv[0].Replace('+',' ')).ToLower()
        $v = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1].Replace('+',' ')) } else { '' }
        $h[$k] = $v
    }
    return $h
}

# 다양한 SMS 포워더 앱 형식을 흡수
function Extract-SmsFields {
    param($req)
    $from = $null; $text = $null
    $fromKeys = @('from','sender','phone','number','sourceaddress','msisdn')
    $textKeys = @('text','content','msg','message','body','sms')

    # 쿼리스트링
    $qs = @{}
    if ($req.Url -match '\?(.*)$') { $qs = Parse-KeyValues $matches[1] }

    $ct = if ($req.Headers.ContainsKey('content-type')) { $req.Headers['content-type'] } else { '' }

    # --- 평문 모드 ---
    # Content-Type 이 text/plain 이거나 ?raw=1 이면 본문 전체를 메시지로 그대로 쓴다.
    # 문자 내용에 따옴표(")나 역슬래시가 들어가도 깨지지 않는다.
    # (JSON 템플릿은 이스케이프가 안 돼서, & 나 " 가 섞이면 파싱이 망가진다)
    if ($ct -match 'text/plain' -or $qs.ContainsKey('raw')) {
        foreach ($k in $fromKeys) { if (-not $from -and $qs.ContainsKey($k) -and $qs[$k]) { $from = $qs[$k] } }
        return @{ from = $from; text = $req.Body }
    }

    # 바디
    $bodyMap = @{}
    if ($req.Body) {
        if ($ct -match 'json' -or $req.Body.TrimStart().StartsWith('{')) {
            try {
                $o = $req.Body | ConvertFrom-Json
                foreach ($p in $o.PSObject.Properties) { $bodyMap[$p.Name.ToLower()] = [string]$p.Value }
            } catch { }
        } else {
            $bodyMap = Parse-KeyValues $req.Body
        }
    }

    foreach ($src in @($bodyMap, $qs)) {
        foreach ($k in $fromKeys) { if (-not $from -and $src.ContainsKey($k) -and $src[$k]) { $from = $src[$k] } }
        foreach ($k in $textKeys) { if (-not $text -and $src.ContainsKey($k) -and $src[$k]) { $text = $src[$k] } }
    }

    # 아무 키도 못 찾았고 바디가 평문이면 통째로 본문 취급
    if (-not $text -and $req.Body -and $bodyMap.Count -eq 0) { $text = $req.Body }

    return @{ from = $from; text = $text }
}

# ---------- 요청 처리 ----------
function Handle-Sms {
    param([string]$from, [string]$text)

    <#
      릴레이가 보낸 답장이 되돌아오면 무시한다.

      답장 문자가 어떤 경로로든 다시 릴레이로 들어오면 그건 평범한 문자로 처리된다.
      대상이 고정돼 있으면 답장 내용이 통째로 상대방 카톡으로 나가고,
      고정이 없으면 '[카톡]' 이 방 이름이 되어 또 실패 답장이 나간다.
      양쪽 폰에 같은 매크로가 들어가 있으면 둘이 끝없이 주고받는다.

      중복 차단은 이걸 못 막는다. 성공한 전송만 기록하기 때문이다.
      표식은 이미 붙여 보내고 있으니 들어올 때 그것만 보면 된다.
    #>
    if (Test-IsEchoOfReply $text) {
        Write-Log "무시: 릴레이가 보낸 답장이 되돌아옴" 'WARN'
        return @{ ok = $true; error = $null; echo = $true; retryable = $false; silent = $true }
    }

    # retryable=$false 인 응답은 HTTP 200 으로 돌려준다.
    # 포워더 앱이 200 이 아니면 재시도하는데, 비밀번호 오류처럼 다시 보내도 소용없는 건
    # 재시도시켜봐야 로그만 더러워지기 때문이다.
    if (-not (Test-AllowedSender $from)) {
        Write-Log "거부: 허용되지 않은 발신번호 '$from'  (본문: '$text')" 'WARN'
        # silent: 답장 문자를 보내지 않는다.
        # 모르는 번호에서 온 문자에 답장하면 엉뚱한 사람에게 문자가 가고 요금도 나간다.
        return @{ ok = $false; retryable = $false; silent = $true
                  error = '요청 거부' + [char]10 + '원인: 미등록 발신자' }
    }

    $dedupeKey = Get-DedupeKey -From $from -Text $text
    if (Test-AlreadySent $dedupeKey) {
        Write-Log "무시: 이미 전송된 메시지 (앱 재시도로 추정) '$text'" 'WARN'
        <#
          조용히 버리면 사용자는 보낸 줄 안다.
          성공에도 답장이 없으므로, 답장이 없다는 것만으로는 구분할 수 없다.
        #>
        return @{ ok = $true; error = $null; duplicate = $true; retryable = $false
                  reply = '전송 생략' + [char]10 + '중복 수신 · 이미 전송됨' }
    }

    $joinMs = if ($cfg.PSObject.Properties.Name -contains 'joinWindowMs') { [int]$cfg.joinWindowMs } else { 0 }
    $cmd = Parse-Command $text -From $from

    <#
      대상 고정 명령은 보내는 것이 아니라 설정을 바꾸는 것이다.
      조각 이어붙이기나 중복 차단보다 먼저 처리한다.
    #>
    <#
      답장 문구는 무엇이 달라졌는지에 따라 다르게 적는다.
      '지정했다' 와 '바꿨다' 가 같은 문장이면, 대상이 바뀐 것을 알아차리지 못한다.
      방 이름 뒤에 조사를 붙이면 받침에 따라 달라지므로 콜론으로 적는다.
    #>
    $before = Get-Pin $from
    $nl     = [char]10
    $arrow  = [char]0x2192

    if ($cmd.pinAction -eq 'clear') {
        Clear-Pin $from
        Write-Log "대상 해제 (이전 [$before])" 'INFO'
        $say = if ($before) { '대상 해제 완료' + $nl + (Format-RoomForSms $before) + " $arrow 없음" }
               else         { '대상 해제 생략' + $nl + '지정된 대상 없음' }
        return @{ ok = $true; error = $null; pinned = $null; retryable = $false; reply = $say }
    }
    if ($cmd.pinAction -eq 'set') {
        <#
          없는 방을 고정해 버리면 그 뒤로 보내는 문자가 전부 실패한다.
          그래서 카카오톡에서 실제로 찾은 뒤에만 고정한다.
          내용이 함께 온 경우에는 그 전송 자체가 확인이 되므로 따로 확인하지 않는다.
        #>
        $onlyPin = [string]::IsNullOrWhiteSpace($cmd.text)
        $real    = $cmd.room
        $sendRes = $null

        if ($onlyPin) {
            $chk = Test-KakaoRoom $cmd.room
            if (-not $chk.ok) { $real = $null } else { $real = $chk.room }
        } else {
            $sendRes = Invoke-Send -Room $cmd.room -Text $cmd.text.Trim() -DedupeKey $dedupeKey
            if (-not $sendRes.ok) { $real = $null } elseif ($sendRes.room) { $real = $sendRes.room }
        }

        if (-not $real) {
            $why = if ($onlyPin) { $chk.error } else { $sendRes.error }
            $ret = if ($onlyPin) { $chk.retryable } else { [bool]$sendRes.retryable }
            # 방이 없어서 실패한 것인지, 카카오톡이 아직 준비되지 않아 실패한 것인지 가려서 알린다
            $missing = if ($onlyPin) { [bool]$chk.missing } else { -not [bool]$sendRes.retryable }
            Write-Log "대상 지정 안 함 - [$($cmd.room)] 확인 실패: $why" 'WARN'
            $say = if ($missing) {
                       $keep = if ($before) { '현재: ' + (Format-RoomForSms $before) } else { '현재: 없음' }
                       '대상 변경 실패' + $nl + (Format-RoomForSms $cmd.room) + ': 채팅방 없음' + $nl + $keep
                   } else {
                       '대상 변경 실패' + $nl + '원인: 카카오톡 미응답' + $nl + '조치: 잠시 후 재전송'
                   }
            return @{ ok = $false; error = $why; pinned = $before; retryable = $ret; reply = $say }
        }

        Set-Pin $from $real
        Write-Log ("대상 지정 -> [{0}] ({1})" -f $real, $(if ($before) { "이전 [$before]" } else { '처음 지정' })) 'INFO'
        $rs = Format-RoomForSms $real
        $say = if (-not $before)          { '대상 지정 완료' + $nl + $rs + $nl + '해제: @ 전송' }
               elseif ($before -eq $real) { '대상 유지' + $nl + $rs + ' (이미 지정됨)' }
               else                       { '대상 변경 완료' + $nl + (Format-RoomForSms $before) + " $arrow $rs" }

        if ($onlyPin) { return @{ ok = $true; error = $null; pinned = $real; retryable = $false; reply = $say } }
        $sendRes['reply'] = if ($sendRes.ok) { $say } else { $say + $nl + '문자: 전송 실패' }
        return $sendRes
    }

    if ($joinMs -gt 0) {
        $pk = Get-SenderKey $from
        if ($cmd.ok) {
            # 새 메시지의 시작. 앞서 붙들고 있던 게 있으면 먼저 내보낸다.
            if ($script:pending.ContainsKey($pk)) { Send-Pending $pk }
            $script:pending[$pk] = @{ room = $cmd.room; text = $cmd.text; at = (Get-Date); key = $dedupeKey }
            Write-Log "조각 접수 -> [$($cmd.room)] (이어질 조각 $joinMs ms 대기)" 'INFO'
            return @{ ok = $true; error = $null; queued = $true; retryable = $false }
        }
        if ($script:pending.ContainsKey($pk)) {
            # 방이름이 없는 메시지 = 앞 메시지의 뒷조각
            $p = $script:pending[$pk]
            $p.text = $p.text + ' ' + $text.Trim()
            $p.at   = Get-Date
            Write-Log "조각 이어붙임 -> [$($p.room)] (누적 $($p.text.Length)자)" 'INFO'
            return @{ ok = $true; error = $null; queued = $true; retryable = $false }
        }
    }

    if (-not $cmd.ok) {
        $peek = if ($text.Length -gt 30) { $text.Substring(0,30) + '…' } else { $text }
        Write-Log "거부: $($cmd.error)  (원문: '$peek')" 'WARN'
        return @{ ok = $false; error = $cmd.error; retryable = $false; reply = $cmd.error }
    }

    $r = Invoke-Send -Room $cmd.room -Text $cmd.text -DedupeKey $dedupeKey
    <#
      이름이 정확히 맞지 않고 앞부분만 맞아 열린 경우에는 어디로 갔는지 알려 준다.
      '엄마' 로 보냈는데 '엄마들 모임' 으로 갈 수 있는데, 성공하면 답장이 없어서
      지금은 끝내 모른 채 지나간다.
    #>
    if ($r.ok -and $r.approx -and $r.room -and ($r.room -ne $cmd.room)) {
        $r['reply'] = '전송 완료' + $nl + (Format-RoomForSms $cmd.room) + " $arrow " + (Format-RoomForSms $r.room) + $nl + '참고: 유사 이름'
    }
    if (-not $r.ok) {
        # 문자로 나가는 답은 짧게 줄인다. 자세한 사유는 기록에 남는다.
        # retryable 이 아니면 방을 못 찾은 것이다(Invoke-Send 참고).
        $r['reply'] = if ($r.retryable) { '전송 실패' + $nl + '원인: 카카오톡 미응답' + $nl + '조치: 잠시 후 재전송' }
                      else                { '전송 실패' + $nl + (Format-RoomForSms $cmd.room) + ': 채팅방 없음' }
    }
    return $r
}

# 붙들고 있던 조각을 합쳐 내보낸다
function Send-Pending {
    param([string]$Key)
    if (-not $script:pending.ContainsKey($Key)) { return }
    $p = $script:pending[$Key]
    $script:pending.Remove($Key)
    Write-Log "조각 합쳐 전송 -> [$($p.room)] ($($p.text.Length)자)" 'SEND'
    [void](Invoke-Send -Room $p.room -Text $p.text -DedupeKey $p.key)
}

<#
  트레이 아이콘과 툴팁을 현재 상태에 맞춘다.
  꺼짐 표시 파일은 조작 창이 밖에서 만들거나 지우므로 주기적으로 확인해야 한다.
#>
$script:lastPaused  = $null
$script:trayCheckAt = [datetime]::MinValue
function Sync-Tray {
    if (-not $notify) { return }
    <#
      이 함수는 수락 루프 안에서 돈다. 여기서 예외가 나면 루프가 통째로 끝나고
      트레이 아이콘까지 사라진다. 트레이는 다시 켜는 유일한 통로이므로
      무슨 일이 있어도 예외를 밖으로 내보내지 않는다.
    #>
    try {
        # 루프는 0.1 초마다 도는데 표시 파일을 그때마다 볼 이유는 없다
        $now = Get-Date
        if (($now - $script:trayCheckAt).TotalMilliseconds -lt 1000) { return }
        $script:trayCheckAt = $now

        $p = Test-Paused
        if ($p -eq $script:lastPaused) { return }
        # 다시 시작한 순간부터 대기 시간을 새로 센다
        if ($script:lastPaused -eq $true -and -not $p) { $script:readyAt = Get-Date
<#
  시험 모드로 처리한 마지막 문자의 목적지.
  시험 모드의 목적이 '어디로 갈 뻔했는지 확인' 인데, 지금까지 그 정보는
  로그 한 줄에만 있었고 아무도 로그를 열지 않았다. 조작 창이 보여줄 수 있게 들고 있는다.
#>
$script:lastDryRoom = $null }
        $script:lastPaused = $p
        if ($p) {
            if ($script:trayIconOff) { $notify.Icon = $script:trayIconOff }
            $notify.Text = '카톡 릴레이 - 일시 중지'
        } else {
            if ($script:trayIconOn) { $notify.Icon = $script:trayIconOn }
            $notify.Text = '카톡 릴레이 - 전달 중'
        }
    } catch {
        Write-Log "트레이 표시 갱신 실패(무시하고 계속): $($_.Exception.Message)" 'WARN'
    }
}

# 대기 시간이 지난 보류분을 내보낸다 (수락 루프에서 주기적으로 호출)
function Flush-Pending {
    $joinMs = if ($cfg.PSObject.Properties.Name -contains 'joinWindowMs') { [int]$cfg.joinWindowMs } else { 0 }
    if ($joinMs -le 0 -or $script:pending.Count -eq 0) { return }
    $now = Get-Date
    foreach ($k in @($script:pending.Keys)) {
        if (($now - $script:pending[$k].at).TotalMilliseconds -ge $joinMs) { Send-Pending $k }
    }
}

<#
  채팅방이 실제로 있는지 확인한다.

  '@엄마' 로 대상을 지정할 때, 있지도 않은 이름이 그대로 고정되면
  그 뒤로 보내는 문자가 전부 실패한다. 그런데 정작 실패는 다음 문자를 보낸
  다음에야 알게 된다. 고정하기 전에 한 번 열어 보고 확인한다.

  보내지 않고 열어 보기만 하는 것은 시험 모드(dryRun)와 같은 동작이라
  같은 경로를 그대로 쓴다. 찾으면 카카오톡에 있는 실제 방 이름을 돌려주므로,
  이름 일부만 적었어도 정확한 이름으로 고정할 수 있다.
#>
function Test-KakaoRoom {
    param([Parameter(Mandatory)][string]$Room)

    $offsets  = if ($cfg.PSObject.Properties.Name -contains 'rowOffsets' -and $cfg.rowOffsets) { [int[]]$cfg.rowOffsets } else { @(30,62,92,122,152,182) }
    $auto     = if ($cfg.PSObject.Properties.Name -contains 'autoOpen') { [bool]$cfg.autoOpen } else { $false }
    $keep     = if ($cfg.PSObject.Properties.Name -contains 'closeAfterSend') { -not [bool]$cfg.closeAfterSend } else { $false }
    $hideMain = if ($cfg.PSObject.Properties.Name -contains 'hideMainAfterSend') { [bool]$cfg.hideMainAfterSend } else { $false }

    Write-Log "대상 확인 -> [$Room]" 'INFO'
    $res = Send-KakaoMessage -Room $Room -Text '확인' -Mode $cfg.sendMode -DryRun `
             -AutoOpen:$auto -RowOffsets $offsets -KeepOpen:$keep -HideMain:$hideMain

    <#
      메인창 안에서 열린 경우에는 어느 방이 열렸는지 확인할 수 없다.
      그 상태의 방 제목은 '카카오톡'(메인창 제목)이라, 그대로 고정하면
      사용자는 '엄마로 지정됐다' 고 믿는데 실제로는 검색 결과 첫 줄로 계속 나간다.
      확인이 안 된 결과는 고정하지 않는다.
    #>
    if ($res.ok -and $res.unverified) {
        return @{ ok = $false; room = $null; missing = $false; retryable = $true
                  error = '전송 실패' + [char]10 + '원인: 새 창 열기 꺼짐' + [char]10 + '조치: 카카오톡 설정 > 채팅' }
    }
    if ($res.ok) { return @{ ok = $true; room = $res.room; error = $null; retryable = $false; missing = $false } }
    <#
      '방이 없다' 와 '카카오톡이 아직 준비되지 않았다' 는 전혀 다른 상황이다.
      앞은 이름을 고쳐야 하고, 뒤는 잠시 뒤 다시 보내면 된다.
      섞어서 '채팅방 없음' 이라고 알리면 멀쩡한 이름을 의심하게 된다.
    #>
    return @{ ok = $false; room = $null; error = $res.error
              missing = [bool]$res.roomNotFound; retryable = (-not $res.roomNotFound) }
}

function Invoke-Send {
    param([string]$Room, [string]$Text, [string]$DedupeKey)

    $cmd = @{ room = $Room; text = $Text }
    $preview = if ($cmd.text.Length -gt 40) { $cmd.text.Substring(0,40) + '...' } else { $cmd.text }
    Write-Log "전송 시도 -> [$($cmd.room)] '$preview'" 'SEND'

    $offsets = if ($cfg.PSObject.Properties.Name -contains 'rowOffsets' -and $cfg.rowOffsets) { [int[]]$cfg.rowOffsets } else { @(30,62,92,122,152,182) }
    $auto    = if ($cfg.PSObject.Properties.Name -contains 'autoOpen') { [bool]$cfg.autoOpen } else { $false }

    # 직전에 성공한 전송버튼 오프셋이 있으면 그걸 1순위로 (창 크기가 그대로면 항상 첫 시도에 맞는다)
    $btn = if ($script:lastSendButton) { $script:lastSendButton }
           elseif ($cfg.PSObject.Properties.Name -contains 'sendButton' -and $cfg.sendButton) { [int[]]$cfg.sendButton }
           else { @(58,29) }

    $keep   = if ($cfg.PSObject.Properties.Name -contains 'closeAfterSend') { -not [bool]$cfg.closeAfterSend } else { $false }
    $method = if ($cfg.PSObject.Properties.Name -contains 'sendMethod' -and $cfg.sendMethod) { [string]$cfg.sendMethod } else { 'auto' }
    $hideMain = if ($cfg.PSObject.Properties.Name -contains 'hideMainAfterSend') { [bool]$cfg.hideMainAfterSend } else { $false }

    $tries    = if ($cfg.PSObject.Properties.Name -contains 'retryCount') { [int]$cfg.retryCount + 1 } else { 1 }
    $retryGap = if ($cfg.PSObject.Properties.Name -contains 'retryDelayMs') { [int]$cfg.retryDelayMs } else { 1500 }

    $res = $null
    for ($attempt = 1; $attempt -le $tries; $attempt++) {
        $res = Send-KakaoMessage -Room $cmd.room -Text $cmd.text -Mode $cfg.sendMode `
                 -DryRun:([bool]$cfg.dryRun) -AutoOpen:$auto -RowOffsets $offsets -SendButton $btn `
                 -SendMethod $method -KeepOpen:$keep -HideMain:$hideMain
        if ($res.ok) {
            if ($attempt -gt 1) { Write-Log "재시도 $attempt회 만에 성공" 'SEND' }
            break
        }
        if ($res.roomNotFound) {
            # 방을 못 찾은 것은 재시도해도 같다. 3회를 돌면 60초를 넘겨 폰이 먼저 포기한다.
            Write-Log "전송 실패 - $($res.error) / 방이 없으므로 재시도하지 않음" 'WARN'
            break
        }
        if ($attempt -lt $tries) {
            Write-Log "전송 실패 ($attempt/$tries) - $($res.error) [$($res.diag)] / $retryGap ms 후 재시도" 'WARN'
            Start-Sleep -Milliseconds $retryGap
        }
    }

    if ($res.ok) {
        Set-Delivered $DedupeKey
        # sendButton 은 '21,29' 같은 오프셋일 수도, '픽셀탐지' 같은 방식 이름일 수도 있다.
        # 숫자쌍일 때만 다음 전송의 1순위 후보로 기억한다.
        if ($res.sendButton -match '^\s*(\d+)\s*,\s*(\d+)\s*$') {
            $script:lastSendButton = @([int]$matches[1], [int]$matches[2])
        }
        if ($res.dryRun) {
            $script:lastDryRoom = $res.room
            Write-Log "DRYRUN 성공 - 창=$($res.room) 입력창=$($res.inputHwnd) ($($res.inputClass))" 'SEND'
        }
        else             { Write-Log "전송 성공 -> [$($res.room)] (열기 $(if($res.rowOffset){$res.rowOffset}else{'기존창'}), 방식 $($res.via)$(if($res.sendButton){" $($res.sendButton)"})$(if($res.closed){', 창 닫음'})$(if($res.mainHidden){', 메인창 숨김'}))" 'SEND' }
    } else {
        Write-Log "전송 실패: $($res.error)" 'ERR'
    }

    # 전송 자체가 실패한 것은 일시적일 수 있으므로(카톡 잠금 등) 앱이 재시도하도록 둔다.
    return @{ ok = [bool]$res.ok; room = $res.room; dryRun = [bool]$res.dryRun
              openMode = $res.openMode; rowOffset = $res.rowOffset; error = $res.error
              approx = [bool]$res.approx; unverified = [bool]$res.unverified
              retryable = ((-not $res.ok) -and (-not $res.roomNotFound)) }
}

# ---------- 서버 시작 ----------
$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -ExpandProperty IPAddress)

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, [int]$cfg.port)
<#
  로그를 실시간으로 보여 주는 창을 띄운다.
  릴레이와 별개의 프로세스라서 그 창을 닫아도 릴레이는 계속 돈다.
#>
<#
  조작 창을 연다. 트레이 메뉴의 유일한 동작이다.
  -ConfirmQuit 를 주면 창이 열리자마자 끝내기 확인 화면을 보여 준다.
#>
function Open-ControlPanel {
    param([switch]$ConfirmQuit)
    $panel = Join-Path $PSScriptRoot 'Launch-Control.ps1'
    if (-not (Test-Path $panel)) { return }
    $argv = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $panel + '"'))
    if ($ConfirmQuit) { $argv += '-ConfirmQuit' }
    try {
        Start-Process powershell.exe -ArgumentList $argv `
            -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    } catch {
        Write-Log "조작 창 열기 실패: $_" 'ERR'
    }
}

try {
    $listener.Start()
} catch {
    # 대개 릴레이가 이미 떠 있는 경우다. 스택 트레이스를 뱉고 죽는 대신 한 줄만 남기고 조용히 끝낸다.
    # (감시자가 포트를 보고 판단하므로, 이미 살아있다면 아무 문제 없다)
    Write-Log "포트 $($cfg.port) 열기 실패. 이미 실행 중이거나 다른 프로그램이 사용 중: $($_.Exception.Message)" 'WARN'
    return
}

if (-not $script:noConsole) {
Write-Host ""
Write-Host "  카톡 릴레이 서버 시작" -ForegroundColor Cyan
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
foreach ($ip in $ips) { Write-Host "  수신 주소 : http://$ip`:$($cfg.port)/sms" -ForegroundColor White }
$fmtLine = if ($cfg.PSObject.Properties.Name -contains 'requirePassword' -and -not $cfg.requirePassword) { '채팅방 내용   (첫 띄어쓰기로 구분)' } else { '비밀번호 채팅방 내용' }
Write-Host "  형식      : $fmtLine" -ForegroundColor White
Write-Host "  허용번호  : $(($cfg.allowFrom) -join ', ')" -ForegroundColor White
Write-Host "  허용 IP   : $(if ($cfg.allowIPs) { ($cfg.allowIPs) -join ', ' } else { '제한 없음(위험)' })" -ForegroundColor White
Write-Host "  DRY RUN   : $($cfg.dryRun)" -ForegroundColor $(if ($cfg.dryRun) {'Yellow'} else {'Green'})
Write-Host "  자동 열기 : $(if ($cfg.autoOpen) {'켜짐'} else {'꺼짐 (채팅방 창을 미리 열어둬야 함)'})" -ForegroundColor White
Write-Host "  중지      : Ctrl+C" -ForegroundColor DarkGray
Write-Host ""
}
Write-Log "카톡 릴레이 v$RelayVersion 시작 (포트 $($cfg.port), 시험 모드 $(if($cfg.dryRun){'켜짐'}else{'꺼짐'}))"

$script:running   = $true
$script:startedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
<#
  '몇 분째 대기 중' 은 프로세스가 뜬 시각이 아니라 마지막으로 전달을 시작한 시각부터 센다.
  일시 중지했다 다시 시작하면 프로세스는 그대로이므로, 프로세스 시각을 쓰면
  멈춰 있던 시간까지 대기 시간에 들어가 버린다.
#>
$script:readyAt = Get-Date
$notify = $null

if ($winMode -eq 'tray') {
    try {
        # 카카오톡 실행 파일에서 로고를 뽑아 쓰지 않는다.
        # 트레이에 카카오 로고가 뜨면 카톡 본체와 구분되지 않고,
        # 남에게 배포할 때 카카오 공식 프로그램으로 오해할 소지가 있다.
        # exe 아이콘과 같은 자체 아이콘(relay.ico)을 쓴다.
        $icon = $null
        $icoPath = Join-Path $PSScriptRoot 'relay.ico'
        if (Test-Path $icoPath) { try { $icon = New-Object System.Drawing.Icon($icoPath) } catch { } }
        if (-not $icon) {
            # ico 가 없으면 exe 자신에 박힌 아이콘을 쓴다
            try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
        }
        if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Application }

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = $icon
        $script:trayIconOn = $icon
        # 꺼짐 상태는 회색조 아이콘으로 구분한다
        $script:trayIconOff = $null
        try {
            $bmpOn = $icon.ToBitmap()
            $bmpOff = New-Object System.Drawing.Bitmap($bmpOn.Width, $bmpOn.Height)
            $gOff = [System.Drawing.Graphics]::FromImage($bmpOff)
            $cm = New-Object System.Drawing.Imaging.ColorMatrix
            $cm.Matrix00 = 0.30; $cm.Matrix01 = 0.30; $cm.Matrix02 = 0.30
            $cm.Matrix10 = 0.59; $cm.Matrix11 = 0.59; $cm.Matrix12 = 0.59
            $cm.Matrix20 = 0.11; $cm.Matrix21 = 0.11; $cm.Matrix22 = 0.11
            $cm.Matrix33 = 0.55; $cm.Matrix44 = 1.0
            $ia = New-Object System.Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
            $gOff.DrawImage($bmpOn, (New-Object System.Drawing.Rectangle(0,0,$bmpOn.Width,$bmpOn.Height)),
                            0,0,$bmpOn.Width,$bmpOn.Height, 'Pixel', $ia)
            $gOff.Dispose()
            $script:trayIconOff = [System.Drawing.Icon]::FromHandle($bmpOff.GetHicon())
        } catch { }
        $notify.Text = '카톡 릴레이 - 전달 중'      # 툴팁은 63자 제한
        $notify.Visible = $true

        <#
          트레이 메뉴 모양.

          기본 ContextMenuStrip 은 옛 회색 테두리에 각진 모서리라 요즘 트레이 메뉴와 겉돈다.
          윈도우 11 의 트레이 메뉴(휴대폰 연결 등)는 모서리가 둥글고, 항목이 넉넉하며,
          마우스를 올린 항목만 둥근 사각형으로 옅게 칠해진다. 그 느낌으로 직접 그린다.
        #>
        if (-not ('TrayMenuStyle' -as [type])) {
        # protected 오버라이드만 있어 '공개 멤버 없음' 경고가 나온다. 정상이므로 감춘다.
        Add-Type -WarningAction SilentlyContinue -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class TrayMenuStyle : ToolStripRenderer {
    static readonly Color Bg    = Color.FromArgb(251, 251, 251);
    static readonly Color Line  = Color.FromArgb(225, 223, 220);
    static readonly Color Hover = Color.FromArgb(234, 231, 226);
    static readonly Color Ink   = Color.FromArgb(26, 23, 20);
    static readonly Color Sep   = Color.FromArgb(232, 230, 227);

    static GraphicsPath Round(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, rad, rad, 180, 90);
        p.AddArc(r.Right - rad, r.Y, rad, rad, 270, 90);
        p.AddArc(r.Right - rad, r.Bottom - rad, rad, rad, 0, 90);
        p.AddArc(r.X, r.Bottom - rad, rad, rad, 90, 90);
        p.CloseFigure();
        return p;
    }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        e.Graphics.Clear(Bg);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        Rectangle r = new Rectangle(0, 0, e.AffectedBounds.Width - 1, e.AffectedBounds.Height - 1);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = Round(r, 8))
        using (Pen pen = new Pen(Line, 1))
            e.Graphics.DrawPath(pen, p);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        Rectangle r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = Round(r, 5))
        using (SolidBrush b = new SolidBrush(Hover))
            e.Graphics.FillPath(b, p);
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = Ink;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2;
        using (Pen pen = new Pen(Sep, 1))
            e.Graphics.DrawLine(pen, 12, y, e.Item.Width - 12, y);
    }
}
'@
        }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Renderer = New-Object TrayMenuStyle
        # 창 자체도 모서리를 둥글게 잘라 낸다. 테두리만 둥글면 각진 흰 귀퉁이가 남는다.
        $menu.Add_Opened({
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath
            $w = $menu.Width; $h = $menu.Height; $r = 8
            $p.AddArc(0,0,$r,$r,180,90);         $p.AddArc(($w-$r),0,$r,$r,270,90)
            $p.AddArc(($w-$r),($h-$r),$r,$r,0,90); $p.AddArc(0,($h-$r),$r,$r,90,90)
            $p.CloseFigure()
            $menu.Region = New-Object System.Drawing.Region($p)
        })
        # 기본값이면 항목 왼쪽에 아이콘 자리(회색 띠)가 생긴다. 글자만 쓰므로 없앤다.
        # 대신 여백을 직접 줘야 한다. 그냥 끄기만 하면 글자가 테두리에 붙어 옹색해 보인다.
        $menu.ShowImageMargin = $false
        # 글꼴은 윈도우가 메뉴에 쓰는 것을 그대로 쓴다. 다른 트레이 메뉴와 같아 보인다.
        $menu.Font = [System.Drawing.SystemFonts]::MenuFont
        $menu.Padding = New-Object System.Windows.Forms.Padding(0,3,0,3)

        <#
          트레이 메뉴에는 두 가지만 둔다.

          예전에는 상태 보기 / 터미널로 보기 / 로그 열기 / 설정 열기 가 여기 있었다.
          상주 아이콘의 작은 메뉴에 기능을 늘어놓으면 어디에 무엇이 있는지 외워야 하고,
          같은 일을 하는 자리가 창과 메뉴 두 곳으로 갈린다.
          전부 조작 창으로 옮기고, 여기에는 그 창을 여는 문과 끝내는 문만 남겼다.
        #>
        <#
          항목 여백.
          메뉴 폭은 가장 넓은 항목에 맞춰 정해지므로 폭을 직접 주지 않고 여백으로 넓힌다.
          오른쪽을 조금 더 두는 것은 윈도우 기본 메뉴와 같은 방식이다.
          너무 키우면 글자만 왼쪽에 붙고 오른쪽이 비어 보이므로 적당히 둔다.
        #>
        <#
          세로 여백은 주지 않는다.

          ToolStripMenuItem 은 세로 여백을 글자 위치에 반영하지 않는다.
          여백을 주면 글자는 제자리에 있고 항목만 아래로 길어져서,
          강조 사각형 안에서 글자가 위로 붙어 보인다. 실측하면 이렇다.
              항목 24px -> 사각형 6~28, 글자 10~20  (위 4 / 아래 7)
              항목 20px -> 사각형 6~24, 글자 10~20  (위 4 / 아래 3)
          여백 없이 20px 일 때 글자가 사각형 한가운데에 온다. 좌우만 넉넉히 준다.
        #>
        function Set-MenuItemPadding($item) {
            $item.Padding = New-Object System.Windows.Forms.Padding(16,0,40,0)
        }

        <#
          첫 항목과 마지막 항목은 위아래로 조금 띄운다.
          띄우지 않으면 강조 사각형의 모서리가 창의 둥근 모서리와 겹쳐,
          위로 밀려 올라간 것처럼 보인다.
        #>
        $miOpen = $menu.Items.Add('열기')
        Set-MenuItemPadding $miOpen
        $miOpen.Margin = New-Object System.Windows.Forms.Padding(0,3,0,0)
        $miOpen.Add_Click({ Open-ControlPanel })

        [void]$menu.Items.Add('-')

        # 조작 창의 [프로그램 완전히 끝내기] 와 같은 동작이다.
        # 되돌리는 방법을 함께 보여 줘야 하므로 확인 화면을 그 창에 맡긴다.
        $miQuit = $menu.Items.Add('끝내기')
        Set-MenuItemPadding $miQuit
        $miQuit.Margin = New-Object System.Windows.Forms.Padding(0,0,0,3)
        $miQuit.Add_Click({ Open-ControlPanel -ConfirmQuit })

        $notify.ContextMenuStrip = $menu
        $script:lastPaused = $null
        # 더블클릭 = 창 열기. 우클릭 메뉴의 [열기] 와 같다.
        $notify.Add_DoubleClick({ Open-ControlPanel })
    } catch {
        Write-Log "트레이 아이콘 생성 실패(무시하고 계속): $($_.Exception.Message)" 'WARN'
        $notify = $null
    }
}

try {
    while ($script:running) {
        # 트레이 메뉴가 응답하려면 메시지를 처리해줘야 하므로 블로킹 Accept 를 쓰지 않는다
        if (-not $listener.Pending()) {
            if ($notify) { [System.Windows.Forms.Application]::DoEvents() }
            Sync-Tray
            Flush-Pending
            Start-Sleep -Milliseconds 100
            continue
        }
        $client = $null
        try { $client = $listener.AcceptTcpClient() } catch {
            Write-Log "연결 수락 실패(계속 대기): $($_.Exception.Message)" 'WARN'
            Start-Sleep -Milliseconds 200
            continue
        }
        if (-not $client) { continue }
        $peer = try { $client.Client.RemoteEndPoint.ToString() } catch {"?" }
        try {
            # 요청을 읽다가 예외가 나도 응답 형식을 정할 수 있어야 한다
            $plain = $false
            $req = Read-HttpRequest -client $client
            if (-not $req) {
                <#
                  조작 창이 릴레이가 살아 있는지 볼 때 TCP 로 붙었다 바로 끊는다.
                  같은 PC 에서 온 그 확인은 우리가 스스로 만드는 자국이므로 기록하지 않는다.
                  기록하면 5초마다 노란 경고가 쌓여, 아무 문제가 없는데도 문제처럼 보인다.
                  밖에서 온 것이라면 진짜로 이상한 상황이니 남긴다.
                #>
                if ($peer -notlike '127.0.0.1:*') {
                    Write-Log "$peer 연결만 하고 끊음" 'WARN'
                }
                $client.Close(); continue
            }

            $path = ($req.Url -split '\?')[0]
            <#
              주소에 reply=text 를 붙이면 사람이 읽을 한 문장만 돌려준다.
              중계 휴대폰이 이 응답을 그대로 보낸 사람에게 문자로 되돌려 준다.
              거부나 오류로 끝나는 길에서도 같은 형식으로 답해야 하므로 여기서 미리 구한다.
              표식 없는 응답은 '릴레이에 닿지 못했다' 는 뜻으로만 남겨 두어야 한다.
            #>
            $plain = ($req.Url -match '[?&]reply=text(&|$)')

            if (-not (Test-AllowedIP $peer)) {
                Write-Log "거부: 허용되지 않은 접속 IP $peer  ($($req.Method) $($req.Url))" 'WARN'
                $msg = "요청 거부`n원인: 허용되지 않은 기기`n조치: PC 허용 대역 확인"
                Send-HttpResponse -stream $req.Stream -Status $(if ($plain) { 200 } else { 403 }) -PlainText:$plain `
                    -Payload @{ ok=$false; error=$msg; reply=$msg; retryable=$false }
                $client.Close()
                continue
            }

            $ct2  = if ($req.Headers.ContainsKey('content-type')) { $req.Headers['content-type'] } else { '-' }
            $ua2  = if ($req.Headers.ContainsKey('user-agent')) { $req.Headers['user-agent'] } else { '-' }
            <#
              /health 는 감시자가 1분마다, 조작 창이 열릴 때마다 두드린다.
              이걸 다 적으면 로그의 대부분이 자기 자신을 확인한 기록으로 채워져
              정작 문자가 오간 줄이 묻힌다. 실측으로 전체의 44% 였다.
            #>
            <#
              [기록 폴더]는 사용자가 직접 열어 보는 곳이다.
              예전에는 여기에 POST·ct·len·ua 를 통째로 적어, 한 줄이 화면 폭을 다 먹고
              정작 문자가 오간 줄이 묻혔다. 사람이 읽을 한 줄만 남기고
              진단용 상세는 logRawBody 를 켰을 때만 적는다.
            #>
            if ($req.Url -notlike '/health*') {
                if ($path -eq '/sms' -or $path -eq '/') {
                    Write-Log "문자 받음  ($peer)"
                } else {
                    Write-Log "요청 $($req.Method) $path  ($peer)"
                }
                if ($cfg.PSObject.Properties.Name -contains 'logRawBody' -and [bool]$cfg.logRawBody) {
                    Write-Log "  (진단) $($req.Url)  ct=$ct2  len=$($req.Body.Length)  ua=$ua2"
                }
            }
            # 폰에서 무엇이 넘어오는지 그대로 보고 싶을 때만 켠다.
            # 메시지 내용이 로그 파일에 남으므로 평소에는 꺼둔다.
            if ($cfg.PSObject.Properties.Name -contains 'logRawBody' -and [bool]$cfg.logRawBody -and
                $req.Body -and $req.Method -eq 'POST') {
                $rawDbg = $req.Body -replace "`r", '' -replace "`n", '⏎'
                if ($rawDbg.Length -gt 400) { $rawDbg = $rawDbg.Substring(0, 400) + '…' }
                Write-Log "  받은 본문 그대로: [$rawDbg]" 'INFO'
            }

            if ($path -eq '/health') {
                Send-HttpResponse -stream $req.Stream -Payload @{
                    ok         = $true
                    service    = 'kakao-relay'
                    dryRun     = [bool]$cfg.dryRun
                    paused     = [bool](Test-Paused)
                    lastDryRoom = $script:lastDryRoom
                    <#
                      화면에 보일 값이다. 열쇠에 붙은 'name:' 은 내부 표시이므로 떼어낸다.
                      보내는 사람이 하나뿐이면 방 이름만 보여 주는 편이 읽기 쉽다.
                    #>
                    <#
                      고정 대상은 사람 이름과 채팅방 이름이다.
                      /rooms 는 이 PC 에서만 답하도록 막아 놓고 여기로 새어 나가면 소용이 없다.
                      조작 창과 감시자는 모두 이 PC 에서 붙으므로 잃는 기능이 없다.
                    #>
                    pins        = $(if ($peer -notlike '127.0.0.1:*') { $null } else {
                        if ($script:pins.Count -eq 0) { $null }
                        elseif ($script:pins.Count -eq 1) { @($script:pins.Values)[0] }
                        else {
                            ($script:pins.GetEnumerator() | ForEach-Object {
                                "$($_.Key -replace '^name:','') → $($_.Value)"
                            }) -join ', '
                        }
                    })
                    version    = $RelayVersion
                    pid        = $PID
                    windowMode = $winMode
                    trayIcon   = [bool]($notify -ne $null -and $notify.Visible)
                    hasConsole = ([WinCon]::GetConsoleWindow() -ne [IntPtr]::Zero)
                    kakaoTalk  = ((Get-KakaoProcessIds).Count -gt 0)
                    startedAt  = $script:startedAt
                    uptimeMin  = [int][Math]::Floor(((Get-Date) - $script:readyAt).TotalMinutes)
                }
            }
            elseif ($path -eq '/rooms') {
                <#
                  열려 있는 채팅방 제목은 곧 사람 이름과 단톡방 이름이다.
                  같은 공유기에 붙은 아무 기기나 볼 수 있으면 안 된다.
                  진단용이므로 이 PC 에서만 답한다.
                #>
                if ($peer -notlike '127.0.0.1:*') {
                    Send-HttpResponse -stream $req.Stream -Status 403 -Payload @{ ok=$false; error='이 PC에서만 볼 수 있습니다.' }
                } else {
                    $rooms = @(Get-KakaoRoomWindows | Select-Object -ExpandProperty Title)
                    Send-HttpResponse -stream $req.Stream -Payload @{ ok=$true; rooms=$rooms }
                }
            }
            elseif ($path -eq '/sms' -or $path -eq '/') {
                # 처리하는 동안 감시자가 좀비로 오해하지 않게 표시해 둔다
                try { Set-Content $BusyFile (Get-Date -Format 'o') -Encoding UTF8 } catch { }
                $f = Extract-SmsFields -req $req
                <#
                  발신자 검사가 가장 앞에 와야 한다.

                  예전에는 이 검사가 Handle-Sms 안에 있어서, 일시 중지 상태이거나
                  본문이 비어 있으면 검사를 거치지 않고 답장 문구가 만들어졌다.
                  그러면 광고 스팸이 올 때마다 그 번호로 답장 문자가 나간다.
                  요금이 나가고, 상대에게 이 번호가 살아 있다는 것도 알려 준다.

                  등록되지 않은 발신자에게는 정상 전송과 똑같은 응답을 돌려준다.
                  응답이 다르면 번호를 하나씩 넣어보며 주인 번호를 알아낼 수 있다.
                #>
                if (-not (Test-AllowedSender $f.from)) {
                    Write-Log "거부: 허용되지 않은 발신번호 '$($f.from)'" 'WARN'
                    Send-HttpResponse -stream $req.Stream -Status 200 -PlainText:$plain `
                        -Payload @{ ok=$false; silent=$true; retryable=$false
                                    error='요청 거부' + [char]10 + '원인: 미등록 발신자' }
                }
                elseif (Test-Paused) {
                    Write-Log "일시 중지 상태라 전달하지 않음: '$($f.text)'" 'WARN'
                    $msg = "전송 보류`n원인: 릴레이 일시 중지`n조치: PC에서 재개"
                    Send-HttpResponse -stream $req.Stream -Status 200 -PlainText:$plain -Payload @{
                        ok=$false; paused=$true; retryable=$false; error=$msg; reply=$msg }
                }
                elseif (-not $f.text) {
                    $msg = "요청 거부`n원인: 내용 없음"
                    # 답장 모드는 언제나 200 이다. 400 을 돌려주면 중계 휴대폰이 요청 실패로 보고
                    # 응답 변수를 제 오류 메시지로 덮어써, 표식 없는 값이 문자로 나간다.
                    $code = if ($plain) { 200 } else { 400 }
                    Send-HttpResponse -stream $req.Stream -Status $code -PlainText:$plain -Payload @{ ok=$false; error=$msg; reply=$msg }
                } else {
                    $result = Handle-Sms -from $f.from -text $f.text
                    # 카톡 전송이 실패하면 보낸 사람도 알아야 하므로 사유를 담는다.
                    # 등록되지 않은 발신자에게만은 답장하지 않는다(silent).
                    if (-not $result.ok -and -not $result.silent -and -not $result.reply) {
                        $result['reply'] = [string]$result.error
                    }
                    <#
                      포워더 앱은 200 이 아니면 최대 10회 재시도한다.
                      재시도해도 소용없는 실패(인증/형식)는 200, 일시적 실패만 503 으로 돌려준다.

                      다만 답장 모드에서는 언제나 200 으로 돌려준다.
                      실패를 문자로 직접 알려 주므로 재시도에 맡길 이유가 없고,
                      재시도에 맡기면 같은 답장 문자가 열 번 나갈 수 있다.
                      덕분에 답장 모드에서 빈 응답이 오는 경우는
                      '릴레이에 닿지 못했다' 하나뿐이 된다.
                    #>
                    $code = if ($result.retryable -and -not $plain) { 503 } else { 200 }
                    Send-HttpResponse -stream $req.Stream -Status $code -PlainText:$plain -Payload $result
                }
            }
            else {
                $msg = "요청 거부`n원인: 잘못된 주소`n조치: 매크로 URL 확인"
                Send-HttpResponse -stream $req.Stream -Status $(if ($plain) { 200 } else { 404 }) -PlainText:$plain `
                    -Payload @{ ok=$false; error=$msg; reply=$msg }
            }
        } catch {
            <#
              전송이 오래 걸리는 동안 조작 창의 생존 확인이 기다리다 끊는 일이 있다.
              그때 응답을 쓰려 하면 '연결이 중단되었습니다' 예외가 나는데,
              이건 고장이 아니라 상대가 먼저 간 것뿐이다. 오류로 남기면
              멀쩡한 상황이 빨간 줄로 쌓여 진짜 오류를 가린다.
            #>
            $msg = $_.Exception.Message
            if ($peer -like '127.0.0.1:*' -and ($msg -like '*연결*' -or $msg -like '*connection*')) {
                # 같은 PC 에서 온 확인이 먼저 끊긴 것이므로 넘어간다
            } else {
                Write-Log "요청 처리 오류 ($peer): $msg" 'ERR'
                <#
                  여기서 아무것도 안 보내면 중계 휴대폰은 응답을 못 받는다.
                  그러면 표식 없는 값이 남아 'PC 에 닿지 못함' 으로 잘못 알리고,
                  200 이 아니므로 포워더가 최대 10회까지 같은 요청을 되풀이한다.
                  무슨 일이 있어도 한 번은 답하고 끝낸다.
                #>
                try {
                    $emsg = "전송 실패`n원인: PC 내부 오류`n조치: PC 기록 확인"
                    Send-HttpResponse -stream $req.Stream -Status 200 -PlainText:$plain `
                        -Payload @{ ok=$false; retryable=$false; error=$emsg; reply=$emsg }
                } catch { }
            }
        } finally {
            # 처리가 끝났으니 '일하는 중' 표시를 지운다
            try { Remove-Item $BusyFile -Force -ErrorAction SilentlyContinue } catch { }
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    if ($notify) { $notify.Visible = $false; $notify.Dispose() }
    Write-Log "릴레이 종료"
}
