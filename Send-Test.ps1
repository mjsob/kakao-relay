<#
  Send-Test.ps1 - 수동 전송 테스트
    .\Send-Test.ps1 -Room "채팅방이름" -Text "테스트"          # 드라이런(전송 안 함)
    .\Send-Test.ps1 -Room "채팅방이름" -Text "테스트" -Live     # 실제 전송
#>
param(
    [Parameter(Mandatory)][string]$Room,
    [Parameter(Mandatory)][string]$Text,
    [switch]$Live,
    [switch]$AutoOpen,
    [switch]$KeepOpen,
    [switch]$HideMain,
    [ValidateSet('auto','enter','button')][string]$SendMethod = 'auto',
    [int[]]$SendButton = @(58,29),
    [ValidateSet('replacesel','clipboard','settext')][string]$Mode = 'replacesel'
)
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. "$PSScriptRoot\KakaoCore.ps1"

if ($Live) { Write-Host "[LIVE] 실제로 전송합니다." -ForegroundColor Red }
else       { Write-Host "[DRYRUN] 창만 찾고 전송은 하지 않습니다. 실제 전송은 -Live 옵션." -ForegroundColor Yellow }

$r = Send-KakaoMessage -Room $Room -Text $Text -Mode $Mode -DryRun:(-not $Live) -AutoOpen:$AutoOpen -SendButton $SendButton -KeepOpen:$KeepOpen -SendMethod $SendMethod -HideMain:$HideMain
$r | Format-List
if ($r.ok) { Write-Host "성공" -ForegroundColor Green } else { Write-Host "실패: $($r.error)" -ForegroundColor Red }
