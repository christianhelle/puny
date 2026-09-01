#Requires -Version 7.0
<#
.SYNOPSIS
  Orchestrate an autonomous puny loop: implement -> review -> fix until merge worthy.

.DESCRIPTION
  Runs:  puny --prompt/--prompt-file --oneshot  (implement)
         puny --review                           (review, exit 0/1/2)
         loop on exit 1: feed review-results.md back to puny for fixes
  Commits dirty worktree (excluding review-results.md) so that --review
  (which reviews merge-base..HEAD) can see the changes.

.PARAMETER Prompt
  Initial task prompt (mutually exclusive with PromptFile).

.PARAMETER PromptFile
  Load initial prompt from a file (10 MiB limit, as with puny).

.PARAMETER MaxIterations
  Max review->fix cycles (default: 5).

.PARAMETER NoAutoCommit
  Do not auto-commit dirty worktree after each implement step.

.PARAMETER PunyBin
  Puny binary to invoke (default: puny, or $env:PUNY_BIN).

.PARAMETER Help
  Show help.

.EXAMPLE
  ./scripts/orchestrate.ps1 -Prompt "Add CSV export to the report command"
  ./scripts/orchestrate.ps1 -PromptFile spec.md -MaxIterations 3
  ./scripts/orchestrate.ps1 -Prompt "/plan Add CSV export"
  $env:PUNY_BIN = "./zig-out/bin/puny.exe"; ./scripts/orchestrate.ps1 -Prompt "Fix typo"

  Run from the repository root on a feature branch (not main, not detached HEAD).
  Exit code mirrors puny --review: 0=merge worthy, 1=rejected, 2=operational failure.
#>
[CmdletBinding()]
param(
  [string]$Prompt = "",
  [string]$PromptFile = "",
  [string]$Plan = "",
  [string]$PlanFile = "",
  [int]$MaxIterations = 5,
  [switch]$NoAutoCommit,
  [string]$PunyBin = "",
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
  @"
Usage: orchestrate.ps1 [options]

Orchestrate an autonomous puny loop: implement -> review -> fix until merge worthy.

  -Prompt <text>       Initial task prompt (mutually exclusive with -PromptFile)
  -PromptFile <path>   Load initial prompt from a file (10 MiB limit)
  -Plan <text>         Run an interactive planning phase before implement (mutually exclusive with -PlanFile)
  -PlanFile <path>     Run an interactive planning phase from a file
  -MaxIterations <n>   Max review->fix cycles (default: 5)
  -NoAutoCommit        Do not auto-commit; rely on the agent to commit
  -PunyBin <bin>       Puny binary to invoke (default: puny, or `$env:PUNY_BIN)
  -Help                Show this help

Examples:
  ./scripts/orchestrate.ps1 -Prompt "Add CSV export to the report command"
  ./scripts/orchestrate.ps1 -PromptFile spec.md -MaxIterations 3
  ./scripts/orchestrate.ps1 -Plan "Add CSV export with PRD" -Prompt "Implement the PRD at ./prd.md"
  ./scripts/orchestrate.ps1 -PlanFile spec.md
  `$env:PUNY_BIN="./zig-out/bin/puny.exe"; ./scripts/orchestrate.ps1 -Prompt "Fix typo" -NoAutoCommit

Notes:
  - Run from the repository root on a feature branch (not main, not detached HEAD).
  - The script commits dirty changes (excluding review-results.md) so that
    puny --review (which reviews merge-base..HEAD) can see them.
  - Review report is written to review-results.md each iteration.
  - Exit code mirrors puny --review: 0=merge worthy, 1=rejected, 2=operational failure.
  - Planning mode is interactive and cannot be used with -Prompt "/plan ..." + --oneshot.
    The orchestrate planning phase runs `puny --prompt "/plan ..."` without --oneshot,
    waits until you exit puny (/quit), then copies the generated plan.md from the
    session store to ./prd.md in the repo. The next implement step can then use
    -PromptFile ./prd.md or your original -Prompt.
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if (-not $PunyBin) {
  if ($env:PUNY_BIN) { $PunyBin = $env:PUNY_BIN } else { $PunyBin = "puny" }
}

function Fail-WithError {
  param([string]$Message)
  [Console]::Error.WriteLine("error: $Message")
  exit 2
}

if ($Prompt -and $PromptFile) {
  Fail-WithError "cannot use both -Prompt and -PromptFile"
}
if ($Plan -and $PlanFile) {
  Fail-WithError "cannot use both -Plan and -PlanFile"
}
if (-not $Prompt -and -not $PromptFile -and -not $Plan -and -not $PlanFile) {
  Fail-WithError "one of -Prompt, -PromptFile, -Plan, or -PlanFile is required (see -Help)"
}
if ($MaxIterations -lt 1) {
  Fail-WithError "-MaxIterations must be a positive integer"
}

# Planning mode is interactive and cannot be used with --oneshot. Warn if the user
# tries to use -Prompt "/plan ..." which would exit after the first question.
if ($Prompt -like "/plan*") {
  Write-Host "warning: -Prompt `"/plan ...`" with --oneshot will exit after the first planning question." -ForegroundColor Yellow
  Write-Host "         Use -Plan `"task`" for an interactive planning session that waits for the PRD to be saved." -ForegroundColor Yellow
}

# Verify puny binary exists (either in PATH or as a path).
$punyCmd = Get-Command $PunyBin -ErrorAction SilentlyContinue
if (-not $punyCmd -and -not (Test-Path -LiteralPath $PunyBin)) {
  Fail-WithError "puny binary not found: $PunyBin (set -PunyBin or `$env:PUNY_BIN)"
}

# Verify git repository and branch preconditions (mirrors puny --review checks).
try { $null = git rev-parse --show-toplevel 2>$null } catch {
  Fail-WithError "not a git repository"
}
if ($LASTEXITCODE -ne 0) {
  Fail-WithError "not a git repository"
}

$branch = (git symbolic-ref --quiet --short HEAD 2>$null)
if (-not $branch) {
  Fail-WithError "detached HEAD is not supported — checkout a feature branch"
}
if ($branch -eq "main") {
  Fail-WithError "orchestration cannot run on main — checkout a feature branch"
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
$reportPath = Join-Path $repoRoot "review-results.md"
$autoCommit = -not $NoAutoCommit

Write-Host "[orchestrate] branch: $branch"
Write-Host "[orchestrate] repo:   $repoRoot"
Write-Host "[orchestrate] max iterations: $MaxIterations"
Write-Host "[orchestrate] auto-commit:    $(if ($autoCommit) { 'yes' } else { 'no' })"
if ($Plan -or $PlanFile) {
  Write-Host "[orchestrate] planning requested: $(if ($PlanFile) { $PlanFile } else { $Plan })"
}

function Get-DirtyStatus {
  $raw = git status --porcelain=v1 --untracked-files=all 2>$null
  if (-not $raw) { return @() }
  $lines = $raw -split "`n" | Where-Object { $_.Trim().Length -gt 0 }
  # Exclude review-results.md (match puny's withoutGeneratedReport filter).
  $filtered = $lines | Where-Object {
    $path = if ($_.Length -gt 3) { $_.Substring(3).Trim() } else { "" }
    $path -ne "review-results.md"
  }
  return @($filtered)
}

function Commit-IfDirty {
  param([string]$Message)
  $status = @(Get-DirtyStatus)
  if ($status.Count -eq 0) {
    Write-Host "[orchestrate] worktree clean — nothing to commit"
    return $true
  }
  Write-Host "[orchestrate] committing dirty worktree..."
  $status | ForEach-Object { Write-Host "  $_" }
  # Stage everything except review-results.md (puny treats it as generated).
  # Always ensure review-results.md is not staged, even if it was staged before.
  git add -A -- ':!review-results.md' 2>$null
  if ($LASTEXITCODE -ne 0) {
    git add -A
    if ($LASTEXITCODE -ne 0) {
      [Console]::Error.WriteLine("error: git add failed")
      return $false
    }
  }
  git reset -q HEAD -- review-results.md 2>$null | Out-Null
  git commit -m $Message
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("error: git commit failed")
    return $false
  }
  return $true
}

function Get-PunySessionBase {
  if ($env:XDG_CONFIG_HOME) {
    return Join-Path $env:XDG_CONFIG_HOME "puny/sessions"
  } elseif ($env:APPDATA) {
    return Join-Path $env:APPDATA "puny/sessions"
  } elseif ($env:USERPROFILE) {
    # Fallback for Windows when APPDATA not set
    $p = Join-Path $env:USERPROFILE "puny/sessions"
    if (Test-Path $p) { return $p }
    return Join-Path $env:USERPROFILE ".config/puny/sessions"
  } else {
    return Join-Path $env:HOME ".config/puny/sessions"
  }
}

function Find-LatestPlan {
  param(
    [DateTime]$Since = [DateTime]::MinValue
  )
  $base = Get-PunySessionBase
  # Also try alternative fallbacks
  $candidates = @($base)
  if ($env:USERPROFILE) {
    $candidates += Join-Path $env:USERPROFILE "puny/sessions"
    $candidates += Join-Path $env:USERPROFILE ".config/puny/sessions"
  }
  if ($env:HOME) {
    $candidates += Join-Path $env:HOME ".config/puny/sessions"
  }
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      $latest = Get-ChildItem -Path $candidate -Recurse -Filter "plan.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
      if ($latest) { return $latest.FullName }
    }
  }
  return $null
}

function Invoke-PlanningPhase {
  Write-Host "[orchestrate] Starting interactive planning phase..."
  Write-Host "[orchestrate] Puny will run without --oneshot. Answer the planning questions."
  Write-Host "[orchestrate] When the PRD is saved, exit puny (/quit or Ctrl+C) to continue to implement."
  Write-Host "[orchestrate] The generated PRD will be copied to $repoRoot/prd.md"
  $planInput = ""
  if ($PlanFile) {
    if (-not (Test-Path $PlanFile)) {
      Fail-WithError "plan file not found: $PlanFile"
    }
    $planInput = Get-Content -Raw -LiteralPath $PlanFile
  } else {
    $planInput = $Plan
  }
  # Record start time to avoid picking up stale plans from previous sessions
  # Capture existing plans before planning for session binding
  $baseForBefore = Get-PunySessionBase
  $beforePlans = @()
  $candidatesBefore = @($baseForBefore)
  if ($env:USERPROFILE) {
    $candidatesBefore += Join-Path $env:USERPROFILE "puny/sessions"
    $candidatesBefore += Join-Path $env:USERPROFILE ".config/puny/sessions"
  }
  if ($env:HOME) {
    $candidatesBefore += Join-Path $env:HOME ".config/puny/sessions"
  }
  foreach ($candidate in $candidatesBefore) {
    if (Test-Path $candidate) {
      $beforePlans += Get-ChildItem -Path $candidate -Recurse -Filter "plan.md" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
  }
  $planningStart = Get-Date
  # Use a temporary prompt file to avoid OS command-line length limits (ARG_MAX)
  $tmpPrompt = [System.IO.Path]::GetTempFileName()
  try {
    "/plan $planInput" | Set-Content -LiteralPath $tmpPrompt -Encoding utf8 -NoNewline
    # Run puny in planning mode without --oneshot, wait indefinitely until exit
    & $PunyBin --prompt-file $tmpPrompt
    $ec = $LASTEXITCODE
  } finally {
    Remove-Item -LiteralPath $tmpPrompt -Force -ErrorAction SilentlyContinue
  }
  if ($ec -ne 0) {
    Write-Host "[orchestrate] planning puny exited with code $ec (continuing to look for PRD)" -ForegroundColor Yellow
  }
  # Find latest plan that is new and newer than start time (session binding)
  $latestPlan = $null
  $latestTime = [DateTime]::MinValue
  foreach ($candidate in $candidatesBefore) {
    if (Test-Path $candidate) {
      $plans = Get-ChildItem -Path $candidate -Recurse -Filter "plan.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notin $beforePlans -and $_.LastWriteTime -ge $planningStart } |
        Sort-Object LastWriteTime -Descending
      if ($plans) {
        $candidateLatest = $plans | Select-Object -First 1
        if ($candidateLatest.LastWriteTime -gt $latestTime) {
          $latestTime = $candidateLatest.LastWriteTime
          $latestPlan = $candidateLatest.FullName
        }
      }
    }
  }
  # Fallback to Find-LatestPlan with start-time filter if no new session plan found
  if (-not $latestPlan) {
    $latestPlan = Find-LatestPlan -Since $planningStart
  }
  if (-not $latestPlan -or -not (Test-Path $latestPlan)) {
    Write-Host "[orchestrate] warning: no plan.md found in session store after planning (or no plan newer than start time)." -ForegroundColor Yellow
    Write-Host "[orchestrate] Checked: $(Get-PunySessionBase) (and fallbacks) since $planningStart" -ForegroundColor Yellow
    Write-Host "[orchestrate] You can manually copy the PRD to $repoRoot/prd.md and continue." -ForegroundColor Yellow
    return $false
  }
  Write-Host "[orchestrate] Found plan: $latestPlan"
  Copy-Item -LiteralPath $latestPlan -Destination (Join-Path $repoRoot "prd.md") -Force
  Write-Host "[orchestrate] Copied PRD to $(Join-Path $repoRoot "prd.md")"
  $latestHtml = [System.IO.Path]::ChangeExtension($latestPlan, ".html")
  # Actually plan.html is sibling with same base name but .html
  $latestHtml = Join-Path (Split-Path $latestPlan) "plan.html"
  if (Test-Path $latestHtml) {
    Copy-Item -LiteralPath $latestHtml -Destination (Join-Path $repoRoot "prd.html") -Force
    Write-Host "[orchestrate] Copied HTML to $(Join-Path $repoRoot "prd.html")"
  }
  if (-not $Prompt -and -not $PromptFile) {
    $script:PromptFile = Join-Path $repoRoot "prd.md"
    Write-Host "[orchestrate] Using generated prd.md for implement phase"
  }
  return $true
}

function Invoke-PunyImplement {
  $argsList = @()
  if ($PromptFile) {
    $argsList += @("--prompt-file", $PromptFile)
  } else {
    $argsList += @("--prompt", $Prompt)
  }
  $argsList += @("--oneshot")
  Write-Host "[orchestrate] running: $PunyBin $($argsList -join ' ')"
  & $PunyBin @argsList
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("error: puny implement step failed with exit code $LASTEXITCODE")
    exit 2
  }
}

function Invoke-PunyFix {
  $fixPrompt = "Review found issues (see review-results.md). Read $reportPath with read_file and fix every finding, then ensure existing tests still pass. Do not edit review-results.md. Work only on source files."
  Write-Host "[orchestrate] running fix: $PunyBin --prompt <fix> --oneshot"
  & $PunyBin --prompt $fixPrompt --oneshot
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("error: puny fix step failed with exit code $LASTEXITCODE")
    exit 2
  }
}

function Invoke-Review {
  Write-Host "[orchestrate] running: $PunyBin --review"
  & $PunyBin --review
  return $LASTEXITCODE
}

# Phase 0: interactive planning (optional, runs without --oneshot and waits)
# Planning mode uses an interactive interview and cannot be used with --oneshot.
# This phase runs `puny --prompt "/plan ..."` without --oneshot, waits indefinitely
# until you exit puny, then copies the generated plan.md from the session store
# to $repoRoot/prd.md for the implement step.
if ($Plan -or $PlanFile) {
  $planningOk = Invoke-PlanningPhase
  if (-not $planningOk) {
    Write-Host "[orchestrate] planning phase did not produce a PRD, continuing..." -ForegroundColor Yellow
  }
  if (-not $Prompt -and -not $PromptFile) {
    if (-not (Test-Path (Join-Path $repoRoot "prd.md"))) {
      Fail-WithError "no implement prompt available and no prd.md was generated (provide -Prompt/-PromptFile or ensure planning saved a PRD)"
    }
  }
}

if (-not $Prompt -and -not $PromptFile) {
  Fail-WithError "no implement prompt available (provide -Prompt/-PromptFile or use -Plan to generate prd.md)"
}

# Phase 1: initial implement
Invoke-PunyImplement
if ($autoCommit) {
  if (-not (Commit-IfDirty -Message "puny orchestrate: implement initial prompt")) {
    exit 2
  }
}

# Phase 2: review -> fix loop
for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
  Write-Host ""
  Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  Write-Host "[orchestrate] review iteration $iteration/$MaxIterations"
  Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  $ec = Invoke-Review

  if ($ec -eq 0) {
    Write-Host ""
    Write-Host "[orchestrate] ✓ MERGE WORTHY — report: $reportPath"
    if (Test-Path -LiteralPath $reportPath) {
      Get-Content -LiteralPath $reportPath -Tail 20 | Write-Host
    }
    exit 0
  } elseif ($ec -eq 1) {
    Write-Host "[orchestrate] ✗ not merge worthy (exit 1) — report: $reportPath"
    if (-not (Test-Path -LiteralPath $reportPath)) {
      Write-Host "[orchestrate] missing report; treating as operational failure" -ForegroundColor Red
      exit 2
    }
    Write-Host "---- review findings (tail) ----"
    Get-Content -LiteralPath $reportPath -Tail 60 | Write-Host
    Write-Host "--------------------------------"
    if ($iteration -eq $MaxIterations) {
      Write-Host "[orchestrate] max iterations ($MaxIterations) reached — branch still not merge worthy" -ForegroundColor Red
      exit 1
    }
    Write-Host "[orchestrate] applying fixes for iteration $iteration..."
    Invoke-PunyFix
    if ($autoCommit) {
      if (-not (Commit-IfDirty -Message "puny orchestrate: fix review findings (iteration $iteration)")) {
        exit 2
      }
    }
  } elseif ($ec -eq 2) {
    Write-Host "[orchestrate] ! operational failure (exit 2) — report: $reportPath" -ForegroundColor Red
    if (Test-Path -LiteralPath $reportPath) {
      Write-Host "---- fallback report ----"
      Get-Content -LiteralPath $reportPath | Write-Host
      Write-Host "-------------------------"
    }
    exit 2
  } else {
    Write-Host "[orchestrate] ! unexpected exit code $ec from puny --review" -ForegroundColor Red
    exit 2
  }
}

Write-Host "[orchestrate] loop exhausted — not merge worthy after $MaxIterations iterations" -ForegroundColor Red
exit 1
