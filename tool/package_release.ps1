# Builds the release/ folder and beam_share_final.zip.
#
# Run from the project root after building:
#   flutter build apk --release
#   flutter build windows --release
#   powershell -ExecutionPolicy Bypass -File tool\package_release.ps1
#
# release/
#   BeamShare-android.apk
#   BeamShare-windows-x64.zip   (unzip anywhere, run beam_share.exe)
# ..\beam_share_final.zip       (source without generated folders + release/)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$release = Join-Path $root 'release'
New-Item -ItemType Directory -Force $release | Out-Null

$apk = 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) { throw "APK not found: run 'flutter build apk --release' first" }
Copy-Item $apk (Join-Path $release 'BeamShare-android.apk') -Force

$win = 'build\windows\x64\runner\Release'
if (-not (Test-Path "$win\beam_share.exe")) { throw "Windows build not found: run 'flutter build windows --release' first" }
$winZip = Join-Path $release 'BeamShare-windows-x64.zip'
if (Test-Path $winZip) { Remove-Item $winZip -Force }
Compress-Archive -Path "$win\*" -DestinationPath $winZip -CompressionLevel Optimal

# Source copy without generated / machine-specific folders.
$stage = Join-Path $env:TEMP 'beam_share_stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$dest = Join-Path $stage 'beam_share'
New-Item -ItemType Directory -Force $dest | Out-Null
$exclude = @('build', '.dart_tool', '.idea', '.gradle', '.kotlin', 'ephemeral', '.plugin_symlinks', 'Pods', '.symlinks', '.git', '.cxx')
robocopy $root $dest /E /NFL /NDL /NJH /NJS /NP /XD $exclude /XF '*.iml' 'local.properties' '.flutter-plugins' '.flutter-plugins-dependencies' | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

$final = Join-Path (Split-Path -Parent $root) 'beam_share_final.zip'
if (Test-Path $final) { Remove-Item $final -Force }
Compress-Archive -Path $dest -DestinationPath $final -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force

Get-Item $final, (Join-Path $release '*') | Select-Object FullName, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
