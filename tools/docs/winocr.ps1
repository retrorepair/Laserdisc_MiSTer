# OCR every pNNN.png in a directory with the built-in Windows.Media.Ocr engine
# and write one combined UTF-8 text file with "===== PAGE N =====" separators.
# Usage: powershell -ExecutionPolicy Bypass -File winocr.ps1 <imagedir> <out.txt>
param([string]$ImageDir, [string]$OutFile)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) {
    $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
    $task.Wait() | Out-Null
    $task.Result
}

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) { throw 'No OCR engine for user profile languages' }

$sb = New-Object System.Text.StringBuilder
Get-ChildItem -Path $ImageDir -Filter 'p*.png' | Sort-Object Name | ForEach-Object {
    $n = [int]($_.BaseName.Substring(1))
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($_.FullName)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    [void]$sb.AppendLine("===== PAGE $n =====")
    foreach ($line in $res.Lines) { [void]$sb.AppendLine($line.Text) }
    $stream.Dispose()
}
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
Write-Output "wrote $OutFile"
