<#
  Calibrate-Open.ps1 - 채팅방 자동 열기 보정

  검색 결과의 첫 행 y좌표를 실측해서 config.json 의 rowOffsets 에 저장한다.
  메시지는 절대 보내지 않는다. 방을 열어보기만 한다.

    .\Calibrate-Open.ps1 -Room "테스트할채팅방이름"
#>
param(
    [Parameter(Mandatory)][string]$Room,
    [string]$ConfigPath
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
. "$PSScriptRoot\KakaoCore.ps1"

Write-Host "`n채팅방 '$Room' 으로 자동 열기 보정 중..." -ForegroundColor Cyan
Write-Host "(메시지는 보내지 않습니다. 방만 열어봅니다.)`n" -ForegroundColor DarkGray

if ((Get-KakaoProcessIds).Count -eq 0) { Write-Host "카카오톡이 실행 중이 아닙니다." -ForegroundColor Red; return }

# 이미 열려 있으면 알려주고 종료
$existing = Find-KakaoRoomWindow -Room $Room
if ($existing) {
    Write-Host "이미 '$($existing.Title)' 창이 열려 있습니다. 자동 열기 보정이 필요 없습니다." -ForegroundColor Green
    Write-Host "다른 (닫혀 있는) 채팅방 이름으로 다시 실행해 보세요." -ForegroundColor DarkGray
    return
}

$offsets = @(20,30,40,50,62,75,88,100,112,124,136,150,165,180,200)
$res = Open-KakaoRoom -Room $Room -RowOffsets $offsets -WaitMs 1300

if (-not $res.ok) {
    Write-Host "실패: $($res.error)" -ForegroundColor Red
    Write-Host "`n확인할 것:" -ForegroundColor Yellow
    Write-Host "  - 채팅방 이름이 카톡에 보이는 것과 정확히 같은지"
    Write-Host "  - 카톡 화면잠금이 걸려 있지 않은지"
    return
}

Write-Host "성공!" -ForegroundColor Green
Write-Host "  열림 방식 : $($res.mode)   ($(if($res.mode -eq 'window'){'새 창'}else{'메인창 안'}))"
Write-Host "  행 오프셋 : $($res.rowOffset)"
Write-Host "  창 제목   : $($res.window.Title)"

# config.json 에 저장
$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$best = @($res.rowOffset) + @($offsets | Where-Object { $_ -ne $res.rowOffset })
if ($cfg.PSObject.Properties.Name -contains 'rowOffsets') { $cfg.rowOffsets = $best }
else { $cfg | Add-Member -NotePropertyName rowOffsets -NotePropertyValue $best }
if ($cfg.PSObject.Properties.Name -contains 'autoOpen') { $cfg.autoOpen = $true }
else { $cfg | Add-Member -NotePropertyName autoOpen -NotePropertyValue $true }
$cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8

Write-Host "`nconfig.json 에 저장했습니다 (rowOffsets 맨 앞 = $($res.rowOffset), autoOpen = true)" -ForegroundColor Green
