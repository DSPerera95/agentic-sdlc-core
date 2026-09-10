<#
.SYNOPSIS
    Renders a terminal bar chart of token usage per skill and per agent for a
    Claude Code session on this project.

.DESCRIPTION
    Reads the session transcript Claude Code already writes to
    <home>\.claude\projects\<slug>\<session-id>.jsonl (where <slug> is this
    project's working-directory path with ":" and "\" replaced by "-") and
    attributes token usage to whichever skill or agent was active at the time.

    This is a read-only, on-demand report, not a hook. The transcript file is
    written incrementally while a session is open, so this can be run from a
    second terminal while the session you want to inspect is still running, or
    afterward against a finished one. Nothing is written back - the transcript
    stays the only source of truth; re-run this any time for a fresh view.

    Attribution rules:
      - Agent-level: every Agent/Task tool call that invokes a named subagent
        (risk-classifier, validator, implementer, etc.) completes with a
        "task-notification" carrying a single pre-aggregated subagent_tokens
        total. This has been observed in two different transcript shapes
        within the same Claude Code build - an "attachment" entry (also used
        for unrelated background *shell command* completions, which carry no
        subagent_tokens and are harmlessly skipped) and a plain-string "user"
        message - so this script checks both. A task-id can notify more than
        once (e.g. resumed after its first stop); subagent_tokens is a running
        total each time, so only the latest value per invocation is kept, not
        summed. This is exact per invocation, but is one number per agent call
        - it does not break down into input/output/cache like the
        skill/orchestrator figures below do.
      - Skill-level: a "Skill" tool call marks the start of a skill's inline
        execution. Everything from the next assistant turn onward is
        attributed to that skill until the next Skill call (or session end).
        This is a best-effort heuristic, not an exact boundary - skills run
        inline with no isolation marker, so there is no hard stop event to
        detect. Labelled "(heuristic)" in the output for this reason.
      - Anything before the first Skill call, or with no skill active, is
        attributed to "orchestrator (unattributed)" rather than being dropped,
        so the printed total always reconciles with the session's real total.

    A single assistant turn is logged as multiple JSONL lines (one per content
    block: thinking/text/tool_use), each repeating the same cumulative usage
    object for that turn. This script dedupes by requestId so each turn is
    only counted once.

    Known limitation: the exact folder-naming scheme for
    .claude\projects\<slug> is reverse-engineered from observed behavior, not
    documented Claude Code behavior, and could change across versions. If the
    derived folder isn't found, this script says so and lists what actually
    exists rather than guessing further.

.PARAMETER SessionId
    Session (transcript file, without .jsonl) to read. Defaults to the most
    recently modified transcript for this project.

.PARAMETER ProjectDir
    Working directory to derive the transcript folder from. Defaults to the
    current directory.

.PARAMETER List
    List available sessions for this project (id, last modified, size)
    instead of rendering a chart.

.PARAMETER BarWidth
    Width in characters of the longest bar in the terminal chart. Defaults to 40.

.PARAMETER Html
    Also write a self-contained HTML report (colored bar charts, a legend, a
    table view, and light/dark themes) alongside the terminal chart. No
    external assets or build step - everything is inlined in the one file.

.PARAMETER HtmlPath
    Where to write the HTML report. Defaults to
    "<ProjectDir>\.claude\analytics\token-usage-report-<session-id>-<timestamp>.html",
    creating the analytics folder if it doesn't exist yet. Only used with
    -Html. These are disposable, regenerate-anytime output - consider adding
    ".claude/analytics/" to the project's .gitignore rather than committing
    every run.

.EXAMPLE
    .\token-usage-report.ps1

.EXAMPLE
    .\token-usage-report.ps1 -List

.EXAMPLE
    .\token-usage-report.ps1 -SessionId d843fcc6-c65c-4c71-a912-6f59c0180477

.EXAMPLE
    .\token-usage-report.ps1 -Html -HtmlPath report.html
#>

[CmdletBinding()]
param(
    [string]$SessionId,
    [string]$ProjectDir = (Get-Location).Path,
    [switch]$List,
    [int]$BarWidth = 40,
    [switch]$Html,
    [string]$HtmlPath
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "OK  $msg" -ForegroundColor Green }

# --- Locate the transcript folder for this project --------------------------

if (-not (Test-Path $ProjectDir)) {
    Write-Warn "ProjectDir not found: $ProjectDir"
    exit 1
}
$resolvedProjectDir = (Resolve-Path $ProjectDir).Path
$slug = ($resolvedProjectDir -replace '[:\\/]', '-')
$projectsRoot = Join-Path $env:USERPROFILE ".claude\projects"
$transcriptDir = Join-Path $projectsRoot $slug

if (-not (Test-Path $transcriptDir)) {
    Write-Warn "No transcript folder found at $transcriptDir"
    Write-Warn "The project-folder naming scheme is reverse-engineered from observed behavior, not documented - if Claude Code changed it, this script needs updating."
    if (Test-Path $projectsRoot) {
        Write-Info "Folders that do exist under $projectsRoot :"
        Get-ChildItem $projectsRoot -Directory | ForEach-Object { Write-Info "  $($_.Name)" }
    }
    exit 1
}

$transcriptFiles = @(Get-ChildItem $transcriptDir -Filter "*.jsonl" | Sort-Object LastWriteTime -Descending)

if ($transcriptFiles.Count -eq 0) {
    Write-Warn "No .jsonl transcripts found in $transcriptDir"
    exit 1
}

if ($List) {
    Write-Step "Sessions for this project ($transcriptDir)"
    foreach ($f in $transcriptFiles) {
        $sizeKb = [math]::Round($f.Length / 1kb, 1)
        Write-Info "$($f.BaseName)  $($f.LastWriteTime)  ${sizeKb}KB"
    }
    exit 0
}

if ($SessionId) {
    $transcriptFile = $transcriptFiles | Where-Object { $_.BaseName -eq $SessionId } | Select-Object -First 1
    if (-not $transcriptFile) {
        Write-Warn "No transcript named '$SessionId' in $transcriptDir - use -List to see what's available."
        exit 1
    }
} else {
    $transcriptFile = $transcriptFiles[0]
}

Write-Step "Reading $($transcriptFile.Name)"

# --- Parse the transcript and attribute usage --------------------------------

$toolUseById   = @{}   # tool_use id -> @{ name; input }
$skillUsage    = @{}   # skill name -> usage totals
$agentUsage    = @{}   # agent (subagent_type) -> total tokens
$agentInvocationTokens = @{}   # tool_use id of the Agent/Task call -> latest subagent_tokens
$seenRequests  = @{}
$currentSkill  = $null
$nextSkill     = $null
$skippedLines  = 0

function Add-Usage([hashtable]$Bucket, [string]$Key, [object]$Usage) {
    if (-not $Bucket.Contains($Key)) {
        $Bucket[$Key] = [ordered]@{ input = 0; output = 0; cacheRead = 0; cacheCreate = 0 }
    }
    $Bucket[$Key].input       += [int64]($Usage.input_tokens)
    $Bucket[$Key].output      += [int64]($Usage.output_tokens)
    $Bucket[$Key].cacheRead   += [int64]($Usage.cache_read_input_tokens)
    $Bucket[$Key].cacheCreate += [int64]($Usage.cache_creation_input_tokens)
}

foreach ($line in [System.IO.File]::ReadLines($transcriptFile.FullName)) {
    if ($line.Trim() -eq "") { continue }

    try {
        $entry = $line | ConvertFrom-Json
    } catch {
        $skippedLines++
        continue
    }

    if ($entry.type -eq "assistant" -and $entry.message -and $entry.message.content) {
        foreach ($block in @($entry.message.content)) {
            if ($block.type -eq "tool_use") {
                $toolUseById[$block.id] = @{ name = $block.name; input = $block.input }
                if ($block.name -eq "Skill" -and $block.input -and $block.input.skill) {
                    $nextSkill = [string]$block.input.skill
                }
            }
        }

        $isSidechain = [bool]$entry.isSidechain
        if (-not $isSidechain -and $entry.message.usage -and $entry.requestId) {
            if (-not $seenRequests.ContainsKey($entry.requestId)) {
                $seenRequests[$entry.requestId] = $true

                if ($nextSkill) {
                    $currentSkill = $nextSkill
                    $nextSkill = $null
                }

                $bucketKey = if ($currentSkill) { $currentSkill } else { "orchestrator (unattributed)" }
                Add-Usage $skillUsage $bucketKey $entry.message.usage
            }
        }
    }

    # Agent completions show up as a "task-notification" block in either of two
    # observed shapes: an "attachment" entry (also used for unrelated background
    # *shell command* completions, which carry no subagent_tokens and are
    # harmlessly skipped below), or a plain-string "user" message. Both carry
    # the same <task-notification>...</task-notification> text.
    $notificationText = $null
    if ($entry.type -eq "attachment" -and $entry.attachment -and $entry.attachment.commandMode -eq "task-notification") {
        $notificationText = [string]$entry.attachment.prompt
    } elseif ($entry.type -eq "user" -and $entry.message -and ($entry.message.content -is [string]) -and $entry.message.content -like "*<task-notification>*") {
        $notificationText = [string]$entry.message.content
    }

    if ($notificationText) {
        $toolUseIdMatch = [regex]::Match($notificationText, '<tool-use-id>(.*?)</tool-use-id>')
        $tokensMatch    = [regex]::Match($notificationText, '<subagent_tokens>(\d+)</subagent_tokens>')

        if ($toolUseIdMatch.Success -and $tokensMatch.Success) {
            # A task-id can notify more than once (e.g. resumed after its first
            # stop); subagent_tokens is a running total each time, not a delta,
            # so keep the latest value per tool-use-id rather than summing.
            $agentInvocationTokens[$toolUseIdMatch.Groups[1].Value] = [int64]$tokensMatch.Groups[1].Value
        }
    }
}

if ($skippedLines -gt 0) {
    Write-Info "$skippedLines line(s) could not be parsed and were skipped."
}

# Resolve each completed invocation's tool-use-id back to the agent name that
# was called, now that toolUseById is fully populated.
foreach ($callerToolUseId in $agentInvocationTokens.Keys) {
    $tokens = $agentInvocationTokens[$callerToolUseId]
    $agentName = "unknown-agent"

    if ($toolUseById.ContainsKey($callerToolUseId)) {
        $call = $toolUseById[$callerToolUseId]
        if ($call.name -eq "Agent" -or $call.name -eq "Task") {
            if ($call.input -and $call.input.subagent_type) {
                $agentName = [string]$call.input.subagent_type
            } elseif ($call.input -and $call.input.description) {
                $agentName = [string]$call.input.description
            }
        }
    }

    if (-not $agentUsage.Contains($agentName)) { $agentUsage[$agentName] = 0 }
    $agentUsage[$agentName] += $tokens
}

# --- Render -------------------------------------------------------------------

function Get-Total($usage) { return $usage.input + $usage.output + $usage.cacheRead + $usage.cacheCreate }

# --- HTML report ----------------------------------------------------------
# Colors are the validated categorical palette (blue/orange/aqua/yellow, slots
# 1-4), checked with the dataviz skill's validator for both light and dark
# surfaces on the "adjacent" pairlist (the relevant one for a stacked bar) -
# both passed all hard gates. Light-mode aqua/yellow fall below 3:1 contrast
# against the surface (a documented, expected property of those two slots),
# which is why segment values are never labelled in-fill - only via the
# legend, hover/focus tooltip, and the table view, none of which depend on
# reading text off the fill color.

function ConvertTo-HtmlText([string]$Text) {
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-NiceCeiling([double]$Value) {
    if ($Value -le 0) { return 1 }
    $exponent = [math]::Floor([math]::Log10($Value))
    $magnitude = [math]::Pow(10, $exponent)
    $normalized = $Value / $magnitude
    if ($normalized -le 1) { $nice = 1 }
    elseif ($normalized -le 2) { $nice = 2 }
    elseif ($normalized -le 5) { $nice = 5 }
    else { $nice = 10 }
    return $nice * $magnitude
}

function Format-Compact([double]$Value) {
    if ($Value -ge 1000000) { return "{0:N1}M" -f ($Value / 1000000) }
    if ($Value -ge 1000)    { return "{0:N1}K" -f ($Value / 1000) }
    return "{0:N0}" -f $Value
}

function Get-AxisHtml([double]$AxisMax) {
    $fractions = 0, 0.25, 0.5, 0.75, 1.0
    $ticks = foreach ($f in $fractions) {
        $pct = [math]::Round($f * 100, 2)
        $val = Format-Compact ($f * $AxisMax)
        "<div class=`"tick`" style=`"left:$pct%`"><span>$val</span></div>"
    }
    return ($ticks -join "`n")
}

function Get-GridlinesHtml {
    $fractions = 0, 0.25, 0.5, 0.75, 1.0
    $lines = foreach ($f in $fractions) {
        $pct = [math]::Round($f * 100, 2)
        "<div class=`"gridline`" style=`"left:$pct%`"></div>"
    }
    return ($lines -join "`n")
}

$script:HtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Token Usage Report - __SESSION__</title>
<style>
  :root {
    color-scheme: light;
    --page:           #f9f9f7;
    --surface-1:      #fcfcfb;
    --text-primary:   #0b0b0b;
    --text-secondary: #52514e;
    --text-muted:     #898781;
    --gridline:       #e1e0d9;
    --border:         rgba(11,11,11,0.10);
    --series-1:       #2a78d6;
    --series-2:       #eb6834;
    --series-3:       #1baf7a;
    --series-4:       #eda100;
    --agent-hue:      #2a78d6;
  }
  @media (prefers-color-scheme: dark) {
    html:not([data-theme="light"]) {
      color-scheme: dark;
      --page:           #0d0d0d;
      --surface-1:      #1a1a19;
      --text-primary:   #ffffff;
      --text-secondary: #c3c2b7;
      --text-muted:     #898781;
      --gridline:       #2c2c2a;
      --border:         rgba(255,255,255,0.10);
      --series-1:       #3987e5;
      --series-2:       #d95926;
      --series-3:       #199e70;
      --series-4:       #c98500;
      --agent-hue:      #3987e5;
    }
  }
  html[data-theme="dark"] {
    color-scheme: dark;
    --page:           #0d0d0d;
    --surface-1:      #1a1a19;
    --text-primary:   #ffffff;
    --text-secondary: #c3c2b7;
    --text-muted:     #898781;
    --gridline:       #2c2c2a;
    --border:         rgba(255,255,255,0.10);
    --series-1:       #3987e5;
    --series-2:       #d95926;
    --series-3:       #199e70;
    --series-4:       #c98500;
    --agent-hue:      #3987e5;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--page);
    color: var(--text-primary);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    padding: 32px 16px;
  }
  .container { max-width: 980px; margin: 0 auto; }
  .top-bar { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 24px; gap: 16px; flex-wrap: wrap; }
  h1 { font-size: 21px; margin: 0 0 4px 0; font-weight: 600; }
  .meta { color: var(--text-secondary); font-size: 13px; }
  button.chrome-btn {
    border: 1px solid var(--border); background: var(--surface-1); color: var(--text-primary);
    border-radius: 6px; padding: 7px 14px; font-size: 13px; cursor: pointer; font-family: inherit;
  }
  button.chrome-btn:hover { filter: brightness(0.97); }
  html[data-theme="dark"] button.chrome-btn:hover, html:not([data-theme="light"]) button.chrome-btn:hover { filter: brightness(1.2); }
  .btn-row { display: flex; gap: 8px; }
  .hero {
    background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px;
    padding: 20px 24px; margin-bottom: 20px;
  }
  .hero .label { color: var(--text-secondary); font-size: 13px; margin-bottom: 6px; }
  .hero .value { font-size: 38px; font-weight: 600; }
  .card {
    background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px;
    padding: 20px 24px; margin-bottom: 20px;
  }
  .card h2 { font-size: 15px; margin: 0 0 4px 0; font-weight: 600; }
  .card .subtitle { color: var(--text-secondary); font-size: 13px; margin-bottom: 16px; }
  .legend { display: flex; gap: 18px; flex-wrap: wrap; margin-bottom: 18px; font-size: 13px; color: var(--text-secondary); }
  .legend-item { display: flex; align-items: center; gap: 6px; }
  .legend-swatch { width: 11px; height: 11px; border-radius: 3px; display: inline-block; }
  .bar-row { margin-bottom: 16px; }
  .bar-row-label { display: flex; justify-content: space-between; font-size: 13px; margin-bottom: 5px; gap: 12px; }
  .bar-row-label .name { color: var(--text-primary); font-weight: 500; }
  .bar-row-label .total { color: var(--text-secondary); font-variant-numeric: tabular-nums; white-space: nowrap; }
  .bar-track { position: relative; height: 24px; }
  .gridlines { position: absolute; inset: 0; z-index: 0; }
  .gridline { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--gridline); }
  .bar-fill {
    position: absolute; left: 0; top: 0; height: 100%; z-index: 1;
    background: var(--agent-hue); border-radius: 0 4px 4px 0; min-width: 2px;
  }
  .stack {
    position: absolute; left: 0; top: 0; height: 100%; z-index: 1;
    display: flex; gap: 2px; border-radius: 0 4px 4px 0; overflow: hidden;
  }
  .stack-segment { height: 100%; min-width: 2px; }
  .stack-segment.s1 { background: var(--series-1); }
  .stack-segment.s2 { background: var(--series-2); }
  .stack-segment.s3 { background: var(--series-3); }
  .stack-segment.s4 { background: var(--series-4); }
  .bar-fill:hover, .stack-segment:hover { filter: brightness(1.1); cursor: pointer; }
  .bar-fill:focus-visible, .stack-segment:focus-visible { outline: 2px solid var(--text-primary); outline-offset: 2px; }
  .axis { position: relative; height: 18px; margin-top: 4px; border-top: 1px solid var(--gridline); }
  .tick { position: absolute; top: 4px; transform: translateX(-50%); font-size: 11px; color: var(--text-muted); }
  .tick:first-child { transform: translateX(0); }
  .tick:last-child { transform: translateX(-100%); }
  .empty { color: var(--text-muted); font-size: 13px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--gridline); font-variant-numeric: tabular-nums; }
  th { color: var(--text-secondary); font-weight: 600; font-variant-numeric: normal; }
  td:first-child, th:first-child { font-variant-numeric: normal; }
  #table-wrap[hidden] { display: none; }
  footer { color: var(--text-muted); font-size: 12px; line-height: 1.6; margin-top: 8px; }
  #tooltip {
    position: absolute; background: var(--text-primary); color: var(--page);
    padding: 6px 10px; border-radius: 6px; font-size: 12px; pointer-events: none;
    z-index: 10; max-width: 260px; box-shadow: 0 4px 12px rgba(0,0,0,0.2);
  }
  #tooltip[hidden] { display: none; }
  #tooltip .tooltip-value { font-weight: 600; }
  #tooltip .tooltip-name { opacity: 0.85; margin-top: 2px; }
</style>
</head>
<body>
<div class="container">
  <div class="top-bar">
    <div>
      <h1>Token Usage Report</h1>
      <div class="meta">Session __SESSION__ &mdash; __PROJECT__<br>Generated __GENERATED__</div>
    </div>
    <div class="btn-row">
      <button type="button" class="chrome-btn" id="table-toggle">Show data table</button>
      <button type="button" class="chrome-btn" id="theme-toggle">Dark mode</button>
    </div>
  </div>

  <div class="hero">
    <div class="label">Session total</div>
    <div class="value">__GRAND_TOTAL__ tokens</div>
  </div>

  <div class="card">
    <h2>Agent invocations</h2>
    <div class="subtitle">Exact totals - one pre-aggregated figure per invocation, not broken down by token type.</div>
    __AGENT_ROWS__
  </div>

  <div class="card">
    <h2>Skills and orchestrator</h2>
    <div class="subtitle">Best-effort heuristic - skills run inline with no hard boundary marker, so a skill call only marks where attribution starts.</div>
    <div class="legend">
      <div class="legend-item"><span class="legend-swatch" style="background:var(--series-1)"></span>Input Tokens</div>
      <div class="legend-item"><span class="legend-swatch" style="background:var(--series-2)"></span>Output Tokens</div>
      <div class="legend-item"><span class="legend-swatch" style="background:var(--series-3)"></span>Cache Read Input Tokens</div>
      <div class="legend-item"><span class="legend-swatch" style="background:var(--series-4)"></span>Cache Creation Input Tokens</div>
    </div>
    __SKILL_ROWS__
  </div>

  <div class="card" id="table-wrap" hidden>
    <h2>All rows</h2>
    <table>
      <thead>
        <tr><th>Name</th><th>Input Tokens</th><th>Output Tokens</th><th>Cache Read Input Tokens</th><th>Cache Creation Input Tokens</th><th>Total</th></tr>
      </thead>
      <tbody>
        __TABLE_ROWS__
      </tbody>
    </table>
  </div>

  <footer>
    Generated by scripts/token-usage-report.ps1 (agentic-sdlc-core). Agent totals come from a pre-aggregated figure the harness reports per invocation; skill totals are attributed heuristically from the session transcript and may not land on an exact boundary.
  </footer>
</div>
<div id="tooltip" role="tooltip" hidden></div>
<script>
(function () {
  var themeBtn = document.getElementById('theme-toggle');
  var html = document.documentElement;
  themeBtn.addEventListener('click', function () {
    var isDark = html.getAttribute('data-theme') === 'dark';
    if (isDark) {
      html.setAttribute('data-theme', 'light');
      themeBtn.textContent = 'Dark mode';
    } else {
      html.setAttribute('data-theme', 'dark');
      themeBtn.textContent = 'Light mode';
    }
  });

  var tableBtn = document.getElementById('table-toggle');
  var tableWrap = document.getElementById('table-wrap');
  tableBtn.addEventListener('click', function () {
    if (tableWrap.hasAttribute('hidden')) {
      tableWrap.removeAttribute('hidden');
      tableBtn.textContent = 'Hide data table';
    } else {
      tableWrap.setAttribute('hidden', '');
      tableBtn.textContent = 'Show data table';
    }
  });

  var tooltip = document.getElementById('tooltip');
  var marks = document.querySelectorAll('.bar-fill, .stack-segment');
  marks.forEach(function (mark) {
    function render(evt) {
      var name = mark.getAttribute('data-name');
      var value = mark.getAttribute('data-value');
      tooltip.textContent = '';
      var valueEl = document.createElement('div');
      valueEl.className = 'tooltip-value';
      valueEl.textContent = value + ' tokens';
      var nameEl = document.createElement('div');
      nameEl.className = 'tooltip-name';
      nameEl.textContent = name;
      tooltip.appendChild(valueEl);
      tooltip.appendChild(nameEl);
      tooltip.hidden = false;
      var rect = mark.getBoundingClientRect();
      var x = (evt && typeof evt.clientX === 'number') ? evt.clientX : rect.left + rect.width / 2;
      tooltip.style.left = (x + window.scrollX + 12) + 'px';
      tooltip.style.top = (rect.top + window.scrollY - 8) + 'px';
    }
    function hide() { tooltip.hidden = true; }
    mark.addEventListener('pointermove', render);
    mark.addEventListener('pointerenter', render);
    mark.addEventListener('pointerleave', hide);
    mark.addEventListener('focus', render);
    mark.addEventListener('blur', hide);
  });
})();
</script>
</body>
</html>
'@

function New-HtmlReport {
    param(
        [array]$Rows,
        [double]$GrandTotal,
        [string]$SessionName,
        [string]$ProjectPath,
        [string]$OutFile
    )

    $agentRows = @($Rows | Where-Object { $_.Category -eq "agent" })
    $skillRows = @($Rows | Where-Object { $_.Category -ne "agent" })

    $agentMax = if ($agentRows.Count -gt 0) { ($agentRows | Measure-Object -Property Total -Maximum).Maximum } else { 0 }
    $skillMax = if ($skillRows.Count -gt 0) { ($skillRows | Measure-Object -Property Total -Maximum).Maximum } else { 0 }
    $agentAxisMax = Get-NiceCeiling $agentMax
    $skillAxisMax = Get-NiceCeiling $skillMax

    if ($agentRows.Count -eq 0) {
        $agentRowsHtml = '<p class="empty">No agent invocations in this session.</p>'
    } else {
        $parts = foreach ($row in $agentRows) {
            $pct = if ($agentAxisMax -gt 0) { [math]::Round(($row.Total / $agentAxisMax) * 100, 3) } else { 0 }
            $name = ConvertTo-HtmlText ($row.Label -replace '^agent: ', '')
            $totalStr = "{0:N0}" -f $row.Total
            @"
<div class="bar-row">
  <div class="bar-row-label"><span class="name">$name</span><span class="total">$totalStr tokens</span></div>
  <div class="bar-track" role="img" aria-label="$name total $totalStr tokens">
    <div class="gridlines">$(Get-GridlinesHtml)</div>
    <div class="bar-fill" style="width:$pct%" tabindex="0" data-name="$name" data-value="$totalStr"></div>
  </div>
</div>
"@
        }
        $agentRowsHtml = ($parts -join "`n") + "`n<div class=`"axis`">$(Get-AxisHtml $agentAxisMax)</div>"
    }

    if ($skillRows.Count -eq 0) {
        $skillRowsHtml = '<p class="empty">No skill or orchestrator usage in this session.</p>'
    } else {
        $segDefs = @(
            @{ key = "input";       cls = "s1"; label = "Input Tokens" },
            @{ key = "output";      cls = "s2"; label = "Output Tokens" },
            @{ key = "cacheRead";   cls = "s3"; label = "Cache Read Input Tokens" },
            @{ key = "cacheCreate"; cls = "s4"; label = "Cache Creation Input Tokens" }
        )
        $parts = foreach ($row in $skillRows) {
            $totalStr = "{0:N0}" -f $row.Total
            $name = ConvertTo-HtmlText $row.Label
            $rowPct = if ($skillAxisMax -gt 0) { [math]::Round(($row.Total / $skillAxisMax) * 100, 3) } else { 0 }
            $segHtml = ""
            if ($row.Detail -and $row.Total -gt 0) {
                $segParts = foreach ($seg in $segDefs) {
                    $val = $row.Detail[$seg.key]
                    if ($val -gt 0) {
                        $segPct = [math]::Round(($val / $row.Total) * 100, 3)
                        $valStr = "{0:N0}" -f $val
                        "<div class=`"stack-segment $($seg.cls)`" style=`"width:$segPct%`" tabindex=`"0`" data-name=`"$($seg.label)`" data-value=`"$valStr`"></div>"
                    }
                }
                $segHtml = $segParts -join "`n"
            }
            @"
<div class="bar-row">
  <div class="bar-row-label"><span class="name">$name</span><span class="total">$totalStr tokens</span></div>
  <div class="bar-track" role="img" aria-label="$name total $totalStr tokens">
    <div class="gridlines">$(Get-GridlinesHtml)</div>
    <div class="stack" style="width:$rowPct%">$segHtml</div>
  </div>
</div>
"@
        }
        $skillRowsHtml = ($parts -join "`n") + "`n<div class=`"axis`">$(Get-AxisHtml $skillAxisMax)</div>"
    }

    $tableRows = foreach ($row in $Rows) {
        $name = ConvertTo-HtmlText $row.Label
        $totalStr = "{0:N0}" -f $row.Total
        if ($row.Detail) {
            $inStr = "{0:N0}" -f $row.Detail.input
            $outStr = "{0:N0}" -f $row.Detail.output
            $crStr = "{0:N0}" -f $row.Detail.cacheRead
            $ccStr = "{0:N0}" -f $row.Detail.cacheCreate
        } else {
            $inStr = "-"; $outStr = "-"; $crStr = "-"; $ccStr = "-"
        }
        "<tr><td>$name</td><td>$inStr</td><td>$outStr</td><td>$crStr</td><td>$ccStr</td><td>$totalStr</td></tr>"
    }

    $html = $script:HtmlTemplate
    $html = $html.Replace("__SESSION__", (ConvertTo-HtmlText $SessionName))
    $html = $html.Replace("__PROJECT__", (ConvertTo-HtmlText $ProjectPath))
    $html = $html.Replace("__GENERATED__", (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    $html = $html.Replace("__GRAND_TOTAL__", ("{0:N0}" -f $GrandTotal))
    $html = $html.Replace("__AGENT_ROWS__", $agentRowsHtml)
    $html = $html.Replace("__SKILL_ROWS__", $skillRowsHtml)
    $html = $html.Replace("__TABLE_ROWS__", ($tableRows -join "`n"))

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $html, $utf8NoBom)
}

$categoryColors = @{
    agent        = "Magenta"
    skill        = "Cyan"
    orchestrator = "DarkGray"
}

$rows = @()
foreach ($key in $skillUsage.Keys) {
    if ($key -eq "orchestrator (unattributed)") {
        $label = $key
        $category = "orchestrator"
    } else {
        $label = "skill: $key (heuristic)"
        $category = "skill"
    }
    $rows += [PSCustomObject]@{ Label = $label; Total = (Get-Total $skillUsage[$key]); Detail = $skillUsage[$key]; Category = $category }
}
foreach ($key in $agentUsage.Keys) {
    $rows += [PSCustomObject]@{ Label = "agent: $key"; Total = $agentUsage[$key]; Detail = $null; Category = "agent" }
}

if ($rows.Count -eq 0) {
    Write-Warn "No usage data found in this transcript."
    exit 0
}

$rows = $rows | Sort-Object Total -Descending
$grandTotal = ($rows | Measure-Object -Property Total -Sum).Sum
$maxTotal = ($rows | Measure-Object -Property Total -Maximum).Maximum

Write-Step "Token usage - $($transcriptFile.BaseName)"
Write-Info "Agent totals are exact (one pre-aggregated number per invocation)."
Write-Info "Skill totals are a best-effort heuristic - skills run inline with no hard boundary marker."
Write-Host "    " -NoNewline
Write-Host "##" -ForegroundColor $categoryColors.agent -NoNewline
Write-Host " agent   " -NoNewline
Write-Host "##" -ForegroundColor $categoryColors.skill -NoNewline
Write-Host " skill   " -NoNewline
Write-Host "##" -ForegroundColor $categoryColors.orchestrator -NoNewline
Write-Host " orchestrator"
Write-Host ""

foreach ($row in $rows) {
    $barLen = if ($maxTotal -gt 0) { [math]::Max(1, [math]::Round(($row.Total / $maxTotal) * $BarWidth)) } else { 0 }
    $bar = "#" * $barLen
    $totalStr = "{0:N0}" -f $row.Total
    $color = $categoryColors[$row.Category]
    Write-Host ("{0,-32} {1,10}  " -f $row.Label, $totalStr) -NoNewline
    Write-Host $bar -ForegroundColor $color
    if ($row.Detail) {
        Write-Info ("    in={0:N0} out={1:N0} cache-read={2:N0} cache-create={3:N0}" -f $row.Detail.input, $row.Detail.output, $row.Detail.cacheRead, $row.Detail.cacheCreate)
    }
}

Write-Host ""
Write-Ok ("Session total: {0:N0} tokens" -f $grandTotal)

if ($Html) {
    if (-not $HtmlPath) {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $analyticsDir = Join-Path $resolvedProjectDir ".claude\analytics"
        New-Item -ItemType Directory -Force -Path $analyticsDir | Out-Null
        $HtmlPath = Join-Path $analyticsDir "token-usage-report-$($transcriptFile.BaseName)-$timestamp.html"
    } else {
        $htmlParent = Split-Path $HtmlPath -Parent
        if ($htmlParent -and -not (Test-Path $htmlParent)) {
            New-Item -ItemType Directory -Force -Path $htmlParent | Out-Null
        }
    }
    New-HtmlReport -Rows $rows -GrandTotal $grandTotal -SessionName $transcriptFile.BaseName -ProjectPath $resolvedProjectDir -OutFile $HtmlPath
    $resolvedHtmlPath = (Resolve-Path $HtmlPath).Path
    Write-Ok "HTML report written to $resolvedHtmlPath"
}
