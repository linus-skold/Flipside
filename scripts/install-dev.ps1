<#
.SYNOPSIS
Installs a branch, commit or worktree of Flipside into the WoW AddOns folder.

.DESCRIPTION
Copies the git-tracked files minus the `ignore:` list of .pkgmeta into
<AddOns>\<package-as>. It deletes the old <AddOns>\<package-as> folder first.
It deletes nothing else. Use -WhatIf to see the plan without any change.

.EXAMPLE
.\scripts\install-dev.ps1 -Ref fix/selling-tree-insets

.EXAMPLE
.\scripts\install-dev.ps1 -Source C:\path\to\worktree -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source,
    [string]$Ref,
    [string]$AddOnsPath
)
$ErrorActionPreference = 'Stop'

if (-not $Source) { $Source = Split-Path -Parent $PSScriptRoot }
$Source = (Resolve-Path -LiteralPath $Source).Path

if (-not $AddOnsPath) { $AddOnsPath = $env:FLIPSIDE_ADDONS_PATH }
if (-not $AddOnsPath) {
    $AddOnsPath = 'C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns'
}
$AddOnsPath = $AddOnsPath.TrimEnd('\', '/')
if ($AddOnsPath -notmatch '[\\/]Interface[\\/]AddOns$') {
    throw "Refused: the target path must end in Interface\AddOns. Got: $AddOnsPath"
}

function Invoke-Git {
    $out = & git -C $Source @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" }
    $out
}
function Test-GitRef($r) {
    & git -C $Source rev-parse --verify --quiet "$r^{commit}" *> $null
    $LASTEXITCODE -eq 0
}

$tempDir = $null
try {
    # Step 1: get the file tree (exported ref or working tree).
    if ($Ref) {
        $isRemote = $Ref -like 'origin/*'
        if ($isRemote -or -not (Test-GitRef $Ref)) {
            Write-Host "Fetching from origin..."
            Invoke-Git fetch origin | Out-Null
        }
        $resolved = $Ref
        if (-not (Test-GitRef $resolved)) {
            if (Test-GitRef "origin/$Ref") { $resolved = "origin/$Ref" }
            else { throw "Ref not found: $Ref" }
        }
        $commit = (Invoke-Git rev-parse --short $resolved) -join ''
        $branchLabel = $resolved
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("flipside-install-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        $zip = Join-Path $tempDir 'src.zip'
        $root = Join-Path $tempDir 'tree'
        Invoke-Git archive --format=zip -o $zip $resolved | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $root
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
            ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') }
    } else {
        $root = $Source
        $commit = (Invoke-Git rev-parse --short HEAD) -join ''
        $branchLabel = (Invoke-Git rev-parse --abbrev-ref HEAD) -join ''
        $files = Invoke-Git ls-files |
            Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf }
    }

    # Step 2: read .pkgmeta.
    $pkgmeta = Join-Path $root '.pkgmeta'
    if (-not (Test-Path -LiteralPath $pkgmeta)) { throw ".pkgmeta not found in $root" }
    $packageAs = $null
    $ignore = @()
    $inIgnore = $false
    foreach ($line in Get-Content -LiteralPath $pkgmeta) {
        if ($line -match '^package-as:\s*(\S+)') { $packageAs = $Matches[1].Trim('"', "'"); $inIgnore = $false }
        elseif ($line -match '^ignore:\s*$') { $inIgnore = $true }
        elseif ($inIgnore -and $line -match '^\s+-\s*(.+?)\s*$') { $ignore += $Matches[1].Trim('"', "'") }
        elseif ($line -match '^\S') { $inIgnore = $false }
    }
    if (-not $packageAs) { throw 'package-as not found in .pkgmeta' }
    $ignore += 'scripts'   # safety net: the script never ships
    if ($packageAs -notmatch '^[A-Za-z0-9_.-]+$') { throw "Unsafe package name: $packageAs" }

    # A file is ignored if any path segment matches an ignore pattern.
    $keep = foreach ($f in $files) {
        $skip = $false
        foreach ($seg in $f.Split('/')) {
            foreach ($p in $ignore) { if ($seg -like $p) { $skip = $true; break } }
            if ($skip) { break }
        }
        if (-not $skip) { $f }
    }
    $keep = @($keep)

    $target = Join-Path $AddOnsPath $packageAs
    Write-Host "Source : $Source"
    Write-Host "Ref    : $branchLabel @ $commit$(if ($Ref) { ' (exported)' } else { ' (working tree)' })"
    Write-Host "Target : $target"
    Write-Host "Files  : $($keep.Count) of $(@($files).Count) (ignored: $(@($files).Count - $keep.Count))"

    $toc = Join-Path $root "$packageAs.toc"
    if (Test-Path -LiteralPath $toc) {
        $ver = Select-String -LiteralPath $toc -Pattern '^## Version:\s*(.*)$' | Select-Object -First 1
        if ($ver -and $ver.Matches[0].Groups[1].Value -match '@') {
            Write-Host "Note   : TOC version token left as is: $($ver.Matches[0].Groups[1].Value)"
        }
    }

    if (Get-Process -Name 'WowClassic*', 'Wow*' -ErrorAction SilentlyContinue) {
        Write-Warning 'WoW is running. The new files load on /reload or relog.'
    }

    # Step 3: delete the old folder, copy, write the marker.
    if (Test-Path -LiteralPath $target) {
        if ($PSCmdlet.ShouldProcess($target, 'Delete old addon folder')) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
    if ($PSCmdlet.ShouldProcess($target, "Copy $($keep.Count) files")) {
        foreach ($f in $keep) {
            $dest = Join-Path $target $f
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath (Join-Path $root $f) -Destination $dest
        }
        $full = (Invoke-Git rev-parse ($(if ($Ref) { $resolved } else { 'HEAD' }))) -join ''
        @(
            "ref: $branchLabel"
            "commit: $full"
            "installed: $((Get-Date).ToString('o'))"
            "source: $Source"
        ) | Set-Content -LiteralPath (Join-Path $target '.dev-install')
        Write-Host "Copied $($keep.Count) files. Run /reload in game."
    } else {
        $keep | Select-Object -First 15 | ForEach-Object { Write-Host "  would copy $_" }
        if ($keep.Count -gt 15) { Write-Host "  ... and $($keep.Count - 15) more" }
    }
}
finally {
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
