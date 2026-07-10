param(
    [switch]$NoBuild
)

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Binary = Join-Path $ProjectRoot "zig-out" "bin" "puny"

function Invoke-Build {
    param([string]$Target = "")

    $label = if ($Target) { "Building for $Target..." } else { "Building (native)..." }
    Write-Host "  $label" -ForegroundColor Cyan

    $zigArgs = @("build")
    if ($Target) {
        $zigArgs += "-Dtarget=$Target"
    }

    Push-Location $ProjectRoot
    $buildOutput = & zig @zigArgs 2>&1
    $ok = $LASTEXITCODE -eq 0
    Pop-Location

    if (-not $ok) {
        Write-Host "    FAILED" -ForegroundColor Red
    } else {
        Write-Host "    OK" -ForegroundColor Green
    }

    return $ok
}

function Build-Project {
    $ok = Invoke-Build
    if (-not $ok) { exit 1 }
}

function Run-Test {
    param(
        [string]$Name,
        [string[]]$TestArgs,
        [string[]]$Expect,
        [string[]]$NotExpect
    )

    Write-Host -NoNewline ("  " + $Name + "... ")

    $output = & $Binary @TestArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
        return $false
    }

    $text = $output -join "`n"

    foreach ($expected in $Expect) {
        if (-not $text.Contains($expected)) {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "    missing: '$expected'" -ForegroundColor DarkYellow
            return $false
        }
    }

    foreach ($notExpected in $NotExpect) {
        if ($text.Contains($notExpected)) {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Host "    unexpected: '$notExpected'" -ForegroundColor DarkYellow
            return $false
        }
    }

    Write-Host "PASSED" -ForegroundColor Green
    return $true
}

if (-not $NoBuild) {
    Build-Project
}

Write-Host ""
Write-Host "Regression tests (mock mode)" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host ""

$passed = 0
$failed = 0
$total = 0

$tests = @(
    @{Name="Basic text response"; Args=@("--mock","--model","mock-model","--prompt","hello world","--oneshot"); Expect=@("mock response","hello world")}
    @{Name="Tool call: read_file"; Args=@("--mock","--model","mock-model","--prompt","read the code","--oneshot"); Expect=@("read_file","Tool executed")}
    @{Name="Tool call: grep_search"; Args=@("--mock","--model","mock-model","--prompt","search for pattern","--oneshot"); Expect=@("grep_search","Tool executed")}
    @{Name="Tool call: execute_shell"; Args=@("--mock","--model","mock-model","--prompt","run a command","--oneshot"); Expect=@("execute_shell","Tool executed")}
    @{Name="Error does not produce content"; Args=@("--mock","--model","mock-model","--prompt","trigger an error","--oneshot"); Expect=@("Chatting with model"); NotExpect=@("mock response")}
)

$total = $tests.Count

foreach ($test in $tests) {
    $ok = Run-Test -Name $test.Name -TestArgs $test.Args -Expect $test.Expect -NotExpect $test.NotExpect
    if ($ok) { $passed++ } else { $failed++ }
}

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Cyan
if ($failed -eq 0) {
    Write-Host ("All $total tests passed") -ForegroundColor Green
} else {
    Write-Host ("$passed passed, $failed failed (of $total)") -ForegroundColor Red
}
Write-Host ""

exit $failed
