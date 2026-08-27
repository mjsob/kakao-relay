<#
  설치하기.bat / 조작 창의 [설치하기] 가 호출한다.
  관리자 권한이 없으면 스스로 올려서 다시 실행한다.

  주의: 권한을 올리는 쪽(else 가지)이 사실상 항상 타는 경로다.
  조작 창은 일반 권한으로 뜨기 때문이다.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$setup = Join-Path $PSScriptRoot 'Setup.ps1'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    & $setup
    Write-Host ''
    Read-Host '엔터를 누르면 창이 닫힙니다'
} else {
    <#
      여기서 찍는 안내는 사실 아무도 못 읽는다. 바로 뒤에 UAC 가 화면을 덮고,
      승인하고 나면 이 창은 이미 사라진 뒤다.
      같은 안내가 조작 창에 미리 떠 있으므로 여기서는 짧게만 남긴다.
    #>
    Write-Host '관리자 권한 창이 뜨면 [예] 를 눌러주세요.' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList `
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$setup
    } catch {
        <#
          UAC 를 취소한 경우다. 조작 창은 이미 닫혔으므로 여기서 되돌려주지 않으면
          사용자는 갈 데가 없다.
        #>
        Write-Host ''
        Write-Host '관리자 권한 승인이 취소되어 설치를 진행하지 못했습니다.' -ForegroundColor Red
        Write-Host '방화벽 설정과 자동 실행 등록에는 관리자 권한이 필요합니다.' -ForegroundColor Red
        Write-Host ''
        Read-Host '엔터를 누르면 [카톡 릴레이] 창이 다시 열립니다'
        $bat = Join-Path (Split-Path $PSScriptRoot -Parent) 'KakaoRelay.bat'
        if (Test-Path $bat) { Start-Process $bat -WorkingDirectory (Split-Path $bat -Parent) }
    }
}
