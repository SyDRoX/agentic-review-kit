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

    ark audit-plan [-Repo <path>] [-Paths <glob,...>] [-MaxLines 800] [-IncludeTests] [-Force]
        Divide the current code into chunks by folder and write the plan. Reads no history and runs no model.
        Tests, vendor code, generated files and docs are left out. Contract code comes first, then hot paths.

    ark audit   [-Repo <path>] [-Count <n> | -All | -Chunk <id>] [-Level ...] [-NoRefute] [-NoWait] [-DryRun]
        Audit the next chunks of the plan as the code is now: no diff, old defects count.
        With -Paths <glob,...> and no plan: audit exactly those files once.

    ark assess  [-Repo <path>] [-Base <ref>] [-Head <ref>]
        Size the change and print the plan. Runs no model.

    ark sweep   [-Targets <file>] [-NoWait]
        Review every repository listed in targets.json that has unreviewed work, one after another,
        inside the budget. Made to run unattended.

    ark usage   [-Model <provider/id>]
        Print what is known about the plan limits and the kit's own spend.

    ark allocation [reset]
        Print what is spent of each provider's allocation (budget.json). `reset` starts a new count from the use now.

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
    [string[]] $Paths = @(), [int] $MaxLines = 800, [int] $Count = 1, [int] $Chunk, [switch] $All, [switch] $IncludeTests,
    [switch] $NoRefute, [switch] $DryRun, [switch] $Wait, [switch] $NoWait, [switch] $Force, [switch] $Full
)

$ErrorActionPreference = 'Stop'
foreach ($m in 'Scope', 'Harness', 'Limits', 'Findings', 'Rabbit', 'Audit', 'Review') { Import-Module (Join-Path $PSScriptRoot "lib/$m.psm1") -Force }

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

    if (Get-CursorAuthPath) {
        $applies = @($budget.cursor.applies_to | Where-Object { $_ })
        if ($providers -notcontains 'cursor' -and -not ($applies | Where-Object { $providers -contains $_ })) {
            Write-Host (Format-UsageLine (Get-ProviderUsage -Provider 'cursor' -Budget $budget))
        }
        Write-Host $(if ($applies.Count) { "cursor pool: enforced as the quota of $($applies -join ', ') (cursor.applies_to in budget.json)" }
            else { 'cursor pool: reported only. It is the pool of the Cursor Agent login; set cursor.applies_to in budget.json to enforce it for another provider once you know they share it.' })
    }

    foreach ($p in @($budget.allocation.Keys | Sort-Object)) {
        Write-Host "${p}: $(Format-Allocation (Get-AllocationStatus -Provider $p -Budget $budget -Usage (Get-ProviderUsage -Provider $p -Budget $budget) -ReadOnly))"
    }

    $rabbit = Get-RabbitState -Budget $budget
    Write-Host "coderabbit: $($rabbit.Reason)"
    $week = Get-LedgerSpend -Since (Get-Date).AddDays(-7)
    Write-Host ('kit ledger, last 7 days: {0} steps, {1} tokens, {2:N2} USD (API-equivalent)' -f $week.Steps, $week.Tokens, $week.Usd)
    Write-Host ('budget: pause at 5h {0:P0}, stop at week {1:P0}; run caps: usd={2} tokens={3} minutes={4}' -f $budget.five_h_pause, $budget.week_stop,
        ($budget.run.max_usd ?? 'none'), ($budget.run.max_tokens ?? 'none'), ($budget.run.max_minutes ?? 'none'))
    Write-Host "budget file: $(Join-Path (Get-KitHome) 'budget.json')$(if (-not (Test-Path (Join-Path (Get-KitHome) 'budget.json'))) { ' (not present; defaults in use)' })"
}

function Invoke-Allocation {
    $budget = Get-Budget
    $path = Get-AllocationPath
    if ($Argument -eq 'reset') {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        Write-Host 'allocation: count reset. The next reading of each provider is the new baseline.'
    }
    elseif ($Argument) { throw "unknown argument '$Argument'; use 'ark allocation' or 'ark allocation reset'" }
    $names = @($budget.allocation.Keys | Sort-Object)
    if (-not $names.Count) { Write-Host 'allocation: none set. Add "allocation" to budget.json, for example { "openai-codex": { "week_points": 30 } }.'; return }
    foreach ($p in $names) {
        $a = Get-AllocationStatus -Provider $p -Budget $budget -Usage (Get-ProviderUsage -Provider $p -Budget $budget)
        Write-Host "${p}: $(Format-Allocation $a)"
    }
    Write-Host "role takeover: $(if ($budget.role_takeover) { 'on' } else { 'off' }). State: $path"
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

function Invoke-AuditPlan {
    $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
    $old = Read-AuditPlan -Root $root
    if ($old -and @($old.chunks | Where-Object Status -eq 'done').Count -and -not $Force) {
        throw "a plan with finished chunks exists at $(Get-AuditPlanPath $root); use -Force to replace it and start over"
    }
    $prof = Get-ReviewProfile -Root $root
    $files = @(Get-AuditFile -Root $root -ReviewProfile $prof -Paths $Paths -IncludeTests:$IncludeTests)
    if (-not $files.Count) { throw 'no source files in scope; check -Paths and the vendor and tests globs of the profile' }
    $null = Initialize-RunFolder -Root $root
    $plan = [ordered]@{
        created = [datetime]::UtcNow.ToString('o'); head = ([string] (Invoke-Git $root @('rev-parse', 'HEAD'))).Trim()
        maxLines = $MaxLines; paths = $Paths; chunks = @(Split-AuditChunk -Files $files -MaxLines $MaxLines -ReviewProfile $prof)
    }
    Write-AuditPlan -Root $root -Plan $plan
    Format-AuditPlan -Plan (Read-AuditPlan -Root $root) | ForEach-Object { Write-Host $_ }
    Write-Host "Plan: $(Get-AuditPlanPath $root)"
    Write-Host 'Largest folders in scope (check for third-party code and add it to "vendor" in .review-kit/profile.json):'
    $files | Group-Object { ($_.Path.Split('/') | Select-Object -First 3) -join '/' } | ForEach-Object { [pscustomobject]@{ Dir = $_.Name; Lines = ($_.Group | Measure-Object Lines -Sum).Sum; Files = $_.Count } } |
        Sort-Object Lines -Descending | Select-Object -First 12 | ForEach-Object { Write-Host ('  {0,7} lines {1,4} files  {2}' -f $_.Lines, $_.Files, $_.Dir) }
}

function Invoke-AuditRun {
    $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
    $budget = Get-Budget
    $common = @{ Repo = $root; Level = $Level; NoRefute = $NoRefute; DryRun = $DryRun; Wait = (-not $NoWait); Budget = $budget }
    if ($Model) { $common.Model = $Model }
    if ($RefuteModel) { $common.RefuteModel = $RefuteModel }

    $plan = Read-AuditPlan -Root $root
    if ($Paths.Count -and -not $Chunk) {
        $files = @(Get-AuditFile -Root $root -ReviewProfile (Get-ReviewProfile -Root $root) -Paths $Paths -IncludeTests:$IncludeTests)
        if (-not $files.Count) { throw 'no source files match -Paths' }
        $r = Invoke-Audit @common -Files @($files.Path) -Name 'paths'
        exit $(if ($r.Status -in 'done', 'nothing', 'dry-run') { 0 } elseif ($r.Status -eq 'budget') { 3 } else { 1 })
    }
    if (-not $plan) { throw "no audit plan in $root; run 'ark audit-plan' first, or pass -Paths" }

    $todo = if ($Chunk) { @($plan.chunks | Where-Object Id -eq $Chunk) } else { @($plan.chunks | Where-Object Status -ne 'done') }
    if (-not $todo.Count) { Write-Host 'audit: every chunk of the plan is done'; return }
    if (-not $All -and -not $Chunk) { $todo = @($todo | Select-Object -First $Count) }

    $run = "audit-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    $started = Get-Date
    $stop = Join-Path (Get-KitHome) 'STOP'
    $fails = 0
    $code = 0
    foreach ($c in $todo) {
        if (Test-Path -LiteralPath $stop) { Write-Host 'audit: STOP file found, stopping'; break }
        Write-Host "=== chunk $($c.Id): $($c.Name) ($($c.Lines) lines, $(@($c.Files).Count) files)"
        $r = Invoke-Audit @common -Files @($c.Files) -Name "chunk$($c.Id)" -RunId $run -RunStarted $started
        if ($DryRun) { continue }

        $c.Status = $r.Status; $c.Note = $r.Reason; $c.Head = $r.Head; $c.Tokens = $r.Tokens
        if ($r.Status -eq 'done') { $c.File = $r.File; $c.Findings = $r.Findings; $c.Confirmed = $r.Confirmed; $c.Unclear = $r.Unclear; $c.Refuted = $r.Refuted; $fails = 0 }
        elseif ($r.Status -eq 'nothing') { $c.Status = 'done'; $c.Findings = 0; $c.Confirmed = 0; $c.Unclear = 0; $c.Refuted = 0 }
        else { $fails++ }
        Write-AuditPlan -Root $root -Plan $plan

        # A budget stop ends the run: the next chunk would hit the same wall. So do two failures in a row.
        if ($r.Status -eq 'budget') { $code = 3; break }
        if ($fails -ge 2) { Write-Host 'audit: two chunks failed in a row, stopping'; $code = 1; break }
    }
    if (-not $DryRun) {
        Format-AuditPlan -Plan (Read-AuditPlan -Root $root) | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
        $spend = Get-LedgerSpend -Run $run
        Write-Host ('Run: {0} tokens, {1:N2} USD (API-equivalent), {2} min. Plan: {3}' -f $spend.Tokens, $spend.Usd, [int] ((Get-Date) - $started).TotalMinutes, (Get-AuditPlanPath $root))
    }
    exit $code
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
    'audit-plan' { Invoke-AuditPlan }
    'audit' { Invoke-AuditRun }
    'usage' { Invoke-Usage }
    'allocation' { Invoke-Allocation }
    'init' { Invoke-Init }
    'fix' { Invoke-FixPrompt }
    default { Get-Help $PSCommandPath -Full | Out-String | Write-Host }
}
