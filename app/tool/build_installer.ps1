# Build the Casework Windows installer on this PC, the same way GitHub does for a release.
# Use it when GitHub Actions can't run (for example, the monthly build minutes are used up).
#
#   powershell -ExecutionPolicy Bypass -File app\tool\build_installer.ps1
#
# Needs: Flutter, Visual Studio with "Desktop development with C++", and Inno Setup 6
# (https://jrsoftware.org/isdl.php). Result: app\build\installer\Casework-Setup-<version>.exe
# Then on GitHub: Releases -> Draft a new release -> tag v<version> -> attach that .exe -> Publish.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

function Run($exe, [string[]]$params) {
  Write-Host "> $exe $($params -join ' ')" -ForegroundColor Cyan
  & $exe @params
  if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: $exe $($params -join ' ')" -ForegroundColor Red; exit $LASTEXITCODE }
}

$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
  Write-Host 'Inno Setup 6 is not installed. Get it from https://jrsoftware.org/isdl.php and run this again.' -ForegroundColor Red
  exit 1
}

# Same checks as GitHub runs before any release.
Run flutter @('pub', 'get')
Run flutter @('analyze')
Run flutter @('test')
Run flutter @('build', 'windows', '--release')

# The Visual C++ runtime goes inside the installer so PCs without it still work.
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item "$env:WINDIR\System32\$dll" build\windows\x64\runner\Release\ -Force
}

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value)
Run $iscc @("/DAppVersion=$version", 'windows\installer\cabinet_crm.iss')

$out = Resolve-Path "build\installer\Casework-Setup-$version.exe"
Write-Host ''
Write-Host "Installer ready: $out" -ForegroundColor Green
Write-Host "Publish it: GitHub -> Releases -> Draft a new release -> tag v$version -> attach the .exe -> Publish release."
