<#
  KakaoCore.ps1 - PC 카카오톡 Win32 제어 코어
  의존성 없음 (PowerShell 5.1 내장 기능만 사용)
#>

if (-not ('KK' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class KK {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessageStr(IntPtr h, uint msg, IntPtr wp, string lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessageTxt(IntPtr h, uint msg, IntPtr wp, StringBuilder lp);
  [DllImport("user32.dll", EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", EntryPoint="PostMessageW")]
    public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

  public static string Cls(IntPtr h){ var b=new StringBuilder(256); GetClassName(h,b,256); return b.ToString(); }
  public static string Txt(IntPtr h){ var b=new StringBuilder(1024); GetWindowTextW(h,b,1024); return b.ToString(); }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetFocus();
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

  public static string EditTxt(IntPtr h){ var b=new StringBuilder(4096); SendMessageTxt(h, 0x000D, (IntPtr)4096, b); return b.ToString(); }
}
'@
}

# --- Win32 상수 ---
$Script:WM_SETTEXT = 0x000C
$Script:WM_PASTE   = 0x0302
$Script:WM_KEYDOWN = 0x0100
$Script:WM_KEYUP   = 0x0101
$Script:WM_CHAR    = 0x0102
$Script:VK_RETURN  = 0x0D
$Script:WM_CLOSE   = 0x0010
$Script:EM_SETSEL  = 0x00B1
$Script:EM_REPLACESEL = 0x00C2

function Get-KakaoProcessIds {
    @(Get-Process -Name KakaoTalk -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
}

# 카카오톡 프로세스 소유의 최상위 창 전부
function Get-KakaoTopWindows {
    $pids = Get-KakaoProcessIds
    if ($pids.Count -eq 0) { return @() }
    $script:__tops = New-Object System.Collections.ArrayList
    $cb = [KK+EnumProc]{
        param($h, $l)
        [uint32]$p = 0
        [void][KK]::GetWindowThreadProcessId($h, [ref]$p)
        if ($pids -contains [int]$p) {
            $r = New-Object KK+RECT
            [void][KK]::GetWindowRect($h, [ref]$r)
            [void]$script:__tops.Add([pscustomobject]@{
                Hwnd    = $h
                Class   = [KK]::Cls($h)
                Title   = [KK]::Txt($h)
                Visible = [KK]::IsWindowVisible($h)
                Rect    = $r
            })
        }
        return $true
    }
    [void][KK]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:__tops.ToArray()
}

# 특정 창의 모든 자손 창 수집 (EnumChildWindows 는 이미 재귀적이므로 한 번만 호출)
function Get-KakaoChildWindows {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $handles = New-Object System.Collections.ArrayList
    $cb = [KK+EnumProc]{
        param($c, $l)
        [void]$handles.Add($c)
        return $true
    }
    [void][KK]::EnumChildWindows($Hwnd, $cb, [IntPtr]::Zero)

    $seen = New-Object 'System.Collections.Generic.HashSet[int64]'
    $out  = New-Object System.Collections.ArrayList
    foreach ($c in $handles) {
        if (-not $seen.Add([int64]$c)) { continue }
        $r = New-Object KK+RECT
        [void][KK]::GetWindowRect($c, [ref]$r)
        [void]$out.Add([pscustomobject]@{
            Hwnd    = $c
            Class   = [KK]::Cls($c)
            Title   = [KK]::Txt($c)
            Visible = [KK]::IsWindowVisible($c)
            Rect    = $r
        })
    }
    return $out.ToArray()
}

<#
  메인창 판별.
  주의: 카톡은 '채팅방 창'도 메인창과 동일한 클래스(EVA_Window_Dblclk)를 쓴다.
  따라서 클래스나 제목만으로는 구분할 수 없고, 메인창에만 있는 자식 컨트롤
  (ChatRoomListCtrl / OnlineMainView)로 판별해야 한다.
#>
function Get-KakaoMainWindow {
    # 카톡을 트레이로 내리면 메인창은 살아있지만 Visible=False 가 된다.
    # 따라서 Visible 로 거르면 안 되고, 메인창에만 있는 자식 컨트롤로 판별한다.
    $cands = @(Get-KakaoTopWindows | Where-Object { $_.Class -eq 'EVA_Window_Dblclk' })
    foreach ($c in $cands) {
        $kids = Get-KakaoChildWindows -Hwnd $c.Hwnd
        if ($kids | Where-Object { $_.Title -like 'ChatRoomListCtrl*' -or $_.Title -like 'OnlineMainView*' }) {
            return $c
        }
    }
    return ($cands | Where-Object { $_.Title -eq '카카오톡' } | Select-Object -First 1)
}

# 채팅방 창 = 메인창이 아니면서 RichEdit 입력창을 가진 최상위 창
function Get-KakaoRoomWindows {
    $main = Get-KakaoMainWindow
    $mh   = if ($main) { [int64]$main.Hwnd } else { 0 }
    $out  = New-Object System.Collections.ArrayList
    foreach ($t in (Get-KakaoTopWindows | Where-Object { $_.Visible -and $_.Title })) {
        if ([int64]$t.Hwnd -eq $mh) { continue }
        $kids = Get-KakaoChildWindows -Hwnd $t.Hwnd
        if ($kids | Where-Object { $_.Class -match 'RICHEDIT' }) { [void]$out.Add($t) }
    }
    return $out.ToArray()
}

<#
  열려 있는 채팅방 창을 이름으로 찾는다.
  카톡 채팅방을 '새 창'으로 띄우면 클래스 #32770, 제목 = 채팅방 이름인 최상위 창이 된다.
#>
function Find-KakaoRoomWindow {
    param([Parameter(Mandatory)][string]$Room)
    $rooms = Get-KakaoRoomWindows
    if (-not $rooms) { return $null }
    # 1) 정확히 일치
    $hit = $rooms | Where-Object { $_.Title -eq $Room } | Select-Object -First 1
    if ($hit) { return $hit }
    # 2) 부분 일치 (참여자 수 접미사 등을 흡수)
    $rooms | Where-Object { $_.Title.Replace(' ','').StartsWith($Room.Replace(' ','')) } | Select-Object -First 1
}

# 채팅방 창 안의 입력창(RichEdit) 핸들. 여러 개면 가장 아래쪽 것이 입력창.
function Get-KakaoInputBox {
    param([Parameter(Mandatory)][IntPtr]$RoomHwnd)
    $kids = Get-KakaoChildWindows -Hwnd $RoomHwnd
    $edits = $kids | Where-Object { $_.Class -match 'RICHEDIT' -or $_.Class -eq 'Edit' }
    if (-not $edits) { return $null }
    # 화면상 가장 아래에 있는 편집 컨트롤 = 메시지 입력창
    $edits | Sort-Object { $_.Rect.Top } -Descending | Select-Object -First 1
}

<#
  메시지 전송.
  -DryRun 이면 창/입력창만 찾고 실제 전송(Enter)은 하지 않는다.
#>
<#
  전송 버튼 상태/위치를 화면 픽셀로 판정한다.
  카톡 노랑 = #FEE500 (254,229,0). 비활성일 때는 회색(242,242,242)이다.
  입력창 아래 영역만 훑기 때문에 대화 내용의 노란 말풍선에 속지 않는다.
#>
function Find-KakaoSendButton {
    param([Parameter(Mandatory)]$Win, [Parameter(Mandatory)]$Box)

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $wr = New-Object KK+RECT; [void][KK]::GetWindowRect($Win.Hwnd, [ref]$wr)
    $br = New-Object KK+RECT; [void][KK]::GetWindowRect($Box.Hwnd, [ref]$br)

    $top = $br.Bottom                      # 입력창 아래부터
    $h   = $wr.Bottom - $top
    $w   = $wr.Right  - $wr.Left
    if ($h -lt 5 -or $w -lt 5) { return $null }

    try {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($wr.Left, $top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $g.Dispose()
    } catch { return $null }

    $minX=[int]::MaxValue; $minY=[int]::MaxValue; $maxX=-1; $maxY=-1; $cnt=0
    for ($x = 0; $x -lt $w; $x += 2) {
        for ($y = 0; $y -lt $h; $y += 2) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -gt 230 -and $c.G -gt 195 -and $c.G -lt 250 -and $c.B -lt 110) {
                $cnt++
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    $bmp.Dispose()
    if ($cnt -lt 20) { return $null }      # 노란 영역 없음 = 버튼 비활성

    # 노란 덩어리는 [전송] + 구분선 + [∨] 가 붙어 있는 하나다.
    # 가운데를 누르면 ∨ 쪽으로 밀려 드롭다운이 열리고, 그 팝업이 이후
    # 모든 클릭과 Enter 를 삼켜 버린다. 그래서 왼쪽 30% 지점을 누른다.
    $bw = $maxX - $minX
    return @{
        ScreenX = $wr.Left + [int]($minX + $bw * 0.30)
        ScreenY = $top     + [int](($minY + $maxY) / 2)
        Pixels  = $cnt
        Width   = $bw
        RightGap = $w - $maxX          # 창 오른쪽 끝에서 노란 영역까지의 거리
    }
}

# 실제 키 입력처럼 한 글자씩 넣는다. 카톡이 반드시 '입력됨'으로 인식한다.
function Set-KakaoInputByChars {
    param([Parameter(Mandatory)][IntPtr]$BoxHwnd, [Parameter(Mandatory)][string]$Text)
    [void][KK]::SendMessage($BoxHwnd, $Script:EM_SETSEL, [IntPtr]0, [IntPtr](-1))
    [void][KK]::SendMessageStr($BoxHwnd, $Script:EM_REPLACESEL, [IntPtr]1, '')
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq "`n" -or $ch -eq "`r") { continue }   # Enter 로 해석되면 전송돼버린다
        [void][KK]::SendMessage($BoxHwnd, $Script:WM_CHAR, [IntPtr][int]$ch, [IntPtr]1)
    }
}

<#
  화면 좌표에 합성 클릭을 보낸다.

  카톡은 UI 를 자식 창 위에 그리는 경우가 많다. 그 지점을 덮고 있는 자식 창이 있는데
  부모(메인창)에 클릭을 보내면 그냥 무시된다.
  그래서 점을 포함하는 가장 안쪽 자식 창을 찾아 거기로 보낸다.
#>
function Send-KakaoClickAtPoint {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][int]$ScreenX, [Parameter(Mandatory)][int]$ScreenY)

    $target = $Root.Hwnd
    $best   = [int]::MaxValue
    foreach ($c in (Get-KakaoChildWindows -Hwnd $Root.Hwnd)) {
        if (-not $c.Visible) { continue }
        $r = $c.Rect
        if ($ScreenX -lt $r.Left -or $ScreenX -ge $r.Right)  { continue }
        if ($ScreenY -lt $r.Top  -or $ScreenY -ge $r.Bottom) { continue }
        $area = ($r.Right - $r.Left) * ($r.Bottom - $r.Top)
        if ($area -gt 0 -and $area -lt $best) { $best = $area; $target = $c.Hwnd }
    }

    $pt = New-Object KK+POINT
    $pt.X = $ScreenX; $pt.Y = $ScreenY
    [void][KK]::ScreenToClient($target, [ref]$pt)
    $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))

    [void][KK]::PostMessage($target, $Script:WM_MOUSEMOVE,   [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 70
    [void][KK]::PostMessage($target, $Script:WM_LBUTTONDOWN, [IntPtr]1, $lp)
    Start-Sleep -Milliseconds 50
    [void][KK]::PostMessage($target, $Script:WM_LBUTTONUP,   [IntPtr]0, $lp)
    return $target
}

# 채팅 목록이 실제로 그려져 있는가 (= 채팅 탭이 선택된 상태인가)
function Test-KakaoChatTabActive {
    <#
      친구 목록(ContactListCtrl)과 채팅 목록(ChatRoomListCtrl)은 같은 자리에 겹쳐 있고
      둘 다 크기를 가진다. 크기로는 구분되지 않고, 지금 '보이는' 쪽이 선택된 탭이다.

      단, 트레이에서 창을 막 꺼낸 직후에는 카톡이 아직 목록을 그리지 않아 둘 다
      보이지 않는다. 이때 성급히 거짓을 반환하면 탭 막대를 마구 눌러 엉뚱한 곳이 클릭된다.
      그래서 잠깐 기다려 보고, 그래도 판단이 서지 않으면 채팅 탭으로 간주한다.
    #>
    param([Parameter(Mandatory)]$Main, [int]$WaitMs = 0)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $kids = Get-KakaoChildWindows -Hwnd $Main.Hwnd
        $chat = $kids | Where-Object { $_.Title -like 'ChatRoomListCtrl*' } | Select-Object -First 1
        $cont = $kids | Where-Object { $_.Title -like 'ContactListCtrl*'  } | Select-Object -First 1
        if ($chat -and $chat.Visible) { return $true }
        if ($cont -and $cont.Visible) { return $false }
        if ($sw.ElapsedMilliseconds -ge $WaitMs) { break }
        Start-Sleep -Milliseconds 150
    } while ($true)

    <#
      어느 목록도 보이지 않는다. 두 경우가 있다.
        1) 창이 아직 그려지지 않음        - 판단할 수 없다
        2) '더보기' 같은 다른 탭이 열려 있음 - 채팅 탭이 아니다
      호출부에서 WaitMs 를 충분히 주고도 아무것도 안 보이는데 창이 화면에 떠 있다면
      2)로 본다. 이걸 1)로 오판하면 탭을 바꾸지 못해 모든 전송이 실패한다.
    #>
    if ($Main.Visible -and -not [KK]::IsIconic($Main.Hwnd)) { return $false }
    return $true
}

<#
  채팅 탭을 선택한다.

  카톡을 재부팅 후 처음 켜면 '친구' 탭이 선택돼 있는 경우가 있다.
  그 상태에서 검색하면 결과가 '친구' 목록에 뜨고, 거기서 더블클릭해도 채팅방이 열리지 않는다.

  좌측 탭 바는 별도 HWND 가 아니라 창에 그려져 있어서 좌표로 눌러야 하는데,
  아이콘 위치를 못 박아두면 UI 가 바뀔 때 깨진다.
  그래서 위에서부터 훑어 내려가며 누르고, 채팅 목록이 나타나면 멈춘다.
#>
function Test-KakaoFriendTabActive {
    param([Parameter(Mandatory)]$Main)
    $c = Get-KakaoChildWindows -Hwnd $Main.Hwnd |
         Where-Object { $_.Title -like 'ContactListCtrl*' } | Select-Object -First 1
    return ($c -and $c.Visible)
}

<#
  카톡 창에 조합키를 하나 보낸다.

  PostMessage 로는 전혀 먹지 않는다. 카톡이 실제 키보드 상태를 보기 때문에
  창을 잠깐 앞으로 가져와야 한다. 끝나면 쓰던 창으로 되돌린다.
  좌표로 하는 방법이 실패했을 때만 쓰는 수단이다.
#>
function Invoke-KakaoKey {
    param(
        [Parameter(Mandatory)]$Main,
        [byte[]]$Modifiers = @(),
        [Parameter(Mandatory)][byte]$Key,
        [int]$SettleMs = 700
    )
    $fg = [KK]::GetForegroundWindow()
    $my = [KK]::GetCurrentThreadId()
    [uint32]$dummy = 0
    $tt = [KK]::GetWindowThreadProcessId($Main.Hwnd, [ref]$dummy)
    $attached = $false
    try {
        $attached = [KK]::AttachThreadInput($my, $tt, $true)
        [void][KK]::SetForegroundWindow($Main.Hwnd)
        Start-Sleep -Milliseconds 250
        foreach ($k in $Modifiers) { [KK]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
        [KK]::keybd_event($Key, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 70
        [KK]::keybd_event($Key, 0, 2, [UIntPtr]::Zero)
        for ($i = $Modifiers.Count - 1; $i -ge 0; $i--) { [KK]::keybd_event($Modifiers[$i], 0, 2, [UIntPtr]::Zero) }
        Start-Sleep -Milliseconds $SettleMs
    } catch {
    } finally {
        if ($attached) { [void][KK]::AttachThreadInput($my, $tt, $false) }
        if ($fg -ne [IntPtr]::Zero) { [void][KK]::SetForegroundWindow($fg) }
    }
}

<#
  Ctrl+Tab 으로 탭을 옮긴다.

  카톡의 Ctrl+Tab 은 친구 -> 채팅 -> 더보기 순으로 순환한다 (실측).
  좌표를 쓰지 않으므로 화면 배율이나 창 크기에 영향을 받지 않는다.

  대신 실제 키 입력이라 카톡을 잠깐 앞으로 가져와야 한다. PostMessage 로는
  전혀 먹지 않는다(카톡이 실제 키보드 상태를 본다). 끝나면 쓰던 창으로 되돌린다.
  탭 막대 클릭이 실패했을 때만 쓰는 마지막 수단이다.
#>
function Invoke-KakaoTabCycle {
    param(
        [Parameter(Mandatory)]$Main,
        [ValidateSet('chat','friend')][string]$Target,
        [int]$MaxPress = 4   # 친구/채팅/더보기 3개 주기라 최대 2번이면 닿는다
    )
    function Script:Reached {
        $mm = Get-KakaoMainWindow
        if (-not $mm) { return $false }
        if ($Target -eq 'chat') { return (Test-KakaoChatTabActive   -Main $mm) }
        else                    { return (Test-KakaoFriendTabActive -Main $mm) }
    }
    if (Script:Reached) { return $true }

    $fg  = [KK]::GetForegroundWindow()
    $my  = [KK]::GetCurrentThreadId()
    [uint32]$dummy = 0
    $tt  = [KK]::GetWindowThreadProcessId($Main.Hwnd, [ref]$dummy)
    $attached = $false
    try {
        $attached = [KK]::AttachThreadInput($my, $tt, $true)
        [void][KK]::SetForegroundWindow($Main.Hwnd)
        Start-Sleep -Milliseconds 300
        for ($i = 0; $i -lt $MaxPress; $i++) {
            [KK]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)      # Ctrl down
            [KK]::keybd_event(0x09, 0, 0, [UIntPtr]::Zero)      # Tab down
            Start-Sleep -Milliseconds 70
            [KK]::keybd_event(0x09, 0, 2, [UIntPtr]::Zero)
            [KK]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 650
            if (Script:Reached) { return $true }
        }
    } catch {
    } finally {
        if ($attached) { [void][KK]::AttachThreadInput($my, $tt, $false) }
        if ($fg -ne [IntPtr]::Zero) { [void][KK]::SetForegroundWindow($fg) }
    }
    return (Script:Reached)
}

function Select-KakaoChatTab {
    param([Parameter(Mandatory)]$Main, [int]$TimeoutMs = 8000)

    if (Test-KakaoChatTabActive -Main $Main) { return $true }

    # 레이아웃이 잡힐 때까지 잠깐 기다린다 (트레이에서 막 꺼낸 경우)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2000) {
        if (Test-KakaoChatTabActive -Main $Main) { return $true }
        $any = Get-KakaoChildWindows -Hwnd $Main.Hwnd |
               Where-Object { $_.Title -like '*ListView*' -and ($_.Rect.Bottom - $_.Rect.Top) -gt 50 }
        if ($any) { break }
        Start-Sleep -Milliseconds 200
    }
    if (Test-KakaoChatTabActive -Main $Main) { return $true }

    # 좌표를 쓰지 않는 Ctrl+Tab 을 먼저 쓴다. 화면 배율이나 UI 변경에 영향받지 않는다.
    if (Invoke-KakaoTabCycle -Main $Main -Target chat) { return $true }

    $wr = New-Object KK+RECT
    [void][KK]::GetWindowRect($Main.Hwnd, [ref]$wr)

    # 단축키가 막혔을 때만. 본문이 창 왼쪽 약 66px 부터라 그 왼쪽이 탭 바다.
    $railX = 33
    foreach ($y in 35..300) {
        if (($y - 35) % 16 -ne 0) { continue }
        [void](Send-KakaoClickAtPoint -Root $Main -ScreenX ($wr.Left + $railX) -ScreenY ($wr.Top + $y))
        Start-Sleep -Milliseconds 320

        if (Test-KakaoChatTabActive -Main $Main) { return $true }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { break }
    }
    return (Test-KakaoChatTabActive -Main $Main)
}

function Send-KakaoMessage {
    param(
        [Parameter(Mandatory)][string]$Room,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('replacesel','clipboard','settext')][string]$Mode = 'replacesel',
        [switch]$DryRun,
        [switch]$AutoOpen,
        [int[]]$RowOffsets = @(30, 62, 92, 122, 152, 182),
        [int[]]$SendButton = @(58, 29),   # 창 오른쪽 끝 21~30px 은 [∨] 드롭다운이다
        [ValidateSet('auto','enter','button')][string]$SendMethod = 'auto',
        [switch]$KeepOpen,
        [switch]$HideMain
    )

    if ((Get-KakaoProcessIds).Count -eq 0) {
        return [pscustomobject]@{ ok=$false; error='KakaoTalk 프로세스가 실행 중이 아님' }
    }

    # 카톡이 트레이로 내려가 있으면 검색/열기가 동작하지 않는다.
    # 잠깐 표시했다가(포커스는 뺏지 않는 SW_SHOWNOACTIVATE) 전송이 다 끝난 뒤 되돌린다.
    # 주의: 전송 도중에 메인창을 숨기면 카톡이 채팅방 창까지 같이 정리해버린다.
    # 방을 열면 카톡이 그 창을 활성화해 포커스를 가져간다.
    # 사용자가 쓰던 창을 기억해뒀다가 끝나고 되돌려준다.
    $fgBefore = [KK]::GetForegroundWindow()

    <#
      부팅 직후에는 프로세스만 떠 있고 메인창이 아직 만들어지지 않았을 수 있다.
      그대로 실패로 처리하면 재시도 간격(1.5초)이 짧아 4초 만에 포기해 버린다.
      창이 생길 때까지 기다린다.
    #>
    $mainW = Get-KakaoMainWindow
    if (-not $mainW) {
        $swWait = [Diagnostics.Stopwatch]::StartNew()
        while ($swWait.ElapsedMilliseconds -lt 30000 -and -not $mainW) {
            Start-Sleep -Milliseconds 700
            $mainW = Get-KakaoMainWindow
        }
    }
    if (-not $mainW) {
        return [pscustomobject]@{ ok=$false
            error='카카오톡 메인창을 찾을 수 없음 (30초 기다림 - 카카오톡이 아직 시작 중이거나 로그인 전일 수 있습니다)' }
    }
    $restoreTray = $false
    if ($mainW -and ((-not $mainW.Visible) -or [KK]::IsIconic($mainW.Hwnd))) {
        if ([KK]::IsIconic($mainW.Hwnd)) {
            [void][KK]::ShowWindow($mainW.Hwnd, 9)  # SW_RESTORE - 최소화는 이걸로만 풀린다
        } else {
            [void][KK]::ShowWindow($mainW.Hwnd, 4)  # SW_SHOWNOACTIVATE
        }
        $restoreTray = $true
        Start-Sleep -Milliseconds 400
        # 창이 뜬 것만으로는 부족하다. 카톡이 목록을 다시 그릴 때까지 기다려야
        # 검색창에 넣은 글자가 실제로 검색으로 이어진다.
        $swShow = [Diagnostics.Stopwatch]::StartNew()
        while ($swShow.ElapsedMilliseconds -lt 4000) {
            $m2 = Get-KakaoMainWindow
            if ($m2) {
                $mainW = $m2
                $drawn = Get-KakaoChildWindows -Hwnd $m2.Hwnd | Where-Object {
                    ($_.Title -like 'ChatRoomListCtrl*' -or $_.Title -like 'ContactListCtrl*') -and $_.Visible
                }
                if ($drawn) { break }
            }
            Start-Sleep -Milliseconds 200
        }
    }

    try {

    $usedOffset = $null
    $openMode   = 'existing'

    # 1) 이미 열려 있는 채팅방 창 찾기
    $win = Find-KakaoRoomWindow -Room $Room
    $box = if ($win) { Get-KakaoInputBox -RoomHwnd $win.Hwnd } else { $null }

    # 2) 없으면 검색해서 자동으로 연다
    if (-not $box -and $AutoOpen) {
        # 친구 탭이 선택돼 있으면 검색 결과가 친구 목록에 떠서 채팅방이 열리지 않는다
        if ($mainW -and -not (Test-KakaoChatTabActive -Main $mainW -WaitMs 2500)) {
            [void](Select-KakaoChatTab -Main $mainW)
        }
        $opened = Open-KakaoRoom -Room $Room -RowOffsets $RowOffsets
        if (-not $opened.ok) {
            # 방이 없는 것은 다시 해도 같다 -> 재시도 제외.
            # 검색 UI 가 안 뜬 것은 다시 하면 될 수 있다 -> 재시도 허용.
            return [pscustomobject]@{ ok=$false; error=$opened.error
                                      roomNotFound=[bool]$opened.roomMissing }
        }
        $usedOffset = $opened.rowOffset
        $openMode   = $opened.mode
        $win = $opened.window
        $box = if ($opened.mode -eq 'inline') { $opened.input } else { Get-KakaoInputBox -RoomHwnd $win.Hwnd }
    }

    if (-not $win) {
        return [pscustomobject]@{ ok=$false; roomNotFound=$true; error="채팅방 '$Room' 을(를) 찾을 수 없음. 카톡에 방을 새 창으로 열어두거나 AutoOpen 을 켜세요." }
    }
    if (-not $box) {
        return [pscustomobject]@{ ok=$false; error="'$($win.Title)' 창에서 입력창을 찾을 수 없음" }
    }

    if ($DryRun) {
        return [pscustomobject]@{
            ok=$true; dryRun=$true; room=$win.Title
            windowHwnd=("0x{0:X}" -f [int64]$win.Hwnd)
            inputHwnd =("0x{0:X}" -f [int64]$box.Hwnd)
            inputClass=$box.Class
            openMode=$openMode; rowOffset=$usedOffset
            wouldSend=$Text
        }
    }

    # ---- 입력창에 텍스트 주입 ----
    # 중요: WM_SETTEXT 는 글자는 들어가지만 카톡이 '입력이 생겼다'는 것을 인지하지 못해
    #       전송 버튼이 회색(비활성) 그대로다 -> 눌러도 전송되지 않는다.
    #       EM_REPLACESEL 은 실제 편집으로 처리되어 변경 알림이 발생하고 버튼이 활성화된다.
    switch ($Mode) {
        'clipboard' {
            Set-Clipboard -Value $Text
            Start-Sleep -Milliseconds 150
            [void][KK]::SendMessage($box.Hwnd, $Script:WM_PASTE, [IntPtr]::Zero, [IntPtr]::Zero)
        }
        'settext' {
            # 하위호환용. 전송 버튼이 활성화되지 않으므로 권장하지 않는다.
            [void][KK]::SendMessageStr($box.Hwnd, $Script:WM_SETTEXT, [IntPtr]::Zero, $Text)
        }
        default {
            [void][KK]::SendMessage($box.Hwnd, $Script:EM_SETSEL, [IntPtr]0, [IntPtr](-1))       # 전체 선택
            [void][KK]::SendMessageStr($box.Hwnd, $Script:EM_REPLACESEL, [IntPtr]1, $Text)       # 실제 편집으로 치환
        }
    }
    # 카톡이 입력 내용을 인식하고 '전송' 버튼을 활성화(회색->노랑)할 시간을 준다.
    # 너무 짧으면 비활성 버튼을 눌러 전송이 안 된다.
    Start-Sleep -Milliseconds 350

    # 주입 검증: 입력창 내용이 우리가 넣은 것과 같은지 확인 (다르면 Enter 안 침)
    $now = [KK]::EditTxt($box.Hwnd)
    $norm = { param($s) ($s -replace "`r","").Trim() }
    if ((& $norm $now) -ne (& $norm $Text)) {
        return [pscustomobject]@{
            ok=$false
            error="입력창 주입 검증 실패 (기대: '$Text' / 실제: '$now'). Enter 미전송."
            room=$win.Title
        }
    }

    # ---- 전송 ----
    # 실측으로 확인한 카톡의 성질 세 가지를 모두 만족시켜야 전송이 된다.
    #
    #  (1) 카톡이 '글자가 입력됐다'고 인식해야 전송 버튼이 활성화(회색->노랑)된다.
    #      EM_REPLACESEL 로 대개 되지만 간헐적으로 인식하지 못하는 경우가 있었다.
    #      그래서 버튼 색을 실제로 확인하고, 회색이면 WM_CHAR 로 한 글자씩 다시 넣는다.
    #  (2) 버튼 좌표는 창 크기/UI 에 따라 달라진다. 고정 오프셋 대신 노란 픽셀을 찾는다.
    #  (3) 합성 클릭 전에 WM_MOUSEMOVE 를 보내 hover 상태를 만들어야 클릭이 먹는다.
    #      (실제 마우스는 커서가 지나가며 자동으로 이 상태가 된다)

    if ([KK]::IsIconic($win.Hwnd)) { [void][KK]::ShowWindow($win.Hwnd, 4) ; Start-Sleep -Milliseconds 300 }

    # 픽셀을 읽어야 하므로 창을 맨 위로. 활성화(포커스)는 하지 않는다.
    #   SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE
    [void][KK]::SetWindowPos($win.Hwnd, [IntPtr]0, 0, 0, 0, 0, (0x0002 -bor 0x0001 -bor 0x0010))
    Start-Sleep -Milliseconds 250

    $want    = ($Text -replace "`r", '').Trim()
    $sent    = $false
    $usedBtn = $null
    $usedVia = $null
    $after   = ''

    function Test-Sent {
        $cur = ([KK]::EditTxt($box.Hwnd) -replace "`r", '').Trim()
        return @{ sent = (-not $cur.Contains($want)); text = $cur }
    }

    # --- 전송 버튼이 실제로 활성화됐는지 확인, 아니면 진짜 키 입력으로 다시 넣는다 ---
    $btn = Find-KakaoSendButton -Win $win -Box $box
    if (-not $btn) {
        Set-KakaoInputByChars -BoxHwnd $box.Hwnd -Text $Text
        Start-Sleep -Milliseconds 400
        $btn = Find-KakaoSendButton -Win $win -Box $box
        $Script:LastClickDiag = '버튼 비활성 -> WM_CHAR 재주입: ' + $(if ($btn) { '활성화됨' } else { '여전히 비활성' })
    } else {
        $Script:LastClickDiag = '버튼 활성(픽셀 ' + $btn.Pixels + '개, 노란폭 ' + $btn.Width + 'px, 우측여백 ' + $btn.RightGap + 'px)'
    }

    # --- 방법 1: 전송 버튼 클릭 ---
    if ($SendMethod -eq 'button' -or $SendMethod -eq 'auto') {
        $wr = New-Object KK+RECT
        [void][KK]::GetWindowRect($win.Hwnd, [ref]$wr)

        # 픽셀로 찾은 좌표를 1순위로, 실패하면 알려진 오프셋들을 시도
        $points = New-Object System.Collections.ArrayList
        if ($btn) { [void]$points.Add(@{ x = $btn.ScreenX; y = $btn.ScreenY; tag = '픽셀탐지' }) }
        # 창 오른쪽 끝에서 21~30px 지점은 [∨] 드롭다운이다. 여기를 누르면 팝업이 열려
        # 그 뒤 모든 클릭이 막힌다. [전송] 글자는 오른쪽 끝에서 약 55~65px 안쪽에 있다.
        foreach ($d in @(@(58,29), @(64,30), @(52,28))) {
            [void]$points.Add(@{ x = $wr.Right - $d[0]; y = $wr.Bottom - $d[1]; tag = "$($d[0]),$($d[1])" })
        }

        foreach ($pnt in $points) {
            if (($wr.Right - $pnt.x) -lt 40) {          # ∨ 영역 방어
                $Script:LastClickDiag += "  [$($pnt.tag)]건너뜀(∨ 영역)"
                continue
            }
            $pt = New-Object KK+POINT
            $pt.X = $pnt.x; $pt.Y = $pnt.y
            [void][KK]::ScreenToClient($win.Hwnd, [ref]$pt)
            $lp = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))

            [void][KK]::PostMessage($win.Hwnd, $Script:WM_MOUSEMOVE,   [IntPtr]0, $lp)
            Start-Sleep -Milliseconds 120
            [void][KK]::PostMessage($win.Hwnd, $Script:WM_LBUTTONDOWN, [IntPtr]1, $lp)
            Start-Sleep -Milliseconds 80
            [void][KK]::PostMessage($win.Hwnd, $Script:WM_LBUTTONUP,   [IntPtr]0, $lp)
            Start-Sleep -Milliseconds 600

            $chk = Test-Sent
            $after = $chk.text
            $Script:LastClickDiag += "  [$($pnt.tag)]->($($pt.X),$($pt.Y)) 잔여='$($chk.text)'"
            if ($chk.sent) { $sent = $true; $usedBtn = $pnt.tag; $usedVia = 'button'; break }
        }
    }

    # --- 방법 2: 포커스 + Enter (버튼이 끝내 안 먹을 때) ---
    if (-not $sent -and ($SendMethod -eq 'enter' -or $SendMethod -eq 'auto')) {
        [uint32]$dummyPid = 0
        $myTid  = [KK]::GetCurrentThreadId()
        $tgtTid = [KK]::GetWindowThreadProcessId($win.Hwnd, [ref]$dummyPid)
        $attached = $false
        if ($tgtTid -ne 0 -and $tgtTid -ne $myTid) { $attached = [KK]::AttachThreadInput($myTid, $tgtTid, $true) }
        try {
            [void][KK]::ShowWindow($win.Hwnd, 5)
            [void][KK]::BringWindowToTop($win.Hwnd)
            [void][KK]::SetForegroundWindow($win.Hwnd)
            Start-Sleep -Milliseconds 300
            [void][KK]::SetFocus($box.Hwnd)
            Start-Sleep -Milliseconds 150
            [void][KK]::SendMessage($box.Hwnd, $Script:EM_SETSEL, [IntPtr](-1), [IntPtr](-1))
            [KK]::keybd_event(0x0D, 0x1C, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
            [KK]::keybd_event(0x0D, 0x1C, 2, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 500
        } finally {
            if ($attached) { [void][KK]::AttachThreadInput($myTid, $tgtTid, $false) }
        }
        $chk = Test-Sent
        $after = $chk.text
        $Script:LastClickDiag += "  [Enter] 잔여='$($chk.text)'"
        if ($chk.sent) { $sent = $true; $usedVia = 'enter' }
    }

    if (-not $sent) {
        # 실패 순간의 채팅방 하단을 캡처해 둔다 (원인 파악용)
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $fr = New-Object KK+RECT
            [void][KK]::GetWindowRect($win.Hwnd, [ref]$fr)
            $fw = $fr.Right - $fr.Left; $fh = [Math]::Min(160, $fr.Bottom - $fr.Top)
            if ($fw -gt 0 -and $fh -gt 0) {
                $bmp = New-Object System.Drawing.Bitmap($fw, $fh)
                $gg  = [System.Drawing.Graphics]::FromImage($bmp)
                $gg.CopyFromScreen($fr.Left, $fr.Bottom - $fh, 0, 0, (New-Object System.Drawing.Size($fw, $fh)))
                $gg.Dispose()
                $bmp.Save((Join-Path $PSScriptRoot 'fail-shot.png'), [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
            }
        } catch { }
        [void][KK]::SendMessageStr($box.Hwnd, $Script:WM_SETTEXT, [IntPtr]::Zero, '')
    }

    # ---- 전송 후 채팅방 창 닫기 (성공/실패 무관, 기본 동작) ----
    # 안전장치: 'inline' 로 열린 경우 $win 은 메인창이므로 절대 닫으면 안 된다 (카톡이 종료된다).
    $closed = $false
    if (-not $KeepOpen) {
        $mainW = Get-KakaoMainWindow
        $mh    = if ($mainW) { [int64]$mainW.Hwnd } else { 0 }
        if ($openMode -ne 'inline' -and [int64]$win.Hwnd -ne $mh) {
            Start-Sleep -Milliseconds 400          # 전송이 반영될 시간
            [void][KK]::PostMessage($win.Hwnd, $Script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 300
            $closed = -not [KK]::IsWindow($win.Hwnd)
        }
    }

    return [pscustomobject]@{
        ok         = $sent
        room       = $win.Title
        text       = $Text
        openMode   = $openMode
        rowOffset  = $usedOffset
        sendButton = $usedBtn
        via        = $usedVia
        diag       = $Script:LastClickDiag
        closed     = $closed
        trayRestored = $restoreTray
        mainHidden   = [bool]($mainW -and ($restoreTray -or $HideMain))
        error      = $(if ($sent) { $null } else { "전송 실패(버튼/Enter 모두). 입력창 잔여: '$after'" })
    }

    }
    finally {
        # 메인창 정리.
        #   - 원래 트레이 상태였으면 되돌린다
        #   - HideMain 이면 원래 떠 있었더라도 트레이로 내린다
        # 채팅방 창을 먼저 닫은 뒤에 실행된다. (메인창을 먼저 숨기면 카톡이 채팅방 창까지 정리해버린다)
        if ($mainW -and ($restoreTray -or $HideMain)) {
            [void][KK]::ShowWindow($mainW.Hwnd, 0)  # SW_HIDE
        }

        # 포커스를 원래 쓰던 창으로 복구
        if ($fgBefore -ne [IntPtr]::Zero -and [KK]::IsWindow($fgBefore)) {
            $now = [KK]::GetForegroundWindow()
            if ($now -ne $fgBefore) {
                # SetForegroundWindow 는 백그라운드 프로세스에서 그냥은 막히므로
                # 현재 전경 스레드에 입력큐를 붙여서 권한을 얻는다.
                [uint32]$dummy = 0
                $myTid = [KK]::GetCurrentThreadId()
                $fgTid = [KK]::GetWindowThreadProcessId($now, [ref]$dummy)
                $attached = $false
                if ($fgTid -ne 0 -and $fgTid -ne $myTid) { $attached = [KK]::AttachThreadInput($myTid, $fgTid, $true) }
                [void][KK]::ShowWindow($fgBefore, 9)          # SW_RESTORE
                [void][KK]::SetForegroundWindow($fgBefore)
                if ($attached) { [void][KK]::AttachThreadInput($myTid, $fgTid, $false) }
            }
        }
    }
}

# ============================================================
#  채팅방 자동 열기 (검색창 주입 -> 결과 행 더블클릭)
# ============================================================
$Script:WM_MOUSEMOVE     = 0x0200
$Script:WM_LBUTTONDOWN   = 0x0201
$Script:WM_LBUTTONUP     = 0x0202
$Script:WM_LBUTTONDBLCLK = 0x0203

# 메인창의 검색 입력창 (0 크기 Edit 컨트롤)
function Get-KakaoSearchBox {
    $main = Get-KakaoMainWindow
    if (-not $main) { return $null }
    $kids = Get-KakaoChildWindows -Hwnd $main.Hwnd
    # 보이는 Edit 중 검색바(EVA_Window_Dblclk, 높이 40 내외) 근처에 있는 것
    <#
      메인창의 Edit 은 여러 개다. 실측하면 다음과 같다.
          0x0     자리만 잡아둔 것        - 글자를 넣어도 검색되지 않는다
          28x25   상단의 작은 컨트롤 4개   - 검색과 무관
          138x23  실제 검색 입력창         - 여기에 넣어야 검색 결과가 뜬다
      또 이 컨트롤들은 창이 화면에 떠 있어도 Visible=False 로 보고된다.
      그래서 가시성으로 거르면 안 되고, 폭으로 골라야 한다.
    #>
    $edits = $kids | Where-Object { $_.Class -eq 'Edit' }
    if (-not $edits) { return $null }
    $wide = $edits | Where-Object { ($_.Rect.Right - $_.Rect.Left) -gt 60 } |
            Sort-Object { $_.Rect.Right - $_.Rect.Left } -Descending | Select-Object -First 1
    if ($wide) { return $wide }
    return ($edits | Select-Object -First 1)
}

function Get-KakaoSearchList {
    $main = Get-KakaoMainWindow
    if (-not $main) { return $null }
    $kids  = Get-KakaoChildWindows -Hwnd $main.Hwnd
    $lists = $kids | Where-Object {
        $_.Title -like 'SearchListCtrl*' -and $_.Visible -and ($_.Rect.Bottom - $_.Rect.Top) -gt 50
    }
    if (-not $lists) { return $null }
    # 친구 탭과 채팅 탭은 검색 결과 목록을 따로 갖는다. 크기로 고르면 친구 쪽을 집는다.
    # 채팅 목록과 같은 자리에 뜨는 것이 채팅방 검색 결과다.
    $chat = $kids | Where-Object { $_.Title -like 'ChatRoomListCtrl*' } | Select-Object -First 1
    if ($chat) {
        $same = $lists | Where-Object { [Math]::Abs($_.Rect.Top - $chat.Rect.Top) -le 4 } | Select-Object -First 1
        if ($same) { return $same }
    }
    return ($lists | Select-Object -First 1)
}

<#
  검색어를 지운다.

  어느 Edit 이 검색창인지 크기로는 알 수 없으므로(같은 컨트롤이 138x23 이 되기도 0x0 이 되기도 한다)
  메인창의 Edit 을 모두 비운다. 하나만 지우면 엉뚱한 것을 지워 검색어가 남고,
  다음 검색이 걸리지 않는다.
#>
function Clear-KakaoSearch {
    $main = Get-KakaoMainWindow
    if (-not $main) { return }
    Get-KakaoChildWindows -Hwnd $main.Hwnd |
        Where-Object { $_.Class -eq 'Edit' } |
        ForEach-Object { [void][KK]::SendMessageStr($_.Hwnd, $Script:WM_SETTEXT, [IntPtr]::Zero, '') }
    Start-Sleep -Milliseconds 250
}

function Send-DoubleClick {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y)
    $lp = [IntPtr](($Y -shl 16) -bor ($X -band 0xFFFF))
    # 합성 클릭 전에 마우스 이동을 먼저 보내 hover 상태를 만든다 (전송 버튼과 같은 이유)
    [void][KK]::PostMessage($Hwnd, $Script:WM_MOUSEMOVE, [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 100
    [void][KK]::PostMessage($Hwnd, $Script:WM_LBUTTONDOWN,   [IntPtr]1, $lp)
    [void][KK]::PostMessage($Hwnd, $Script:WM_LBUTTONUP,     [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 30
    [void][KK]::PostMessage($Hwnd, $Script:WM_LBUTTONDBLCLK, [IntPtr]1, $lp)
    [void][KK]::PostMessage($Hwnd, $Script:WM_LBUTTONUP,     [IntPtr]0, $lp)
}

# 메인창 안에 채팅 입력창(RichEdit)이 떠 있으면 = 방이 '창 안에서' 열린 상태
function Get-KakaoInlineInput {
    param([IntPtr]$MainHwnd = [IntPtr]::Zero)
    if ($MainHwnd -eq [IntPtr]::Zero) {
        $main = Get-KakaoMainWindow
        if (-not $main) { return $null }
        $MainHwnd = $main.Hwnd
    }
    Get-KakaoChildWindows -Hwnd $MainHwnd |
        Where-Object { $_.Class -match 'RICHEDIT' -and $_.Visible } |
        Sort-Object { $_.Rect.Top } -Descending |
        Select-Object -First 1
}

<#
  방 이름으로 검색해서 채팅방을 연다.
  - 새 창으로 열리면 그 창 정보를 반환 (Mode='window')
  - 메인창 안에서 열리면 메인창 정보를 반환 (Mode='inline')
  RowOffsets: 검색 결과에서 시도할 y 오프셋 목록. 성공한 값은 호출측에서 캐싱하면 된다.
#>
<#
  친구 탭으로 옮긴다.

  탭 막대를 훑어 내려가는 방식은 쓰지 않는다. 판정이 어긋나면 '더보기'까지
  내려가 갇혀 버리고, 그 뒤 모든 전송이 실패했다. Ctrl+Tab 만 쓴다.
#>
function Select-KakaoFriendTab {
    param([Parameter(Mandatory)]$Main, [int]$TimeoutMs = 6000)
    if (Test-KakaoFriendTabActive -Main $Main) { return $true }

    if (Invoke-KakaoTabCycle -Main $Main -Target friend) { return $true }

    # 단축키가 막혔을 때만 탭 막대를 누른다.
    $wr = New-Object KK+RECT
    [void][KK]::GetWindowRect($Main.Hwnd, [ref]$wr)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($y in 35..300) {
        if ((($y - 35) % 16) -ne 0) { continue }
        [void](Send-KakaoClickAtPoint -Root $Main -ScreenX ($wr.Left + 33) -ScreenY ($wr.Top + $y))
        Start-Sleep -Milliseconds 300
        if (Test-KakaoFriendTabActive -Main $Main) { return $true }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { break }
    }
    return (Test-KakaoFriendTabActive -Main $Main)
}

<#
  검색어를 넣고 결과 목록이 뜨기를 기다린다.

  검색 입력창을 크기로 고를 수 없다. 같은 컨트롤이 상황에 따라 138x23 이 되기도 하고
  0x0 이 되기도 한다 (검색바가 접혀 있으면 0x0). 가시성도 창이 떠 있어도 False 로 나온다.
  그래서 '글자를 넣어 보고 결과 목록이 뜨는지'로 판별한다.
  한 번 통한 컨트롤은 기억해 두고 다음부터 먼저 시도한다.
  카톡을 다시 켜면 핸들이 바뀌므로, 기억한 것이 없으면 조용히 다음 후보로 넘어간다.

  한 탭에서 결과 목록을 띄우는 Edit 은 하나뿐이라는 것을 실측으로 확인했다.
#>
$Script:LastSearchBox = @{}

<#
  채팅 목록 위쪽의 돋보기를 눌러 검색창을 연다.

  카톡 검색창은 평소에 닫혀 있다. 닫혀 있으면 Edit 컨트롤이 0x0 이라
  글자를 넣어도 아무 일도 일어나지 않는다. 열려 있으면 138x23 이 된다.
  돋보기는 목록 오른쪽 위에 있고, 창 오른쪽 끝에서 약 105px 안쪽이다.
#>
function Open-KakaoSearchBar {
    param([Parameter(Mandatory)]$Main)
    function Script:HasWideEdit {
        $mm = Get-KakaoMainWindow
        if (-not $mm) { return $null }
        Get-KakaoChildWindows -Hwnd $mm.Hwnd |
            Where-Object { $_.Class -eq 'Edit' -and ($_.Rect.Right - $_.Rect.Left) -gt 60 } |
            Select-Object -First 1
    }
    if (Script:HasWideEdit) { return $true }
    # Ctrl+F 가 확실하다. 좌표는 카톡 UI 가 바뀌면 어긋난다.
    Invoke-KakaoKey -Main $Main -Modifiers @([byte]0x11) -Key 0x46 -SettleMs 800
    if (Script:HasWideEdit) { return $true }
    # 단축키가 막혀 있으면 돋보기를 직접 누른다.
    $wr = New-Object KK+RECT
    [void][KK]::GetWindowRect($Main.Hwnd, [ref]$wr)
    foreach ($dx in 105, 109, 100, 113, 96, 118) {
        [void](Send-KakaoClickAtPoint -Root $Main -ScreenX ($wr.Right - $dx) -ScreenY ($wr.Top + 57))
        Start-Sleep -Milliseconds 500
        if (Script:HasWideEdit) { return $true }
    }
    return $false
}

function Invoke-KakaoSearch {
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('chat','friend')][string]$Tab = 'chat',
        [int]$FirstMs = 4000,
        [int]$ProbeMs = 1200
    )
    $main = Get-KakaoMainWindow
    if (-not $main) { return $null }
    [void](Open-KakaoSearchBar -Main $main)      # 닫혀 있으면 열어야 글자가 들어간다
    $main = Get-KakaoMainWindow
    $edits = @(Get-KakaoChildWindows -Hwnd $main.Hwnd | Where-Object { $_.Class -eq 'Edit' })
    if (-not $edits) { return $null }

    # 검색창이 열려 있으면 폭이 있는 것이 그 컨트롤이다. 그것부터 시도한다.
    <#
      한 번 통한 검색창이 지금도 살아 있으면 그것만 쓴다.
      결과가 없는 검색어일 때 후보를 계속 훑으면 시간만 버린다(탭마다 10초).
      카톡을 다시 켜면 핸들이 바뀌어 목록에서 사라지므로 그때만 다시 훑는다.
    #>
    $order  = New-Object System.Collections.ArrayList
    $cached = $Script:LastSearchBox[$Tab]
    $hit = $null
    if ($cached) { $hit = $edits | Where-Object { [int64]$_.Hwnd -eq [int64]$cached } | Select-Object -First 1 }
    if ($hit) {
        [void]$order.Add($hit)
    } else {
        $wide = $edits | Where-Object { ($_.Rect.Right - $_.Rect.Left) -gt 60 } | Select-Object -First 1
        if ($wide) { [void]$order.Add($wide) }
        foreach ($e in $edits) {
            if (-not ($order | Where-Object { [int64]$_.Hwnd -eq [int64]$e.Hwnd })) { [void]$order.Add($e) }
        }
    }

    $first = $true
    foreach ($e in $order) {
        [void][KK]::SendMessageStr($e.Hwnd, $Script:WM_SETTEXT, [IntPtr]::Zero, $Text)
        $budget = if ($first) { $FirstMs } else { $ProbeMs }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $budget) {
            Start-Sleep -Milliseconds 150
            $l = Get-KakaoChildWindows -Hwnd $main.Hwnd |
                 Where-Object { $_.Title -like 'SearchListCtrl*' -and $_.Visible -and ($_.Rect.Bottom - $_.Rect.Top) -gt 50 } |
                 Select-Object -First 1
            if ($l) {
                $Script:LastSearchBox[$Tab] = [int64]$e.Hwnd
                return [pscustomobject]@{ list = $l; box = $e }
            }
        }
        [void][KK]::SendMessageStr($e.Hwnd, $Script:WM_SETTEXT, [IntPtr]::Zero, '')
        $first = $false
    }
    return $null
}

<#
  검색 결과 목록을 키보드로 열어 본다.

  검색을 하면 첫 번째 항목이 이미 선택된 상태다(실측). 그래서
      1번째 결과 = Enter
      2번째 결과 = ↓ + Enter
      3번째 결과 = ↓ ↓ + Enter
  이다. 좌표를 전혀 쓰지 않으므로 화면 배율이나 줄 높이에 영향받지 않는다.

  ↓ 와 Enter 는 수정키가 없어 PostMessage 로도 그대로 먹는다.
  (Ctrl+Tab 같은 조합키는 실제 키보드 상태가 필요해 포커스를 빌려야 하지만
   이건 그럴 필요가 없다 - 사용자 포커스를 건드리지 않는다.)
#>
function Open-KakaoRoomByKeys {
    param(
        [Parameter(Mandatory)][string]$Room,
        [Parameter(Mandatory)]$List,
        [int]$MaxItems = 6,
        [int]$WaitMs = 900
    )
    $opened = 0        # 창이 하나라도 열렸다면 키 입력이 먹은 것이다
    $mainWin  = Get-KakaoMainWindow
    $mainHwnd = if ($mainWin) { [int64]$mainWin.Hwnd } else { 0 }
    $before = @(Get-KakaoTopWindows | Where-Object { $_.Visible -and $_.Title } | ForEach-Object { [int64]$_.Hwnd })

    for ($i = 0; $i -lt $MaxItems; $i++) {
        if ($i -gt 0) {
            [void][KK]::PostMessage($List.Hwnd, $Script:WM_KEYDOWN, [IntPtr]0x28, [IntPtr]0)   # VK_DOWN
            Start-Sleep -Milliseconds 60
            [void][KK]::PostMessage($List.Hwnd, $Script:WM_KEYUP,   [IntPtr]0x28, [IntPtr]0)
            Start-Sleep -Milliseconds 250
        }
        [void][KK]::PostMessage($List.Hwnd, $Script:WM_KEYDOWN, [IntPtr]0x0D, [IntPtr]0)       # VK_RETURN
        Start-Sleep -Milliseconds 60
        [void][KK]::PostMessage($List.Hwnd, $Script:WM_KEYUP,   [IntPtr]0x0D, [IntPtr]0)
        Start-Sleep -Milliseconds $WaitMs

        $new = Get-KakaoTopWindows |
               Where-Object { $_.Visible -and $_.Title -and ($before -notcontains [int64]$_.Hwnd) -and ([int64]$_.Hwnd -ne $mainHwnd) } |
               Select-Object -First 1
        if ($new) {
            $opened++
            $match = ($new.Title -eq $Room) -or ($new.Title.Replace(' ','').StartsWith($Room.Replace(' ','')))
            if ($match -and -not (Get-KakaoInputBox -RoomHwnd $new.Hwnd)) { $match = $false }
            if ($match) { return [pscustomobject]@{ ok=$true; mode='window'; window=$new; rowOffset="key$i" } }
            [void][KK]::PostMessage($new.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            Start-Sleep -Milliseconds 400
            continue
        }
        if ($mainHwnd -ne 0) {
            $inline = Get-KakaoInlineInput -MainHwnd ([IntPtr]$mainHwnd)
            if ($inline) { return [pscustomobject]@{ ok=$true; mode='inline'; window=$mainWin; input=$inline; rowOffset="key$i" } }
        }
    }
    return [pscustomobject]@{ ok=$false; opened=$opened }
}

# 검색 결과 목록의 행을 눌러 채팅방을 연다. 채팅 탭/친구 탭 공통.
function Open-KakaoRoomFromList {
    param(
        [Parameter(Mandatory)][string]$Room,
        [Parameter(Mandatory)]$List,
        [int[]]$RowOffsets,
        [int]$WaitMs = 1200
    )
    $mainWin  = Get-KakaoMainWindow
    $mainHwnd = if ($mainWin) { [int64]$mainWin.Hwnd } else { 0 }
    $before = @(Get-KakaoTopWindows | Where-Object { $_.Visible -and $_.Title } | ForEach-Object { [int64]$_.Hwnd })

    foreach ($off in $RowOffsets) {
        Send-DoubleClick -Hwnd $List.Hwnd -X 120 -Y $off
        Start-Sleep -Milliseconds $WaitMs

        $new = Get-KakaoTopWindows |
               Where-Object { $_.Visible -and $_.Title -and ($before -notcontains [int64]$_.Hwnd) -and ([int64]$_.Hwnd -ne $mainHwnd) } |
               Select-Object -First 1
        if ($new) {
            $match = ($new.Title -eq $Room) -or ($new.Title.Replace(' ','').StartsWith($Room.Replace(' ','')))
            # 친구 프로필 카드는 제목이 이름과 같지만 입력창이 없다. 그것까지 걸러낸다.
            if ($match -and -not (Get-KakaoInputBox -RoomHwnd $new.Hwnd)) { $match = $false }
            if ($match) { return [pscustomobject]@{ ok=$true; mode='window'; window=$new; rowOffset=$off } }
            [void][KK]::PostMessage($new.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
            Start-Sleep -Milliseconds 400
            continue
        }

        if ($mainHwnd -ne 0) {
            $inline = Get-KakaoInlineInput -MainHwnd ([IntPtr]$mainHwnd)
            if ($inline) { return [pscustomobject]@{ ok=$true; mode='inline'; window=$mainWin; input=$inline; rowOffset=$off } }
        }
    }
    return [pscustomobject]@{ ok=$false }
}

<#
  채팅 탭에서 방을 찾아 연다.

  친구 탭에서 찾는 기능은 뺐다. 탭 막대를 눌러 옮겨 다니다가 '더보기' 탭에
  갇히는 일이 있었고, 그 상태가 되면 이후 모든 전송이 실패했다.
#>
function Open-KakaoRoom {
    param(
        [Parameter(Mandatory)][string]$Room,
        [int[]]$RowOffsets = @(30, 62, 92, 122, 152, 182),
        [int]$WaitMs = 1200
    )

    $mw = Get-KakaoMainWindow
    if (-not $mw) { return [pscustomobject]@{ ok=$false; error='카카오톡 메인창을 찾을 수 없음' } }

    # ---- 1) 채팅 목록에서 찾는다. 대부분 여기서 끝난다 ----
    if (-not (Test-KakaoChatTabActive -Main $mw -WaitMs 2500)) { [void](Select-KakaoChatTab -Main $mw) }
    $found = Invoke-KakaoSearch -Text $Room -Tab chat
    if ($found) {
        $r = Open-KakaoRoomByKeys -Room $Room -List $found.list
        if (-not $r.ok -and $r.opened -eq 0) {
            $r = Open-KakaoRoomFromList -Room $Room -List $found.list -RowOffsets $RowOffsets -WaitMs $WaitMs
        }
        Clear-KakaoSearch
        if ($r.ok) { return $r }
    }
    Clear-KakaoSearch

    # ---- 2) 친구 목록에서 찾는다. 아직 한 번도 대화하지 않은 상대 ----
    $found2 = $null
    $mw = Get-KakaoMainWindow
    if ($mw -and (Select-KakaoFriendTab -Main $mw)) {
        $found2 = Invoke-KakaoSearch -Text $Room -Tab friend
        $r2 = $null
        if ($found2) {
            $r2 = Open-KakaoRoomByKeys -Room $Room -List $found2.list
            if (-not $r2.ok -and $r2.opened -eq 0) {
                $r2 = Open-KakaoRoomFromList -Room $Room -List $found2.list -RowOffsets $RowOffsets -WaitMs $WaitMs
            }
        }
        Clear-KakaoSearch
        # 어느 쪽이든 채팅 탭으로 되돌려 둔다. 친구 탭에 남으면 다음 전송이 느려진다.
        $mw2 = Get-KakaoMainWindow
        if ($mw2) { [void](Select-KakaoChatTab -Main $mw2) }
        if ($r2 -and $r2.ok) {
            $r2 | Add-Member -NotePropertyName viaFriend -NotePropertyValue $true -Force
            return $r2
        }
    }

    <#
      검색 결과 목록이 한 번도 뜨지 않았다면 방이 없는 게 아니라
      검색 UI 가 아직 준비되지 않은 것이다(부팅 직후 카톡이 뜨는 중 등).
      이건 다시 시도하면 되는 상황이라 구분해서 알린다.
    #>
    if (-not $found -and -not $found2) {
        return [pscustomobject]@{ ok=$false; searchFailed=$true
            error="검색 결과 목록이 뜨지 않음 ('$Room'). 카카오톡이 아직 준비되지 않았을 수 있습니다." }
    }
    return [pscustomobject]@{ ok=$false; roomMissing=$true
        error="'$Room' 을(를) 열지 못함. 채팅 목록과 친구 목록 모두에서 찾지 못했습니다." }
}
