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
      - Writes .claude/agentic-sdlc-core.version with the installed repo/ref/commit
      - Copies project-template/.claude/* -> .claude/  (only files that don't already exist,
        unless -Force is passed)
      - Adds .claude/analytics/ to this repo's .gitignore, only if a .gitignore
        already exists here and doesn't already cover it - never creates one

    Skills, agents, schemas, and scripts are treated as "core" and always synced to the pinned ref.
    CLAUDE.md, config/orchestration.yaml, and state/ are project-specific and are
    never overwritten by default, so re-running this script to pick up a newer
    core version is safe.

.PARAMETER RepoUrl
    Git URL of the agentic-sdlc-core repository.

.PARAMETER Ref
    Branch, tag, or commit to install. Defaults to "main". Pin to a release tag
    (e.g. "v1.0.0") for a reproducible install.

.PARAMETER Force
    Also overwrite existing project-template files (CLAUDE.md, orchestration.yaml,
    decision-log.md, stories/README.md). Without this flag, only files that don't
    already exist are created.

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
    $skillCount = (Get-ChildItem $skillsDest -Directory).Count
    Write-Ok "$skillCount skills installed"
} else {
    Write-Warn "No skills/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $agentsSrc) {
    Write-Step "Installing agents -> $agentsDest"
    New-Item -ItemType Directory -Force -Path $agentsDest | Out-Null
    Copy-Item -Path "$agentsSrc\*" -Destination $agentsDest -Recurse -Force
    $agentCount = (Get-ChildItem $agentsDest -File -Filter "*.md").Count
    Write-Ok "$agentCount agents installed"
} else {
    Write-Warn "No agents/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $schemasSrc) {
    Write-Step "Installing schemas -> $schemasDest"
    New-Item -ItemType Directory -Force -Path $schemasDest | Out-Null
    Copy-Item -Path "$schemasSrc\*" -Destination $schemasDest -Recurse -Force
    Write-Ok "Schemas installed"
} else {
    Write-Warn "No schemas/ folder found in the source repo at ref '$Ref' - skipped."
}

if (Test-Path $scriptsSrc) {
    Write-Step "Installing scripts -> $scriptsDest"
    New-Item -ItemType Directory -Force -Path $scriptsDest | Out-Null
    Copy-Item -Path "$scriptsSrc\*" -Destination $scriptsDest -Recurse -Force
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
    Install-TemplateFile "config\orchestration.yaml"
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
