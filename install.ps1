<#
.SYNOPSIS
    Installs or updates the agentic-sdlc-core skill set into this repository.

.DESCRIPTION
    Run from the root of the project repo you want to add agentic-sdlc-core to.
    Clones agentic-sdlc-core at the given ref into a temp folder, then:

      - Copies skills/*      -> .claude/skills/     (always overwritten)
      - Copies agents/*      -> .claude/agents/      (always overwritten)
      - Copies schemas/*     -> .claude/schemas/     (always overwritten)
      - Copies scripts/*     -> .claude/scripts/      (always overwritten)
      - Removes anything in .claude/skills, .claude/agents, .claude/schemas, or
        .claude/scripts that no longer exists in the source at this ref - e.g.
        a skill that moved to agents/ (or was deleted outright) between the
        version you last installed and this one. Reported individually as
        each one is removed, never silent.
      - Writes .claude/agentic-sdlc-core.version with the installed repo/ref/commit
      - Copies project-template/.claude/* -> .claude/  (only files that don't already exist,
        unless -Force is passed)
      - Except config/orchestration.yaml: if one already exists, it is never
        overwritten (not even with -Force) - instead, whatever top-level
        properties exist in the version being installed but are missing from
        the project's file get appended, with their original comments, and
        everything already there is left exactly as it was. Only whole new
        top-level properties are added this way; a new property nested inside
        one that already exists (e.g. a future addition under
        risk_thresholds) is not detected on its own.
      - Adds .claude/analytics/ to this repo's .gitignore, only if a .gitignore
        already exists here and doesn't already cover it - never creates one

    Skills, agents, schemas, and scripts are treated as "core" and always fully
    mirrored to match the pinned ref - not just overwritten by name, but kept
    free of anything stale. Do not hand-add your own files inside
    .claude/skills, .claude/agents, .claude/schemas, or .claude/scripts - they
    will be deleted on the next re-run if they don't exist in the core at the
    ref you install. CLAUDE.md and state/ are project-specific and are never
    overwritten by default, so re-running this script to pick up a newer core
    version is safe for those. config/orchestration.yaml is project-specific
    too, but additively merged rather than left fully alone - see above.

.PARAMETER RepoUrl
    Git URL of the agentic-sdlc-core repository.

.PARAMETER Ref
    Branch, tag, or commit to install. Defaults to "main". Pin to a release tag
    (e.g. "v1.0.0") for a reproducible install.

.PARAMETER Force
    Also overwrite existing project-template files (CLAUDE.md, decision-log.md,
    stories/README.md). Without this flag, only files that don't already exist
    are created. Does not affect config/orchestration.yaml, which is always
    additively merged (new properties only) regardless of -Force - never fully
    overwritten, so a project's own config customizations are never at risk.

.EXAMPLE
    .\install.ps1 -RepoUrl "https://github.com/acme-corp/agentic-sdlc-core.git" -Ref "v1.0.0"

.EXAMPLE
    # Update an already-installed project to a newer core version
    .\install.ps1 -RepoUrl "https://github.com/acme-corp/agentic-sdlc-core.git" -Ref "v1.1.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,

    [string]$Ref = "main",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

function Remove-StaleEntries([string]$SourceDir, [string]$DestDir, [string]$Label) {
    $sourceNames = @(Get-ChildItem $SourceDir -Force | ForEach-Object { $_.Name })
    $staleItems  = @(Get-ChildItem $DestDir -Force | Where-Object { $sourceNames -notcontains $_.Name })

    foreach ($item in $staleItems) {
        Write-Warn "Removing stale $Label no longer in the core: $($item.Name)"
        Remove-Item -Recurse -Force $item.FullName
    }

    if ($staleItems.Count -gt 0) {
        Write-Ok "$($staleItems.Count) stale $Label(s) removed"
    }
}

# Splits a YAML file's text into top-level (column-0) key blocks, each
# including any comment lines directly above it (no blank line in between)
# and everything indented beneath it. Deliberately line-based, not a real
# YAML parser - re-serializing through a generic parser would strip the
# inline comments that make orchestration.yaml usable. Only understands
# top-level keys; a new property nested inside an existing top-level key
# (e.g. a future addition under risk_thresholds) will not be detected as
# missing on its own - only whole new top-level keys are merged.
function Get-YamlTopLevelBlocks([string[]]$Lines) {
    $blocks = [ordered]@{}
    $currentKey = $null
    $currentLines = New-Object System.Collections.Generic.List[string]
    $pendingComments = New-Object System.Collections.Generic.List[string]

    function Complete-Block {
        if (-not $currentKey) { return }
        while ($currentLines.Count -gt 0 -and $currentLines[$currentLines.Count - 1].Trim() -eq "") {
            $currentLines.RemoveAt($currentLines.Count - 1)
        }
        $blocks[$currentKey] = @($currentLines)
    }

    foreach ($line in $Lines) {
        if ($line -match '^[A-Za-z_][A-Za-z0-9_]*:') {
            Complete-Block
            $currentKey = ($line -split ':', 2)[0]
            $currentLines = New-Object System.Collections.Generic.List[string]
            foreach ($c in $pendingComments) { $currentLines.Add($c) }
            $pendingComments.Clear()
            $currentLines.Add($line)
        }
        elseif ($line.TrimStart().StartsWith("#") -and -not ($line.StartsWith(" ") -or $line.StartsWith("`t"))) {
            $pendingComments.Add($line)
        }
        elseif ($line.Trim() -eq "") {
            if ($currentKey) { $currentLines.Add($line) }
            $pendingComments.Clear()
        }
        else {
            if ($currentKey) { $currentLines.Add($line) }
        }
    }
    Complete-Block

    return $blocks
}

# Adds only the top-level properties from $SrcPath that are missing from
# $DstPath, appended at the end with their original comments intact. Never
# touches a property that already exists in $DstPath, even if its value in
# the source differs - this is a one-way, additive merge, not a sync.
function Merge-OrchestrationYaml([string]$SrcPath, [string]$DstPath) {
    # orchestration.yaml's comments legitimately contain non-ASCII characters
    # (em-dashes). Reading via [System.IO.File]::ReadAllLines with an explicit
    # encoding, not Get-Content -Encoding UTF8 - PowerShell 5.1's Get-Content
    # doesn't reliably honor that flag for a BOM-less UTF8 file, the same
    # class of encoding gotcha documented in this repo's own CLAUDE.md, just
    # hitting a different cmdlet.
    $utf8 = [System.Text.Encoding]::UTF8
    $srcLines = [System.IO.File]::ReadAllLines((Resolve-Path $SrcPath).Path, $utf8)
    $dstLines = [System.IO.File]::ReadAllLines((Resolve-Path $DstPath).Path, $utf8)
    $srcBlocks = Get-YamlTopLevelBlocks $srcLines
    $dstBlocks = Get-YamlTopLevelBlocks $dstLines

    $missingKeys = @($srcBlocks.Keys | Where-Object { -not $dstBlocks.Contains($_) })

    if ($missingKeys.Count -eq 0) {
        Write-Info "$DstPath already has every property from this version - left untouched."
        return
    }

    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $dstLines) { $output.Add($line) }
    $output.Add("")
    $output.Add("# --- Added by agentic-sdlc-core install.ps1 ($Ref) - new properties only, nothing above this line was touched ---")
    foreach ($key in $missingKeys) {
        $output.Add("")
        foreach ($line in $srcBlocks[$key]) { $output.Add($line) }
        Write-Warn "Adding new property to $DstPath : $key"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($DstPath, $output, $utf8NoBom)
    Write-Ok "$($missingKeys.Count) new propert(y/ies) added to $DstPath"
}

# --- Preconditions ----------------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "git is required but was not found on PATH." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path ".git")) {
    Write-Warn "No .git directory found in the current folder."
    Write-Warn "This script expects to be run from the root of the repo you're installing into."
    $continue = Read-Host "Continue anyway? (y/N)"
    if ($continue -ne "y") { exit 1 }
}

# --- Fetch agentic-sdlc-core at the pinned ref -----------------------------

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agentic-sdlc-core-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))

Write-Step "Fetching agentic-sdlc-core @ $Ref"
git clone --branch $Ref --depth 1 $RepoUrl $tempDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to clone $RepoUrl at ref '$Ref'. Check the URL and that the ref exists." -ForegroundColor Red
    exit 1
}

$commitSha = (git -C $tempDir rev-parse HEAD).Trim()
Write-Ok "Fetched commit $($commitSha.Substring(0, 8))"

# --- Install skills, agents, and schemas (always synced to the pinned version)

$claudeDir   = ".claude"
$skillsSrc   = Join-Path $tempDir "skills"
$agentsSrc   = Join-Path $tempDir "agents"
$schemasSrc  = Join-Path $tempDir "schemas"
$scriptsSrc  = Join-Path $tempDir "scripts"
$skillsDest  = Join-Path $claudeDir "skills"
$agentsDest  = Join-Path $claudeDir "agents"
$schemasDest = Join-Path $claudeDir "schemas"
$scriptsDest = Join-Path $claudeDir "scripts"

if (Test-Path $skillsSrc) {
    Write-Step "Installing skills -> $skillsDest"
    New-Item -ItemType Directory -Force -Path $skillsDest | Out-Null
    Copy-Item -Path "$skillsSrc\*" -Destination $skillsDest -Recurse -Force
    Remove-StaleEntries -SourceDir $skillsSrc -DestDir $skillsDest -Label "skill"
    $skillCount = (Get-ChildItem $skillsDest -Directory).Count
    Write-Ok "$skillCount skills installed"
} else {
    Write-Warn "No skills/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $agentsSrc) {
    Write-Step "Installing agents -> $agentsDest"
    New-Item -ItemType Directory -Force -Path $agentsDest | Out-Null
    Copy-Item -Path "$agentsSrc\*" -Destination $agentsDest -Recurse -Force
    Remove-StaleEntries -SourceDir $agentsSrc -DestDir $agentsDest -Label "agent"
    $agentCount = (Get-ChildItem $agentsDest -File -Filter "*.md").Count
    Write-Ok "$agentCount agents installed"
} else {
    Write-Warn "No agents/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $schemasSrc) {
    Write-Step "Installing schemas -> $schemasDest"
    New-Item -ItemType Directory -Force -Path $schemasDest | Out-Null
    Copy-Item -Path "$schemasSrc\*" -Destination $schemasDest -Recurse -Force
    Remove-StaleEntries -SourceDir $schemasSrc -DestDir $schemasDest -Label "schema file"
    Write-Ok "Schemas installed"
} else {
    Write-Warn "No schemas/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $scriptsSrc) {
    Write-Step "Installing scripts -> $scriptsDest"
    New-Item -ItemType Directory -Force -Path $scriptsDest | Out-Null
    Copy-Item -Path "$scriptsSrc\*" -Destination $scriptsDest -Recurse -Force
    Remove-StaleEntries -SourceDir $scriptsSrc -DestDir $scriptsDest -Label "script"
    Write-Ok "Scripts installed"
} else {
    Write-Warn "No scripts/ folder found in the source repo at ref '$Ref' - skipped."
}

# Record what's installed, so a re-run (or a teammate) can see the pinned version
$versionFile = Join-Path $claudeDir "agentic-sdlc-core.version"
@"
repo: $RepoUrl
ref: $Ref
commit: $commitSha
installed: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")
"@ | Set-Content -Path $versionFile
Write-Ok "Recorded install metadata -> $versionFile"

# --- Scaffold project-template (never clobbers existing files unless -Force)

Write-Step "Scaffolding project config/state"

$templateRoot = Join-Path $tempDir "project-template\.claude"

function Install-TemplateFile([string]$RelativePath) {
    $src = Join-Path $templateRoot $RelativePath
    $dst = Join-Path $claudeDir $RelativePath

    if (-not (Test-Path $src)) { return }

    if ((Test-Path $dst) -and -not $Force) {
        Write-Info "Skipped (already exists): $dst"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -Path $src -Destination $dst -Force
    Write-Ok "Wrote $dst"
}

if (Test-Path $templateRoot) {
    Install-TemplateFile "CLAUDE.md"

    $orchestrationSrc = Join-Path $templateRoot "config\orchestration.yaml"
    $orchestrationDst = Join-Path $claudeDir "config\orchestration.yaml"
    if (Test-Path $orchestrationDst) {
        Write-Step "Adding any new orchestration.yaml properties"
        Merge-OrchestrationYaml -SrcPath $orchestrationSrc -DstPath $orchestrationDst
    } else {
        Install-TemplateFile "config\orchestration.yaml"
    }

    Install-TemplateFile "state\README.md"
    Install-TemplateFile "state\decision-log.jsonl"
    Install-TemplateFile "state\decision-log-archive\.gitkeep"
    Install-TemplateFile "state\stories\README.md"
} else {
    Write-Warn "No project-template/ folder found in the source repo at ref '$Ref' - skipped."
}

# --- Ignore disposable analytics output, only if this repo already uses a .gitignore

$gitignorePath = ".gitignore"
if (Test-Path $gitignorePath) {
    Write-Step "Updating .gitignore"
    $gitignoreContent = Get-Content $gitignorePath -Raw -ErrorAction SilentlyContinue
    if ($gitignoreContent -and $gitignoreContent.Contains(".claude/analytics")) {
        Write-Info ".gitignore already covers .claude/analytics/ - left as-is."
    } else {
        $entry = "`n# agentic-sdlc-core: token-usage-report.ps1 -Html output - disposable, regenerate anytime`n.claude/analytics/"
        Add-Content -Path $gitignorePath -Value $entry
        Write-Ok "Added .claude/analytics/ to .gitignore"
    }
} else {
    Write-Info "No .gitignore in this repo - skipped (not creating one on the project's behalf)."
}

# --- Cleanup ------------------------------------------------------------------

Remove-Item -Recurse -Force $tempDir

Write-Step "Done"
Write-Info "Skills, agents, schemas, and scripts are synced to $Ref (commit $($commitSha.Substring(0, 8)))."
Write-Info "Fill in $claudeDir\config\orchestration.yaml with this project's ticket system and context_mode default."
Write-Info "Commit the changes under $claudeDir to this repo's version control."
