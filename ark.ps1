#Requires -Version 7.0
<#
.SYNOPSIS
    agentic-review-kit: budget-aware code review run by a headless coding agent.

.DESCRIPTION
    ark review  [-Repo <path>] [-Base <ref>] [-Head <ref>] [-Level auto|low|medium|high|xhigh|max]
                [-Backend pi|coderabbit|both] [-Model <provider/id>] [-RefuteModel <provider/id>]
                [-NoRefute] [-DryRun] [-Wait] [-Full]
        Review a change. Without -Head the working tree is reviewed, uncommitted edits included.
        Without -Base the range starts at the head of the previous review of this branch, or, on the
        first review, at the merge-base with the default branch. -Full ignores the previous review.
        -Wait sleeps through a 5-hour limit instead of stopping.

    ark baseline [-Repo <path>]
        Mark the current head as the start for later reviews, without reviewing what came before.

    ark assess  [-Repo <path>] [-Base <ref>] [-Head <ref>]
        Size the change and print the plan. Runs no model.

    ark sweep   [-Targets <file>] [-NoWait]
        Review every repository listed in targets.json that has unreviewed work, one after another,
        inside the budget. Made to run unattended.

    ark usage   [-Model <provider/id>]
        Print what is known about the plan limits and the kit's own spend.

    ark init    [-Repo <path>] [-Type unity|ts-worker|python|generic] [-Force]
        Write .review-kit/profile.json and profile.md for a repository.

    ark fix     <findings file>
        Print the prompt that applies a findings file. Paste it into an agent session in that repository.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'help',
    [Parameter(Position = 1)] [string] $Argument,
    [string] $Repo = (Get-Location).Path,
    [string] $Base, [string] $Head,
    [ValidateSet('auto', 'low', 'medium', 'high', 'xhigh', 'max')] [string] $Level = 'auto',
    [ValidateSet('pi', 'coderabbit', 'both')] [string] $Backend,
    [string] $Model, [string] $RefuteModel,
    [string] $Type, [string] $Targets,
    [switch] $NoRefute, [switch] $DryRun, [switch] $Wait, [switch] $NoWait, [switch] $Force, [switch] $Full
)

$ErrorActionPreference = 'Stop'
foreach ($m in 'Scope', 'Harness', 'Limits', 'Findings', 'Rabbit', 'Review') { Import-Module (Join-Path $PSScriptRoot "lib/$m.psm1") -Force }

function Get-RepoType([string] $Root) {
    if (Test-Path -LiteralPath (Join-Path $Root 'ProjectSettings/ProjectVersion.txt')) { return 'unity' }
    if (Test-Path -LiteralPath (Join-Path $Root 'wrangler.toml')) { return 'ts-worker' }
    if ((Test-Path -LiteralPath (Join-Path $Root 'pyproject.toml')) -or (Test-Path -LiteralPath (Join-Path $Root 'requirements.txt'))) { return 'python' }
    return 'generic'
}

function Invoke-Init {
    $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
    $kind = if ($Type) { $Type } else { Get-RepoType $root }
    $src = Join-Path $PSScriptRoot "profiles/$kind"
    if (-not (Test-Path -LiteralPath "$src.json")) { throw "unknown profile type '$kind'; have: $((Get-ChildItem (Join-Path $PSScriptRoot 'profiles') -Filter *.json).BaseName -join ', ')" }

    $dir = Join-Path $root '.review-kit'
    $null = New-Item -ItemType Directory -Force -Path $dir
    foreach ($ext in 'json', 'md') {
        $to = Join-Path $dir "profile.$ext"
        if ((Test-Path -LiteralPath $to) -and -not $Force) { Write-Host "kept    $to (use -Force to replace)"; continue }
        Copy-Item -LiteralPath "$src.$ext" -Destination $to -Force
        Write-Host "wrote   $to"
    }
    $ignore = Join-Path $dir '.gitignore'
    if (-not (Test-Path -LiteralPath $ignore)) { [System.IO.File]::WriteAllText($ignore, "runs/`n") }
    Write-Host "Profile type: $kind. Edit the globs and notes to fit the repository, then commit .review-kit/."
}

function Invoke-Usage {
    $budget = Get-Budget
    $models = @(@($Model, $budget.models.finder, $budget.models.refute) | Where-Object { $_ } | Select-Object -Unique)
    $providers = @(@($models | ForEach-Object { Get-ProviderOf $_ }) + @('openai-codex') + @($budget.self_metered.Keys) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($p in $providers) { Write-Host (Format-UsageLine (Get-ProviderUsage -Provider $p -Budget $budget)) }

    $rabbit = Get-RabbitState -Budget $budget
    Write-Host "coderabbit: $($rabbit.Reason)"
    $week = Get-LedgerSpend -Since (Get-Date).AddDays(-7)
    Write-Host ('kit ledger, last 7 days: {0} steps, {1} tokens, {2:N2} USD (API-equivalent)' -f $week.Steps, $week.Tokens, $week.Usd)
    Write-Host ('budget: pause at 5h {0:P0}, stop at week {1:P0}; run caps: usd={2} tokens={3} minutes={4}' -f $budget.five_h_pause, $budget.week_stop,
        ($budget.run.max_usd ?? 'none'), ($budget.run.max_tokens ?? 'none'), ($budget.run.max_minutes ?? 'none'))
    Write-Host "budget file: $(Join-Path (Get-KitHome) 'budget.json')$(if (-not (Test-Path (Join-Path (Get-KitHome) 'budget.json'))) { ' (not present; defaults in use)' })"
}

function Invoke-Sweep {
    $path = if ($Targets) { $Targets } else { Join-Path (Get-KitHome) 'targets.json' }
    if (-not (Test-Path -LiteralPath $path)) { throw "no targets file at $path; see targets.example.json" }
    $list = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).targets)
    $budget = Get-Budget
    $run = "sweep-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $started = Get-Date
    $rows = [System.Collections.Generic.List[string]]::new()
    $stop = Join-Path (Get-KitHome) 'STOP'

    foreach ($t in $list) {
        if (Test-Path -LiteralPath $stop) { Write-Host 'sweep: STOP file found, stopping'; break }
        Write-Host "=== $($t.repo)"
        try {
            $a = @{ Repo = $t.repo; Budget = $budget; RunId = $run; RunStarted = $started; Wait = (-not $NoWait); Level = ($t.level ?? 'auto'); Backend = ($t.backend ?? $Backend ?? 'pi') }
            if ($t.base) { $a.Base = $t.base }
            if ($Model) { $a.Model = $Model }
            if ($RefuteModel) { $a.RefuteModel = $RefuteModel }
            $r = Invoke-Review @a
        }
        catch {
            Write-Host "sweep: $($t.repo) failed: $($_.Exception.Message)"
            $rows.Add("| $($t.repo) | error | - | $($_.Exception.Message) |")
            continue
        }
        $what = if ($r.File) { "$($r.Findings) findings ($($r.Confirmed) confirmed, $($r.Unclear) unclear, $($r.Refuted) refuted)" } else { $r.Reason }
        $rows.Add("| $($t.repo) | $($r.Status) | $($r.Level ?? '-') | $what$(if ($r.File) { " - $($r.File)" }) |")
        # A stop from the budget ends the sweep: the next repository would hit the same wall.
        if ($r.Status -eq 'budget') { Write-Host 'sweep: budget stop, ending the sweep'; break }
    }

    $spend = Get-LedgerSpend -Run $run
    $dir = Join-Path (Get-KitHome) 'sweeps'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $report = Join-Path $dir "$run.md"
    $body = @("# Sweep $run", '', ('Spent: {0} tokens, {1:N2} USD (API-equivalent), {2} min' -f $spend.Tokens, $spend.Usd, [int] ((Get-Date) - $started).TotalMinutes), '',
        '| Repository | Status | Level | Result |', '|---|---|---|---|') + $rows
    [System.IO.File]::WriteAllText($report, (($body -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Report: $report"
}

function Invoke-FixPrompt {
    if (-not $Argument -or -not (Test-Path -LiteralPath $Argument)) { throw 'ark fix needs the path of a findings file' }
    $file = (Resolve-Path -LiteralPath $Argument).Path
    $t = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'prompts/fix.md'))
    Write-Output $t.Replace('{{FILE}}', $file)
}

switch ($Command.ToLowerInvariant()) {
    'review' {
        $a = @{ Repo = $Repo; Level = $Level; NoRefute = $NoRefute; DryRun = $DryRun; Wait = $Wait; Full = $Full; Backend = ($Backend ? $Backend : 'pi') }
        foreach ($k in 'Base', 'Head', 'Model', 'RefuteModel') { $v = Get-Variable $k -ValueOnly; if ($v) { $a[$k] = $v } }
        $r = Invoke-Review @a
        exit $(if ($r.Status -in 'done', 'nothing', 'dry-run') { 0 } elseif ($r.Status -eq 'budget') { 3 } else { 1 })
    }
    'assess' {
        $a = @{ Repo = $Repo; Level = $Level; DryRun = $true; Full = $Full }
        foreach ($k in 'Base', 'Head') { $v = Get-Variable $k -ValueOnly; if ($v) { $a[$k] = $v } }
        $null = Invoke-Review @a
    }
    'baseline' {
        $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
        $null = Initialize-RunFolder -Root $root
        $head = ([string] (Invoke-Git $root @('rev-parse', 'HEAD'))).Trim()
        $branch = ([string] (Invoke-Git $root @('branch', '--show-current') -AllowFail)).Trim()
        Set-LastReview -Root $root -Branch $branch -Head $head -File '(baseline, not reviewed)'
        Write-Host "baseline: reviews of $(if ($branch) { $branch } else { 'the detached head' }) in $root now start at $($head.Substring(0, 8))"
    }
    'sweep' { Invoke-Sweep }
    'usage' { Invoke-Usage }
    'init' { Invoke-Init }
    'fix' { Invoke-FixPrompt }
    default { Get-Help $PSCommandPath -Full | Out-String | Write-Host }
}
