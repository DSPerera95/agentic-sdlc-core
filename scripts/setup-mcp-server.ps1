<#
.SYNOPSIS
    Fetches, installs, and registers one of agentic-sdlc-core's bundled MCP
    servers (e.g. "turso-state") into this project.

.DESCRIPTION
    Generic across whichever MCP server is named - the mechanics are the same
    for any of them:

      1. Determines which agentic-sdlc-core repo/ref to fetch from. Uses
         -RepoUrl/-Ref if given; otherwise reads them from
         .claude\agentic-sdlc-core.version (written by install.ps1).
      2. Shallow-clones that ref to a temp folder and copies
         mcp-servers\<Name>\dist\* -> .claude\mcp-servers\<Name>\
         (wiping any existing copy first, so this is always a clean sync,
         never a merge of old and new files).
      3. Runs "npm install" inside .claude\mcp-servers\<Name>\. The dist\
         folder this repo ships is prebuilt (already compiled from
         TypeScript) and carries its own runtime-only package.json - only
         the three packages actually imported at runtime get installed,
         nothing from agentic-sdlc-core's own devDependencies.
      4. Registers an entry for <Name> in .mcp.json at the project root,
         pointing at the installed index.js, with whatever -EnvVars were
         passed through as its "env" block. If an entry with this name
         already exists, it is left untouched unless -Force is passed.

    This script does not decide *when* to set up a given MCP server - that's
    the caller's job (install.ps1 calls it when it detects
    state_backend: turso in orchestration.yaml, passing the env vars that
    server needs). Run it directly if you flip a state_backend (or similar)
    setting on after the initial install, without re-running the whole
    installer.

.PARAMETER Name
    The MCP server's directory name under mcp-servers\ in agentic-sdlc-core,
    e.g. "turso-state". Required.

.PARAMETER RepoUrl
    Git URL of the agentic-sdlc-core repository. Defaults to the "repo:"
    value recorded in .claude\agentic-sdlc-core.version.

.PARAMETER Ref
    Branch, tag, or commit to fetch mcp-servers\<Name>\dist from. Defaults
    to the "ref:" value recorded in .claude\agentic-sdlc-core.version.

.PARAMETER EnvVars
    Hashtable of environment variables to write into this server's "env"
    block in .mcp.json. Use the literal string '${VAR_NAME}' as a value to
    have Claude Code expand it from the environment at MCP-server-launch
    time rather than writing a real value into .mcp.json.

.PARAMETER Force
    Overwrite an existing .mcp.json entry for this server name instead of
    leaving it untouched.

.EXAMPLE
    .\setup-mcp-server.ps1 -Name turso-state -EnvVars @{
        TURSO_DATABASE_URL = "libsql://my-db-my-org.turso.io"
        TURSO_AUTH_TOKEN   = '${TURSO_AUTH_TOKEN}'
    }

.EXAMPLE
    # Override the source repo/ref explicitly instead of reading the version file
    .\setup-mcp-server.ps1 -Name turso-state -RepoUrl "https://github.com/acme-corp/agentic-sdlc-core.git" -Ref "v7.6.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [string]$RepoUrl,

    [string]$Ref,

    [hashtable]$EnvVars = @{},

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

# --- Preconditions ------------------------------------------------------------

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "git is required but was not found on PATH." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "node is required but was not found on PATH." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "npm is required but was not found on PATH." -ForegroundColor Red
    exit 1
}

# --- Resolve repo/ref -----------------------------------------------------

$claudeDir  = ".claude"
$versionFile = Join-Path $claudeDir "agentic-sdlc-core.version"

if (-not $RepoUrl -or -not $Ref) {
    if (-not (Test-Path $versionFile)) {
        Write-Host "No -RepoUrl/-Ref given and $versionFile does not exist - pass both explicitly, or run install.ps1 first." -ForegroundColor Red
        exit 1
    }

    $versionLines = Get-Content $versionFile

    if (-not $RepoUrl) {
        $repoLine = $versionLines | Where-Object { $_ -match '^repo:\s*(.+)$' } | Select-Object -First 1
        if ($repoLine) { $RepoUrl = ($repoLine -replace '^repo:\s*', '').Trim() }
    }

    if (-not $Ref) {
        $refLine = $versionLines | Where-Object { $_ -match '^ref:\s*(.+)$' } | Select-Object -First 1
        if ($refLine) { $Ref = ($refLine -replace '^ref:\s*', '').Trim() }
    }

    if (-not $RepoUrl -or -not $Ref) {
        Write-Host "Could not determine repo/ref from $versionFile - pass -RepoUrl and -Ref explicitly." -ForegroundColor Red
        exit 1
    }
}

Write-Info "Source: $RepoUrl @ $Ref"

# --- Fetch mcp-servers\<Name>\dist -----------------------------------------

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-setup-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))

Write-Step "Fetching $Name from agentic-sdlc-core @ $Ref"
git clone --branch $Ref --depth 1 $RepoUrl $tempDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to clone $RepoUrl at ref '$Ref'. Check the URL and that the ref exists." -ForegroundColor Red
    exit 1
}

$serverDistSrc = Join-Path $tempDir "mcp-servers\$Name\dist"
if (-not (Test-Path $serverDistSrc)) {
    Remove-Item -Recurse -Force $tempDir
    $available = Get-ChildItem (Join-Path $tempDir "mcp-servers") -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    Write-Host "mcp-servers\$Name\dist not found at ref '$Ref'." -ForegroundColor Red
    if ($available) { Write-Host "Available MCP servers at this ref: $($available -join ', ')" -ForegroundColor Red }
    exit 1
}

$serverDest = Join-Path $claudeDir "mcp-servers\$Name"
if (Test-Path $serverDest) {
    Write-Info "Removing existing $serverDest for a clean sync"
    Remove-Item -Recurse -Force $serverDest
}
New-Item -ItemType Directory -Force -Path $serverDest | Out-Null
Copy-Item -Path "$serverDistSrc\*" -Destination $serverDest -Recurse -Force
Write-Ok "$Name installed -> $serverDest"

Remove-Item -Recurse -Force $tempDir

# --- npm install (runtime deps only - dist ships its own trimmed package.json)

Write-Step "Running npm install in $serverDest"
Push-Location $serverDest
try {
    npm install
    if ($LASTEXITCODE -ne 0) {
        Write-Host "npm install failed in $serverDest" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
Write-Ok "Dependencies installed"

# --- Register in .mcp.json --------------------------------------------------

$mcpConfigPath = ".mcp.json"
$serverEntryPath = Join-Path $claudeDir "mcp-servers\$Name\index.js"

if (Test-Path $mcpConfigPath) {
    $mcpConfig = Get-Content $mcpConfigPath -Raw | ConvertFrom-Json
} else {
    $mcpConfig = [PSCustomObject]@{ mcpServers = [PSCustomObject]@{} }
}

if (-not $mcpConfig.mcpServers) {
    $mcpConfig | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([PSCustomObject]@{})
}

$alreadyRegistered = $mcpConfig.mcpServers.PSObject.Properties.Name -contains $Name

if ($alreadyRegistered -and -not $Force) {
    Write-Info "$Name already registered in $mcpConfigPath - leaving existing entry untouched. Pass -Force to overwrite it."
} else {
    $envObject = [PSCustomObject]@{}
    foreach ($key in $EnvVars.Keys) {
        $envObject | Add-Member -MemberType NoteProperty -Name $key -Value $EnvVars[$key]
    }

    $entry = [PSCustomObject]@{
        command = "node"
        args    = @($serverEntryPath)
        env     = $envObject
    }

    if ($alreadyRegistered) {
        $mcpConfig.mcpServers.$Name = $entry
    } else {
        $mcpConfig.mcpServers | Add-Member -MemberType NoteProperty -Name $Name -Value $entry
    }

    ($mcpConfig | ConvertTo-Json -Depth 10) | Set-Content -Path $mcpConfigPath
    Write-Ok "Registered $Name in $mcpConfigPath"
}

Write-Step "Done"
Write-Info "$Name is set up at $serverDest and registered in $mcpConfigPath."
