param(
    [Parameter(Mandatory=$true)]
    [string]$ZipPath,

    [string]$Repo = "newbie7627-ops/joonwoocraft-resourcepacks",

    [string]$Tag
)

$ErrorActionPreference = "Stop"

$zip = (Resolve-Path $ZipPath).Path
$name = [System.IO.Path]::GetFileName($zip)

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
if ($name -ne $expectedName) {
    throw "ZIP filename must exactly match tag: expected '$expectedName', got '$name'."
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is not installed. Install once with: winget install --id GitHub.cli"
}

# Verify login before doing anything.
gh auth status | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run once: gh auth login"
}

# Basic ZIP integrity check using .NET.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    if ($archive.Entries.Count -eq 0) { throw "ZIP is empty." }
    $duplicate = $archive.Entries | Group-Object FullName | Where-Object { $_.Count -gt 1 }
    if ($duplicate) {
        throw "ZIP contains duplicate entries: $($duplicate.Name -join ', ')"
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Write-Host "ZIP: $zip"
Write-Host "TAG: $Tag"
Write-Host "SHA256: $hash"

# Refuse to overwrite an existing release/tag accidentally.
gh release view $Tag --repo $Repo *> $null
if ($LASTEXITCODE -eq 0) {
    throw "Release '$Tag' already exists. Refusing to overwrite it."
}

$notes = @"
JoonwooCraft resource pack release $Tag

SHA256: $hash
"@

# One command creates the tag + release and uploads the exact ZIP asset.
gh release create $Tag $zip --repo $Repo --title $Tag --notes $notes --target main
if ($LASTEXITCODE -ne 0) {
    throw "GitHub release creation/upload failed."
}

# Read back the published asset and print its download URL.
$assetUrl = gh release view $Tag --repo $Repo --json assets --jq ".assets[] | select(.name == \"$expectedName\") | .url"
if ($LASTEXITCODE -ne 0 -or -not $assetUrl) {
    throw "Release exists but uploaded asset could not be verified."
}

Write-Host ""
Write-Host "PUBLISHED OK"
Write-Host "Asset: $expectedName"
Write-Host "SHA256: $hash"
Write-Host "URL: $assetUrl"
