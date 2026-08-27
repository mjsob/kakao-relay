<#
  Install-Autostart.ps1 - 로그온 시 릴레이 자동 실행 등록 (관리자 권한 불필요)
  해제:  .\Install-Autostart.ps1 -Remove
#>
param(
    [switch]$Remove,
    # 감시자 실행 주기(분). 죽었을 때 되살아나기까지의 최대 지연이다.
    [ValidateRange(1,60)][int]$WatchdogMinutes = 1
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$TaskName = 'KakaoRelay'

$WatchName = 'KakaoRelayWatchdog'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName  -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $WatchName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "자동 실행 / 감시자 해제 완료" -ForegroundColor Green
    return
}

$ps      = (Get-Command powershell.exe).Source
$script  = Join-Path $PSScriptRoot 'Relay.ps1'
$vbsRun  = Join-Path $PSScriptRoot 'run-hidden.vbs'
$relayEx = Join-Path $PSScriptRoot 'KakaoRelay.exe'

# 전용 exe 가 있으면 그걸로 띄운다.
#   - 작업관리자에 'KakaoRelay.exe' 로 표시되어 다른 powershell 과 구분된다
#   - 창이 아예 생기지 않는다 (winexe)
# 없으면 창 없는 wscript 래퍼로 대신한다.
#   (-WindowStyle Hidden 은 콘솔을 '만든 뒤 숨기는' 것이라 부팅 때 한 번 번쩍인다)
if (Test-Path $relayEx) {
    $action = New-ScheduledTaskAction -Execute $relayEx -WorkingDirectory $PSScriptRoot
} else {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
                -Argument "`"$vbsRun`" `"$script`"" `
                -WorkingDirectory $PSScriptRoot
}
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 `
              -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description '문자 -> PC 카카오톡 릴레이' -Force | Out-Null

Write-Host "자동 실행 등록 완료 (작업 이름: $TaskName)" -ForegroundColor Green

<#
  --- 자동 복구: 릴레이 생존 확인, 죽어 있거나 굳어 있으면 되살림 ---

  릴레이는 단일 스레드이고 카카오톡에 SendMessage 를 보낸다. 상대 창이 응답하지 않으면
  그 자리에서 무한정 기다리므로, 프로세스는 살아 있는데 일은 못 하는 상태가 될 수 있다.
  작업 스케줄러는 '돌고 있다' 로만 보므로 이 상태를 잡아내지 못한다.
  그래서 별도 작업이 health 응답까지 확인한다.
  중복 실행은 IgnoreNew 라 앞 회차가 길어져도 겹치지 않는다.
#>
$wScript = Join-Path $PSScriptRoot 'Watchdog.ps1'
$vbs     = Join-Path $PSScriptRoot 'run-hidden.vbs'
$watchEx = Join-Path $PSScriptRoot 'KakaoRelayWatchdog.exe'

if (Test-Path $watchEx) {
    $wAction = New-ScheduledTaskAction -Execute $watchEx -WorkingDirectory $PSScriptRoot
} else {
    $wAction = New-ScheduledTaskAction -Execute 'wscript.exe' `
                 -Argument "`"$vbs`" `"$wScript`"" `
                 -WorkingDirectory $PSScriptRoot
}
# 트리거 두 개: 로그온 시 + 정해진 주기마다 반복
# 주의: RepetitionDuration 에 [TimeSpan]::MaxValue 를 주면 작업 스케줄러가 거부한다
#       (P99999999DT23H59M59S 는 허용 범위를 벗어난 값). 지정하지 않으면 무기한이다.
$wTriggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes))
)
$wSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

try {
    Register-ScheduledTask -TaskName $WatchName -Action $wAction -Trigger $wTriggers -Settings $wSettings `
        -Description "카톡 릴레이 생존 감시 ($WatchdogMinutes분 주기)" -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host "감시자 등록 실패: $($_.Exception.Message)" -ForegroundColor Red
}

# [완전히 중지] 로 꺼둔 상태였을 수 있으므로 반드시 다시 활성화한다
foreach ($n in @($TaskName, $WatchName)) {
    Enable-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue | Out-Null
}

# --- 등록 결과를 실제로 확인하고 보고한다 (메시지만 찍고 넘어가지 않도록) ---
Write-Host ''
foreach ($n in @($TaskName, $WatchName)) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) { Write-Host ("  OK   {0}  ({1})" -f $n, $t.State) -ForegroundColor Green }
    else    { Write-Host ("  실패  {0}  등록되지 않음" -f $n) -ForegroundColor Red }
}
Write-Host ''
Write-Host "지금 바로 시작하려면:  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor DarkGray
