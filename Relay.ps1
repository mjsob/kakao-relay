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

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
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
  발신자 허용 여부.
  allowFrom 에는 전화번호도, 이름도 넣을 수 있다.
  알림 트리거에는 번호가 없어 이름({not_title})밖에 보낼 수 없기 때문이다.
#>
function Test-AllowedSender {
    param([string]$from)
    $allow = @($cfg.allowFrom)
    if ($allow.Count -eq 0) { return $true }   # 비어있으면 전체 허용
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

function Resolve-Room {
    param([string]$name)
    if (-not $name) { return $null }
    $name = $name.Trim()
    if ($cfg.aliases -and $cfg.aliases.PSObject.Properties.Name -contains $name) {
        return $cfg.aliases.$name
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
function Split-RoomAndText {
    param([string]$s)
    $s = $s.Trim()
    $sp = $s.IndexOf(' ')
    if ($sp -lt 1) { return @{ room = $null; text = $s } }
    return @{ room = (Resolve-Room $s.Substring(0, $sp)); text = $s.Substring($sp + 1) }
}

function Parse-Command {
    param([string]$body)
    $body = (Remove-MmsSubjectLine $body).Trim()
    if (-not $body) { return @{ ok=$false; error='문자 내용이 비어 있습니다.' } }

    $needPw = if ($cfg.PSObject.Properties.Name -contains 'requirePassword') { [bool]$cfg.requirePassword } else { $true }
    $fmt    = if ($needPw) { '비밀번호 채팅방 내용' } else { '채팅방 내용' }

    if ($needPw) {
        $i = $body.IndexOf(' ')
        if ($i -lt 1) { return @{ ok=$false; error="형식이 맞지 않습니다. '$fmt' 형식으로 보내 주세요." } }
        if ($body.Substring(0, $i).Trim() -ne $cfg.password) { return @{ ok=$false; error='비밀번호가 맞지 않습니다.' } }
        $body = $body.Substring($i + 1).Trim()
        if (-not $body) { return @{ ok=$false; error='보낼 내용이 없습니다.' } }
    }

    <#
      defaultRoom 을 정해 두면 방 이름을 적지 않는다. 본문 전체가 내용이다.
      첫 낱말을 방 이름으로 떼어내 버리면 문장의 첫 단어가 사라지기 때문이다.
    #>
    if ($cfg.defaultRoom) {
        $room = Resolve-Room $cfg.defaultRoom
        $text = $body
    } else {
        $r = Split-RoomAndText $body
        if (-not $r.room) {
            return @{ ok=$false; error="채팅방 이름이 없습니다. '$fmt' 형식으로, 채팅방 이름 뒤에 띄어쓰기를 하고 내용을 적어 주세요." }
        }
        $room = $r.room
        $text = $r.text
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return @{ ok=$false; error='보낼 내용이 없습니다.' } }
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
    return (Normalize-Phone $From) + '|' + $flat
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

function Send-HttpResponse {
    param([System.Net.Sockets.NetworkStream]$stream, [int]$Status = 200, [hashtable]$Payload)
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

    # retryable=$false 인 응답은 HTTP 200 으로 돌려준다.
    # 포워더 앱이 200 이 아니면 재시도하는데, 비밀번호 오류처럼 다시 보내도 소용없는 건
    # 재시도시켜봐야 로그만 더러워지기 때문이다.
    if (-not (Test-AllowedSender $from)) {
        Write-Log "거부: 허용되지 않은 발신번호 '$from'  (본문: '$text')" 'WARN'
        return @{ ok = $false; error = '등록되지 않은 발신자입니다. PC 설정의 allowFrom 을 확인하세요.'; retryable = $false }
    }

    $dedupeKey = Get-DedupeKey -From $from -Text $text
    if (Test-AlreadySent $dedupeKey) {
        Write-Log "무시: 이미 전송된 메시지 (앱 재시도로 추정) '$text'" 'WARN'
        return @{ ok = $true; error = $null; duplicate = $true; retryable = $false }
    }

    $joinMs = if ($cfg.PSObject.Properties.Name -contains 'joinWindowMs') { [int]$cfg.joinWindowMs } else { 0 }
    $cmd = Parse-Command $text

    if ($joinMs -gt 0) {
        $pk = Normalize-Phone $from
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
        Write-Log "거부: $($cmd.error)  (원문: '$text')" 'WARN'
        return @{ ok = $false; error = $cmd.error; retryable = $false }
    }

    return Invoke-Send -Room $cmd.room -Text $cmd.text -DedupeKey $dedupeKey
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
            $notify.Text = '카톡 릴레이 - 일시 중지 (문자 전달 안 함)'
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
            if ($attempt -gt 1) { Write-Log "재시도 $attempt 회차에 성공" 'SEND' }
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
    Write-Log "포트 $($cfg.port) 를 열 수 없음. 이미 실행 중이거나 다른 프로그램이 사용 중: $($_.Exception.Message)" 'WARN'
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
Write-Log "서버 시작 (port=$($cfg.port), dryRun=$($cfg.dryRun))"

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

            if (-not (Test-AllowedIP $peer)) {
                Write-Log "거부: 허용되지 않은 접속 IP $peer  ($($req.Method) $($req.Url))" 'WARN'
                Send-HttpResponse -stream $req.Stream -Status 403 -Payload @{ ok=$false; error='허용되지 않은 접속입니다. 같은 공유기에 연결되어 있는지 확인하세요.'; retryable=$false }
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
            if ($req.Url -notlike '/health*') {
                Write-Log "요청 $peer  $($req.Method) $($req.Url)  ct=$ct2  len=$($req.Body.Length)  ua=$ua2"
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
                $rooms = @(Get-KakaoRoomWindows | Select-Object -ExpandProperty Title)
                Send-HttpResponse -stream $req.Stream -Payload @{ ok=$true; rooms=$rooms }
            }
            elseif ($path -eq '/sms' -or $path -eq '/') {
                $f = Extract-SmsFields -req $req
                if (Test-Paused) {
                    Write-Log "일시 중지 상태라 전달하지 않음: '$($f.text)'" 'WARN'
                    Send-HttpResponse -stream $req.Stream -Status 200 -Payload @{
                        ok=$false; paused=$true; retryable=$false
                        error='문자 전달이 일시 중지 상태입니다. [카톡 릴레이] 창에서 다시 시작하세요.' }
                }
                elseif (-not $f.text) {
                    Send-HttpResponse -stream $req.Stream -Status 400 -Payload @{ ok=$false; error='문자 내용을 찾지 못했습니다.' }
                } else {
                    $result = Handle-Sms -from $f.from -text $f.text
                    # 포워더 앱은 200 이 아니면 최대 10회 재시도한다.
                    # 재시도해도 소용없는 실패(인증/형식)는 200, 일시적 실패만 503 으로 돌려준다.
                    $code = if ($result.retryable) { 503 } else { 200 }
                    Send-HttpResponse -stream $req.Stream -Status $code -Payload $result
                }
            }
            else {
                Send-HttpResponse -stream $req.Stream -Status 404 -Payload @{ ok=$false; error='잘못된 주소입니다.' }
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
            }
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    if ($notify) { $notify.Visible = $false; $notify.Dispose() }
    Write-Log "서버 종료"
}
