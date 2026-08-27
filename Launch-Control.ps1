<#
  Launch-Control.ps1 - KakaoRelay.bat 과 트레이 아이콘의 [열기] 가 호출한다.

  이 도구의 유일한 화면이다. 설치, 켜고 끄기, 점검, 설정, 기록 보기가 모두 여기 있다.
  트레이 메뉴에는 [열기] 와 [끝내기] 만 남겼다. 상주 아이콘의 작은 메뉴에
  기능을 늘어놓으면 어디에 무엇이 있는지 기억해야 하기 때문이다.

  예전에는 검은 콘솔에 숫자를 입력받았다. 처음 보는 사람에게 위압적이라
  작은 창으로 바꿨다. 확인도 따로 팝업을 띄우지 않고 버튼 자리에서 물어본다.

  -ConfirmQuit  트레이의 [끝내기] 가 쓴다. 창을 열자마자 끝내기 확인 화면을 보여 준다.
#>
param([switch]$ConfirmQuit)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# 콘솔은 숨긴다. GUI 뒤에 검은 창이 남아 있으면 지저분하다.
if (-not ('WinCtl' -as [type])) {
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class WinCtl {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")]   public static extern bool ReleaseCapture();
  [DllImport("user32.dll")]   public static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
}
'@
}
$con = [WinCtl]::GetConsoleWindow()
if ($con -ne [IntPtr]::Zero) { [void][WinCtl]::ShowWindow($con, 0) }

<#
  창은 하나만 띄운다.

  트레이 아이콘을 여러 번 누르면 같은 창이 계속 쌓였다.
  이름 있는 뮤텍스로 먼저 뜬 창이 있는지 보고, 이미 있으면 새로 만들지 않는다.

  먼저 뜬 창을 앞으로 꺼내는 일은 FindWindow 로 제목을 찾지 않는다.
  창 제목은 언제든 바뀔 수 있고, 아직 화면에 안 뜬 창은 찾지 못한다.
  대신 이름 있는 신호를 하나 두고, 먼저 뜬 쪽이 그 신호를 보고 스스로 앞으로 나온다.
  자기 창을 자기가 올리는 것이라 다른 프로세스가 끼어들 여지가 없다.
#>
$script:onlyOne  = New-Object System.Threading.Mutex($false, 'Local\KakaoRelayControlPanel')
$script:showSign = New-Object System.Threading.EventWaitHandle(
                       $false, [System.Threading.EventResetMode]::AutoReset,
                       'Local\KakaoRelayControlPanelShow')
if (-not $script:onlyOne.WaitOne(0)) {
    [void]$script:showSign.Set()
    exit
}

<#
  작업 표시줄 아이콘.

  그냥 두면 윈도우가 이 창을 powershell.exe 로 묶어서 파워셸 아이콘을 보여 준다.
  Form.Icon 을 지정해도 그룹 아이콘에 덮인다.
  전용 AppUserModelID 를 주면 별개의 앱으로 취급되어 Form.Icon 이 그대로 쓰인다.
  창을 하나라도 만들기 전에 호출해야 한다.
#>
if (-not ('AppIdNative' -as [type])) {
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class AppIdNative {
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
  public static extern void SetCurrentProcessExplicitAppUserModelID(string id);
}
'@
}
try { [AppIdNative]::SetCurrentProcessExplicitAppUserModelID('KakaoRelay.ControlPanel') } catch { }

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$port = 8787
$cfgPath = Join-Path $root 'config.json'
if (Test-Path $cfgPath) {
    try { $port = [int]((Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).port) } catch { }
}

# ---------- 색 ----------
$C = @{
    Bg      = [System.Drawing.Color]::FromArgb(251,250,247)
    Card    = [System.Drawing.Color]::FromArgb(255,255,255)
    Ink     = [System.Drawing.Color]::FromArgb(26,23,20)
    Muted   = [System.Drawing.Color]::FromArgb(110,101,90)
    Line    = [System.Drawing.Color]::FromArgb(228,221,208)
    Kakao   = [System.Drawing.Color]::FromArgb(254,229,0)
    KakaoIn = [System.Drawing.Color]::FromArgb(26,21,0)
    Ok      = [System.Drawing.Color]::FromArgb(30,107,73)
    Warn    = [System.Drawing.Color]::FromArgb(163,43,34)
    Amber   = [System.Drawing.Color]::FromArgb(138,90,0)
}
$F = @{
    Title = New-Object System.Drawing.Font('Malgun Gothic', 10.5, [System.Drawing.FontStyle]::Bold)
    State = New-Object System.Drawing.Font('Malgun Gothic', 14,   [System.Drawing.FontStyle]::Bold)
    Body  = New-Object System.Drawing.Font('Malgun Gothic', 9)
    Small = New-Object System.Drawing.Font('Malgun Gothic', 8.5)
    Btn   = New-Object System.Drawing.Font('Malgun Gothic', 10.5, [System.Drawing.FontStyle]::Bold)
}

<#
  표시 파일 두 개로 상태를 나눈다. 프로세스 사이에 신호를 주고받을 필요가 없고,
  컴퓨터를 껐다 켜도 남는다.

    paused.marker   문자 전달만 멈춤. 프로그램과 트레이 아이콘은 그대로.
    stopped.marker  프로그램을 아예 내림. 감시자가 이 파일을 보면 되살리지 않는다.
                    다음에 컴퓨터를 켜면 릴레이가 시작하면서 스스로 지운다.
#>
$PauseFile = Join-Path $root 'paused.marker'
$StopFile  = Join-Path $root 'stopped.marker'

<#
  현재 상태를 모은다. 이 함수가 느리면 창이 그대로 굳어 버린다(같은 스레드에서 돈다).
  그래서 느린 조회는 전부 걷어냈다.
    Get-ScheduledTask  약 1000 ms -> 작업 파일 Test-Path  약 25 ms
    Get-NetTCPConnection 약 670 ms -> TcpClient 로 직접 붙어 보기  약 1 ms
    Invoke-WebRequest    죽은 포트일 때 대기 시간을 다 쓴다 -> 붙었을 때만 호출
#>
function Test-Port([int]$p) {
    # 그냥 Connect 를 쓰면 방화벽이 응답을 버리는 경우 SYN 재시도로 2 초를 기다린다.
    # 대기 시간을 직접 잘라 낸다. 로컬이라 열려 있으면 20 ms 안에 붙는다.
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect([System.Net.IPAddress]::Loopback, $p, $null, $null)
        if ($a.AsyncWaitHandle.WaitOne(400)) { $c.EndConnect($a); $true } else { $false }
    } catch { $false } finally { $c.Close() }
}

<#
  예약 작업이 등록돼 있는지.

  작업은 Tasks 폴더에 파일로 남으므로 Test-Path 로 25 ms 만에 확인된다.
  다만 이 폴더는 관리자가 아니면 목록을 볼 수 없어, 정책에 따라 파일이 있는데도
  False 가 나올 수 있다. 그때만 느리지만 확실한 방법으로 한 번 더 확인한다.
  (없다고 잘못 판단하면 창이 '설치되지 않음' 을 띄운다)
#>
function Test-HasTask {
    if (Test-Path (Join-Path $env:SystemRoot 'System32\Tasks\KakaoRelay')) { return $true }
    return ($null -ne (Get-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue))
}

function Get-State {
    $listening = Test-Port $port
    $kk = $null; $up = $null; $dry = $false; $dryRoom = $null
    if ($listening) {
        try {
            $h = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 4).Content | ConvertFrom-Json
            $kk = [bool]$h.kakaoTalk; $up = $h.uptimeMin; $dry = [bool]$h.dryRun
            $dryRoom = $h.lastDryRoom
        } catch { }
    }
    [pscustomobject]@{
        Running = $listening
        Paused  = (Test-Path $PauseFile)
        Stopped = (Test-Path $StopFile)
        HasTask = (Test-HasTask)
        Kakao   = $kk
        Uptime  = $up
        DryRun  = $dry
        DryRoom = $dryRoom
    }
}

# ---------- 창 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '카톡 릴레이'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'CenterScreen'
<#
  창 치수는 여기 한 곳에서만 정한다.

  좁으면 답답해 보이므로 폭을 넉넉히 잡고, 안쪽 여백도 함께 키웠다.
  가로로 붙는 버튼 두 개는 사이를 GapS 만큼 띄우고 남은 폭을 반씩 나눈다.
#>
$L = @{
    W      = 412   # 창 폭
    Pad    = 24    # 좌우 안쪽 여백
    GapL   = 20    # 묶음과 묶음 사이
    GapS   = 10    # 같은 묶음 안
    GapT   = 16    # 버튼 아래 안내문
    GapSep = 12    # 구분선 위아래. 선 자체가 이미 묶음이 바뀐다는 신호라 GapL 을 또 주면 과하다
    BarH   = 52    # 제목 줄 높이
    CardPad= 18    # 카드 안쪽 여백
    BtnH   = 50    # 큰 버튼 높이
    ToolH  = 36    # 보조 버튼 높이. 큰 버튼(50)과 차이가 나야 급이 갈린다
    Bottom = 22    # 마지막 줄과 창 아래 사이
}
$L.Content = $L.W - $L.Pad * 2                      # 안쪽 내용 폭
$L.Half    = [int](($L.Content - $L.GapS) / 2)      # 나란히 놓는 버튼 하나의 폭
$L.CardTop = $L.BarH + 8

$form.ClientSize = New-Object System.Drawing.Size($L.W, 344)
$form.BackColor = $C.Bg
# TopMost 를 켜면 전체화면 게임 위에도 떠 버린다. 사용자가 직접 연 창이므로
# 처음 한 번만 앞으로 오면 되고, 그 뒤에는 다른 창에 가려도 된다.
$form.TopMost = $false
$form.ShowInTaskbar = $true
foreach ($ico in 'relay.ico', 'watchdog.ico') {
    $icoPath = Join-Path $root $ico
    if (Test-Path $icoPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($icoPath); break } catch { }
    }
}

# 모서리를 둥글게
$script:rr = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = 14
$script:rr.AddArc(0,0,$r,$r,180,90)
$script:rr.AddArc(($form.Width-$r),0,$r,$r,270,90)
$script:rr.AddArc(($form.Width-$r),($form.Height-$r),$r,$r,0,90)
$script:rr.AddArc(0,($form.Height-$r),$r,$r,90,90)
$script:rr.CloseFigure()
$form.Region = New-Object System.Drawing.Region($script:rr)
$form.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $pen = New-Object System.Drawing.Pen($C.Line, 1)
    $g.DrawPath($pen, $script:rr)
    $pen.Dispose()
})

# ---------- 타이틀바 ----------
$bar = New-Object System.Windows.Forms.Panel
$bar.Bounds = New-Object System.Drawing.Rectangle(0,0,$L.W,$L.BarH)
$bar.BackColor = $C.Bg
$form.Controls.Add($bar)

<#
  제목 옆에는 아무것도 두지 않는다.
  예전에는 카카오톡 노랑 점을 장식으로 찍었는데, 바로 아래 카드에 상태를 나타내는
  점이 또 있어서 둘 다 상태 표시로 읽혔다. 뜻이 있는 점은 하나만 둔다.
#>
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '카톡 릴레이'
$lblTitle.Font = $F.Title
$lblTitle.ForeColor = $C.Ink
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point($L.Pad,17)
$bar.Controls.Add($lblTitle)

<#
  닫기 버튼.

  글자 하나만 놓아 두면 장식인지 버튼인지 구분이 안 된다.
  마우스를 올렸을 때 바탕이 채워지게 해서 누를 수 있는 자리임을 보여 준다.
  색은 윈도우 제목 표시줄과 같은 빨강을 쓴다. 설명 없이도 닫기로 읽힌다.
  ✕ 는 글꼴에 맡기지 않고 직접 그린다. 글꼴마다 굵기와 위치가 달라 흐리게 보인다.
#>
$xRed  = [System.Drawing.Color]::FromArgb(0xE5,0x48,0x4D)
$xRedD = [System.Drawing.Color]::FromArgb(0xC1,0x35,0x3A)
$script:xState = 0      # 0 평소  1 올려 놓음  2 누름

$btnX = New-Object System.Windows.Forms.Panel
$btnX.Bounds = New-Object System.Drawing.Rectangle(($L.W - $L.Pad - 34),9,34,34)
$btnX.BackColor = $C.Bg
$btnX.Cursor = 'Hand'
$btnX.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    if ($script:xState -gt 0) {
        $bg = if ($script:xState -eq 2) { $xRedD } else { $xRed }
        $pp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $r = 10
        $pp.AddArc(0,0,$r,$r,180,90);        $pp.AddArc((34-$r),0,$r,$r,270,90)
        $pp.AddArc((34-$r),(34-$r),$r,$r,0,90); $pp.AddArc(0,(34-$r),$r,$r,90,90)
        $pp.CloseFigure()
        $br = New-Object System.Drawing.SolidBrush($bg)
        $g.FillPath($br, $pp); $br.Dispose(); $pp.Dispose()
    }
    $ink = if ($script:xState -gt 0) { [System.Drawing.Color]::White } else { $C.Muted }
    $pen = New-Object System.Drawing.Pen($ink, 1.6)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawLine($pen, 12, 12, 22, 22)
    $g.DrawLine($pen, 22, 12, 12, 22)
    $pen.Dispose()
})
$btnX.Add_MouseEnter({ $script:xState = 1; $btnX.Invalidate() })
$btnX.Add_MouseLeave({ $script:xState = 0; $btnX.Invalidate() })
$btnX.Add_MouseDown({ $script:xState = 2; $btnX.Invalidate() })
$btnX.Add_MouseUp({   $script:xState = 1; $btnX.Invalidate() })
$btnX.Add_Click({ $form.Close() })
$bar.Controls.Add($btnX)

# 창을 닫으면 릴레이까지 꺼지는 줄 알고 못 닫는 경우가 있다. 올려 두면 알려 준다.
$tip = New-Object System.Windows.Forms.ToolTip
$tip.InitialDelay = 300; $tip.ReshowDelay = 100
$tip.SetToolTip($btnX, '창 닫기  ·  릴레이는 계속 켜져 있습니다')

# 타이틀바를 잡고 창을 옮길 수 있게
$drag = {
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [void][WinCtl]::ReleaseCapture()
        [void][WinCtl]::SendMessage($form.Handle, 0xA1, 2, 0)   # WM_NCLBUTTONDOWN / HTCAPTION
    }
}
$bar.Add_MouseDown($drag)
$lblTitle.Add_MouseDown($drag)

# ---------- 상태 카드 ----------
$card = New-Object System.Windows.Forms.Panel
$card.Bounds = New-Object System.Drawing.Rectangle($L.Pad,$L.CardTop,$L.Content,104)
$card.BackColor = $C.Card
$card.Add_Paint({
    $g=$_.Graphics; $g.SmoothingMode='AntiAlias'
    $p=New-Object System.Drawing.Drawing2D.GraphicsPath
    $rad=10; $w=$card.Width-1; $h=$card.Height-1
    $p.AddArc(0,0,$rad,$rad,180,90); $p.AddArc(($w-$rad),0,$rad,$rad,270,90)
    $p.AddArc(($w-$rad),($h-$rad),$rad,$rad,0,90); $p.AddArc(0,($h-$rad),$rad,$rad,90,90); $p.CloseFigure()
    $b=New-Object System.Drawing.SolidBrush($C.Card); $g.FillPath($b,$p); $b.Dispose()
    $pen=New-Object System.Drawing.Pen($C.Line,1); $g.DrawPath($pen,$p); $pen.Dispose(); $p.Dispose()
})
$form.Controls.Add($card)

$sdot = New-Object System.Windows.Forms.Panel
$sdot.Bounds = New-Object System.Drawing.Rectangle($L.CardPad,26,12,12)
$sdot.BackColor = $C.Card
$script:dotColor = $C.Muted
$sdot.Add_Paint({
    $g=$_.Graphics; $g.SmoothingMode='AntiAlias'
    $b=New-Object System.Drawing.SolidBrush($script:dotColor)
    $g.FillEllipse($b,0,0,11,11); $b.Dispose()
})
$card.Controls.Add($sdot)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Font = $F.State
$lblState.ForeColor = $C.Ink
$lblState.AutoSize = $true
$lblState.Location = New-Object System.Drawing.Point(($L.CardPad + 20),$L.CardPad)
$card.Controls.Add($lblState)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Font = $F.Body
$lblSub.ForeColor = $C.Muted
# 고정 높이를 주면 한 줄짜리 글에도 두 줄만큼 빈자리가 남는다. 글에 맞춰 늘어나게 한다.
$lblSub.AutoSize = $true
$lblSub.MaximumSize = New-Object System.Drawing.Size(($L.Content - $L.CardPad * 2 - 20),0)
$lblSub.Location = New-Object System.Drawing.Point(($L.CardPad + 20),50)
$card.Controls.Add($lblSub)

# ---------- 버튼 ----------
function New-FlatButton {
    param([string]$Text,[int]$Y,[bool]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Font = $F.Btn
    $b.Bounds = New-Object System.Drawing.Rectangle($L.Pad,$Y,$L.Content,$L.BtnH)
    $b.FlatStyle = 'Flat'
    $b.Cursor = 'Hand'
    if ($Primary) {
        $b.BackColor = $C.Kakao; $b.ForeColor = $C.KakaoIn
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240,216,0)
    } else {
        $b.BackColor = $C.Card; $b.ForeColor = $C.Ink
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $C.Line
        $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(244,241,233)
    }
    return $b
}

$btnMain = New-FlatButton '문자 전달 다시 시작' 174 $true   # 실제 문구는 Sync-Ui 가 상황에 맞게 덮어쓴다
$btnStop = New-FlatButton '문자 전달 일시 중지' 228 $false
# 상태를 확인하기 전에는 어느 버튼이 맞는지 모른다. 기본값(보임)으로 두면
# 켜기와 끄기가 같이 나타났다가 하나가 사라지는 깜빡임이 생긴다.
$btnMain.Visible = $false; $btnStop.Visible = $false
$form.Controls.Add($btnMain)
$form.Controls.Add($btnStop)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Font = $F.Small
$lblHint.ForeColor = $C.Muted
$lblHint.AutoSize = $true
$lblHint.MaximumSize = New-Object System.Drawing.Size($L.Content,0)
$lblHint.Location = New-Object System.Drawing.Point($L.Pad,284)
$form.Controls.Add($lblHint)

<#
  프로그램 자체를 내리는 자리.

  '문자 전달 일시 중지' 와 헷갈리면 안 되는 동작이다.
  처음에는 작은 글씨 링크로 뒀는데 있는 줄도 모른다는 지적을 받아 버튼으로 바꿨다.
  대신 위 버튼들보다 낮고(ToolH) 글자를 굵게 하지 않아 급을 낮췄고,
  구분선으로 갈라 놓았으며, 마우스를 올리면 빨갛게 바뀐다.
#>
$script:quitLinkOn = $false
$script:toolsOn    = $false

<#
  보조 도구.

  예전에는 폴더에 점검하기.bat, 설정편집.bat 이 따로 있었다.
  실행 파일이 여럿 널려 있으면 무엇을 눌러야 할지 알기 어려우므로
  들어오는 문을 이 창 하나로 모으고, 도구는 여기에 붙였다.
#>
function New-ToolButton([string]$Text, [int]$X, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Font = $F.Body
    $b.Bounds = New-Object System.Drawing.Rectangle($X,346,$W,$L.ToolH)
    $b.FlatStyle = 'Flat'
    $b.Cursor = 'Hand'
    $b.BackColor = $C.Card
    $b.ForeColor = $C.Ink
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $C.Line
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(244,241,233)
    $b.Visible = $false
    $form.Controls.Add($b)
    return $b
}
$colL = $L.Pad
$colR = $L.Pad + $L.Half + $L.GapS
$btnCheck = New-ToolButton '점검하기'   $colL $L.Half
$btnCfg   = New-ToolButton '설정 편집'  $colR $L.Half
$btnLog   = New-ToolButton '기록 폴더 열기' $colL $L.Half
$btnTerm  = New-ToolButton '실시간 보기' $colR $L.Half

# 위 버튼들과 다른 성격의 동작이라는 걸 선으로 갈라 놓는다
$sep = New-Object System.Windows.Forms.Panel
$sep.Bounds = New-Object System.Drawing.Rectangle($L.Pad,330,$L.Content,1)
$sep.BackColor = $C.Line
$sep.Visible = $false
$form.Controls.Add($sep)

$quitIdle = [System.Drawing.Color]::FromArgb(253,246,245)
$btnQuit = New-Object System.Windows.Forms.Button
$btnQuit.Text = '프로그램 완전히 끝내기'
$btnQuit.Font = $F.Body                  # 위 버튼보다 작고 굵지 않게 - 주된 동작이 아니다
$btnQuit.Bounds = New-Object System.Drawing.Rectangle($L.Pad,342,$L.Content,$L.ToolH)
$btnQuit.FlatStyle = 'Flat'
$btnQuit.Cursor = 'Hand'
$btnQuit.BackColor = $C.Card
$btnQuit.ForeColor = $C.Muted
$btnQuit.FlatAppearance.BorderSize = 1
$btnQuit.FlatAppearance.BorderColor = $C.Line
$btnQuit.FlatAppearance.MouseOverBackColor = $quitIdle
$btnQuit.Add_MouseEnter({
    $btnQuit.ForeColor = $C.Warn
    $btnQuit.FlatAppearance.BorderColor = $C.Warn
})
$btnQuit.Add_MouseLeave({
    $btnQuit.ForeColor = $C.Muted
    $btnQuit.FlatAppearance.BorderColor = $C.Line
})
$btnQuit.Visible = $false
$form.Controls.Add($btnQuit)

# 확인용 버튼 (중지 누르면 이 자리에 나타난다 - 팝업을 띄우지 않는다)
$btnYes = New-FlatButton '네, 끝냅니다' 228 $false   # 실제 문구는 Show-QuitConfirm 이 덮어쓴다
$btnYes.ForeColor = $C.Warn
$btnYes.Bounds = New-Object System.Drawing.Rectangle($L.Pad,228,($L.Content - 130 - $L.GapS),$L.BtnH)
$btnNo  = New-FlatButton '취소' 228 $false
$btnNo.Bounds  = New-Object System.Drawing.Rectangle(($L.W - $L.Pad - 130),228,130,$L.BtnH)
$btnYes.Visible = $false; $btnNo.Visible = $false
$form.Controls.Add($btnYes); $form.Controls.Add($btnNo)

# ---------- 상태 반영 ----------
<#
  버튼 개수에 맞춰 창 높이를 조절한다.
  할 수 없는 동작의 버튼을 비활성으로 남겨 두면 무엇을 눌러야 할지 헷갈린다.
  지금 할 수 있는 것만 보여 준다.
#>
<#
  세로 배치를 위에서 아래로 한 번에 계산한다.

  간격 규칙은 하나다. 묶음 사이 16, 같은 묶음 안 8, 버튼 아래 안내문 14.
  글의 높이는 상태마다 다르므로 고정값을 쓰지 않고 그때그때 재서 쌓는다.
  (고정 높이를 주면 한 줄짜리 안내문 아래에 두 줄만큼 빈자리가 남는다)

  창이 아직 안 떠 있으면 Control.Visible 게터가 항상 False 를 주므로
  무엇을 보일지는 따로 둔 변수로 판단한다.
#>
$script:showMain = $false
$script:showStop = $false
# 'normal' 일 때만 주기 갱신을 돌린다. 확인 화면이나 작업 중에 덮어쓰면 안 된다.
$script:uiMode = 'normal'

function Set-Layout {
    param([switch]$Confirm)

    # --- 상태 카드: 글자 높이에 맞춘다 ---
    $sdot.Top    = $L.CardPad + [int](($lblState.Height - $sdot.Height) / 2)
    $lblSub.Top  = $L.CardPad + $lblState.Height + 4
    $card.Height = $lblSub.Top + $lblSub.Height + $L.CardPad

    $y = $card.Bottom + $L.GapL

    # --- 큰 버튼 ---
    $showMain = (-not $Confirm) -and $script:showMain
    $showStop = (-not $Confirm) -and $script:showStop
    $btnYes.Visible  = [bool]$Confirm
    $btnNo.Visible   = [bool]$Confirm
    $btnMain.Visible = $showMain
    $btnStop.Visible = $showStop

    if ($Confirm) {
        $btnYes.Top = $y; $btnNo.Top = $y
        $y += $btnYes.Height + $L.GapT
    } else {
        if ($showMain) { $btnMain.Top = $y; $y += $btnMain.Height + $L.GapS }
        if ($showStop) { $btnStop.Top = $y; $y += $btnStop.Height + $L.GapS }
        if ($showMain -or $showStop) { $y += $L.GapT - $L.GapS }
    }

    # --- 안내문 ---
    $lblHint.Top = $y
    $y = $lblHint.Top + $lblHint.Height

    # --- 구분선 아래: 보조 도구, 그리고 끝내기 ---
    $showTools = (-not $Confirm) -and $script:toolsOn
    $showQuit  = (-not $Confirm) -and $script:quitLinkOn
    $sep.Visible      = ($showTools -or $showQuit)
    $btnCheck.Visible = $showTools
    $btnCfg.Visible   = $showTools
    $btnLog.Visible   = $showTools
    $btnTerm.Visible  = $showTools
    $btnQuit.Visible  = $showQuit

    if ($showTools -or $showQuit) {
        $y += $L.GapSep
        $sep.Top = $y
        $y += $L.GapSep
        if ($showTools) {
            $btnCheck.Top = $y; $btnCfg.Top  = $y
            $y += $btnCheck.Height + $L.GapS
            $btnLog.Top   = $y; $btnTerm.Top = $y
            $y += $btnLog.Height
        }
        if ($showQuit) {
            if ($showTools) { $y += $L.GapL }   # 성격이 다른 동작이라 한 칸 띄운다
            $btnQuit.Top = $y
            $y += $btnQuit.Height
        }
    }

    $h = $y + $L.Bottom
    if ($form.ClientSize.Height -ne $h) {
        $form.ClientSize = New-Object System.Drawing.Size($L.W, $h)
        $script:rr = New-Object System.Drawing.Drawing2D.GraphicsPath
        $rad = 14
        $script:rr.AddArc(0,0,$rad,$rad,180,90)
        $script:rr.AddArc(($form.Width-$rad),0,$rad,$rad,270,90)
        $script:rr.AddArc(($form.Width-$rad),($form.Height-$rad),$rad,$rad,0,90)
        $script:rr.AddArc(0,($form.Height-$rad),$rad,$rad,90,90)
        $script:rr.CloseFigure()
        $form.Region = New-Object System.Drawing.Region($script:rr)
        $form.Invalidate()
    }
}

<#
  대기 시간을 사람이 읽는 단위로 바꾼다.
  분으로만 세면 하루만 지나도 '1440분째 대기 중' 이 된다.

  주의: 파워셸은 한글도 변수 이름으로 받는다. "$m분째" 라고 쓰면 $m 이 아니라
  '$m분째' 라는 변수를 찾아 빈 값이 나온다. 반드시 "${m}분째" 로 감싼다.
  또 [int] 는 자르는 게 아니라 반올림한다. 1439/60 이 24 가 되어 '24시간 59분' 이 나온다.
  나눗셈은 [Math]::Floor 로 내림해야 한다.
#>
function Format-Uptime($min) {
    if ($null -eq $min) { return '' }
    $m = [int]$min
    if ($m -lt 1)    { return '방금 시작' }
    if ($m -lt 60)   { return "${m}분째 대기 중" }
    if ($m -lt 1440) {
        $h = [Math]::Floor($m / 60); $r = $m % 60
        if ($r -eq 0) { return "${h}시간째 대기 중" }
        return "${h}시간 ${r}분째 대기 중"
    }
    $d = [Math]::Floor($m / 1440); $h = [Math]::Floor(($m % 1440) / 60)
    if ($h -eq 0) { return "${d}일째 대기 중" }
    return "${d}일 ${h}시간째 대기 중"
}

function Sync-Ui {
    $s = Get-State
    foreach ($b in @($btnMain,$btnStop,$btnCheck,$btnCfg,$btnLog,$btnTerm,$btnQuit)) { $b.Enabled = $true }
    # 끝내기는 프로그램이 떠 있을 때만, 도구는 설치가 끝난 뒤에만 의미가 있다
    $script:quitLinkOn = $s.Running
    $script:toolsOn    = $s.HasTask
    # 큰 버튼이 상황에 따라 설치·켜기·시험 모드 해제를 맡는다. 무엇을 할지 여기서 정한다.
    $script:mainAction = if ($s.HasTask) { 'start' } else { 'install' }
    if (-not $s.HasTask) {
        $script:dotColor = $C.Warn
        $lblState.Text = '설치되지 않음'
        $lblSub.Text   = '아래 버튼을 누르면 설치가 시작됩니다.'
        $lblHint.Text  = "설치에는 관리자 권한이 필요합니다.`r`n창이 뜨면 [예] 를 눌러 주세요."
        $btnMain.Text = '설치하기'
        $script:showMain = $true; $script:showStop = $false
        Set-Layout
    } elseif ($s.Paused) {
        $script:dotColor = $C.Warn
        $lblState.Text = '일시 중지'
        $lblSub.Text   = '문자를 받아도 카카오톡으로 보내지 않습니다.'
        $lblHint.Text  = "카카오톡과 이 프로그램은 그대로 켜져 있습니다.`r`n도착한 문자는 보내지 않고 기록에만 남습니다."
        $btnMain.Text = '문자 전달 다시 시작'
        $script:showMain = $true; $script:showStop = $false
        Set-Layout
    } elseif ($s.Running) {
        $script:dotColor = $C.Ok
        $lblState.Text = '전달 중'
        $k = if ($s.Kakao -eq $true) { '카카오톡 연결됨' } elseif ($s.Kakao -eq $false) { '카카오톡이 꺼져 있어 전달 불가' } else { '' }
        $u = Format-Uptime $s.Uptime
        $lblSub.Text = (@($k,$u) | Where-Object { $_ }) -join '  ·  '
        <#
          시험 모드는 방을 찾고 창을 여는 데까지 다 해 보고 마지막 전송만 건너뛴다.
          그러니 '어디로 갈 뻔했는지' 를 여기서 보여 줘야 확인이 끝난다.
          예전에는 그 정보가 로그 한 줄에만 있었고, 해제하려면 메모장에서
          JSON 을 고쳐야 했다. 둘 다 이 창에서 처리한다.
        #>
        if ($s.DryRun) {
            $script:dotColor = $C.Amber
            $lblState.Text = '시험 모드'
            $script:mainAction = 'undry'
            $btnMain.Text = '시험 모드 해제'
            $script:showMain = $true; $script:showStop = $false
            $lblHint.Text = if ($s.DryRoom) {
                "마지막 문자가 향한 채팅방: [$($s.DryRoom)]`r`n맞으면 아래 버튼을 눌러 실제 전송을 켜세요."
            } else {
                "카카오톡으로 실제 전송하지 않습니다.`r`n문자를 한 통 보내 어느 채팅방으로 갈지 먼저 확인하세요."
            }
        } else {
            $lblHint.Text = "문자를 보내면 카카오톡으로 전달됩니다.`r`n이 창은 닫아도 계속 동작합니다."
            $script:showMain = $false; $script:showStop = $true
        }
        Set-Layout
    } elseif ($s.Stopped) {
        $script:dotColor = $C.Muted
        $lblState.Text = '실행 중 아님'
        $lblSub.Text   = '릴레이가 실행되고 있지 않습니다.'
        $lblHint.Text  = "컴퓨터를 다시 켜면 저절로 실행됩니다.`r`n지금 바로 쓰려면 아래 버튼을 누르세요."
        $btnMain.Text = '지금 다시 실행'
        $script:showMain = $true; $script:showStop = $false
        Set-Layout
    } else {
        $script:dotColor = $C.Amber
        $lblState.Text = '멈춤 (복구 중)'
        $lblSub.Text   = '1분 안에 저절로 다시 켜집니다.'
        $lblHint.Text  = '기다리기 싫으면 아래 버튼을 누르세요.'
        $btnMain.Text = '지금 켜기'
        $script:showMain = $true; $script:showStop = $false
        Set-Layout
    }
    $script:uiMode = 'normal'
    $sdot.Invalidate()
    $form.Refresh()
}

function Set-Busy([string]$msg) {
    $script:uiMode = 'busy'
    $script:dotColor = $C.Amber
    $lblState.Text = $msg
    $lblSub.Text = '잠시만 기다려 주세요.'
    <#
      작업 중에는 버튼을 잠그기만 하고 감추지 않는다.
      감추면 배치가 다시 계산되면서 창 높이가 491 -> 295 로 줄었다가 되돌아온다.
      CenterScreen 은 처음 한 번만 위치를 잡으므로 창 아랫변이 그만큼 튀어,
      진행 표시가 아니라 오작동으로 보인다.
    #>
    foreach ($b in @($btnMain,$btnStop,$btnCheck,$btnCfg,$btnLog,$btnTerm,$btnQuit)) { $b.Enabled = $false }
    Set-Layout
    $sdot.Invalidate(); $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

<#
  릴레이를 껐다 켠다.

  설정 파일은 릴레이가 시작할 때 한 번만 읽는다. 그래서 값을 고쳐도
  다시 띄우기 전에는 반영되지 않는다. 예전에는 그 방법이
  [프로그램 완전히 끝내기] -> [지금 다시 실행] 뿐이었는데,
  설정을 반영하려고 누를 이름이 아니라서 아무도 찾지 못했다.

  끝내기와 달리 stopped.marker 를 만들지 않는다. 자동 복구는 그대로 살아 있어야 한다.
#>
function Restart-Relay {
    Get-Process KakaoRelay -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($o in @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                      Where-Object { $_.LocalPort -eq $port }).OwningProcess)) {
        if ($o) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 600
    Start-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 900
        [System.Windows.Forms.Application]::DoEvents()
        if ((Get-State).Running) { break }
    }
}

$script:mainAction = 'start'

$btnMain.Add_Click({
    <#
      설치는 이 창에서 할 수 없다. 관리자 권한이 필요하고 진행 상황을 글로 보여 줘야 해서
      콘솔 창을 따로 띄운다. 그쪽이 화면을 이어받으므로 이 창은 닫는다.
    #>
    <#
      시험 모드 해제.
      설정 파일에서 dryRun 만 false 로 바꾸고 릴레이를 다시 띄운다.
      사용자가 메모장에서 JSON 을 만질 이유가 이거 하나였으므로, 이걸 버튼으로 빼면
      설정 편집은 별칭 등록용 선택 사항으로 내려간다.
    #>
    if ($script:mainAction -eq 'undry') {
        $cfgFile = Join-Path $root 'config.json'
        try {
            $j = Get-Content $cfgFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $j.dryRun = $false
            $j | ConvertTo-Json -Depth 6 | Set-Content $cfgFile -Encoding UTF8 -ErrorAction Stop
        } catch {
            $script:dotColor = $C.Warn
            $lblState.Text = '설정을 바꾸지 못했습니다'
            $lblSub.Text   = '설정 파일을 확인해 주세요.'
            $sdot.Invalidate(); $form.Refresh()
            return
        }
        Set-Busy '실제 전송 켜는 중'
        Restart-Relay
        Sync-Ui
        return
    }

    if ($script:mainAction -eq 'install') {
        $setup = Join-Path $root 'Launch-Setup.ps1'
        if (Test-Path $setup) {
            Start-Process powershell.exe -ArgumentList @(
                '-NoProfile','-NoLogo','-ExecutionPolicy','Bypass','-File',('"' + $setup + '"')
            ) -WorkingDirectory $root | Out-Null
            $form.Close()
        }
        return
    }

    Set-Busy '다시 시작하는 중'
    Remove-Item $PauseFile -Force -ErrorAction SilentlyContinue
    Remove-Item $StopFile  -Force -ErrorAction SilentlyContinue
    foreach ($t in 'KakaoRelay','KakaoRelayWatchdog') {
        Enable-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Get-State).Running) {
        Start-ScheduledTask -TaskName 'KakaoRelay' -ErrorAction SilentlyContinue
        for ($i=0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 900
            [System.Windows.Forms.Application]::DoEvents()
            if ((Get-State).Running) { break }
        }
    }
    Start-Sleep -Milliseconds 600
    Sync-Ui
    if (-not (Get-State).Running) {
        $lblState.Text = '시작하지 못했습니다'
        $lblSub.Text = '[점검하기] 로 확인해 보세요.'
        $script:dotColor = $C.Warn; $sdot.Invalidate()
    }
})

$btnCheck.Add_Click({
    $chk = Join-Path $root 'Launch-Check.ps1'
    if (-not (Test-Path $chk)) { return }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-NoLogo','-ExecutionPolicy','Bypass','-File',('"' + $chk + '"')
    ) -WorkingDirectory $root | Out-Null
})

<#
  설정 편집은 두 걸음이다.
    1) 누르면 메모장이 열리고, 버튼 이름이 [설정 적용] 으로 바뀐다
    2) 고치고 저장한 뒤 다시 누르면 릴레이를 껐다 켜서 반영한다
  버튼을 하나 더 늘리지 않으면서 '고치면 반영해야 한다' 는 걸 그 자리에서 알려 준다.
#>
$script:cfgEditing = $false
$btnCfg.Add_Click({
    $cfgFile = Join-Path $root 'config.json'
    if (-not (Test-Path $cfgFile)) { return }

    if (-not $script:cfgEditing) {
        Start-Process notepad.exe $cfgFile
        $script:cfgEditing = $true
        $btnCfg.Text = '설정 적용'
        $btnCfg.ForeColor = $C.Amber
        $lblHint.Text = "메모장에서 고치고 저장한 뒤 [설정 적용] 을 누르세요.`r`n누르기 전까지는 예전 설정으로 동작합니다."
        Set-Layout
        return
    }

    # 저장한 내용이 올바른지 먼저 본다. 쉼표 하나만 빠져도 릴레이가 못 뜬다.
    try {
        $null = Get-Content $cfgFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $script:dotColor = $C.Warn
        $lblState.Text = '설정 파일에 문제가 있습니다'
        $lblSub.Text   = '고친 부분을 되돌린 뒤 다시 눌러 주세요.'
        $lblHint.Text  = '쉼표나 따옴표가 빠졌을 수 있습니다. 지금 적용하면 릴레이가 뜨지 못합니다.'
        $sdot.Invalidate(); Set-Layout; $form.Refresh()
        return
    }

    Set-Busy '설정 적용하는 중'
    Restart-Relay
    $script:cfgEditing = $false
    $btnCfg.Text = '설정 편집'
    $btnCfg.ForeColor = $C.Ink
    Sync-Ui
})

<#
  기록 파일을 메모장으로 열지 않는다.

  메모장이 파일을 잡고 있으면 릴레이가 로그를 못 쓴다. 예전에 그것 때문에
  요청 처리가 통째로 죽은 적이 있어 지금은 세 번 재시도하는데,
  세 번 다 실패하면 그 줄은 조용히 사라진다. 보려고 연 창이 보려던 것을 지운다.

  폴더에서 파일을 선택된 상태로 띄우면 파일을 열지 않으므로 잠기지 않고,
  크기가 얼마든 즉시 뜨며, 그대로 끌어다 보낼 수 있다.
#>
$btnLog.Add_Click({
    $logFile = Join-Path $root 'relay.log'
    if (Test-Path $logFile) { Start-Process explorer.exe "/select,`"$logFile`"" }
    else { Start-Process explorer.exe $root }
})

# 오가는 문자를 실시간으로 보여 주는 창. 닫아도 릴레이는 계속 동작한다.
$btnTerm.Add_Click({
    $viewer = Join-Path $root 'Show-Log.ps1'
    if (-not (Test-Path $viewer)) { return }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile','-NoLogo','-ExecutionPolicy','Bypass','-File',('"' + $viewer + '"')
    ) -WorkingDirectory $root | Out-Null
})

<#
  일시 중지는 확인을 묻지 않는다.
  한 번 더 누르면 그대로 돌아오고, 멈춰 있다는 사실이 창과 트레이 아이콘에 계속 보인다.
  되돌리기 쉬운 일에 확인 화면을 끼우면 오히려 큰일처럼 보인다.
  끝내기는 되돌리기 어려우므로 그쪽만 확인을 남겼다.
#>
$btnStop.Add_Click({
    Set-Busy '멈추는 중'
    New-Item $PauseFile -ItemType File -Force | Out-Null
    Start-Sleep -Milliseconds 900
    Sync-Ui
})

<#
  끝내기 확인 화면.
  트레이의 [끝내기] 도 이 화면을 쓰므로 창이 뜨기 전에도 부를 수 있어야 한다.
  (Button.PerformClick 은 창이 아직 안 떠 있으면 아무 일도 하지 않는다)
#>
function Show-QuitConfirm {
    $script:uiMode = 'confirm'
    $script:dotColor = $C.Warn
    $lblState.Text = '프로그램을 끝낼까요?'
    $lblSub.Text   = '작업 표시줄의 트레이 아이콘도 함께 사라집니다.'
    $lblHint.Text  = "컴퓨터를 다시 켜면 저절로 실행됩니다.`r`n그 전에 다시 쓰려면 바탕 화면의 [카톡 릴레이] 를 여세요."
    $btnYes.Text = '네, 끝냅니다'
    Set-Layout -Confirm
}
$btnQuit.Add_Click({ Show-QuitConfirm })
$btnNo.Add_Click({ Sync-Ui })

<#
  끌 때 프로세스를 죽이지 않는다.
  죽이면 트레이 아이콘까지 사라져서 다시 켤 방법이 없어진다.
  표시 파일만 만들면 릴레이가 문자 전달을 멈추고, 트레이 아이콘은 회색으로 남는다.
#>
# 확인 화면은 끝내기 전용이다 (일시 중지는 바로 실행한다)
$btnYes.Add_Click({
    Set-Busy '프로그램 끝내는 중'
    # 표시 파일을 먼저 만들어야 자동 복구가 곧바로 되살리지 않는다
    New-Item $StopFile -ItemType File -Force | Out-Null
    Get-Process KakaoRelay -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # 포트를 아직 물고 있는 프로세스가 남아 있으면 같이 정리한다
    foreach ($o in @((Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                      Where-Object { $_.LocalPort -eq $port }).OwningProcess)) {
        if ($o) { Stop-Process -Id $o -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
    Sync-Ui
})

<#
  창을 띄우기 전에 상태를 다 맞춰 놓는다.
  Shown 안에서 맞추면 잘못된 배치가 한 번 그려졌다가 고쳐지는 게 눈에 보인다.
  (켜기 · 끄기 두 버튼이 같이 떴다가 하나로 줄고, 창 높이도 따라 튄다)
  Get-State 가 0.2 초 안쪽이라 미리 해도 창이 늦게 뜨는 느낌은 없다.
#>
Sync-Ui

# 트레이의 [끝내기] 로 열린 경우, 창을 보여 주기 전에 확인 화면으로 맞춰 둔다
if ($ConfirmQuit -and (Get-State).Running) { Show-QuitConfirm }

<#
  나중에 실행된 쪽이 보낸 신호를 받아 이 창을 앞으로 꺼낸다.
  화면을 다시 그리지 않으므로 확인 화면 중이어도 안전하다.
#>
<#
  창이 열려 있는 동안 상태를 계속 따라가게 한다.

  예전에는 열 때 한 번만 읽어서, '몇 분째 대기 중' 이 창을 열어 둔 채로는
  영영 그대로였고 카카오톡을 켜거나 꺼도 표시가 바뀌지 않았다.
  살아 있는 상태를 보여 주는 창인데 사진 한 장을 붙여 둔 셈이었다.

  Get-State 가 0.2 초 안쪽이라 5초마다 읽어도 부담이 없다.
  다만 확인 화면·작업 중·설정 편집 중에는 화면을 건드리면 안 되므로 건너뛴다.
#>
$refresh = New-Object System.Windows.Forms.Timer
$refresh.Interval = 8000
$refresh.Add_Tick({
    if ($script:uiMode -ne 'normal') { return }
    if ($script:cfgEditing) { return }
    try { Sync-Ui } catch { }
})
$refresh.Start()

$raise = New-Object System.Windows.Forms.Timer
$raise.Interval = 400
$raise.Add_Tick({
    if ($script:showSign.WaitOne(0)) {
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $form.Activate(); $form.BringToFront()
    }
})
$raise.Start()

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
