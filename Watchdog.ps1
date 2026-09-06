<#
  Watchdog.ps1 - 릴레이가 죽어 있으면 다시 살린다.
  KakaoRelayWatchdog 작업으로 1분마다 실행된다.
  설치: .\Install-Autostart.ps1   /   해제: .\Install-Autostart.ps1 -Remove
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$cfgPath = Join-Path $PSScriptRoot 'config.json'
$log     = Join-Path $PSScriptRoot 'watchdog.log'

function W([string]$m) {
    # 이 기록은 1분마다 쌓일 수 있으므로 릴레이 기록처럼 넘치기 전에 한 번 접는다
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 512KB) {
            Move-Item $log "$log.old" -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
}

<#
  설정을 못 읽으면 아무것도 하지 않는다.
  예전에는 여기서 예외가 나거나 포트가 0 이 되어, 1분마다 헛되이
  '포트 0 리스닝 없음' 을 적으며 릴레이를 되살리려 들었다.
#>
$cfg = $null
try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if (-not $cfg -or -not $cfg.port) {
    W '설정 파일을 읽지 못해 확인을 건너뜀 (config.json 을 확인하세요)'
    exit 0
}
$port = [int]$cfg.port

<#
  꺼짐 표시 파일이 있으면 사용자가 일부러 문자 전달을 멈춘 상태다.
  이때도 릴레이 프로세스는 계속 살려 둔다(트레이 아이콘이 유일한 복귀 수단이다).
  다만 카카오톡은 켜 놓을 이유가 없으므로 확인도 자동 실행도 하지 않는다.
#>
$paused = Test-Path (Join-Path $PSScriptRoot 'paused.marker')

<#
  '프로그램 완전히 끝내기' 로 내린 상태면 되살리지 않는다.
  이 파일은 다음에 릴레이가 시작할 때 스스로 지운다(= 컴퓨터를 켜면 돌아온다).
#>
if (Test-Path (Join-Path $PSScriptRoot 'stopped.marker')) {
    exit 0
}

<#
  릴레이가 문자를 처리하는 중이면 건드리지 않는다.

  카카오톡이 로그인 화면이거나 준비 중이면 한 통에 90초까지 걸리는데,
  그동안 릴레이는 단일 스레드라 health 에 답하지 못한다.
  아래 4회 확인(75초)만 보고 죽이면 멀쩡히 일하는 릴레이를 끊게 된다.
  릴레이가 남기는 표시가 최근이면 살아 있는 것으로 본다.
#>
$busy = Join-Path $PSScriptRoot 'busy.marker'
if (Test-Path $busy) {
    $age = (Get-Date) - (Get-Item $busy).LastWriteTime
    if ($age.TotalMinutes -lt 3) { exit 0 }
}

# 0) 카카오톡 생존 확인
#    릴레이가 멀쩡해도 카톡이 죽어 있으면 전송은 전부 실패한다.
#    기본은 '기록만' 한다. config 의 watchdogStartKakao 가 true 면 직접 띄운다.
$kk = @(Get-Process -Name KakaoTalk -ErrorAction SilentlyContinue)
if ($kk.Count -eq 0 -and -not $paused) {
    $autoStart = if ($cfg.PSObject.Properties.Name -contains 'watchdogStartKakao') { [bool]$cfg.watchdogStartKakao } else { $false }
    if ($autoStart) {
        $exe = 'C:\Program Files\Kakao\KakaoTalk\KakaoTalk.exe'
        if (Test-Path $exe) {
            W '카카오톡이 실행 중이 아님 - 실행'
            Start-Process -FilePath $exe -ErrorAction SilentlyContinue
        } else {
            W "카카오톡이 실행 중이 아니고 실행 파일도 못 찾음: $exe"
        }
    } else {
        W '경고: 카카오톡이 실행 중이 아님 (전송 불가 상태). watchdogStartKakao 를 true 로 하면 자동 실행한다'
    }
}

# 1) 포트가 열려 있고 응답까지 하면 정상
$listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
             Where-Object { $_.LocalPort -eq $port }

if ($listening) {
    # 릴레이는 단일 스레드라 전송 처리 중(최대 40초)에는 health 에 답하지 못한다.
    # 한 번 무응답이라고 바로 죽이면 멀쩡히 일하는 릴레이를 끊게 되므로 여러 번 확인한다.
    $alive = $false
    for ($try = 1; $try -le 4; $try++) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 15
            if ($r.StatusCode -eq 200) { $alive = $true; break }
        } catch { }
        Start-Sleep -Seconds 5
    }
    if ($alive) { exit 0 }
    W 'health 4회 연속 무응답 - 좀비로 판단하고 재시작'
    <#
      포트를 쥐고 있는 것이 우리 프로세스일 때만 죽인다.
      릴레이가 못 뜬 사이 다른 프로그램이 이 포트를 먼저 잡았을 수 있는데,
      예전에는 그것을 1분마다 강제 종료했다.
    #>
    foreach ($procId in @($listening.OwningProcess | Sort-Object -Unique)) {
        $pr = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $pr) { continue }
        if ($pr.ProcessName -notmatch '^(KakaoRelay|powershell|pwsh|wscript)$') {
            W "포트 $port 을(를) 쓰는 다른 프로그램이라 건드리지 않음: $($pr.ProcessName) (pid $procId)"
            continue
        }
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
} else {
    W "포트 $port 리스닝 없음 - 릴레이가 죽어 있음. 재시작"
}

# 2) 되살리기
Start-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8

$ok = $false
try { $ok = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 10).StatusCode -eq 200 } catch { }
W $(if ($ok) { '재시작 성공' } else { '재시작 실패 - 카톡/설정 확인 필요' })
