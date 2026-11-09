# Run the same checks as GitHub CI, on this Windows computer: analyzer + all tests.
#   powershell -ExecutionPolicy Bypass -File app\tool\check.ps1          analyze + test
#   powershell -ExecutionPolicy Bypass -File app\tool\check.ps1 -Build   also build the Windows app
param([switch]$Build)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
function Step($cmd) {
  Write-Host "> flutter $cmd" -ForegroundColor Cyan
  & flutter @($cmd -split ' ')
  if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: flutter $cmd" -ForegroundColor Red; exit $LASTEXITCODE }
}
Step 'pub get'
Step 'analyze'
Step 'test'
if ($Build) { Step 'build windows --release' }
Write-Host 'All checks passed.' -ForegroundColor Green
