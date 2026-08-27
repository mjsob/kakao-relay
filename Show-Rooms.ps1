<# 열려 있는 카톡 창 목록 진단 도구 #>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. "$PSScriptRoot\KakaoCore.ps1"

$tops = Get-KakaoTopWindows
if (-not $tops) { Write-Host "카카오톡이 실행 중이 아닙니다." -ForegroundColor Red; exit 1 }

Write-Host "`n=== 보이는 최상위 창 ===" -ForegroundColor Cyan
$tops | Where-Object { $_.Visible -and $_.Title } |
    Select-Object @{n='HWND';e={"0x{0:X}" -f [int64]$_.Hwnd}}, Class, Title |
    Format-Table -Auto

$rooms = Get-KakaoRoomWindows
Write-Host "=== 채팅방 후보 (전송 대상으로 쓸 수 있는 이름) ===" -ForegroundColor Green
if (-not $rooms) {
    Write-Host "  없음 - 카톡에서 채팅방을 '새 창'으로 열어주세요." -ForegroundColor Yellow
    Write-Host "  (카톡 설정 > 채팅 > '채팅방을 새 창으로 열기' 켜거나, 목록에서 채팅방 더블클릭)" -ForegroundColor DarkGray
} else {
    foreach ($r in $rooms) {
        $box = Get-KakaoInputBox -RoomHwnd $r.Hwnd
        $mark = if ($box) { "OK  입력창=$($box.Class)" } else { "??  입력창 못 찾음" }
        Write-Host ("  [{0}]  {1}" -f $r.Title, $mark)
    }
}
Write-Host ""
