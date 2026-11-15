param(
    [Parameter(Mandatory = $true)][string]$IpaPath,
    [switch]$UnsignedInstallationCheck
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$resolved = (Resolve-Path -LiteralPath $IpaPath).Path
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolved)
try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName })
    if (-not ($names -match '^Payload/[^/]+\.app/[^/]+$')) { throw 'IPA has no app payload.' }
    if (-not ($names -match '^Payload/[^/]+\.app/PlugIns/RecipeBookShare\.appex/RecipeBookShare$')) {
        throw 'Required share extension is missing. Do not distribute this IPA.'
    }
    if ($UnsignedInstallationCheck) {
        if ([System.IO.Path]::GetFileName($resolved) -ne 'RecipeBook-installation-check.ipa') { throw 'Unsigned mode is only for the named installation-check package.' }
        if ((Get-Item -LiteralPath $resolved).Length -gt 67108864) { throw 'Installation-check package exceeds 64 MiB.' }
        if ($names -match 'embedded\.mobileprovision$|\.p12$|\.p8$') { throw 'Unsigned installation-check package must not contain provisioning profiles or signing keys.' }
        Write-Output 'Unsigned installation-check layout retains app and share extension. SideStore must re-sign both; this is not signing, installation, login or live-data proof.'
        return
    }
    if (-not ($names -match '^Payload/[^/]+\.app/embedded\.mobileprovision$')) { throw 'App provisioning profile is missing.' }
    if (-not ($names -match '^Payload/[^/]+\.app/PlugIns/RecipeBookShare\.appex/embedded\.mobileprovision$')) {
        throw 'Share-extension provisioning profile is missing.'
    }
    Write-Output 'Bundle layout contains the app, extension and both profiles. Cryptographic entitlement/profile validation and iPhone tests are still required.'
} finally { $archive.Dispose() }
