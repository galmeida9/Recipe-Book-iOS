$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& npm.cmd --prefix (Join-Path $root 'backend') ci --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
& npm.cmd --prefix (Join-Path $root 'backend') run check
if ($LASTEXITCODE -ne 0) { throw 'Backend validation failed.' }
if (Get-Command swift -ErrorAction SilentlyContinue) {
    Push-Location $root
    try {
        & swift test
        if ($LASTEXITCODE -ne 0) { throw 'Portable Swift validation failed.' }
    } finally { Pop-Location }
} else {
    Write-Warning 'Portable Swift tests not run: Swift is not installed. This does not validate the iOS app.'
}
