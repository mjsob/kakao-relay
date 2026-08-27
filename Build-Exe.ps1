<#
  Build-Exe.ps1 - 작업관리자에서 구분되도록 전용 실행 파일을 만든다.

  powershell.exe 로 띄우면 작업관리자에 'Windows PowerShell' 로만 보여
  다른 powershell 프로세스와 구분되지 않는다.
  PowerShell 을 프로세스 안에서 직접 호스팅하는 작은 exe 를 만들면
  이름과 아이콘이 우리 것으로 표시된다.

  Windows 에 기본 포함된 csc.exe 를 쓰므로 따로 설치할 것은 없다.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$csc = @(
  'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
  'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { Write-Host '  csc.exe 를 찾을 수 없습니다 (.NET Framework 4 필요)' -ForegroundColor Red; return }

$sma = Get-ChildItem "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation" `
        -Recurse -Filter 'System.Management.Automation.dll' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
if (-not $sma) { Write-Host '  System.Management.Automation.dll 을 찾을 수 없습니다' -ForegroundColor Red; return }

# 아이콘이 없으면 먼저 만든다
foreach ($i in 'relay.ico','watchdog.ico') {
    if (-not (Test-Path (Join-Path $PSScriptRoot $i))) { & (Join-Path $PSScriptRoot 'Make-Icons.ps1') ; break }
}

$template = @'
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;

// PowerShell 스크립트를 이 프로세스 안에서 실행한다.
// 별도 powershell.exe 를 띄우지 않으므로 작업관리자에 이 exe 이름으로만 보인다.
static class KakaoHost
{
    [STAThread]
    static int Main(string[] argv)
    {
        string dir    = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "__SCRIPT__");
        if (!File.Exists(script)) return 2;

        try
        {
            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;

            using (var rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions  = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (var ps = System.Management.Automation.PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    ps.Invoke();
                }
            }
        }
        catch (Exception ex)
        {
            try { File.AppendAllText(Path.Combine(dir, "host-error.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + ex + Environment.NewLine); }
            catch { }
            return 1;
        }
        return 0;
    }
}
'@

function Build([string]$Exe, [string]$Script, [string]$Icon) {
    $srcPath = Join-Path $env:TEMP ("kakaohost_" + [IO.Path]::GetFileNameWithoutExtension($Exe) + ".cs")
    $template.Replace('__SCRIPT__', $Script) | Set-Content $srcPath -Encoding UTF8

    $outPath  = Join-Path $PSScriptRoot $Exe
    $iconPath = Join-Path $PSScriptRoot $Icon

    # 실행 중이면 파일이 잠겨 덮어쓸 수 없다. 먼저 내린다.
    $procName = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $running  = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host "  $Exe 실행 중 - 종료 후 빌드" -ForegroundColor DarkGray
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $before = if (Test-Path $outPath) { (Get-Item $outPath).LastWriteTime } else { [datetime]::MinValue }
    if (Test-Path $outPath) { Remove-Item $outPath -Force -ErrorAction SilentlyContinue }

    $args = @(
        '/nologo', '/target:winexe', '/optimize+',
        "/out:$outPath",
        "/win32icon:$iconPath",
        "/reference:$sma",
        '/reference:System.dll',
        $srcPath
    )
    $out = & $csc @args 2>&1
    Remove-Item $srcPath -Force -ErrorAction SilentlyContinue

    # 파일이 '있다' 는 것만으로 성공이라 하면 안 된다.
    # 잠겨서 덮어쓰지 못하고 예전 파일이 남아 있어도 통과해버린다.
    if ((Test-Path $outPath) -and ((Get-Item $outPath).LastWriteTime -gt $before)) {
        Write-Host ("  {0,-26} {1:N0} bytes  <- {2}" -f $Exe, (Get-Item $outPath).Length, $Script) -ForegroundColor Green
    } elseif (Test-Path $outPath) {
        Write-Host "  $Exe 갱신되지 않음 (파일이 잠겨 있을 수 있음)" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    } else {
        Write-Host "  $Exe 빌드 실패" -ForegroundColor Red
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    }
}

Write-Host ''
Write-Host '  실행 파일 빌드' -ForegroundColor Cyan
Write-Host "  컴파일러: $csc" -ForegroundColor DarkGray
Build 'KakaoRelay.exe'         'Relay.ps1'    'relay.ico'
Build 'KakaoRelayWatchdog.exe' 'Watchdog.ps1' 'watchdog.ico'
Write-Host ''
