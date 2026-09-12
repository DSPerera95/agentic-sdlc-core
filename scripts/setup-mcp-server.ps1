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
         the packages actually imported at runtime get installed, nothing
         from agentic-sdlc-core's own devDependencies.
      4. If -EnvVars was given and .claude\mcp-servers\<Name>.env.local
         doesn't already exist, writes it there as KEY=VALUE lines - a
         sibling of <Name>\, not nested inside it, so step 2's clean sync
         on a future re-run (e.g. to pick up a newer build) never deletes
         it. Never overwritten once it exists - hand-edit it directly to
         change a value. Also ensures this project's .gitignore excludes
         .claude\mcp-servers\*.env.local (creating a .gitignore if none
         exists yet - a real credential landing in git otherwise is a
         worse outcome than this script creating one file it normally
         wouldn't). The server itself (not this script) loads that file
         at its own startup.
      5. Registers an entry for <Name> in .mcp.json at the project root,
         pointing at the installed index.js. If an entry with this name
         already exists, it is left untouched unless -Force is passed.

    This script does not decide *when* to set up a given MCP server - that's
    the caller's job. install.ps1 does not call this itself; run it directly
    once you've opted into whatever setting a server requires (e.g.
    state_backend: turso in orchestration.yaml) - during initial setup or
    any time after, there's only this one path.

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
    Hashtable of real environment variable values (e.g. credentials) this
    server needs at runtime. Written as KEY=VALUE lines to
    .claude\mcp-servers\<Name>.env.local - gitignored, never committed, and
    never written into .mcp.json. Only used the first time this file is
    created for a given server; ignored on a later run if the file already
    exists (edit it directly instead). Passing real secret values as a
    command-line argument can land them in your shell history - consider
    that before typing one directly, e.g. prefer pulling it from a local
    secret manager into a variable first rather than a literal.

.PARAMETER Force
    Overwrite an existing .mcp.json entry for this server name instead of
    leaving it untouched. Does not affect the .env.local file, which is
    never overwritten by this script regardless.

.EXAMPLE
    .\setup-mcp-server.ps1 -Name turso-state -EnvVars @{
        TURSO_DATABASE_URL = "libsql://my-db-my-org.turso.io"
        TURSO_AUTH_TOKEN   = "my-actual-token"
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

# --- Write .env.local (sibling of $serverDest, survives its clean-sync) ----

$envFilePath = Join-Path $claudeDir "mcp-servers\$Name.env.local"

if (Test-Path $envFilePath) {
    Write-Info "$envFilePath already exists - left untouched. Edit it directly to change a value."
} elseif ($EnvVars.Count -eq 0) {
    Write-Warn "No -EnvVars given and $envFilePath doesn't exist - $Name will only pick up config already present in the real environment, if any."
} else {
    $envLines = foreach ($key in $EnvVars.Keys) { "$key=$($EnvVars[$key])" }
    Set-Content -Path $envFilePath -Value $envLines
    Write-Ok "Wrote $envFilePath"

    $gitignorePath = ".gitignore"
    $ignoreEntry = "$claudeDir/mcp-servers/*.env.local"
    if (Test-Path $gitignorePath) {
        $gitignoreContent = Get-Content $gitignorePath -Raw -ErrorAction SilentlyContinue
        if ($gitignoreContent -and $gitignoreContent.Contains($ignoreEntry)) {
            Write-Info ".gitignore already covers $ignoreEntry - left as-is."
        } else {
            Add-Content -Path $gitignorePath -Value "`n# agentic-sdlc-core: MCP server credentials - never commit`n$ignoreEntry"
            Write-Ok "Added $ignoreEntry to .gitignore"
        }
    } else {
        Set-Content -Path $gitignorePath -Value "# agentic-sdlc-core: MCP server credentials - never commit`n$ignoreEntry"
        Write-Warn "No .gitignore existed - created one covering $ignoreEntry so $envFilePath can't be committed by accident."
    }
}

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
    $entry = [PSCustomObject]@{
        command = "node"
        args    = @($serverEntryPath)
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
