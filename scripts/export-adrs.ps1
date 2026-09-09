<#
.SYNOPSIS
    Renders decision-log.jsonl entries tagged significance: architectural into
    individual ADR files.

.DESCRIPTION
    The decision log stays the source of truth — this script never modifies it,
    only reads it. It filters for significance: architectural, and writes one
    Markdown file per entry into an ADR directory, in the numbered-file convention
    most ADR tooling (adr-tools, log4brains, etc.) expects.

    Filenames use the entry's own DEC-#### id rather than a separate ADR-specific
    numbering scheme, so a file can always be traced back to its exact log line.

    Re-running this script regenerates all ADR files from the current log content
    — it's a projection, not something to hand-edit. If an ADR file needs to
    change, the fix is a new decision-log entry (a correction is itself a decision
    worth recording), not editing the generated file directly.

    Run manually, whenever you want the ADR files to reflect the current log —
    not run automatically by anything else in this system.

.PARAMETER StateDir
    Path to .claude/state. Defaults to ".claude/state".

.PARAMETER OutDir
    Where to write ADR files. Defaults to "docs/adr", created if it doesn't exist.

.PARAMETER IncludeArchive
    Also render architectural entries found in .claude/state/decision-log-archive/,
    not just the hot log. Off by default, since most of the time the hot log is
    what you actually want reflected.

.EXAMPLE
    .\export-adrs.ps1

.EXAMPLE
    .\export-adrs.ps1 -OutDir "documentation/adr" -IncludeArchive
#>

[CmdletBinding()]
param(
    [string]$StateDir = ".claude/state",
    [string]$OutDir = "docs/adr",
    [switch]$IncludeArchive
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

function Read-JsonlEntries([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    $lines = Get-Content $Path | Where-Object { $_.Trim() -ne "" }
    return @($lines | ForEach-Object { $_ | ConvertFrom-Json })
}

function ConvertTo-Slug([string]$Text) {
    $slug = $Text.ToLower()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "untitled" }
    return $slug
}

$logPath = Join-Path $StateDir "decision-log.jsonl"
$archiveDir = Join-Path $StateDir "decision-log-archive"

Write-Step "Reading decision log"
$entries = Read-JsonlEntries $logPath
Write-Info "$($entries.Count) entries in the hot log"

if ($IncludeArchive -and (Test-Path $archiveDir)) {
    $archiveFiles = Get-ChildItem $archiveDir -Filter "*.jsonl"
    foreach ($f in $archiveFiles) {
        $archiveEntries = Read-JsonlEntries $f.FullName
        $entries += $archiveEntries
        Write-Info "$($archiveEntries.Count) entries from $($f.Name)"
    }
}

$architectural = @($entries | Where-Object { $_.significance -eq "architectural" })
Write-Info "$($architectural.Count) entries tagged significance: architectural"

if ($architectural.Count -eq 0) {
    Write-Ok "Nothing to render."
    exit 0
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Step "Writing ADR files -> $OutDir"
$written = 0
foreach ($entry in $architectural) {
    $slug = ConvertTo-Slug $entry.decision
    $fileName = "$($entry.id)-$slug.md"
    $filePath = Join-Path $OutDir $fileName

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $($entry.id): $($entry.decision)")
    $lines.Add("")
    $lines.Add("**Date:** $($entry.date)")
    $lines.Add("**Story:** $($entry.story_id)")
    $lines.Add("")
    if ($entry.context) {
        $lines.Add("## Context")
        $lines.Add("")
        $lines.Add([string]$entry.context)
        $lines.Add("")
    }
    $lines.Add("## Decision")
    $lines.Add("")
    $lines.Add([string]$entry.decision)
    $lines.Add("")
    if ($entry.reasoning) {
        $lines.Add("## Reasoning")
        $lines.Add("")
        $lines.Add([string]$entry.reasoning)
        $lines.Add("")
    }
    if ($entry.alternatives_considered -and $entry.alternatives_considered.Count -gt 0) {
        $lines.Add("## Alternatives considered")
        $lines.Add("")
        foreach ($alt in $entry.alternatives_considered) { $lines.Add("- $alt") }
        $lines.Add("")
    }
    if ($entry.consequences) {
        $lines.Add("## Consequences")
        $lines.Add("")
        $lines.Add([string]$entry.consequences)
        $lines.Add("")
    }
    if ($entry.tradeoffs) {
        $lines.Add("## Tradeoffs")
        $lines.Add("")
        $lines.Add([string]$entry.tradeoffs)
        $lines.Add("")
    }
    $lines.Add("---")
    $lines.Add("*Generated from $($entry.id) in decision-log.jsonl. Don't hand-edit — correct the log instead and re-run export-adrs.ps1.*")

    Set-Content -Path $filePath -Value $lines.ToArray()
    $written++
}

Write-Ok "$written ADR file(s) written to $OutDir"
Write-Info "This is a projection of the log, not a second source of truth — re-run after new architectural decisions land."
