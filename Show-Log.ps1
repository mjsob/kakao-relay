<#
  Show-Log.ps1 - 릴레이 로그를 실시간으로 보여 주는 창.

  릴레이 프로세스와는 별개의 창이다. 로그 파일을 따라 읽기만 하므로
  이 창을 닫아도 릴레이는 그대로 백그라운드에서 계속 돈다.
#>
$ErrorActionPreference = 'SilentlyContinue'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$log = Join-Path $root 'relay.log'
if (-not (Test-Path $log)) { New-Item $log -ItemType File -Force | Out-Null }

<#
  조작 창은 색과 글꼴을 다 손봤는데 이 창만 파워셸 기본값(남색, 120열)이면 따로 논다.
  배경과 크기만 맞춰도 격차가 크게 줄어든다.
#>
$host.UI.RawUI.WindowTitle = '카톡 릴레이 - 실시간 기록'
try {
    $host.UI.RawUI.BackgroundColor = 'Black'
    $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(96, 32)
    Clear-Host
} catch { }

Write-Host ''
Write-Host '  카톡 릴레이 - 실시간 기록' -ForegroundColor White
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host '  이 창은 로그를 보기만 하는 창입니다.' -ForegroundColor DarkGray
Write-Host '  닫아도 릴레이는 백그라운드에서 계속 돌아갑니다.' -ForegroundColor DarkGray
Write-Host '  (릴레이를 끄려면 트레이 아이콘 > 끝내기)' -ForegroundColor DarkGray
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

<#
  이 창의 목적은 '내 문자가 갔나' 하나다.

  그런데 로그에는 감시자의 /health 확인과 포트 확인 자국이 섞여 있어,
  실측하면 최근 40줄 중 30줄이 그 잡음이었다. 게다가 잡음이 노란 경고라
  아무 문제가 없는데도 문제가 난 것처럼 보인다.
  릴레이 쪽에서 /health 를 이제 안 적지만, 예전 줄이 남아 있으므로 여기서도 거른다.
  거르고 나면 화면이 빌 수 있으니 처음 읽는 양을 넉넉히 잡는다.
#>
Get-Content -Path $log -Tail 300 -Wait -Encoding UTF8 | Where-Object {
    $_ -notmatch 'GET /health' -and
    $_ -notmatch '헤더 미완성' -and
    $_ -notmatch '연결만 하고 끊음'
} | ForEach-Object {
    $color = switch -Regex ($_) {
        '\[ERR\]'  { 'Red';    break }
        '\[WARN\]' { 'Yellow'; break }
        '\[SEND\]' { 'Green';  break }
        default    { 'Gray' }
    }
    Write-Host $_ -ForegroundColor $color
}
