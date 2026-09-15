param(
    [Parameter(Mandatory=$true)]
    [string]$ZipPath,

    [string]$Repo = "newbie7627-ops/joonwoocraft-resourcepacks",

    [string]$Tag
)

$ErrorActionPreference = "Stop"

function Assert-LastExitCode {
    param(
        [Parameter(Mandatory=$true)][string]$Message
    )
    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

$resolved = Resolve-Path -LiteralPath $ZipPath
$zip = $resolved.Path
$name = [System.IO.Path]::GetFileName($zip)
$file = Get-Item -LiteralPath $zip

if ($file.Length -le 0) {
    throw "ZIP is empty."
}

if (-not $Tag) {
    if ($name -match '^resourcepacks-(\d+\.\d+\.\d+)\.zip$') {
        $Tag = "resourcepacks-$($Matches[1])"
    } else {
        throw "Cannot infer release tag from '$name'. Use -Tag resourcepacks-X.Y.Z or rename the file to resourcepacks-X.Y.Z.zip."
    }
}

if ($Tag -notmatch '^resourcepacks-\d+\.\d+\.\d+$') {
    throw "Invalid tag '$Tag'. Expected resourcepacks-X.Y.Z"
}

$expectedName = "$Tag.zip"
if ($name -cne $expectedName) {
    throw "ZIP filename must exactly match tag: expected '$expectedName', got '$name'."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is not installed. Install once with: winget install --id GitHub.cli"
}

# Verify GitHub authentication and repository access before touching a release.
gh auth status --hostname github.com | Out-Host
Assert-LastExitCode "GitHub CLI is not authenticated for github.com. Run once: gh auth login"

$defaultBranch = gh repo view $Repo --json defaultBranchRef --jq '.defaultBranchRef.name'
Assert-LastExitCode "Cannot access repository '$Repo'."
$defaultBranch = ($defaultBranch | Out-String).Trim()
if (-not $defaultBranch) {
    throw "Could not determine the default branch for '$Repo'."
}

# Deep ZIP validation. Opening the archive alone only validates the central directory,
# so every file stream is read completely to catch truncated/corrupt compressed data.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    if ($archive.Entries.Count -eq 0) {
        throw "ZIP contains no entries."
    }

    $duplicate = $archive.Entries | Group-Object FullName | Where-Object { $_.Count -gt 1 }
    if ($duplicate) {
        throw "ZIP contains duplicate entries: $($duplicate.Name -join ', ')"
    }

    $caseDuplicate = $archive.Entries | Group-Object { $_.FullName.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 }
    if ($caseDuplicate) {
        throw "ZIP contains case-colliding paths: $($caseDuplicate.Name -join ', ')"
    }

    $packMeta = $archive.GetEntry('pack.mcmeta')
    if (-not $packMeta) {
        throw "ZIP is not a valid Minecraft resource pack: pack.mcmeta is missing."
    }

    $hasAssets = $false
    $buffer = New-Object byte[] 65536
    foreach ($entry in $archive.Entries) {
        $entryName = $entry.FullName

        if ($entryName.StartsWith('/') -or $entryName.StartsWith('\\') -or $entryName -match '(^|/)\.\.(/|$)') {
            throw "Unsafe ZIP path detected: '$entryName'"
        }

        if ($entryName.StartsWith('assets/')) {
            $hasAssets = $true
        }

        if ($entryName.EndsWith('/')) {
            continue
        }

        $stream = $entry.Open()
        try {
            while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
        } finally {
            $stream.Dispose()
        }
    }

    if (-not $hasAssets) {
        throw "ZIP has no assets/ content."
    }

    $metaStream = $packMeta.Open()
    try {
        $reader = New-Object System.IO.StreamReader($metaStream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            $metaText = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
        $meta = $metaText | ConvertFrom-Json
        if (-not $meta.pack) {
            throw "pack.mcmeta does not contain a 'pack' object."
        }
    } finally {
        $metaStream.Dispose()
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
$size = $file.Length

Write-Host "ZIP: $zip"
Write-Host "TAG: $Tag"
Write-Host "TARGET: $defaultBranch"
Write-Host "SIZE: $size bytes"
Write-Host "SHA256: $hash"

# Refuse to collide with an existing release or Git tag.
$releaseListJson = gh release list --repo $Repo --limit 100 --json tagName
Assert-LastExitCode "Could not query existing releases for '$Repo'."
$releaseList = $releaseListJson | ConvertFrom-Json
if ($releaseList | Where-Object { $_.tagName -eq $Tag }) {
    throw "Release '$Tag' already exists. Refusing to overwrite it."
}

$tagRefsJson = gh api "repos/$Repo/git/matching-refs/tags/$Tag"
Assert-LastExitCode "Could not query existing tags for '$Repo'."
$tagRefs = $tagRefsJson | ConvertFrom-Json
if ($tagRefs.Count -gt 0) {
    throw "Git tag '$Tag' already exists. Refusing to reuse it automatically."
}

$notes = @"
JoonwooCraft resource pack release $Tag

SHA256: $hash
Size: $size bytes
"@

# Create the tag/release and upload the exact ZIP.
gh release create $Tag $zip --repo $Repo --title $Tag --notes $notes --target $defaultBranch
if ($LASTEXITCODE -ne 0) {
    # A failed upload can leave a partial release/tag. Since both were confirmed absent
    # immediately before this command, clean up only this newly attempted release.
    gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
    throw "GitHub release creation/upload failed. Any partial release/tag from this attempt was cleaned up."
}

# Verify server-side metadata.
$releaseJson = gh api "repos/$Repo/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) {
    gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
    throw "Release was created but could not be read back. The new release/tag was cleaned up."
}

$release = $releaseJson | ConvertFrom-Json
$asset = $release.assets | Where-Object { $_.name -eq $expectedName } | Select-Object -First 1
if (-not $asset) {
    gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
    throw "Release was created but '$expectedName' is missing. The new release/tag was cleaned up."
}
if ($asset.state -ne 'uploaded') {
    gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
    throw "Uploaded asset is not in state 'uploaded'. The new release/tag was cleaned up."
}
if ([int64]$asset.size -ne [int64]$size) {
    gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
    throw "Uploaded asset size mismatch. The new release/tag was cleaned up."
}

# End-to-end verification: download the just-published asset into a fresh temp directory
# and compare SHA256 with the local source ZIP. This catches a bad/truncated upload even
# when release creation itself reported success.
$verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("joonwoocraft-rp-verify-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verifyDir | Out-Null
try {
    gh release download $Tag --repo $Repo --pattern $expectedName --dir $verifyDir
    if ($LASTEXITCODE -ne 0) {
        gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
        throw "Could not download the published asset for verification. The new release/tag was cleaned up."
    }

    $downloaded = Join-Path $verifyDir $expectedName
    if (-not (Test-Path -LiteralPath $downloaded)) {
        gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
        throw "Published asset verification file is missing. The new release/tag was cleaned up."
    }

    $remoteHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
    if ($remoteHash -ne $hash) {
        gh release delete $Tag --repo $Repo --cleanup-tag --yes *> $null
        throw "Published asset SHA256 mismatch. The bad release/tag was cleaned up. Local=$hash Remote=$remoteHash"
    }
} finally {
    Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
}

$assetUrl = "https://github.com/$Repo/releases/download/$Tag/$expectedName"

Write-Host ""
Write-Host "PUBLISHED + VERIFIED OK"
Write-Host "Asset: $expectedName"
Write-Host "Size: $size bytes"
Write-Host "SHA256: $hash"
Write-Host "URL: $assetUrl"
