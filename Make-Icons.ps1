<#
  Make-Icons.ps1 - 실행 파일에 넣을 아이콘을 그려서 .ico 로 저장한다.

  카카오톡 아이콘을 바탕으로 하고 우하단에 배지를 덧그린다.
  지인에게만 나눠 주는 개인용 도구라는 전제다.

    relay.ico     카톡 아이콘 + 오른쪽 화살표 배지 (문자를 카톡으로 넘긴다)
    watchdog.ico  청록으로 물들인 카톡 아이콘 + 체크 배지 (릴레이가 살아있는지 지켜본다)

  바탕 그림은 base-bubble.png. 없으면 KakaoTalk.exe 에서 뽑고,
  그것도 없으면 자체 말풍선 도형으로 대체한다.

  ICO 는 크기별로 따로 그려서 다중 크기로 기록한다.
  (256px 하나만 넣고 윈도우가 줄이게 두면 16/24px 에서 뭉개진다)
  128px 이하는 32bpp BMP, 256px 은 PNG 로 넣는다 - 둘 다 표준이다.
#>
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not ('IconNative' -as [type])) {
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class IconNative {
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] hIcons, int[] ids, int count, int flags);
}
'@
}

$Sizes = @(16, 20, 24, 32, 40, 48, 64, 96, 128, 256)

# ------------------------------------------------------------------ 바탕 그림

<#
  투명 여백을 잘라낸다.
  원본 PNG 는 사방에 여백과 옅은 그림자가 있어서, 그대로 쓰면
  진짜 카톡 아이콘보다 작아 보인다. 불투명한 부분만 남긴다.
  (알파 200 기준 - 반투명한 그림자는 여백으로 친다)
#>
function Get-OpaqueBounds([System.Drawing.Bitmap]$Bmp) {
    $w = $Bmp.Width; $h = $Bmp.Height
    $bd = $Bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $w, $h)),
          [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $buf = New-Object byte[] ($bd.Stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
        for ($y = 0; $y -lt $h; $y++) {
            $ro = $y * $bd.Stride
            for ($x = 0; $x -lt $w; $x++) {
                if ($buf[$ro + $x * 4 + 3] -gt 200) {
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }
    } finally { $Bmp.UnlockBits($bd) }
    if ($maxX -lt 0) { return (New-Object System.Drawing.Rectangle(0, 0, $w, $h)) }
    return (New-Object System.Drawing.Rectangle($minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)))
}

function Get-KakaoTalkBitmap {
    # 32px 아이콘이 말풍선만 있는 판이다 (40px 이상은 TALK 글자가 들어간다)
    $exe = @(
        'C:\Program Files\Kakao\KakaoTalk\KakaoTalk.exe',
        'C:\Program Files (x86)\Kakao\KakaoTalk\KakaoTalk.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { return $null }
    $hIcons = New-Object IntPtr[] 1; $ids = New-Object int[] 1
    $n = [IconNative]::PrivateExtractIcons($exe, 0, 32, 32, $hIcons, $ids, 1, 0)
    if ($n -lt 1 -or $hIcons[0] -eq [IntPtr]::Zero) { return $null }
    try {
        $ic = [System.Drawing.Icon]::FromHandle($hIcons[0]); $src = $ic.ToBitmap()
        $out = New-Object System.Drawing.Bitmap(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($out)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
        $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, 512, 512)))
        $g.Dispose(); $src.Dispose()
        return $out
    } finally { [void][IconNative]::DestroyIcon($hIcons[0]) }
}

function New-FallbackBubble {
    # 카톡을 못 찾았을 때 쓰는 자체 도형
    $s = 512
    $out = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.SmoothingMode = 'AntiAlias'
    $r = $s * 0.235
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, ($r * 2), ($r * 2), 180, 90)
    $path.AddArc(($s - $r * 2), 0, ($r * 2), ($r * 2), 270, 90)
    $path.AddArc(($s - $r * 2), ($s - $r * 2), ($r * 2), ($r * 2), 0, 90)
    $path.AddArc(0, ($s - $r * 2), ($r * 2), ($r * 2), 90, 90)
    $path.CloseFigure()
    $yellow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 254, 227, 0))
    $g.FillPath($yellow, $path)
    $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 58, 33, 30))
    $g.FillEllipse($ink, ($s * 0.13), ($s * 0.15), ($s * 0.74), ($s * 0.58))
    $g.FillPolygon($ink, @(
        (New-Object System.Drawing.PointF([single]($s * 0.30), [single]($s * 0.62))),
        (New-Object System.Drawing.PointF([single]($s * 0.44), [single]($s * 0.70))),
        (New-Object System.Drawing.PointF([single]($s * 0.29), [single]($s * 0.87)))))
    $yellow.Dispose(); $ink.Dispose(); $path.Dispose(); $g.Dispose()
    return $out
}

<#
  감시자용 색 바꾸기.
  ColorMatrix 로 돌리면 형광 청록이 나와서 눈이 아프다.
  바탕이 사실상 두 색(어두운 말풍선 / 노란 배경)뿐이므로
  밝기를 기준으로 두 목표 색 사이를 섞는다. 가장자리 안티에일리어싱이 그대로 남는다.
#>
function New-Tinted([System.Drawing.Bitmap]$Src) {
    $w = $Src.Width; $h = $Src.Height
    $out = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rc = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $s = $Src.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,  [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $out.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $n = $s.Stride * $h
        $px = New-Object byte[] $n
        [System.Runtime.InteropServices.Marshal]::Copy($s.Scan0, $px, 0, $n)
        $dR = 26.0; $dG = 58.0;  $dB = 56.0     # 어두운 쪽 (말풍선)
        $lR = 27.0; $lG = 176.0; $lB = 160.0    # 밝은 쪽 (배경)
        for ($i = 0; $i -lt $n; $i += 4) {
            if ($px[$i + 3] -eq 0) { continue }
            $L = (0.299 * $px[$i + 2] + 0.587 * $px[$i + 1] + 0.114 * $px[$i]) / 255.0
            $t = ($L - 0.19) / 0.66
            if ($t -lt 0) { $t = 0 } elseif ($t -gt 1) { $t = 1 }
            $px[$i]     = [byte][Math]::Round($dB + ($lB - $dB) * $t)
            $px[$i + 1] = [byte][Math]::Round($dG + ($lG - $dG) * $t)
            $px[$i + 2] = [byte][Math]::Round($dR + ($lR - $dR) * $t)
        }
        [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $d.Scan0, $n)
    } finally { $Src.UnlockBits($s); $out.UnlockBits($d) }
    return $out
}

# ------------------------------------------------------------------ 크기별 렌더

function New-Frame([int]$S, [string]$Kind, [System.Drawing.Bitmap]$Base) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($Base, (New-Object System.Drawing.Rectangle(0, 0, $S, $S)))   # 캔버스를 꽉 채운다

    # 작을수록 배지를 조금 키우고 글리프를 단순하게. 안 그러면 뭉개져서 얼룩으로만 보인다.
    $tiny = ($S -le 20)
    $d    = if ($tiny) { [double]$S * 0.55 } else { [double]$S * 0.48 }
    $ring = if ($tiny) { 1.0 } else { [Math]::Max(1.0, $S * 0.05) }
    $bx = $S - $d; $by = $S - $d
    $g.FillEllipse([System.Drawing.Brushes]::White, ($bx - $ring), ($by - $ring), ($d + $ring * 2), ($d + $ring * 2))
    $col = if ($Kind -eq 'watchdog') { [System.Drawing.Color]::FromArgb(255, 16, 110, 100) }
           else                      { [System.Drawing.Color]::FromArgb(255, 42, 26, 24) }
    $br = New-Object System.Drawing.SolidBrush $col
    $g.FillEllipse($br, $bx, $by, $d, $d)
    $cx = $bx + $d / 2; $cy = $by + $d / 2

    if ($Kind -eq 'watchdog') {
        if ($tiny) {
            $r = $d * 0.21     # 체크는 이 크기에서 안 읽힌다. 점 하나로 간다.
            $g.FillEllipse([System.Drawing.Brushes]::White, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2))
        } else {
            $p = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single][Math]::Max(1.3, $d * 0.17))
            $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'
            $g.DrawLines($p, @(
                (New-Object System.Drawing.PointF([single]($cx - $d * 0.23), [single]($cy + $d * 0.02))),
                (New-Object System.Drawing.PointF([single]($cx - $d * 0.05), [single]($cy + $d * 0.19))),
                (New-Object System.Drawing.PointF([single]($cx + $d * 0.24), [single]($cy - $d * 0.20)))))
            $p.Dispose()
        }
    } else {
        $t = if ($tiny) { $d * 0.28 } else { $d * 0.25 }
        $g.FillPolygon([System.Drawing.Brushes]::White, @(
            (New-Object System.Drawing.PointF([single]($cx - $t * 0.72), [single]($cy - $t))),
            (New-Object System.Drawing.PointF([single]($cx + $t * 0.98), [single]$cy)),
            (New-Object System.Drawing.PointF([single]($cx - $t * 0.72), [single]($cy + $t)))))
    }
    $br.Dispose(); $g.Dispose()
    return $bmp
}

# ------------------------------------------------------------------ ICO 기록

function Get-BmpPayload([System.Drawing.Bitmap]$Bmp, [int]$S) {
    # ICO 안의 BMP: 정보 헤더의 높이는 실제의 2배(XOR + AND), 픽셀은 아래에서 위로.
    $bd = $Bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $S, $S)),
          [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $px = New-Object byte[] ($bd.Stride * $S)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $px, 0, $px.Length)
        $maskStride = [int][Math]::Floor(($S + 31) / 32) * 4
        $ms = New-Object System.IO.MemoryStream
        $w = New-Object System.IO.BinaryWriter $ms
        $w.Write([uint32]40); $w.Write([int32]$S); $w.Write([int32]($S * 2))
        $w.Write([uint16]1);  $w.Write([uint16]32); $w.Write([uint32]0)
        $w.Write([uint32]($S * $S * 4 + $maskStride * $S))
        $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
        for ($y = $S - 1; $y -ge 0; $y--) { $w.Write($px, ($y * $bd.Stride), ($S * 4)) }
        $w.Write((New-Object byte[] ($maskStride * $S)))   # 알파를 쓰므로 AND 마스크는 전부 0
        $w.Flush()
        $out = $ms.ToArray(); $w.Dispose(); $ms.Dispose()
        return , $out          # 쉼표 없이 반환하면 byte[] 가 Object[] 로 풀린다
    } finally { $Bmp.UnlockBits($bd) }
}

function Write-Ico([string]$Path, [string]$Kind, [System.Drawing.Bitmap]$Base) {
    $entries = @()
    foreach ($S in $Sizes) {
        $bmp = New-Frame $S $Kind $Base
        if ($S -eq 256) {
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $payload = $ms.ToArray(); $ms.Dispose()
        } else {
            $payload = [byte[]](Get-BmpPayload $bmp $S)
        }
        $entries += , @{ S = $S; Data = $payload }
        $bmp.Dispose()
    }
    $tmp = "$Path.new"
    $fs = New-Object System.IO.FileStream $tmp, 'Create'
    $w = New-Object System.IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$entries.Count)
    $off = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $b = if ($e.S -eq 256) { 0 } else { $e.S }   # 256 은 0 으로 적는 것이 규격
        $w.Write([byte]$b); $w.Write([byte]$b); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$e.Data.Length); $w.Write([uint32]$off)
        $off += $e.Data.Length
    }
    foreach ($e in $entries) { $w.Write($e.Data) }
    $w.Flush(); $w.Dispose(); $fs.Dispose()

    # 읽어서 확인되기 전에는 기존 파일을 덮지 않는다
    foreach ($chk in 16, 32, 48) {
        $i = New-Object System.Drawing.Icon $tmp, $chk, $chk
        if ($i.Width -ne $chk) { $i.Dispose(); Remove-Item $tmp -Force; throw "$Path : ${chk}px 확인 실패" }
        $i.Dispose()
    }
    Move-Item $tmp $Path -Force
    Write-Host ("  {0,-14} {1} 크기  {2:N0} bytes" -f (Split-Path $Path -Leaf), $entries.Count, (Get-Item $Path).Length)
}

# ------------------------------------------------------------------ 실행

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Host '  아이콘 만들기'
$png = Join-Path $root 'base-bubble.png'
if (Test-Path $png) {
    $raw = [System.Drawing.Bitmap]::FromFile($png)
    Write-Host "  바탕: base-bubble.png"
} else {
    $raw = Get-KakaoTalkBitmap
    if ($raw) { Write-Host '  바탕: KakaoTalk.exe 아이콘' }
    else      { $raw = New-FallbackBubble; Write-Host '  바탕: 자체 도형 (카카오톡을 찾지 못함)' }
}

$crop = Get-OpaqueBounds $raw
$baseRelay = New-Object System.Drawing.Bitmap($crop.Width, $crop.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$gb = [System.Drawing.Graphics]::FromImage($baseRelay)
$gb.DrawImage($raw, (New-Object System.Drawing.Rectangle(0, 0, $crop.Width, $crop.Height)),
              $crop.X, $crop.Y, $crop.Width, $crop.Height, [System.Drawing.GraphicsUnit]::Pixel)
$gb.Dispose(); $raw.Dispose()
Write-Host ("  여백 잘라냄 -> {0}x{1}" -f $crop.Width, $crop.Height)

$baseWatch = New-Tinted $baseRelay
try {
    Write-Ico (Join-Path $root 'relay.ico')    'relay'    $baseRelay
    Write-Ico (Join-Path $root 'watchdog.ico') 'watchdog' $baseWatch
} finally { $baseRelay.Dispose(); $baseWatch.Dispose() }
