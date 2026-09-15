<#
.SYNOPSIS
    Rotates old entries out of decision-log.jsonl into a dated archive, keeping the
    log a story pays to load small and current.

.DESCRIPTION
    Reads .claude/state/decision-log.jsonl, keeps the most recent entries (bounded by
    both an age cutoff and a max count), and moves everything else into
    .claude/state/decision-log-archive/<date>.jsonl with `reasoning`,
    `alternatives_considered`, and `tradeoffs` stripped - keeping `id`, `date`,
    `story_id`, `decision`, and `consequences` only. Appends one breadcrumb entry to
    the hot log noting what was rotated and where it went, continuing the same id
    sequence rather than resetting it.

    An entry is archived if it's older than -MaxAgeMonths, OR if keeping it would put
    the hot log over -MaxEntries (the oldest entries beyond that count go too) -
    whichever threshold it crosses first.

    Run manually and periodically - e.g. before kicking off /project-planner again on
    an existing project. Not run automatically by anything else in this system.

.PARAMETER StateDir
    Path to .claude/state. Defaults to ".claude/state".

.PARAMETER MaxAgeMonths
    Entries older than this many months get archived, regardless of count. Defaults to
    6 - keep this in sync with decision_log_rotation.max_age_months in
    config/orchestration.yaml; this script doesn't read that file itself.

.PARAMETER MaxEntries
    Only the most recent this-many entries are kept in the hot log, regardless of age.
    Defaults to 200 - keep in sync with decision_log_rotation.max_entries in
    orchestration.yaml.

.PARAMETER DryRun
    Show what would be archived without writing anything.

.EXAMPLE
    .\rotate-decision-log.ps1

.EXAMPLE
    .\rotate-decision-log.ps1 -MaxAgeMonths 3 -MaxEntries 100 -DryRun
#>

[CmdletBinding()]
param(
    [string]$StateDir = ".claude/state",
    [int]$MaxAgeMonths = 6,
    [int]$MaxEntries = 200,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

$logPath    = Join-Path $StateDir "decision-log.jsonl"
$archiveDir = Join-Path $StateDir "decision-log-archive"

if (-not (Test-Path $logPath)) {
    Write-Info "No decision-log.jsonl found at $logPath - nothing to rotate."
    exit 0
}

Write-Step "Reading $logPath"
$lines = Get-Content $logPath | Where-Object { $_.Trim() -ne "" }
$entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
Write-Info "$($entries.Count) entries found"

if ($entries.Count -eq 0) {
    Write-Info "Log is empty - nothing to rotate."
    exit 0
}

# Newest first
$sorted = @($entries | Sort-Object -Property @{Expression = { [datetime]$_.date }} -Descending)

$cutoff = (Get-Date).AddMonths(-$MaxAgeMonths)

$keep    = New-Object System.Collections.Generic.List[object]
$archive = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $sorted.Count; $i++) {
    $entry = $sorted[$i]
    $entryDate = [datetime]$entry.date
    if ($i -lt $MaxEntries -and $entryDate -ge $cutoff) {
        $keep.Add($entry)
    } else {
        $archive.Add($entry)
    }
}

Write-Info "$($keep.Count) entries stay in the hot log"
Write-Info "$($archive.Count) entries would be archived"

if ($archive.Count -eq 0) {
    Write-Ok "Nothing past the thresholds - no rotation needed."
    exit 0
}

if ($DryRun) {
    Write-Info "-DryRun: no files written. Would archive:"
    $archive | ForEach-Object { Write-Info "  $($_.id)  $($_.date)  $($_.decision)" }
    exit 0
}

# Strip to id/date/story_id/decision/consequences only on archived entries
$archiveStripped = $archive | ForEach-Object {
    [PSCustomObject]@{
        id           = $_.id
        date         = $_.date
        story_id     = $_.story_id
        decision     = $_.decision
        consequences = $_.consequences
    }
}

New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
$archiveFile = Join-Path $archiveDir "$(Get-Date -Format 'yyyy-MM-dd').jsonl"

Write-Step "Writing archive -> $archiveFile"
$archiveStripped | ForEach-Object { $_ | ConvertTo-Json -Compress } | Add-Content -Path $archiveFile
Write-Ok "$($archiveStripped.Count) entries archived"

# Continue the same id sequence for the breadcrumb - never reset or renumber
$maxNum = 0
function Update-MaxNum([object]$e) {
    if ($e.id -match 'DEC-(\d+)') {
        $n = [int]$Matches[1]
        if ($n -gt $script:maxNum) { $script:maxNum = $n }
    }
}
foreach ($e in $keep) { Update-MaxNum $e }
foreach ($e in $archive) { Update-MaxNum $e }
$breadcrumbId = "DEC-{0:D4}" -f ($maxNum + 1)

$breadcrumb = [PSCustomObject]@{
    id           = $breadcrumbId
    date         = (Get-Date -Format "yyyy-MM-dd")
    story_id     = "system"
    context      = "Automated log rotation"
    decision     = "Rotated $($archiveStripped.Count) entries older than $MaxAgeMonths months or beyond the $MaxEntries most recent into $archiveFile"
    consequences = "Older decisions are no longer loaded by default via context_mode; consult the archive file directly if needed."
}

$keepOldestFirst = $keep | Sort-Object -Property @{Expression = { [datetime]$_.date }}

Write-Step "Writing hot log -> $logPath"
$outLines = @()
foreach ($e in $keepOldestFirst) { $outLines += ($e | ConvertTo-Json -Compress) }
$outLines += ($breadcrumb | ConvertTo-Json -Compress)
Set-Content -Path $logPath -Value $outLines

Write-Ok "Hot log now has $($keep.Count + 1) entries (including the rotation breadcrumb)"
Write-Info "Commit both $logPath and $archiveFile to version control."
