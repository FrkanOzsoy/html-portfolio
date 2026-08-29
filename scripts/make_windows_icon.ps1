# Build a proper multi-resolution windows/runner/resources/app_icon.ico from
# assets/icon/icon.png -- flutter_launcher_icons only emits one 256px frame,
# which Windows downscales blurrily for the small taskbar sizes.
#   powershell -ExecutionPolicy Bypass -File scripts/make_windows_icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'assets\icon\icon.png'
$out  = Join-Path $root 'windows\runner\resources\app_icon.ico'
$img  = [System.Drawing.Image]::FromFile($src)
$sizes = 256,128,64,48,32,24,16
$pngs = @()
foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap $s, $s
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.SmoothingMode = 'HighQuality'
  $g.DrawImage($img, 0, 0, $s, $s); $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $pngs += ,($ms.ToArray())
}
$img.Dispose()
$n = $pngs.Count
$fs = [System.IO.File]::Create($out); $bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$n)
$offset = 6 + 16 * $n
for ($i = 0; $i -lt $n; $i++) {
  $s = $sizes[$i]; $d = $pngs[$i]
  $b = if ($s -ge 256) { 0 } else { $s }
  $bw.Write([byte]$b); $bw.Write([byte]$b); $bw.Write([byte]0); $bw.Write([byte]0)
  $bw.Write([UInt16]1); $bw.Write([UInt16]32)
  $bw.Write([UInt32]$d.Length); $bw.Write([UInt32]$offset)
  $offset += $d.Length
}
foreach ($d in $pngs) { $bw.Write($d) }
$bw.Flush(); $bw.Close(); $fs.Close()
Write-Output ("wrote {0} ({1} sizes, {2} bytes)" -f $out, $n, (Get-Item $out).Length)
