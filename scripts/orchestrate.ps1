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
  -MaxIterations <n>   Max review->fix cycles (default: 5)
  -NoAutoCommit        Do not auto-commit; rely on the agent to commit
  -PunyBin <bin>       Puny binary to invoke (default: puny, or `$env:PUNY_BIN)
  -Help                Show this help

Examples:
  ./scripts/orchestrate.ps1 -Prompt "Add CSV export to the report command"
  ./scripts/orchestrate.ps1 -PromptFile spec.md -MaxIterations 3
  ./scripts/orchestrate.ps1 -Prompt "/plan Add CSV export"   # start with planning mode
  `$env:PUNY_BIN="./zig-out/bin/puny.exe"; ./scripts/orchestrate.ps1 -Prompt "Fix typo"

Notes:
  - Run from the repository root on a feature branch (not main, not detached HEAD).
  - The script commits dirty changes (excluding review-results.md) so that
    puny --review (which reviews merge-base..HEAD) can see them.
  - Review report is written to review-results.md each iteration.
  - Exit code mirrors puny --review: 0=merge worthy, 1=rejected, 2=operational failure.
"@ | Write-Host
}

if ($Help) {
  Show-Usage
  exit 0
}

if (-not $PunyBin) {
  if ($env:PUNY_BIN) { $PunyBin = $env:PUNY_BIN } else { $PunyBin = "puny" }
}

if ($Prompt -and $PromptFile) {
  Write-Error "cannot use both -Prompt and -PromptFile"
  exit 2
}
if (-not $Prompt -and -not $PromptFile) {
  Write-Error "one of -Prompt or -PromptFile is required (see -Help)"
  exit 2
}
if ($MaxIterations -lt 1) {
  Write-Error "-MaxIterations must be a positive integer"
  exit 2
}

# Verify puny binary exists (either in PATH or as a path).
$punyCmd = Get-Command $PunyBin -ErrorAction SilentlyContinue
if (-not $punyCmd -and -not (Test-Path -LiteralPath $PunyBin)) {
  Write-Error "puny binary not found: $PunyBin (set -PunyBin or `$env:PUNY_BIN)"
  exit 2
}

# Verify git repository and branch preconditions (mirrors puny --review checks).
try { $null = git rev-parse --show-toplevel 2>$null } catch {
  Write-Error "not a git repository"
  exit 2
}
if ($LASTEXITCODE -ne 0) {
  Write-Error "not a git repository"
  exit 2
}

$branch = (git symbolic-ref --quiet --short HEAD 2>$null)
if (-not $branch) {
  Write-Error "detached HEAD is not supported — checkout a feature branch"
  exit 2
}
if ($branch -eq "main") {
  Write-Error "orchestration cannot run on main — checkout a feature branch"
  exit 2
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
$reportPath = Join-Path $repoRoot "review-results.md"
$autoCommit = -not $NoAutoCommit

Write-Host "[orchestrate] branch: $branch"
Write-Host "[orchestrate] repo:   $repoRoot"
Write-Host "[orchestrate] max iterations: $MaxIterations"
Write-Host "[orchestrate] auto-commit:    $(if ($autoCommit) { 'yes' } else { 'no' })"

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
  $status = Get-DirtyStatus
  if (-not $status -or $status.Count -eq 0) {
    Write-Host "[orchestrate] worktree clean — nothing to commit"
    return $true
  }
  Write-Host "[orchestrate] committing dirty worktree..."
  $status | ForEach-Object { Write-Host "  $_" }
  git add -A
  if ($LASTEXITCODE -ne 0) {
    Write-Error "git add failed"
    return $false
  }
  git commit -m $Message
  if ($LASTEXITCODE -ne 0) {
    Write-Error "git commit failed"
    return $false
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
    Write-Error "puny implement step failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}

function Invoke-PunyFix {
  $fixPrompt = "Review found issues (see review-results.md). Read $reportPath with read_file and fix every finding, then ensure existing tests still pass. Do not edit review-results.md. Work only on source files."
  Write-Host "[orchestrate] running fix: $PunyBin --prompt <fix> --oneshot"
  & $PunyBin --prompt $fixPrompt --oneshot
  if ($LASTEXITCODE -ne 0) {
    Write-Error "puny fix step failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
  }
}

function Invoke-Review {
  Write-Host "[orchestrate] running: $PunyBin --review"
  & $PunyBin --review
  return $LASTEXITCODE
}

# Phase 1: initial implement (plan -> implement). If the prompt starts with /plan,
# puny will enter planning mode and attempt to save plan.md in one turn.
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
