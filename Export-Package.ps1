<#
  Export-Package.ps1 - 다른 PC/다른 사람에게 넘길 배포본을 만든다.

    .\Export-Package.ps1                        바탕화면에 kakao-relay-setup 폴더로
    .\Export-Package.ps1                        dist\ 에 만든다 (기본)
    .\Export-Package.ps1 -Destination D:\share  지정한 경로로
    .\Export-Package.ps1 -Zip                   zip 으로 압축까지

  받는 사람에게는 최상위에 배치 파일 하나만 보인다.
      KakaoRelay.bat  (설치 / 켜고 끄기 / 점검 / 설정을 모두 이 창에서 한다)
  나머지 스크립트는 program 폴더로 내린다.

  이름을 한글로 짓지 않는다. zip 은 파일명을 UTF-8 로 넣고 그 표시를 켜 두지만,
  한국어 윈도우의 기본 압축 해제기와 오래된 압축 프로그램이 그 표시를 무시하고
  cp949 로 읽어 이름을 깨뜨리는 일이 있다. 이름이 깨지면 설치 프로그램이
  바탕 화면 바로가기를 만들 때 대상 파일을 찾지 못한다.
  사람이 읽을 한글 이름은 바탕 화면 바로가기에 붙인다(윈도우가 직접 만들므로 안전하다).
  개인정보가 담긴 파일(config.json, 로그, 실패 캡처)은 제외한다.
#>
param(
    [string]$Destination,
    [switch]$Zip
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

if (-not $Destination) {
    <#
      배포본은 프로젝트 안 dist 폴더에 만든다.
      예전에는 바탕 화면에 떨어뜨렸는데, 배포처가 GitHub Releases 로 바뀐 뒤로는
      만들자마자 올리고 끝이라 바탕 화면에 남길 이유가 없다. dist 는 git 이 무시한다.
    #>
    $Destination = Join-Path $PSScriptRoot 'dist\kakao-relay-setup'
}

# 최상위에 보일 것 / program 으로 내릴 것 / 아예 넘기지 않을 것
# 설명서는 배포본에 넣지 않고 웹 링크로만 준다. 넣으면 순환이 생긴다 -
# 설명서 안에 이 zip 의 내려받기 주소가 있어서, 주소가 바뀔 때마다 zip 을 다시 말아야 한다.
$topLevel = @()

# 받는 사람에게 필요 없는 것은 아예 넣지 않는다.
#   README.md        개발 과정 기록 (Win32 함정, 실측 데이터) - 사용자와 무관
#   설치설명서.*     설명서는 웹 링크로 준다 (위 $topLevel 주석 참고)
#   Modem-Ingest.ps1 USB 모뎀 방식(B안). 하드웨어가 없어 검증되지 않았다
#   Allow-Firewall   Setup.ps1 이 방화벽을 직접 처리하므로 불필요
#   Export-Package   배포본을 또 만들 일은 없다
#   Make-Base        base-bubble.png 을 만드는 도구. 결과물이 이미 들어가므로 불필요
#   Calibrate-Open   채팅방 목록 좌표를 다시 재는 도구. 기본값이 이미 맞춰져 있다
#   Send-Test        원격 지원용. 필수 인자를 되묻는 데다 -Live 없이는 아무것도 보내지 않아
#                    받는 사람이 우클릭으로 실행하면 오히려 헷갈린다
#   Show-Rooms       열린 채팅방 목록. [점검하기] 가 같은 내용을 보여주므로 중복이다
$exclude  = @('config.json', 'relay.log', 'watchdog.log', 'fail-shot.png',
              'README.md', '설치설명서.md', '설치설명서.html',
              'Modem-Ingest.ps1', 'Allow-Firewall.ps1', 'Export-Package.ps1',
              'Make-Base.ps1', 'Calibrate-Open.ps1', 'Launch-Config.ps1',
              'Send-Test.ps1', 'Show-Rooms.ps1',
              'relay.ico', 'watchdog.ico', 'host-error.log')
# exe 와 ico 는 넣지 않는다. 설치할 때 Setup.ps1 이 현지에서 만든다.
# (서명 없는 exe 를 받으면 SmartScreen 이 경고하고, 백신이 막는 경우도 있다)
# base-bubble.png 은 아이콘 원본이라 함께 넘긴다 (없으면 자체 도형으로 대체된다)
$inner    = @('*.ps1', '*.vbs', 'config.sample.json', 'base-bubble.png')

if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
$program = Join-Path $Destination 'program'
New-Item -ItemType Directory -Path $program -Force | Out-Null

# 1) 최상위 문서 (현재 없음)
foreach ($f in $topLevel) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) { Copy-Item $src -Destination $Destination }
}

# 2) 실행 파일 (배치) - 내용은 ASCII 로만 써야 인코딩 문제가 없다
<#
  들어오는 문은 하나뿐이다.

  예전에는 설치하기 / 점검하기 / 설정편집 / 시작중지 네 개가 폴더에 널려 있었다.
  무엇을 눌러야 하는지 알기 어렵고, 설치 전에는 넷 중 셋이 아무 일도 하지 못했다.
  조작 창이 설치 여부와 실행 상태를 모두 알고 있으므로 그 창에 전부 모았다.
    설치 전 -> [설치하기]
    설치 후 -> [릴레이 켜기 / 끄기] [점검하기] [설정 편집] [프로그램 완전히 끝내기]
#>
$bats = @{
    'KakaoRelay.bat' = 'Launch-Control.ps1'
}
# 조작 창은 GUI 라 뒤에 검은 콘솔이 남으면 지저분하다.
# wscript 로 띄우면 콘솔이 아예 생기지 않는다.
$guiBats = @('KakaoRelay.bat')
foreach ($b in $bats.GetEnumerator()) {
    if ($guiBats -contains $b.Key) {
        $body = "@echo off`r`nstart `"`" wscript.exe `"%~dp0program\run-hidden.vbs`" `"%~dp0program\$($b.Value)`"`r`n"
    } else {
        $body = "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0program\$($b.Value)`"`r`n"
    }
    [IO.File]::WriteAllText((Join-Path $Destination $b.Key), $body, [Text.Encoding]::ASCII)
}

# 3) 나머지 스크립트는 program 으로
$moved = @()
foreach ($pat in $inner) {
    Get-ChildItem -Path $PSScriptRoot -Filter $pat -File |
        Where-Object { $exclude -notcontains $_.Name -and $topLevel -notcontains $_.Name } |
        ForEach-Object { Copy-Item $_.FullName -Destination $program; $moved += $_.Name }
}

Write-Host ''
Write-Host "  배포본: $Destination" -ForegroundColor Green
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
Write-Host '  KakaoRelay.bat      <- 설치도 켜고 끄기도 전부 여기서' -ForegroundColor White
Write-Host "  program\            <- 내부 파일 $($moved.Count)개" -ForegroundColor DarkGray

Write-Host ''
Write-Host '  제외됨 (개인정보 / 개발용 / 미검증)' -ForegroundColor Yellow
foreach ($e in $exclude) {
    if (Test-Path (Join-Path $PSScriptRoot $e)) { Write-Host "    $e" -ForegroundColor DarkGray }
}

if ($Zip) {
    $zipPath = "$Destination.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $Destination '*') -DestinationPath $zipPath
    Write-Host ''
    Write-Host "  압축: $zipPath" -ForegroundColor Green
}

Write-Host ''
Write-Host '  받는 사람이 할 일' -ForegroundColor White
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
Write-Host '    0) 설치 가이드 링크를 함께 보낼 것 (설명서는 zip 에 들어있지 않다)'
Write-Host '    1) 압축 풀기'
Write-Host '    2) 카카오톡 설치 + 로그인, 화면잠금 끄기'
Write-Host '    3) [KakaoRelay.bat] 더블클릭 후 [설치하기]'
Write-Host '    4) 화면에 나온 URL 을 폰 MacroDroid 에 입력'
Write-Host ''
