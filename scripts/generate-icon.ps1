$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$taskRoot = Split-Path -Parent $PSScriptRoot
$assetPath = Join-Path $taskRoot 'assets'
[System.IO.Directory]::CreateDirectory($assetPath) | Out-Null
$iconFrames = [System.Collections.Generic.List[byte[]]]::new()
$iconSizes = @(16, 24, 32, 48, 64, 128, 256)
$sourceImage = [System.Drawing.Image]::FromFile((Join-Path $assetPath 'Brand\sunicapture-icon.png'))
foreach ($iconSize in $iconSizes) {
    $bitmap = [System.Drawing.Bitmap]::new($iconSize, $iconSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($sourceImage, [System.Drawing.Rectangle]::new(0, 0, $iconSize, $iconSize))
    $memory = [System.IO.MemoryStream]::new()
    $bitmap.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
    $iconFrames.Add($memory.ToArray())
    $memory.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$sourceImage.Dispose()
$stream = [System.IO.File]::Create((Join-Path $assetPath 'SuniCapture.ico'))
$writer = [System.IO.BinaryWriter]::new($stream)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$iconFrames.Count)
    $iconOffset = 6 + 16 * $iconFrames.Count
    for ($i = 0; $i -lt $iconFrames.Count; $i++) {
        $sizeByte = if ($iconSizes[$i] -eq 256) { 0 } else { $iconSizes[$i] }
        $writer.Write([byte]$sizeByte); $writer.Write([byte]$sizeByte); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$iconFrames[$i].Length); $writer.Write([uint32]$iconOffset)
        $iconOffset += $iconFrames[$i].Length
    }
    foreach ($frame in $iconFrames) { $writer.Write($frame) }
}
finally { $writer.Dispose(); $stream.Dispose() }
Write-Output 'assets/SuniCapture.ico generated'
