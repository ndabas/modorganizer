#Requires -Version 7.0
<#
.SYNOPSIS
    Rebuilds an official Mod Organizer 2 release archive with patched usvfs binaries.

.DESCRIPTION
    Downloads an upstream Mod Organizer 2 release archive and a usvfs build, replaces
    the four usvfs binaries shipped at the root of the archive, repacks it and
    optionally publishes the result as a pre-release on a fork.

    The usvfs binaries can come either from a GitHub release (-UsvfsRepo/-UsvfsTag) or
    from a local directory (-UsvfsPath).

.EXAMPLE
    ./scripts/New-PatchedRelease.ps1 -BaseTag v2.5.2 -UsvfsTag v0.5.6.1-woa.1

    Builds Mod.Organizer-2.5.2-woa.1.7z locally without publishing.

.EXAMPLE
    ./scripts/New-PatchedRelease.ps1 -BaseTag v2.5.2 -UsvfsTag v0.5.6.1-woa.1 -Publish

    Builds the archive and publishes it as a pre-release on the target repository.
#>
[CmdletBinding(DefaultParameterSetName = 'FromRelease', SupportsShouldProcess)]
param(
    # Upstream Mod Organizer 2 release tag to base the repack on.
    [Parameter(Mandatory)]
    [string]$BaseTag,

    # Repository holding the upstream Mod Organizer 2 release.
    [string]$BaseRepo = 'ModOrganizer2/modorganizer',

    # Repository holding the patched usvfs release.
    [Parameter(ParameterSetName = 'FromRelease')]
    [string]$UsvfsRepo = 'ndabas/usvfs',

    # Tag of the patched usvfs release.
    [Parameter(Mandatory, ParameterSetName = 'FromRelease')]
    [string]$UsvfsTag,

    # Directory containing usvfs_x64.dll, usvfs_x86.dll, usvfs_proxy_x64.exe and
    # usvfs_proxy_x86.exe (searched recursively).
    [Parameter(Mandatory, ParameterSetName = 'FromPath')]
    [string]$UsvfsPath,

    # Suffix appended to the upstream version, e.g. 2.5.2 -> 2.5.2-woa.1.
    [string]$Suffix = 'woa.1',

    # Repository the patched release is published to.
    [string]$TargetRepo = 'ndabas/modorganizer',

    # Working directory for downloads and extraction. Reused across runs.
    [string]$WorkDir = (Join-Path ([System.IO.Path]::GetTempPath()) 'mo2-repack'),

    # Publish the result as a pre-release on $TargetRepo.
    [switch]$Publish,

    # Publish as a draft release.
    [switch]$Draft,

    # Re-download and re-extract even if cached files are present.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$UsvfsFiles = @('usvfs_x64.dll', 'usvfs_x86.dll', 'usvfs_proxy_x64.exe', 'usvfs_proxy_x86.exe')

function Resolve-SevenZip {
    $cmd = Get-Command '7z' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw '7z.exe not found. Install 7-Zip or add it to PATH.'
}

function Invoke-SevenZip {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & $script:SevenZip @Arguments
    if ($LASTEXITCODE -ne 0) { throw "7z failed (exit $LASTEXITCODE): 7z $($Arguments -join ' ')" }
}

function Invoke-Gh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh failed (exit $LASTEXITCODE): gh $($Arguments -join ' ')`n$output" }
    return $output
}

function Get-FileVersionTable {
    param([Parameter(Mandatory)][string]$Directory)
    $table = [ordered]@{}
    foreach ($name in $UsvfsFiles) {
        $file = Get-Item -LiteralPath (Join-Path $Directory $name)
        $table[$name] = $file.VersionInfo.FileVersion
    }
    return $table
}

if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) not found. Install it from https://cli.github.com/.'
}
$script:SevenZip = Resolve-SevenZip

$baseVersion = $BaseTag -replace '^v', ''
$baseAsset = "Mod.Organizer-$baseVersion.7z"
$outputVersion = "$baseVersion-$Suffix"
$outputAsset = "Mod.Organizer-$outputVersion.7z"
$releaseTag = "v$outputVersion"

$downloads = Join-Path $WorkDir 'downloads'
$extract = Join-Path $WorkDir "extract-$outputVersion"
$usvfsStage = Join-Path $WorkDir "usvfs-$($PSCmdlet.ParameterSetName)-$(($UsvfsTag ?? (Split-Path $UsvfsPath -Leaf)) -replace '[^\w.-]', '_')"
$outputPath = Join-Path $WorkDir $outputAsset

New-Item -ItemType Directory -Force -Path $downloads | Out-Null

# --- 1. Fetch the upstream release archive -----------------------------------
$basePath = Join-Path $downloads $baseAsset
if ($Force -or -not (Test-Path -LiteralPath $basePath)) {
    Write-Host "==> Downloading $baseAsset from $BaseRepo@$BaseTag"
    Invoke-Gh @('release', 'download', $BaseTag, '-R', $BaseRepo, '-p', $baseAsset, '-D', $downloads, '--clobber') | Out-Null
}
else {
    Write-Host "==> Using cached $basePath"
}

# --- 2. Fetch the patched usvfs binaries -------------------------------------
if ($Force -and (Test-Path -LiteralPath $usvfsStage)) {
    Remove-Item -LiteralPath $usvfsStage -Recurse -Force
}

if ($PSCmdlet.ParameterSetName -eq 'FromRelease') {
    if (-not (Test-Path -LiteralPath $usvfsStage)) {
        Write-Host "==> Downloading usvfs from $UsvfsRepo@$UsvfsTag"
        $usvfsDownloads = Join-Path $downloads "usvfs-$UsvfsTag"
        New-Item -ItemType Directory -Force -Path $usvfsDownloads | Out-Null
        Invoke-Gh @('release', 'download', $UsvfsTag, '-R', $UsvfsRepo, '-D', $usvfsDownloads, '--clobber') | Out-Null

        New-Item -ItemType Directory -Force -Path $usvfsStage | Out-Null
        foreach ($archive in Get-ChildItem -LiteralPath $usvfsDownloads -File) {
            Write-Host "    extracting $($archive.Name)"
            Invoke-SevenZip @('x', $archive.FullName, "-o$usvfsStage", '-y')
        }
    }
    else {
        Write-Host "==> Using cached usvfs at $usvfsStage"
    }
    $usvfsSearchRoot = $usvfsStage
}
else {
    $usvfsSearchRoot = (Resolve-Path -LiteralPath $UsvfsPath).Path
    Write-Host "==> Using usvfs binaries from $usvfsSearchRoot"
}

# Collect the four binaries into a flat directory, failing on missing/ambiguous hits.
$usvfsFlat = Join-Path $WorkDir 'usvfs-flat'
Remove-Item -LiteralPath $usvfsFlat -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $usvfsFlat | Out-Null
foreach ($name in $UsvfsFiles) {
    $matched = @(Get-ChildItem -LiteralPath $usvfsSearchRoot -Recurse -File -Filter $name)
    if ($matched.Count -eq 0) { throw "$name not found under $usvfsSearchRoot" }
    if ($matched.Count -gt 1) {
        throw "$name is ambiguous under ${usvfsSearchRoot}: $(($matched.FullName) -join ', ')"
    }
    Copy-Item -LiteralPath $matched[0].FullName -Destination $usvfsFlat
}

# --- 3. Extract the upstream archive -----------------------------------------
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $extract 'ModOrganizer.exe'))) {
    Write-Host "==> Extracting $baseAsset"
    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Invoke-SevenZip @('x', $basePath, "-o$extract", '-y', '-bso0', '-bsp0')
}
else {
    Write-Host "==> Using cached extraction at $extract"
}

foreach ($name in $UsvfsFiles) {
    $target = Join-Path $extract $name
    if (-not (Test-Path -LiteralPath $target)) {
        throw "$name is not present at the root of $baseAsset; the archive layout changed."
    }
}

# Recorded on the first (pristine) extraction, because re-running over a cached
# extraction would otherwise report the already-patched versions as the originals.
$baselineFile = Join-Path $extract '.original-usvfs-versions.json'
if (-not (Test-Path -LiteralPath $baselineFile)) {
    (Get-FileVersionTable -Directory $extract) | ConvertTo-Json | Set-Content -LiteralPath $baselineFile -Encoding utf8
}
$baseline = Get-Content -LiteralPath $baselineFile -Raw | ConvertFrom-Json

$before = [ordered]@{}
foreach ($name in $UsvfsFiles) { $before[$name] = $baseline.$name }
$after = Get-FileVersionTable -Directory $usvfsFlat

# --- 4. Patch ----------------------------------------------------------------
Write-Host '==> Replacing usvfs binaries'
foreach ($name in $UsvfsFiles) {
    Write-Host ("    {0,-24} {1,-10} -> {2}" -f $name, $before[$name], $after[$name])
    Copy-Item -LiteralPath (Join-Path $usvfsFlat $name) -Destination (Join-Path $extract $name) -Force
}

# --- 5. Repack ---------------------------------------------------------------
Write-Host "==> Packing $outputAsset"
Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
Push-Location $extract
try {
    Invoke-SevenZip @('a', '-t7z', '-mx=9', '-bso0', '-bsp0', '-xr!.original-usvfs-versions.json', $outputPath, '.\*')
}
finally {
    Pop-Location
}

$hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
$size = '{0:N1} MiB' -f ((Get-Item -LiteralPath $outputPath).Length / 1MB)
Write-Host "==> $outputPath ($size)"
Write-Host "    SHA256 $hash"

# --- 6. Publish --------------------------------------------------------------
if (-not $Publish) {
    Write-Host '==> -Publish not specified; stopping here.'
    return
}

$usvfsSource = if ($PSCmdlet.ParameterSetName -eq 'FromRelease') {
    "[``$UsvfsTag``](https://github.com/$UsvfsRepo/releases/tag/$UsvfsTag)"
}
else {
    "a local build ($usvfsSearchRoot)"
}

$notes = @"
Unofficial repack of [Mod Organizer $baseVersion](https://github.com/$BaseRepo/releases/tag/$BaseTag).

Every file is byte-for-byte identical to the official ``$baseAsset`` except for the
usvfs binaries, which are replaced with a build from $usvfsSource that fixes x64
process injection under Prism emulation on Windows on ARM. Without the fix, Mod
Organizer cannot launch any x64 game on an ARM64 machine.

| File | Official $baseVersion | This build |
| --- | --- | --- |
$(($UsvfsFiles | ForEach-Object { "| ``$_`` | $($before[$_]) | $($after[$_]) |" }) -join "`n")

``````
SHA256  $hash
``````

This repack is not produced or supported by the Mod Organizer 2 team. Report issues
against this fork, not upstream.
"@

$notesFile = Join-Path $WorkDir 'release-notes.md'
Set-Content -LiteralPath $notesFile -Value $notes -Encoding utf8

$ghArgs = @(
    'release', 'create', $releaseTag,
    '-R', $TargetRepo,
    '--title', "Mod Organizer $outputVersion",
    '--notes-file', $notesFile,
    '--prerelease'
)

# Anchor the tag on the upstream release commit rather than the fork's default branch.
$baseSha = (& gh api "repos/$BaseRepo/commits/$BaseTag" --jq '.sha' 2>$null)
if ($LASTEXITCODE -eq 0 -and $baseSha) {
    & gh api "repos/$TargetRepo/commits/$baseSha" --jq '.sha' *> $null
    if ($LASTEXITCODE -eq 0) { $ghArgs += @('--target', $baseSha) }
    else { Write-Warning "$baseSha is not reachable in $TargetRepo; tagging the default branch instead." }
}

if ($Draft) { $ghArgs += '--draft' }
$ghArgs += $outputPath

if ($PSCmdlet.ShouldProcess("$TargetRepo@$releaseTag", 'Create GitHub release')) {
    $existing = & gh release view $releaseTag -R $TargetRepo --json tagName 2>$null
    if ($LASTEXITCODE -eq 0 -and $existing) {
        throw "Release $releaseTag already exists on $TargetRepo. Delete it or pick another -Suffix."
    }
    Write-Host "==> Publishing $releaseTag to $TargetRepo"
    Invoke-Gh $ghArgs
}
