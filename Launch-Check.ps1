<# 점검하기.bat 이 호출한다. #>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
& (Join-Path $PSScriptRoot 'Check-Ready.ps1')
Write-Host ''
Read-Host '엔터를 누르면 창이 닫힙니다'
