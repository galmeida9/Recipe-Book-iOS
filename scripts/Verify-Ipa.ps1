param(
    [Parameter(Mandatory = $true)][string]$IpaPath
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
    if (-not ($names -match '^Payload/[^/]+\.app/embedded\.mobileprovision$')) { throw 'App provisioning profile is missing.' }
    if (-not ($names -match '^Payload/[^/]+\.app/PlugIns/RecipeBookShare\.appex/embedded\.mobileprovision$')) {
        throw 'Share-extension provisioning profile is missing.'
    }
    Write-Output 'Bundle layout contains the app, extension and both profiles. Cryptographic entitlement/profile validation and iPhone tests are still required.'
} finally { $archive.Dispose() }
