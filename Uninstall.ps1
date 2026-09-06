<#
  Uninstall.ps1 - 카톡 릴레이를 컴퓨터에서 지운다.

  설치할 때 만든 것은 넷이다. 이 셋은 폴더를 지워도 남으므로 여기서 치운다.
    예약 작업 2개 (로그온 자동 실행, 자동 복구)
    방화벽 규칙 1개
    바탕 화면 바로가기

  기록과 설정에는 주고받은 문자 내용과 전화번호가 들어 있다.
  지울지 말지는 물어보고 정한다.

  방화벽 규칙을 지우려면 관리자 권한이 필요하므로 스스로 승격한다.
#>
param([switch]$Elevated)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '  카톡 릴레이 지우기' 'White'
Say '  ────────────────────────────────────────────────' 'DarkGray'
Say ''

if (-not $Elevated) {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Say '  관리자 권한 창이 뜨면 [예]를 눌러 주세요.' 'Yellow'
        Say '  방화벽 규칙을 지우는 데에 필요합니다.' 'DarkGray'
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList `
                '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Elevated'
            return
        } catch {
            Say ''
            Say '  권한 승인이 취소되었습니다. 방화벽 규칙은 남겨 두고 나머지만 지웁니다.' 'Yellow'
            Say ''
        }
    }
}

# 1) 프로그램 내리기. 표시 파일을 먼저 만들어야 자동 복구가 되살리지 않는다.
Say '  1. 프로그램을 내립니다'
New-Item (Join-Path $PSScriptRoot 'stopped.marker') -ItemType File -Force | Out-Null
Get-Process KakaoRelay -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$cfg = $null
try { $cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$port = if ($cfg -and $cfg.port) { [int]$cfg.port } else { 8787 }
foreach ($o in @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                  Where-Object { $_.LocalPort -eq $port }).OwningProcess)) {
    if ($o) {
        $pr = Get-Process -Id $o -ErrorAction SilentlyContinue
        if ($pr -and $pr.ProcessName -match '^(KakaoRelay|powershell|pwsh|wscript)$') {
            Stop-Process -Id $o -Force -ErrorAction SilentlyContinue
        }
    }
}

# 2) 예약 작업
Say '  2. 자동 실행과 자동 복구를 지웁니다'
foreach ($t in @('KakaoRelay','KakaoRelayWatchdog')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Say "     $t 지움" 'DarkGray'
    }
}

# 3) 방화벽
Say '  3. 방화벽 규칙을 지웁니다'
$ruleName = "KakaoRelay ($port)"
$rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($rule) {
    try {
        Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
        Say "     $ruleName 지움" 'DarkGray'
    } catch {
        Say '     권한이 없어 지우지 못했습니다. 관리자 PowerShell 에서 아래를 실행하세요.' 'Yellow'
        Say "     Remove-NetFirewallRule -DisplayName `"$ruleName`"" 'White'
    }
} else {
    Say '     남아 있는 규칙이 없습니다' 'DarkGray'
}

# 4) 바로가기
Say '  4. 바탕 화면 바로가기를 지웁니다'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '카톡 릴레이.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; Say '     지움' 'DarkGray' }
else { Say '     없음' 'DarkGray' }

# 5) 기록과 설정
Say ''
Say '  기록에는 주고받은 문자 내용이, 설정에는 전화번호가 들어 있습니다.' 'Yellow'
$ans = Read-Host '  지금 지울까요? (y = 지움 / 그 밖 = 남겨 둠)'
if ($ans -eq 'y') {
    foreach ($f in @('relay.log','relay.log.old','watchdog.log','watchdog.log.old',
                     'config.json','pinned.json','fail-shot.png',
                     'paused.marker','stopped.marker','busy.marker')) {
        Remove-Item (Join-Path $PSScriptRoot $f) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $root '설치결과.txt') -Force -ErrorAction SilentlyContinue
    Say '  지웠습니다.' 'Green'
} else {
    Say '  남겨 두었습니다.' 'DarkGray'
}

Say ''
Say '  ────────────────────────────────────────────────' 'DarkGray'
Say '  컴퓨터에서 할 일은 끝났습니다.' 'Green'
Say ''
Say '  남은 것은 직접 지워 주세요.' 'White'
Say "     이 폴더 통째로   $root" 'Gray'
Say '     중계 휴대폰의 MacroDroid 매크로' 'Gray'
Say ''
Say '  카카오톡과 Windows 설정은 바꾼 것이 없습니다.' 'DarkGray'
Say '  설치할 때 껐던 카카오톡 화면잠금은 필요하면 다시 켜세요.' 'DarkGray'
Say ''
Read-Host '  엔터를 누르면 창이 닫힙니다'
