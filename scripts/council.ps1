#Requires -Version 7.0

<#
.SYNOPSIS
Runs a council of AI reviewers over a plan, a diff, or free text.

.DESCRIPTION
Each member critiques the subject independently, then critiques the other
members' critiques, then a chair synthesises a single ranked verdict. Members
differ by model (round-robin) and by role brief, and are seated in adversarial
pairs so that disagreement is engineered rather than hoped for.

This is the PowerShell twin of council.sh. Both scripts read the same role briefs
and prompt templates from scripts/council, and compose prompts identically, so a
prompt produced by one is byte-for-byte the prompt produced by the other.
#>

[CmdletBinding()]
param(
  [string]$SubjectFile,
  [string]$Diff,
  [string]$Subject,
  [ValidateSet('plan', 'diff', 'text')][string]$Kind,
  [int]$Members = 6,
  [string[]]$Models,
  [string]$Chair,
  [string[]]$Roles,
  [switch]$SkipCross,
  [switch]$SkipChair,
  [switch]$SkipSummary,
  [int]$Jobs = 3,
  [int]$TimeoutSec = 900,
  [int]$MinMembers = 0,
  [int]$MinAnswerChars = 200,
  [int]$MaxPeerChars = 20000,
  [string]$Out,
  [string]$Bin,
  [switch]$NoChatLog,
  [switch]$NoIsolateHome,
  [switch]$KeepTemp,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$Smoke,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AssetDir = Join-Path $ScriptDir 'council'

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-WarningMessage { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-ErrorMessage { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Show-Usage {
  @'
Usage: council.ps1 [options]

Runs a council of AI reviewers over a subject and writes a synthesised verdict.

Subject (exactly one is required):
  -SubjectFile PATH     Critique the contents of a file
  -Diff BASE            Critique "git diff BASE...HEAD"
  -Subject TEXT         Critique the given text
  -Kind KIND            plan | diff | text (default: inferred)

Council:
  -Members N            Number of council members (default: 6, maximum: 8)
  -Models LIST          Models, each [provider:]model
  -Chair SPEC           Model that writes the final verdict (default: first)
  -Roles LIST           Role ids instead of the first N seats
  -SkipCross            Skip round two (the cross-critique)
  -SkipChair            Skip round three (the synthesis)
  -SkipSummary          Skip the plain-language summary of the verdict

Execution:
  -Jobs N               Maximum members running at once (default: 3)
  -TimeoutSec N         Per-member time limit, or 0 for none (default: 900)
  -MinMembers N         Abort after round one below this many (default: half)
  -MinAnswerChars N     Shorter answers count as a failure (default: 200)
  -MaxPeerChars N       Truncate each peer critique in round two (default: 20000)
  -Bin PATH             Path to the puny binary
  -NoChatLog            Extract answers from stdout instead of puny_chat.log
  -NoIsolateHome        Share the real puny config directory between members
  -KeepTemp             Do not delete the per-member working directories

Output:
  -Out DIR              Output directory (default: .council/<timestamp>-<slug>)
  -Force                Clear a non-empty output directory before running
  -DryRun               Compose round-one prompts only, call no models
  -Smoke                Self-test against the mock provider
  -Help                 Show this help text

Environment: PUNY_BIN, COUNCIL_MEMBERS, COUNCIL_MODELS, COUNCIL_CHAIR, COUNCIL_OUT,
COUNCIL_JOBS, COUNCIL_TIMEOUT

Exit codes: 0 ok, 1 usage or preflight, 2 quorum not met, 3 chair failed
'@
}

# Values that arrive through the environment never pass through the parameter
# binder, so a stray "COUNCIL_JOBS=lots" would otherwise crash on the cast.
function ConvertTo-WholeNumber {
  param([string]$Label, [string]$Value, [int]$Minimum)
  $parsed = 0
  if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt $Minimum) {
    Write-Host "[ERROR] $Label must be a whole number of at least $Minimum, got '$Value'" -ForegroundColor Red
    exit 1
  }
  return $parsed
}

function Stop-WithError {
  param([string]$Message, [int]$Code = 1)
  Write-ErrorMessage $Message
  exit $Code
}

# Every file this script writes uses LF endings and UTF-8 without a byte order
# mark, so that prompts match council.sh byte for byte.
function Write-TextFile {
  param([string]$Path, [string]$Text)
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-TextFile {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path)
}

function Join-Lines {
  param([string[]]$Lines)
  if ($null -eq $Lines -or $Lines.Count -eq 0) { return '' }
  return ($Lines -join "`n") + "`n"
}

function Get-FileLines {
  param([string]$Path)
  return [System.IO.File]::ReadAllLines($Path)
}

function Get-FileByteCount {
  param([string]$Path)
  return (Get-Item -LiteralPath $Path).Length
}

# Splits "[provider:]model". A leading token is treated as a provider only when
# it names one. A bare "foo:bar" is rejected so a typo cannot silently become a
# model id, while ids that legitimately contain a colon pass through untouched.
function Split-ModelSpec {
  param([string]$Spec)

  $result = [pscustomobject]@{ Provider = ''; Model = $Spec }
  if ($Spec -notmatch ':') { return $result }

  $head = $Spec.Substring(0, $Spec.IndexOf(':'))
  if ($script:KnownProviders -contains $head) {
    $result.Provider = $head
    $result.Model = $Spec.Substring($head.Length + 1)
    return $result
  }

  if ($head -notmatch '/') {
    Stop-WithError "Unknown provider '$head' in model spec '$Spec' (known: $($script:KnownProviders -join ' '))"
  }

  return $result
}

# These lists live in files both runners read, so adding a provider or tracking a
# new mock keyword does not mean remembering to edit two scripts.
function Read-WordList {
  param([string]$Path, [string]$Label)
  if (-not (Test-Path -LiteralPath $Path)) { Stop-WithError "$Label not found: $Path" }
  $words = @(Get-FileLines $Path |
    Where-Object { $_ -notmatch '^\s*(#|$)' } |
    ForEach-Object { $_.Trim() })
  if ($words.Count -eq 0) { Stop-WithError "$Label is empty: $Path" }
  return $words
}

function Import-SharedLists {
  $script:KnownProviders = Read-WordList (Join-Path $AssetDir 'providers.txt') 'Provider list'
  $script:MockTriggerWords = Read-WordList (Join-Path $AssetDir 'mock-triggers.txt') 'Mock trigger list'
}

function Resolve-PunyBinary {
  if ($script:BinPath) {
    if (-not (Test-Path -LiteralPath $script:BinPath)) {
      Stop-WithError "puny binary not found: $($script:BinPath)"
    }
    return
  }

  foreach ($candidate in @(
      (Join-Path $ScriptDir '..\zig-out\bin\puny.exe'),
      (Join-Path $ScriptDir '..\zig-out\bin\puny'))) {
    if (Test-Path -LiteralPath $candidate) {
      $script:BinPath = (Resolve-Path -LiteralPath $candidate).Path
      return
    }
  }

  $onPath = Get-Command puny -ErrorAction SilentlyContinue
  if ($onPath) {
    $script:BinPath = $onPath.Source
    return
  }

  Stop-WithError "Could not find the puny binary. Build it with 'zig build' or pass -Bin PATH."
}

function Test-Arguments {
  $chosen = @($SubjectFile, $Diff, $Subject | Where-Object { $_ }).Count

  if ($chosen -eq 0) {
    Write-ErrorMessage 'No subject given. Pass one of -SubjectFile, -Diff, or -Subject.'
    Show-Usage
    exit 1
  }
  if ($chosen -gt 1) {
    Stop-WithError '-SubjectFile, -Diff, and -Subject are mutually exclusive'
  }
  if ($SubjectFile -and -not (Test-Path -LiteralPath $SubjectFile -PathType Leaf)) {
    Stop-WithError "Subject file not found: $SubjectFile"
  }
  foreach ($pair in @(@('Members', $script:MemberCount), @('Jobs', $script:JobLimit),
      @('MinAnswerChars', $MinAnswerChars), @('MaxPeerChars', $MaxPeerChars))) {
    if ($pair[1] -lt 1) { Stop-WithError "-$($pair[0]) requires a positive whole number, got '$($pair[1])'" }
  }
  if ($script:Timeout -lt 0) { Stop-WithError "-TimeoutSec requires a whole number, got '$($script:Timeout)'" }
  if ($script:Timeout -eq 0) {
    Write-WarningMessage 'Running without a time limit; a hung member will block its slot indefinitely'
  }

  if ($script:MemberCountExplicit -and $Roles) {
    Stop-WithError '-Members and -Roles are mutually exclusive; let one of them decide the council size'
  }

  if ($script:JobLimit -gt $script:MemberCount) { $script:JobLimit = $script:MemberCount }

  if ($script:MemberFloor -lt 1) {
    $script:MemberFloor = [Math]::Max(2, [Math]::Ceiling($script:MemberCount / 2))
  }
  # Peer critiques are truncated on a line boundary, so a budget smaller than a
  # line of prose would drop the whole critique and leave only the marker.
  if ($MaxPeerChars -lt 1000) {
    Stop-WithError "-MaxPeerChars must be at least 1000, got $MaxPeerChars"
  }

  if ($script:MemberFloor -gt $script:MemberCount) {
    Stop-WithError "-MinMembers ($($script:MemberFloor)) exceeds the member count ($($script:MemberCount))"
  }
}

# Loads the role briefs in seat order. Smoke runs use a separate, keyword-safe
# set because the real briefs contain words the mock provider treats as triggers.
function Import-Roles {
  $script:RoleDir = Join-Path $AssetDir 'roles'
  $script:PromptDir = Join-Path $AssetDir 'prompts'
  if ($Smoke) {
    $script:RoleDir = Join-Path $AssetDir 'smoke\roles'
    $script:PromptDir = Join-Path $AssetDir 'smoke\prompts'
  }

  if (-not (Test-Path -LiteralPath $script:RoleDir)) { Stop-WithError "Role directory not found: $($script:RoleDir)" }
  if (-not (Test-Path -LiteralPath $script:PromptDir)) { Stop-WithError "Prompt directory not found: $($script:PromptDir)" }

  $all = @()
  foreach ($file in Get-ChildItem -LiteralPath $script:RoleDir -Filter '*.md' | Sort-Object Name) {
    if ($file.BaseName -notmatch '^[0-9]{2}-(.+)$') { continue }
    $id = $Matches[1]
    $first = (Get-FileLines $file.FullName | Select-Object -First 1)
    $name = ($first -replace '^#\s*', '')
    if (-not $name) { $name = $id }
    $all += [pscustomobject]@{ Id = $id; Name = $name; File = $file.FullName }
  }

  if ($all.Count -eq 0) { Stop-WithError "No role briefs found in $($script:RoleDir)" }

  $script:Seats = @()
  if ($Roles) {
    $seen = @{}
    foreach ($item in $Roles) {
      foreach ($want in ($item -split ',')) {
        $want = $want.Trim()
        if (-not $want) { continue }
        if ($seen.ContainsKey($want)) { Stop-WithError "Role '$want' selected more than once" }
        $seen[$want] = $true
        $match = $all | Where-Object { $_.Id -eq $want } | Select-Object -First 1
        if (-not $match) { Stop-WithError "Unknown role '$want'. Available: $(($all.Id) -join ' ')" }
        $script:Seats += $match
      }
    }
    $script:MemberTotal = $script:Seats.Count
    if ($script:MemberTotal -eq 0) { Stop-WithError '-Roles selected no roles' }
  }
  else {
    if ($script:MemberCount -gt $all.Count) {
      Stop-WithError "Only $($all.Count) role briefs exist in $($script:RoleDir), cannot seat $($script:MemberCount) members"
    }
    $script:Seats = @($all | Select-Object -First $script:MemberCount)
    $script:MemberTotal = $script:MemberCount
  }

  if ($script:MemberTotal % 2 -ne 0) {
    Write-WarningMessage "Member count $($script:MemberTotal) is odd, so one seat has no adversarial opposite"
  }
}

# Assigns models round-robin across seats and pairs seat i with seat i XOR 1.
function Set-Seating {
  $specs = @()
  if ($Smoke) {
    $specs = @('mock')
  }
  elseif ($script:ModelList) {
    $specs = @($script:ModelList | ForEach-Object { $_.Trim() })
  }
  else {
    $specs = @('')
    Write-Info 'No -Models given; every member uses the model from your puny config'
  }

  if (-not $Smoke) {
    if ($specs.Count -eq 1 -and $specs[0]) {
      Write-WarningMessage 'Only one model given; members will differ by role brief alone'
    }
    elseif ($specs.Count -gt 1 -and $specs.Count % 2 -ne 0) {
      Write-WarningMessage 'An odd number of models means some adversarial pairs share a model'
    }
  }

  for ($i = 0; $i -lt $script:MemberTotal; $i++) {
    $seat = $script:Seats[$i]
    if ($Smoke) {
      $parsed = [pscustomobject]@{ Provider = ''; Model = '' }
    }
    else {
      $parsed = Split-ModelSpec $specs[$i % $specs.Count]
    }
    Add-Member -InputObject $seat -NotePropertyName Index -NotePropertyValue $i -Force
    Add-Member -InputObject $seat -NotePropertyName Provider -NotePropertyValue $parsed.Provider -Force
    Add-Member -InputObject $seat -NotePropertyName Model -NotePropertyValue $parsed.Model -Force
    Add-Member -InputObject $seat -NotePropertyName Slug -NotePropertyValue ('{0:d2}-{1}' -f $i, $seat.Id) -Force
    $pair = $i -bxor 1
    if ($pair -ge $script:MemberTotal) { $pair = -1 }
    Add-Member -InputObject $seat -NotePropertyName Pair -NotePropertyValue $pair -Force
  }

  if ($Smoke) {
    $script:ChairProvider = ''
    $script:ChairModel = ''
  }
  elseif ($script:ChairSpec) {
    $parsed = Split-ModelSpec $script:ChairSpec
    $script:ChairProvider = $parsed.Provider
    $script:ChairModel = $parsed.Model
  }
  else {
    $script:ChairProvider = $script:Seats[0].Provider
    $script:ChairModel = $script:Seats[0].Model
  }
}

function Get-ModelLabel {
  param([int]$Index)
  if ($Smoke) { return 'mock' }
  $seat = $script:Seats[$Index]
  if ($seat.Provider) { return "$($seat.Provider):$($seat.Model)" }
  if ($seat.Model) { return $seat.Model }
  return 'config default'
}

function Get-ChairLabel {
  if ($Smoke) { return 'mock' }
  if ($script:ChairProvider) { return "$($script:ChairProvider):$($script:ChairModel)" }
  if ($script:ChairModel) { return $script:ChairModel }
  return 'config default'
}

# Condenses verdict.md into something readable without opening a file. The chair
# writes for the record and runs to several thousand words; this is the version
# you read in the terminal before deciding what to do.
function Invoke-Summary {
  $verdictPath = Join-Path $script:OutDir 'verdict.md'
  if (-not (Test-Path -LiteralPath $verdictPath) -or (Get-FileByteCount $verdictPath) -eq 0) {
    Write-WarningMessage 'No verdict to summarise'
    return 1
  }

  $template = Join-Path $script:PromptDir 'round4-summary.md'
  if (-not (Test-Path -LiteralPath $template)) { Stop-WithError "Summary template not found: $template" }

  $prompt = Join-Path $script:OutDir 'round4\summary.prompt.md'
  $scratch = "$prompt.scalars"
  Expand-Scalars $template $scratch 'summary' 'Summary' 'none' $script:MemberTotal
  Expand-Markers $scratch $prompt @{ '{{VERDICT_REPORT}}' = $verdictPath }
  Remove-Item -LiteralPath $scratch -Force
  if ($Smoke) { Assert-NoMockTriggers $prompt }

  Write-Info "Summarising the verdict ($(Get-ChairLabel))"
  $dest = Join-Path $script:OutDir 'round4'
  $job = Start-Member 'summary' $script:ChairProvider $script:ChairModel $prompt $dest
  $status = Complete-Member $job

  if ($status -ne 'ok') {
    Write-WarningMessage "The summary step failed ($status); the full verdict is still in verdict.md"
    return 1
  }

  Copy-Item -LiteralPath (Join-Path $dest 'summary.md') -Destination (Join-Path $script:OutDir 'summary.md') -Force
  return 0
}

# The summary is the deliverable, not a diagnostic, so it goes to the output
# stream while every log line goes to the host.
function Show-Summary {
  $path = Join-Path $script:OutDir 'summary.md'
  if (-not (Test-Path -LiteralPath $path) -or (Get-FileByteCount $path) -eq 0) { return }
  Write-Output ''
  Write-Output '──────── Council summary ────────'
  Write-Output ''
  Write-Output (Read-TextFile $path).TrimEnd()
  Write-Output ''
}

function ConvertTo-Slug {
  param([string]$Text)
  $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
  return $slug
}

# Everything a run owns. Kept explicit so -Force clears the previous run
# without touching anything else that happens to live in the directory.
$CouncilArtifacts = @('round1', 'round2', 'round3', 'round4', 'subject.md',
  'verdict.md', 'summary.md', 'council.md', 'manifest.tsv')

function Initialize-OutputDirectory {
  if (-not $script:OutDir) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    if ($SubjectFile) { $slug = ConvertTo-Slug ([System.IO.Path]::GetFileNameWithoutExtension($SubjectFile)) }
    elseif ($Diff) { $slug = ConvertTo-Slug "diff-$Diff" }
    else { $slug = 'text' }
    if (-not $slug) { $slug = 'subject' }
    $script:OutDir = Join-Path '.council' "$stamp-$slug"
  }
  # Reusing a directory silently mixes runs: seats that are not seated this time
  # keep their old critiques, and a skipped chair leaves the previous verdict in
  # place, which then gets reported and summarised as if it were this run's.
  if ((Test-Path -LiteralPath $script:OutDir) -and
      @(Get-ChildItem -LiteralPath $script:OutDir -Force).Count -gt 0) {
    if (-not $Force) {
      Write-ErrorMessage "Output directory is not empty: $($script:OutDir)"
      Write-ErrorMessage 'Rerunning into it would report stale critiques and verdicts as current.'
      Stop-WithError 'Pass -Force to clear the previous run, or choose a different -Out.'
    }
    Write-WarningMessage "Clearing the previous run in $($script:OutDir)"
    foreach ($artifact in $CouncilArtifacts) {
      $path = Join-Path $script:OutDir $artifact
      if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
  }

  foreach ($sub in @('round1', 'round2', 'round3', 'round4')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:OutDir $sub) | Out-Null
  }
  $script:OutDir = (Resolve-Path -LiteralPath $script:OutDir).Path
}

# A three-dot diff is committed work only. Reviewing a branch with uncommitted
# changes would otherwise return a verdict on code the author is not shipping,
# with nothing on screen to say so.
function Write-DirtyTreeWarning {
  $dirty = @(& git status --porcelain=v1 --untracked-files=normal 2>$null)
  if ($dirty.Count -eq 0) { return }

  Write-WarningMessage "$($dirty.Count) uncommitted change(s) are NOT included in this review."
  Write-WarningMessage 'The council will see committed work only. Commit them first, or pass the'
  Write-WarningMessage "output of 'git diff' through -SubjectFile to have them critiqued."
}

# Writes the exact bytes every member will see into <out>/subject.md.
function Resolve-Subject {
  $script:SubjectPath = Join-Path $script:OutDir 'subject.md'
  $kind = $Kind

  if ($SubjectFile) {
    Write-TextFile $script:SubjectPath (Read-TextFile $SubjectFile)
    $script:SubjectLabel = "file $SubjectFile"
    if (-not $kind) {
      switch -Regex ($SubjectFile) {
        '\.(md|markdown)$' { $kind = 'plan'; break }
        '\.(diff|patch)$' { $kind = 'diff'; break }
        default { $kind = 'text' }
      }
    }
  }
  elseif ($Diff) {
    & git rev-parse --git-dir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError '-Diff needs to run inside a git repository' }
    & git rev-parse --verify $Diff 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "-Diff base '$Diff' is not a valid revision" }
    $lines = @('Summary of the change:', '')
    $lines += (& git diff --stat "$Diff...HEAD")
    $lines += @('', 'Full diff:', '')
    $lines += (& git diff "$Diff...HEAD")
    Write-TextFile $script:SubjectPath (Join-Lines $lines)
    Write-DirtyTreeWarning
    $script:SubjectLabel = "git diff $Diff...HEAD"
    # An explicit -Kind wins here too; silently overriding it would judge the
    # change with a template the caller did not ask for.
    if (-not $kind) { $kind = 'diff' }
  }
  else {
    Write-TextFile $script:SubjectPath ($Subject + "`n")
    $script:SubjectLabel = 'inline text'
    if (-not $kind) { $kind = 'text' }
  }

  $script:SubjectKind = $kind
  $bytes = Get-FileByteCount $script:SubjectPath
  if ($bytes -le 0) { Stop-WithError 'The subject is empty' }
  if ($bytes -gt 204800) {
    Write-WarningMessage "Subject is $bytes bytes; large subjects can exceed a model's context window"
  }
  Write-Info "Subject: $($script:SubjectLabel) ($bytes bytes, kind: $kind)"
}

# Replaces whole-line block markers in a single pass, so that text pulled in by
# one marker is never rescanned for another. Inserted content is untrusted model
# output, and a second pass over it would let it expand markers of its own.
function Expand-Markers {
  param([string]$TemplatePath, [string]$OutPath, [hashtable]$Map)

  $builder = [System.Text.StringBuilder]::new()
  foreach ($line in Get-FileLines $TemplatePath) {
    if ($Map.ContainsKey($line)) {
      foreach ($inner in Get-FileLines $Map[$line]) { [void]$builder.Append($inner).Append("`n") }
    }
    else {
      [void]$builder.Append($line).Append("`n")
    }
  }
  Write-TextFile $OutPath $builder.ToString()
}

# Substitutes the short scalar markers, then checks that nothing but the known
# block markers is left. This runs on the template only, before any subject or
# peer text is spliced in, so a subject that happens to contain "{{SUBJECT}}"
# cannot trip the check.
function Expand-Scalars {
  param(
    [string]$TemplatePath, [string]$OutPath,
    [string]$MemberN, [string]$RoleName, [string]$PairName, [string]$MemberCount
  )

  $known = '^\{\{(ROLE_BRIEF|SUBJECT|OWN_ROUND1|PEER_CRITIQUES|ALL_ROUND1|ALL_ROUND2|VERDICT_REPORT)\}\}$'
  $lines = foreach ($line in Get-FileLines $TemplatePath) {
    $line.Replace('{{MEMBER_N}}', $MemberN).
    Replace('{{ROLE_NAME}}', $RoleName).
    Replace('{{PAIR_NAME}}', $PairName).
    Replace('{{N_MEMBERS}}', $MemberCount)
  }
  Write-TextFile $OutPath (Join-Lines $lines)

  $leftover = [System.Text.RegularExpressions.Regex]::Matches(
    (Join-Lines $lines), '\{\{[A-Z_0-9]*\}\}') |
  ForEach-Object { $_.Value } |
  Where-Object { $_ -notmatch $known } |
  Select-Object -Unique

  if ($leftover) {
    Stop-WithError "Unsubstituted marker(s) in $(Split-Path -Leaf $TemplatePath): $($leftover -join ' ')"
  }
}

function Assert-NoMockTriggers {
  param([string]$Path)
  $text = Read-TextFile $Path
  $hits = @()
  foreach ($word in $script:MockTriggerWords) {
    if ($text -match "(?i)(^|[^a-z0-9])$word([^a-z0-9]|$)") { $hits += $word }
  }
  if ($hits) {
    Stop-WithError "Mock trigger word(s) in $(Split-Path -Leaf $Path): $($hits -join ' ') -- fix the smoke fixtures"
  }
}

function New-Round1Prompt {
  param([int]$Index, [string]$OutPath)

  $template = Join-Path $script:PromptDir "round1-$($script:SubjectKind).md"
  if (-not (Test-Path -LiteralPath $template)) { $template = Join-Path $script:PromptDir 'round1.md' }
  if (-not (Test-Path -LiteralPath $template)) {
    Stop-WithError "No round-one template for kind '$($script:SubjectKind)' in $($script:PromptDir)"
  }

  $seat = $script:Seats[$Index]
  $pairName = 'none'
  if ($seat.Pair -ge 0) { $pairName = $script:Seats[$seat.Pair].Name }

  $scratch = "$OutPath.scalars"
  Expand-Scalars $template $scratch ('{0:d2}' -f $Index) $seat.Name $pairName $script:MemberTotal
  Expand-Markers $scratch $OutPath @{
    '{{ROLE_BRIEF}}' = $seat.File
    '{{SUBJECT}}'    = $script:SubjectPath
  }
  Remove-Item -LiteralPath $scratch -Force

  if ($Smoke) { Assert-NoMockTriggers $OutPath }
}

# Concatenates every other surviving member's round-one critique, in seat order
# so that the ordering never hints at which model is which, and truncated so one
# verbose member cannot crowd out the rest of the council.
function New-PeerDigest {
  param([int]$Self, [string]$OutPath, [int[]]$Survivors)

  $builder = [System.Text.StringBuilder]::new()
  foreach ($peer in $Survivors) {
    if ($peer -eq $Self) { continue }
    $seat = $script:Seats[$peer]
    $src = Join-Path $script:OutDir "round1\$($seat.Slug).md"
    if (-not (Test-Path -LiteralPath $src) -or (Get-FileByteCount $src) -eq 0) { continue }

    [void]$builder.Append(('--- Member {0:d2} ({1}) [{2}] ---' -f $peer, $seat.Name, (Get-ModelLabel $peer))).Append("`n`n")

    $bytes = [System.IO.File]::ReadAllBytes($src)
    if ($bytes.Length -gt $MaxPeerChars) {
      # Cut on a line boundary. A bare byte cut can land inside a multi-byte
      # character and leave a broken byte in the middle of a peer's critique.
      $kept = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $MaxPeerChars)
      $keptLines = $kept -split "`n"
      if ($keptLines.Count -gt 0 -and $keptLines[-1] -eq '') {
        $keptLines = @($keptLines[0..($keptLines.Count - 2)])
      }
      if ($keptLines.Count -gt 1) {
        [void]$builder.Append(($keptLines[0..($keptLines.Count - 2)] -join "`n")).Append("`n")
      }
      [void]$builder.Append("[TRUNCATED: $($bytes.Length - $MaxPeerChars) chars omitted]").Append("`n")
    }
    else {
      [void]$builder.Append((Read-TextFile $src))
    }
    [void]$builder.Append("`n`n")
  }

  if ($builder.Length -eq 0) { [void]$builder.Append("(no other member reported)`n") }
  Write-TextFile $OutPath $builder.ToString()
}

function New-Round2Prompt {
  param([int]$Index, [string]$OutPath, [int[]]$Survivors)

  $seat = $script:Seats[$Index]
  $pairName = 'none'
  $pairAlive = $seat.Pair -ge 0 -and ($Survivors -contains $seat.Pair)

  if ($pairAlive) {
    $template = Join-Path $script:PromptDir 'round2.md'
    $pairName = $script:Seats[$seat.Pair].Name
  }
  else {
    $template = Join-Path $script:PromptDir 'round2-nopair.md'
    if ($seat.Pair -ge 0) {
      Write-Info ('Seat {0:d2} lost its opposite; it will attack the strongest claims instead' -f $Index)
    }
  }
  if (-not (Test-Path -LiteralPath $template)) { Stop-WithError "Round-two template not found: $template" }

  $peers = Join-Path $script:TempRoot ('peers-{0:d2}.md' -f $Index)
  New-PeerDigest $Index $peers $Survivors

  $scratch = "$OutPath.scalars"
  Expand-Scalars $template $scratch ('{0:d2}' -f $Index) $seat.Name $pairName $script:MemberTotal
  Expand-Markers $scratch $OutPath @{
    '{{ROLE_BRIEF}}'      = $seat.File
    '{{SUBJECT}}'         = $script:SubjectPath
    '{{OWN_ROUND1}}'      = (Join-Path $script:OutDir "round1\$($seat.Slug).md")
    '{{PEER_CRITIQUES}}'  = $peers
  }
  Remove-Item -LiteralPath $scratch -Force

  if ($Smoke) { Assert-NoMockTriggers $OutPath }
}

# Concatenates a whole round for the chair, in seat order, labelling each block
# with its role and model so the chair can attribute findings.
function New-RoundDigest {
  param([string]$Round, [string]$OutPath, [int[]]$Seats)

  $builder = [System.Text.StringBuilder]::new()
  foreach ($index in $Seats) {
    $seat = $script:Seats[$index]
    $src = Join-Path $script:OutDir "$Round\$($seat.Slug).md"
    [void]$builder.Append(('--- Member {0:d2} ({1}) [{2}] ---' -f $index, $seat.Name, (Get-ModelLabel $index))).Append("`n`n")
    if ((Test-Path -LiteralPath $src) -and (Get-FileByteCount $src) -gt 0) {
      [void]$builder.Append((Read-TextFile $src))
    }
    else {
      [void]$builder.Append("(no $Round from this member)`n")
    }
    [void]$builder.Append("`n`n")
  }

  if ($builder.Length -eq 0) { [void]$builder.Append("(nothing was filed in this round)`n") }
  Write-TextFile $OutPath $builder.ToString()
}

function New-ChairPrompt {
  param([string]$OutPath, [int[]]$Survivors)

  $template = Join-Path $script:PromptDir 'round3-chair.md'
  if (-not (Test-Path -LiteralPath $template)) { Stop-WithError "Chair template not found: $template" }

  $r1 = Join-Path $script:TempRoot 'all-round1.md'
  $r2 = Join-Path $script:TempRoot 'all-round2.md'
  New-RoundDigest 'round1' $r1 $Survivors
  if ($SkipCross) {
    Write-TextFile $r2 "(round two was skipped, so there are no cross-critiques)`n"
  }
  else {
    New-RoundDigest 'round2' $r2 $Survivors
  }

  $scratch = "$OutPath.scalars"
  Expand-Scalars $template $scratch 'chair' 'Chair' 'none' $Survivors.Count
  Expand-Markers $scratch $OutPath @{
    '{{SUBJECT}}'     = $script:SubjectPath
    '{{ALL_ROUND1}}'  = $r1
    '{{ALL_ROUND2}}'  = $r2
  }
  Remove-Item -LiteralPath $scratch -Force

  if ($Smoke) { Assert-NoMockTriggers $OutPath }
}

function Test-PromptSize {
  param([string]$Path)
  $bytes = Get-FileByteCount $Path
  if ($bytes -gt 204800) {
    Write-WarningMessage "$(Split-Path -Leaf $Path) is $bytes bytes and may exceed the model's context window"
  }
}

# Finds the real config.json so each member's isolated config directory can be
# seeded with it. Without a seed, puny treats a missing config as a first run and
# starts an interactive setup that would hang with no terminal attached.
function Find-SeedConfig {
  foreach ($root in @($env:XDG_CONFIG_HOME, $env:APPDATA, (Join-Path $HOME '.config'))) {
    if (-not $root) { continue }
    $candidate = Join-Path $root 'puny\config.json'
    if (Test-Path -LiteralPath $candidate) {
      $script:SeedConfig = $candidate
      return
    }
  }

  if (-not $NoIsolateHome) {
    Write-WarningMessage 'No puny config.json found; sharing the real config directory instead of isolating'
    Write-WarningMessage 'Members may race on the session index, and your session history will grow'
    $script:Isolate = $false
  }
}

# Copilot performs an interactive device login the first time it runs without a
# stored token, and writes the result back to config. Several members doing that
# at once would race and prompt repeatedly, so refuse before any fan-out and let
# the user log in once, deliberately.
function Test-CopilotAuth {
  $usesCopilot = @($script:Seats | Where-Object { $_.Provider -eq 'copilot' }).Count -gt 0
  if ($script:ChairProvider -eq 'copilot') { $usesCopilot = $true }
  if (-not $usesCopilot) { return }

  if ($env:GITHUB_COPILOT_OAUTH_TOKEN) { return }

  if ($script:SeedConfig) {
    try {
      $cfg = Get-Content -LiteralPath $script:SeedConfig -Raw | ConvertFrom-Json
      $entry = $cfg.providers | Where-Object { $_.name -eq 'copilot' } | Select-Object -First 1
      if ($entry -and $entry.apiKey) { return }
    }
    catch {
      Write-WarningMessage "Could not parse $($script:SeedConfig) to check the Copilot token"
    }
  }

  Write-ErrorMessage 'The council includes a copilot member but no Copilot token is stored.'
  Stop-WithError "Run 'puny --provider copilot' once on a terminal to log in, then retry."
}

function Invoke-Preflight {
  & $script:BinPath --version 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-WithError "The puny binary at $($script:BinPath) did not run" }
  Test-CopilotAuth
}

function Remove-AnsiCodes {
  param([string]$Text)
  # puny emits only SGR and simple cursor sequences, all CSI with an alphabetic
  # final byte, so a narrow pattern is safer here than a maximal one.
  return ($Text -replace "`e\[[0-9;?]*[a-zA-Z]", '' -replace "`r", '')
}

# The chat log holds the model's raw markdown. Stdout does not: puny renders
# markdown to the terminal before printing it, so bold, headings and tables are
# destroyed and every line is hard-wrapped at 80 columns when piped.
function Get-AnswerFromChatLog {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path) -or (Get-FileByteCount $Path) -eq 0) { return $null }

  $marker = '^\[(USER|ASSISTANT|REASONING|TOOL_CALL|TOOL_RESULT)\]$'
  $builder = [System.Text.StringBuilder]::new()
  $capture = $false
  foreach ($line in Get-FileLines $Path) {
    if ($line -match $marker) {
      $capture = ($line -eq '[ASSISTANT]')
      if ($capture) { [void]$builder.Clear() }
      continue
    }
    if ($capture) { [void]$builder.Append($line).Append("`n") }
  }
  return $builder.ToString()
}

# Degraded fallback. Slices between the last thinking indicator and whichever
# trailer appears first; the token footer is absent when a turn fails, so several
# end anchors are needed.
function Get-AnswerFromStdout {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $clean = Remove-AnsiCodes (Read-TextFile $Path)

  $builder = [System.Text.StringBuilder]::new()
  $capture = $false
  foreach ($line in $clean -split "`n") {
    if ($line -eq 'Thinking...') { [void]$builder.Clear(); $capture = $true; continue }
    if ($line -like 'Thought for *') { $capture = $false; continue }
    if ($line -like '*tokens: in *') { $capture = $false; continue }
    if ($line -like '─── Session: *') { $capture = $false }
    if ($line -eq 'Goodbye.') { $capture = $false }
    if (-not $capture) { continue }
    if ($line -like '*🔧 *' -or $line -like 'Skill: *') { continue }
    [void]$builder.Append($line).Append("`n")
  }
  return $builder.ToString()
}

function Remove-BlankEdges {
  param([string]$Text)
  if (-not $Text) { return '' }
  $lines = @($Text -split "`n")
  $first = 0
  $last = $lines.Count - 1
  while ($first -le $last -and $lines[$first].Trim() -eq '') { $first++ }
  while ($last -ge $first -and $lines[$last].Trim() -eq '') { $last-- }
  if ($first -gt $last) { return '' }
  return (($lines[$first..$last] -join "`n") + "`n")
}

# Starts one member. A process is all we need per member, so ProcessStartInfo is
# used directly rather than a runspace: it is the only option that gives per-child
# environment variables, a real per-process timeout, and a real exit code.
function Start-Member {
  param([string]$Slug, [string]$Provider, [string]$Model, [string]$PromptPath, [string]$Dest)

  $work = Join-Path $script:TempRoot $Slug
  New-Item -ItemType Directory -Force -Path $work | Out-Null

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $script:BinPath
  $psi.WorkingDirectory = $work
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  if ($script:Isolate) {
    $home_ = Join-Path $work 'home'
    New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'puny') | Out-Null
    $memberConfig = Join-Path $home_ 'puny\config.json'
    # A mock member never calls a provider, so it has no business holding a copy
    # of the real provider tokens.
    if ($Smoke) {
      $stripped = (Read-TextFile $script:SeedConfig) -replace '"apiKey":\s*"[^"]*"', '"apiKey": null'
      Write-TextFile $memberConfig $stripped
    }
    else {
      Copy-Item -LiteralPath $script:SeedConfig -Destination $memberConfig -Force
    }
    $psi.Environment['XDG_CONFIG_HOME'] = $home_
    $psi.Environment['APPDATA'] = $home_
  }

  foreach ($arg in @('--oneshot', '--no-skills', '--prompt-file', $PromptPath)) { [void]$psi.ArgumentList.Add($arg) }
  if (-not $NoChatLog) { [void]$psi.ArgumentList.Add('--chat-log') }
  if ($Smoke) { [void]$psi.ArgumentList.Add('--mock') }
  if ($Provider) { [void]$psi.ArgumentList.Add('--provider'); [void]$psi.ArgumentList.Add($Provider) }
  if ($Model) { [void]$psi.ArgumentList.Add('-m'); [void]$psi.ArgumentList.Add($Model) }

  $proc = [System.Diagnostics.Process]::Start($psi)
  [void]$script:ActiveProcesses.Add($proc)

  return [pscustomobject]@{
    Slug    = $Slug
    Dest    = $Dest
    Work    = $work
    Proc    = $proc
    # Both pipes must be drained asynchronously or a chatty child fills a pipe
    # buffer and deadlocks waiting for us to read it.
    Stdout  = $proc.StandardOutput.ReadToEndAsync()
    Stderr  = $proc.StandardError.ReadToEndAsync()
    Started = [System.Diagnostics.Stopwatch]::StartNew()
  }
}

function Complete-Member {
  param([pscustomobject]$Job)

  $status = 'ok'
  if ($script:Timeout -eq 0) {
    $Job.Proc.WaitForExit()
  }
  elseif (-not $Job.Proc.WaitForExit($script:Timeout * 1000)) {
    try { $Job.Proc.Kill($true) } catch { }
    $status = 'timeout'
  }
  [void][System.Threading.Tasks.Task]::WaitAll(@($Job.Stdout, $Job.Stderr))
  $script:ActiveProcesses.Remove($Job.Proc)
  $Job.Started.Stop()

  $code = $Job.Proc.ExitCode
  if ($status -eq 'ok' -and $code -ne 0) { $status = "exit:$code" }

  $base = Join-Path $Job.Dest $Job.Slug
  Write-TextFile "$base.stdout.log" $Job.Stdout.Result
  Write-TextFile "$base.stderr.log" $Job.Stderr.Result

  $chatLog = Join-Path $Job.Work 'puny_chat.log'
  if (Test-Path -LiteralPath $chatLog) { Copy-Item -LiteralPath $chatLog -Destination "$base.chat.log" -Force }

  # An exit code of 0 does not mean the turn produced anything: a plain one-shot
  # run always exits 0, even when the provider fails outright. The size of what
  # we could extract is the only honest success signal.
  $answer = $null
  if (-not $NoChatLog -and (Test-Path -LiteralPath "$base.chat.log")) {
    $answer = Get-AnswerFromChatLog "$base.chat.log"
  }
  if (-not $answer) { $answer = Get-AnswerFromStdout "$base.stdout.log" }
  $answer = Remove-BlankEdges $answer
  Write-TextFile "$base.md" $answer

  $answerBytes = Get-FileByteCount "$base.md"
  if ($status -eq 'ok' -and $answerBytes -lt $MinAnswerChars) { $status = 'extract-empty' }

  Write-TextFile "$base.status" ("{0}`t{1}`t{2}`t{3}`n" -f $status, $code, [int]$Job.Started.Elapsed.TotalMilliseconds, $answerBytes)
  return $status
}

function Get-StatusField {
  param([string]$Path, [int]$Field)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $line = (Get-FileLines $Path | Select-Object -First 1)
  if (-not $line) { return '' }
  $parts = $line -split "`t"
  if ($Field -gt $parts.Count) { return '' }
  return $parts[$Field - 1]
}

function Get-Verdict {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path) -or (Get-FileByteCount $Path) -eq 0) { return '-' }
  foreach ($line in Get-FileLines $Path) {
    if ($line -match '^VERDICT:\s*(.*?)\s*$') {
      $value = $Matches[1]
      if (-not $value) { return '-' }
      if ($value.Length -gt 40) { $value = $value.Substring(0, 40) }
      return $value
    }
  }
  return '-'
}

# Fans members out, capped at -Jobs, then reports each seat's outcome.
function Invoke-Round {
  param([string]$Round, [int[]]$Indices)

  $dest = Join-Path $script:OutDir $Round
  Write-Info "Round ${Round}: $($Indices.Count) member(s), up to $($script:JobLimit) at once"

  $running = [System.Collections.ArrayList]::new()
  $results = @{}

  foreach ($i in $Indices) {
    while (@($running | Where-Object { -not $_.Proc.HasExited }).Count -ge $script:JobLimit) {
      Start-Sleep -Milliseconds 200
      foreach ($done in @($running | Where-Object { $_.Proc.HasExited })) {
        $results[$done.Slug] = Complete-Member $done
        $running.Remove($done)
      }
    }
    $seat = $script:Seats[$i]
    [void]$running.Add((Start-Member $seat.Slug $seat.Provider $seat.Model (Join-Path $dest "$($seat.Slug).prompt.md") $dest))
  }

  foreach ($job in @($running)) { $results[$job.Slug] = Complete-Member $job }

  $ok = 0
  $bad = 0
  foreach ($i in $Indices) {
    $seat = $script:Seats[$i]
    $status = Get-StatusField (Join-Path $dest "$($seat.Slug).status") 1
    if ($status -eq 'ok') {
      Write-Success "$Round $($seat.Slug) ($(Get-ModelLabel $i))"
      $ok++
    }
    else {
      Write-ErrorMessage "$Round $($seat.Slug) ($(Get-ModelLabel $i)): $status"
      $bad++
    }
  }

  Write-Info "${Round}: $ok passed, $bad failed (of $($Indices.Count))"
}

# Writes verdict.md. A failed chair must still leave something usable behind, so
# the members' own round-two output becomes the fallback verdict.
function Invoke-Chair {
  param([int[]]$Survivors)

  $promptPath = Join-Path $script:OutDir 'round3\chair.prompt.md'
  New-ChairPrompt $promptPath $Survivors
  Test-PromptSize $promptPath

  Write-Info "Round three: the chair ($(Get-ChairLabel)) synthesises the verdict"
  $dest = Join-Path $script:OutDir 'round3'
  $job = Start-Member 'chair' $script:ChairProvider $script:ChairModel $promptPath $dest
  $status = Complete-Member $job

  $verdictPath = Join-Path $script:OutDir 'verdict.md'
  if ($status -eq 'ok') {
    Copy-Item -LiteralPath (Join-Path $dest 'chair.md') -Destination $verdictPath -Force
    Write-Success "Chair verdict: $(Get-Verdict $verdictPath)"
    return 0
  }

  Write-ErrorMessage "The chair failed ($status); falling back to the members' own words"
  $fallback = if ($SkipCross) { Join-Path $script:TempRoot 'all-round1.md' } else { Join-Path $script:TempRoot 'all-round2.md' }
  $text = "CHAIR FAILED: $status`n`nNo synthesis was produced. What follows is every surviving member as filed.`n`n"
  $text += (Read-TextFile $fallback)
  Write-TextFile $verdictPath $text
  return 3
}

function Write-Manifest {
  $lines = @("round`tseat`trole`tmodel`tstatus`texit_code`telapsed_ms`tanswer_bytes`tverdict")

  foreach ($round in @('round1', 'round2')) {
    for ($seat = 0; $seat -lt $script:MemberTotal; $seat++) {
      $entry = $script:Seats[$seat]
      $statusPath = Join-Path $script:OutDir "$round\$($entry.Slug).status"
      if (-not (Test-Path -LiteralPath $statusPath)) {
        if ($DryRun -and $round -eq 'round1') {
          $lines += ('{0}`t{1:d2}`t{2}`t{3}`tPLANNED`t-`t-`t-`t-' -f $round, $seat, $entry.Id, (Get-ModelLabel $seat)).Replace('`t', "`t")
        }
        continue
      }
      $lines += (@(
          $round, ('{0:d2}' -f $seat), $entry.Id, (Get-ModelLabel $seat),
          (Get-StatusField $statusPath 1), (Get-StatusField $statusPath 2),
          (Get-StatusField $statusPath 3), (Get-StatusField $statusPath 4),
          (Get-Verdict (Join-Path $script:OutDir "$round\$($entry.Slug).md"))
        ) -join "`t")
    }
  }

  $chairStatus = Join-Path $script:OutDir 'round3\chair.status'
  if (Test-Path -LiteralPath $chairStatus) {
    $lines += (@(
        'round3', 'chair', 'chair', (Get-ChairLabel),
        (Get-StatusField $chairStatus 1), (Get-StatusField $chairStatus 2),
        (Get-StatusField $chairStatus 3), (Get-StatusField $chairStatus 4),
        (Get-Verdict (Join-Path $script:OutDir 'verdict.md'))
      ) -join "`t")
  }

  $summaryStatus = Join-Path $script:OutDir 'round4\summary.status'
  if (Test-Path -LiteralPath $summaryStatus) {
    $lines += (@(
        'round4', 'summary', 'summary', (Get-ChairLabel),
        (Get-StatusField $summaryStatus 1), (Get-StatusField $summaryStatus 2),
        (Get-StatusField $summaryStatus 3), (Get-StatusField $summaryStatus 4),
        (Get-Verdict (Join-Path $script:OutDir 'summary.md'))
      ) -join "`t")
  }

  Write-TextFile (Join-Path $script:OutDir 'manifest.tsv') (Join-Lines $lines)
}

function Get-StatusCell {
  param([string]$Round, [string]$Slug)
  $path = Join-Path $script:OutDir "$Round\$Slug.status"
  $status = Get-StatusField $path 1
  if (-not $status) { return [char]0x2014 }
  if ($status -eq 'ok') { return (Get-Verdict (Join-Path $script:OutDir "$Round\$Slug.md")) }
  return "**$status**"
}

function Write-Index {
  $verdictPath = Join-Path $script:OutDir 'verdict.md'
  $headRev = (& git rev-parse --short HEAD 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $headRev) { $headRev = 'not a git repository' }
  $punyVersion = (& $script:BinPath --version 2>&1 | Select-Object -First 1)

  $lines = @(
    '# Council verdict', '',
    '| | |', '|---|---|',
    "| Subject | $($script:SubjectLabel) ($($script:SubjectKind)) |",
    "| Run at | $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')) |",
    "| Repository HEAD | ``$headRev`` |",
    "| puny | ``$punyVersion`` |",
    "| Members | $($script:MemberTotal) |",
    "| Chair | $(Get-ChairLabel) |",
    "| Extraction | $(if ($NoChatLog) { 'stdout (lossy)' } else { 'puny_chat.log' }) |",
    ''
  )

  $summaryPath = Join-Path $script:OutDir 'summary.md'
  if ((Test-Path -LiteralPath $summaryPath) -and (Get-FileByteCount $summaryPath) -gt 0) {
    $lines += @('## Summary', '')
    $lines += (Get-FileLines $summaryPath)
    $lines += ''
  }

  if ((Test-Path -LiteralPath $verdictPath) -and (Get-FileByteCount $verdictPath) -gt 0) {
    $lines += @('## Verdict', '')
    $lines += (Get-FileLines $verdictPath)
    $lines += ''
  }
  elseif ($DryRun) {
    $lines += @('## Dry run', '',
      'No models were called. Round-one prompts are on disk and ready to inspect.',
      'Rounds two and three cannot be composed without round-one output.', '')
  }
  else {
    $lines += @('## Verdict', '', 'No verdict was produced.', '')
  }

  $lines += @('## Members', '', '| Seat | Role | Model | Round 1 | Round 2 |', '|---|---|---|---|---|')
  for ($seat = 0; $seat -lt $script:MemberTotal; $seat++) {
    $entry = $script:Seats[$seat]
    $lines += ('| {0:d2} | {1} | {2} | {3} | {4} |' -f $seat, $entry.Name, (Get-ModelLabel $seat),
      (Get-StatusCell 'round1' $entry.Slug), (Get-StatusCell 'round2' $entry.Slug))
  }
  $lines += ''

  $lines += @('## Artifacts', '',
    '- [subject.md](subject.md) — exactly what every member was shown',
    '- [manifest.tsv](manifest.tsv) — per-run status, timings and verdicts')
  if ((Test-Path -LiteralPath $summaryPath) -and (Get-FileByteCount $summaryPath) -gt 0) {
    $lines += '- [summary.md](summary.md) — the short version'
  }
  if ((Test-Path -LiteralPath $verdictPath) -and (Get-FileByteCount $verdictPath) -gt 0) {
    $lines += "- [verdict.md](verdict.md) — the chair's synthesis"
  }
  $lines += ''

  for ($seat = 0; $seat -lt $script:MemberTotal; $seat++) {
    $entry = $script:Seats[$seat]
    $row = "- **$($entry.Name)** — [round 1](round1/$($entry.Slug).md) · [prompt](round1/$($entry.Slug).prompt.md)"
    $r2 = Join-Path $script:OutDir "round2\$($entry.Slug).md"
    if ((Test-Path -LiteralPath $r2) -and (Get-FileByteCount $r2) -gt 0) {
      $row += " · [round 2](round2/$($entry.Slug).md)"
    }
    $lines += $row
  }

  Write-TextFile (Join-Path $script:OutDir 'council.md') (Join-Lines $lines)
}

function Invoke-Main {
  if ($Help) { Show-Usage; exit 0 }

  $script:BinPath = if ($Bin) { $Bin } elseif ($env:PUNY_BIN) { $env:PUNY_BIN } else { '' }
  $script:MemberCountExplicit = $PSBoundParameters.ContainsKey('Members') -or [bool]$env:COUNCIL_MEMBERS
  $script:ModelList = if ($Models) {
    @($Models | ForEach-Object { if ($_ -match ',') { $_ -split ',' } else { $_ } })
  }
  elseif ($env:COUNCIL_MODELS) { @($env:COUNCIL_MODELS -split ',') }
  else { $null }
  $script:ChairSpec = if ($Chair) { $Chair } elseif ($env:COUNCIL_CHAIR) { $env:COUNCIL_CHAIR } else { '' }
  $script:OutDir = if ($Out) { $Out } elseif ($env:COUNCIL_OUT) { $env:COUNCIL_OUT } else { '' }
  $script:JobLimit = if ($PSBoundParameters.ContainsKey('Jobs')) { $Jobs }
  elseif ($env:COUNCIL_JOBS) { ConvertTo-WholeNumber 'Job limit (COUNCIL_JOBS)' $env:COUNCIL_JOBS 1 }
  else { $Jobs }
  $script:Timeout = if ($PSBoundParameters.ContainsKey('TimeoutSec')) { $TimeoutSec }
  elseif ($env:COUNCIL_TIMEOUT) { ConvertTo-WholeNumber 'Timeout (COUNCIL_TIMEOUT)' $env:COUNCIL_TIMEOUT 0 }
  else { $TimeoutSec }
  # council.sh honours COUNCIL_MEMBERS, so this runner must too.
  $script:MemberCount = if ($PSBoundParameters.ContainsKey('Members')) { $Members }
  elseif ($env:COUNCIL_MEMBERS) { ConvertTo-WholeNumber 'Member count (COUNCIL_MEMBERS)' $env:COUNCIL_MEMBERS 1 }
  else { $Members }
  $script:MemberFloor = $MinMembers
  $script:Isolate = -not $NoIsolateHome
  $script:SeedConfig = ''
  $script:ActiveProcesses = [System.Collections.ArrayList]::new()

  Import-SharedLists
  Test-Arguments
  Resolve-PunyBinary
  Import-Roles
  Set-Seating
  Initialize-OutputDirectory
  Resolve-Subject
  Find-SeedConfig
  Invoke-Preflight

  $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("council." + [System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Force -Path $script:TempRoot | Out-Null
  # On Linux and macOS the temp root sits in a shared directory, and each
  # member's copy of the config carries provider tokens.
  if (-not $IsWindows) {
    try {
      [System.IO.Directory]::SetUnixFileMode($script:TempRoot, 'UserRead,UserWrite,UserExecute')
    }
    catch { Write-WarningMessage 'Could not restrict permissions on the temporary directory' }
  }

  if ($KeepTemp -and $script:Isolate -and -not $Smoke) {
    Write-WarningMessage '-KeepTemp leaves a copy of your puny config, provider tokens included,'
    Write-WarningMessage "in $($script:TempRoot). Delete it when you are done."
  }

  try {
    $allSeats = @(0..($script:MemberTotal - 1))
    foreach ($i in $allSeats) {
      New-Round1Prompt $i (Join-Path $script:OutDir "round1\$($script:Seats[$i].Slug).prompt.md")
    }
    Write-Success "Composed $($script:MemberTotal) round-one prompts in $(Join-Path $script:OutDir 'round1')"

    if ($DryRun) {
      Write-Manifest
      Write-Index
      Write-Info 'Dry run: prompts written, no models called'
      Write-Success "Read $(Join-Path $script:OutDir 'council.md')"
      return 0
    }

    if (-not $NoChatLog) {
      if (-not $Smoke) {
        Write-WarningMessage '--chat-log forces high reasoning effort in puny, which costs more per call'
      }
    }
    else {
      Write-WarningMessage 'Extracting from stdout: puny renders markdown before printing, so headings and'
      Write-WarningMessage 'emphasis are lost, lines wrap at 80 columns, and repainted text can duplicate.'
      Write-WarningMessage 'Later rounds will critique that degraded text. Prefer the default channel.'
    }

    Invoke-Round 'round1' $allSeats

    $survivors = @()
    foreach ($i in $allSeats) {
      $path = Join-Path $script:OutDir "round1\$($script:Seats[$i].Slug).status"
      if ((Get-StatusField $path 1) -eq 'ok') { $survivors += $i }
    }

    if ($survivors.Count -lt $script:MemberFloor) {
      Write-ErrorMessage "Only $($survivors.Count) member(s) reported, below the -MinMembers floor of $($script:MemberFloor)"
      Write-Manifest
      Write-Index
      exit 2
    }

    if ($SkipCross) {
      Write-Info 'Skipping round two'
    }
    else {
      foreach ($i in $survivors) {
        $path = Join-Path $script:OutDir "round2\$($script:Seats[$i].Slug).prompt.md"
        New-Round2Prompt $i $path $survivors
        Test-PromptSize $path
      }
      Invoke-Round 'round2' $survivors
    }

    $chairCode = 0
    if ($SkipChair) {
      Write-Info 'Skipping round three'
    }
    else {
      $chairCode = Invoke-Chair $survivors
    }

    if ($SkipSummary) {
      Write-Info 'Skipping the summary'
    }
    elseif (-not $SkipChair -and $chairCode -eq 0) {
      $null = Invoke-Summary
    }

    Write-Manifest
    Write-Index
    Show-Summary
    Write-Success "Read $(Join-Path $script:OutDir 'council.md')"
    return $chairCode
  }
  finally {
    # An interrupt does not stop the members, so without this an interrupted run
    # leaves paid calls finishing unseen.
    foreach ($proc in @($script:ActiveProcesses)) {
      if (-not $proc.HasExited) {
        Write-WarningMessage 'Stopping a member still in flight'
        try { $proc.Kill($true) } catch { }
      }
    }
    if (-not $KeepTemp -and (Test-Path -LiteralPath $script:TempRoot)) {
      Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

exit (Invoke-Main)
