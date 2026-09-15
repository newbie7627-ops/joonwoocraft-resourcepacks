param(
    [Parameter(Mandatory=$true)]
    [string]$ZipPath,

    [string]$Repo = "newbie7627-ops/joonwoocraft-resourcepacks",

    [string]$Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-ExitCode {
    param(
        [Parameter(Mandatory=$true)][int]$Code,
        [Parameter(Mandatory=$true)][string]$Message
    )
    if ($Code -ne 0) {
        throw $Message
    }
}

function Remove-AttemptRelease {
    param(
        [Parameter(Mandatory=$true)][string]$ReleaseTag,
        [Parameter(Mandatory=$true)][string]$Repository
    )
    gh release delete $ReleaseTag --repo $Repository --cleanup-tag --yes *> $null
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
Assert-ExitCode -Code $LASTEXITCODE -Message "GitHub CLI is not authenticated for github.com. Run once: gh auth login"

$defaultBranch = gh repo view $Repo --json defaultBranchRef --jq '.defaultBranchRef.name'
Assert-ExitCode -Code $LASTEXITCODE -Message "Cannot access repository '$Repo'."
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

    $exactNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $foldedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $packMeta = $archive.GetEntry('pack.mcmeta')
    if (-not $packMeta) {
        throw "ZIP is not a valid Minecraft resource pack: pack.mcmeta is missing."
    }

    $hasAssets = $false
    $buffer = New-Object byte[] 65536

    foreach ($entry in $archive.Entries) {
        $entryName = $entry.FullName

        if (-not $exactNames.Add($entryName)) {
            throw "ZIP contains duplicate entry '$entryName'."
        }
        if (-not $foldedNames.Add($entryName)) {
            throw "ZIP contains case-colliding path '$entryName'."
        }

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
$size = [int64]$file.Length

Write-Host "ZIP: $zip"
Write-Host "TAG: $Tag"
Write-Host "TARGET: $defaultBranch"
Write-Host "SIZE: $size bytes"
Write-Host "SHA256: $hash"

# Refuse to collide with any existing release. Use the paginated REST endpoint so this
# remains correct even after the repository has more than 100 releases.
$releaseTags = @(gh api --paginate "repos/$Repo/releases" --jq '.[].tag_name')
Assert-ExitCode -Code $LASTEXITCODE -Message "Could not query existing releases for '$Repo'."
if ($releaseTags -contains $Tag) {
    throw "Release '$Tag' already exists. Refusing to overwrite it."
}

# Refuse to collide with an existing Git tag, even if no release exists for it.
$tagRefsJson = gh api "repos/$Repo/git/matching-refs/tags/$Tag"
Assert-ExitCode -Code $LASTEXITCODE -Message "Could not query existing tags for '$Repo'."
$tagRefs = @($tagRefsJson | ConvertFrom-Json)
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
    # A failed upload can leave a partial release/tag. Both were confirmed absent above,
    # so cleanup is restricted to this newly-attempted tag.
    Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
    throw "GitHub release creation/upload failed. Cleanup of this attempt was requested."
}

# Verify server-side metadata.
$releaseJson = gh api "repos/$Repo/releases/tags/$Tag"
if ($LASTEXITCODE -ne 0) {
    Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
    throw "Release was created but could not be read back. Cleanup of this attempt was requested."
}

$release = $releaseJson | ConvertFrom-Json
$asset = @($release.assets | Where-Object { $_.name -eq $expectedName }) | Select-Object -First 1
if (-not $asset) {
    Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
    throw "Release was created but '$expectedName' is missing. Cleanup of this attempt was requested."
}
if ($asset.state -ne 'uploaded') {
    Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
    throw "Uploaded asset is not in state 'uploaded'. Cleanup of this attempt was requested."
}
if ([int64]$asset.size -ne $size) {
    Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
    throw "Uploaded asset size mismatch. Cleanup of this attempt was requested."
}

# End-to-end verification: download the just-published asset into a fresh temp directory
# and compare SHA256 with the local source ZIP. This catches a bad/truncated upload even
# when release creation itself reported success.
$verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("joonwoocraft-rp-verify-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $verifyDir | Out-Null
try {
    gh release download $Tag --repo $Repo --pattern $expectedName --dir $verifyDir
    if ($LASTEXITCODE -ne 0) {
        Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
        throw "Could not download the published asset for verification. Cleanup of this attempt was requested."
    }

    $downloaded = Join-Path $verifyDir $expectedName
    if (-not (Test-Path -LiteralPath $downloaded)) {
        Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
        throw "Published asset verification file is missing. Cleanup of this attempt was requested."
    }

    $remoteHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloaded).Hash.ToLowerInvariant()
    if ($remoteHash -ne $hash) {
        Remove-AttemptRelease -ReleaseTag $Tag -Repository $Repo
        throw "Published asset SHA256 mismatch. Cleanup of the bad release was requested. Local=$hash Remote=$remoteHash"
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
