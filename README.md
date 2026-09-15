# JoonwooCraft Resource Packs

Public hosting repository for JoonwooCraft server resource packs.

## One-command release publish (Windows)

This repo includes `publish-resourcepack.ps1` so a finished resource-pack ZIP can be published without opening the GitHub Releases page.

### One-time setup

Install GitHub CLI and sign in:

```powershell
winget install --id GitHub.cli
gh auth login
```

Clone this repository once so the publisher script is available locally:

```powershell
git clone https://github.com/newbie7627-ops/joonwoocraft-resourcepacks.git
cd joonwoocraft-resourcepacks
```

### For each resource-pack release

Run one command:

```powershell
.\publish-resourcepack.ps1 -ZipPath "C:\path\to\resourcepacks-1.0.8.zip"
```

The ZIP filename must be exactly `resourcepacks-X.Y.Z.zip`.

The publisher now performs the following checks automatically before and after upload:

- validates the release/tag name and exact ZIP filename
- verifies GitHub authentication and repository access
- detects existing releases and existing tags before writing anything
- opens and fully reads every ZIP entry to catch damaged/truncated compressed data
- rejects duplicate and case-colliding ZIP paths
- rejects unsafe `..` / absolute ZIP paths
- requires a valid root `pack.mcmeta` and `assets/` content
- calculates the local SHA256 and byte size
- creates the tag + GitHub Release and uploads the ZIP
- reads the release back and verifies the asset name, state, and size
- downloads the just-published asset into a temporary directory and compares SHA256 end-to-end
- automatically removes a newly-created partial/bad release and tag if publishing or verification fails
- prints the final verified download URL and SHA256

A successful run ends with `PUBLISHED + VERIFIED OK`.
