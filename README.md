# JoonwooCraft Resource Packs

Public hosting repository for JoonwooCraft server resource packs.

## One-command release publish (Windows)

This repo includes `publish-resourcepack.ps1` so a finished resource-pack ZIP can be published without opening the GitHub Releases page.

One-time setup:

```powershell
winget install --id GitHub.cli
gh auth login
```

For each release, run this from a PowerShell window after downloading/copying the finished ZIP:

```powershell
.\publish-resourcepack.ps1 -ZipPath "C:\path\to\resourcepacks-1.0.8.zip"
```

The script verifies the ZIP is non-empty and has no duplicate entries, infers the tag from the filename, refuses to overwrite an existing release, calculates SHA256, creates the `resourcepacks-X.Y.Z` release, uploads the ZIP, and prints the published asset URL.

The ZIP filename must be exactly `resourcepacks-X.Y.Z.zip`.
