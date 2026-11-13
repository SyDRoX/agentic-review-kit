#Requires -Version 7.0

# One review: size the change, run the finder passes, write the findings file, refute every finding.

Import-Module (Join-Path $PSScriptRoot 'Scope.psm1')
Import-Module (Join-Path $PSScriptRoot 'Harness.psm1')
Import-Module (Join-Path $PSScriptRoot 'Limits.psm1')
Import-Module (Join-Path $PSScriptRoot 'Findings.psm1')
Import-Module (Join-Path $PSScriptRoot 'Rabbit.psm1')

$script:KitRoot = Split-Path $PSScriptRoot -Parent
$script:MaxAutoProd = 4000

$script:Lenses = [ordered]@{
    correctness = 'Correctness: logic errors, wrong conditions, off-by-one, null or undefined access, unhandled error paths, wrong async or ordering, state left inconsistent after a failure, resource leaks.'
    boundaries  = 'Boundaries: data that crosses a process, network, file or database boundary. Field names, types, units, optional against required, versioning, serialization, validation of outside input, migrations against data that already exists, both sides of a client and server contract.'
    lifecycle   = 'Lifecycle and cost: object and subscription lifetime, init and teardown order, work on a hot path (per frame, per request), allocations in loops, blocking calls on a main or event-loop thread, concurrency and reentrancy.'
}

$script:Levels = @{
    low    = @{ Lenses = @('correctness'); Calls = 10; Cap = 8; Thinking = 'low'; Depth = 'the changed hunks and their enclosing functions.' }
    medium = @{ Lenses = @('correctness'); Calls = 20; Cap = 8; Thinking = 'medium'; Depth = 'the enclosing files and the direct callers of changed functions.' }
    high   = @{ Lenses = @('correctness', 'boundaries'); Calls = 30; Cap = 10; Thinking = 'high'; Depth = 'the enclosing modules and every call site of changed functions.' }
    xhigh  = @{ Lenses = @('correctness', 'boundaries', 'lifecycle'); Calls = 40; Cap = 15; Thinking = 'high'; Depth = 'the enclosing modules, every call site of changed functions, and callers of callers where a changed contract propagates.' }
    max    = @{ Lenses = @('correctness', 'boundaries', 'lifecycle'); Calls = 40; Cap = 15; Thinking = 'xhigh'; Depth = 'the enclosing modules, every call site of changed functions, and callers of callers where a changed contract propagates.' }
}

function Get-ReviewProfile {
    <#
    .SYNOPSIS
        The repository's own review settings: .review-kit/profile.json (globs, base, counterparts) and profile.md (notes for the reviewer).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root)

    $dir = Join-Path $Root '.review-kit'
    $p = [ordered]@{ type = $null; base = $null; contracts = @(); hot = @(); tests = @(); vendor = @(); conventions = @(); counterparts = @(); notes = '' }
    $json = Join-Path $dir 'profile.json'
    if (Test-Path -LiteralPath $json) {
        $j = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        foreach ($k in 'type', 'base') { if ($j.$k) { $p[$k] = [string] $j.$k } }
        foreach ($k in 'contracts', 'hot', 'tests', 'vendor', 'conventions') { if ($j.$k) { $p[$k] = @($j.$k | ForEach-Object { [string] $_ }) } }
        if ($j.counterparts) { $p.counterparts = @($j.counterparts) }
    }
    $md = Join-Path $dir 'profile.md'
    if (Test-Path -LiteralPath $md) { $p.notes = ([string] (Get-Content -LiteralPath $md -Raw)).Trim() }
    return [pscustomobject] $p
}

function Get-LastReview {
    param([Parameter(Mandatory)] [string] $Root, [string] $Branch)

    $path = Join-Path $Root '.review-kit/runs/last.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    $key = if ($Branch) { $Branch } else { '(detached)' }
    return $j.$key
}

function Set-LastReview {
    param([Parameter(Mandatory)] [string] $Root, [string] $Branch, [Parameter(Mandatory)] [string] $Head, [string] $File)

    $path = Join-Path $Root '.review-kit/runs/last.json'
    $j = @{}
    if (Test-Path -LiteralPath $path) {
        try { (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $j[$_.Name] = $_.Value } } catch { }
    }
    $key = if ($Branch) { $Branch } else { '(detached)' }
    $j[$key] = [ordered]@{ head = $Head; file = $File; at = [datetime]::UtcNow.ToString('o') }
    [System.IO.File]::WriteAllText($path, ($j | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
}

function Initialize-RunFolder {
    param([Parameter(Mandatory)] [string] $Root)

    $dir = Join-Path $Root '.review-kit'
    $runs = Join-Path $dir 'runs'
    $null = New-Item -ItemType Directory -Force -Path $runs
    $ignore = Join-Path $dir '.gitignore'
    # Findings and logs are per-machine output; the profile beside them is meant to be committed.
    if (-not (Test-Path -LiteralPath $ignore)) { [System.IO.File]::WriteAllText($ignore, "runs/`n") }
    return $runs
}

function Get-SourceForm {
    param([Parameter(Mandatory)] $Target)

    if ($Target.WorkTree) {
        return "Read code from the working tree of $($Target.Root), which is what is under review: files with the read tool, searches with grep under that folder."
    }
    return "Read code ONLY at commit $($Target.Head) of the repository at $($Target.Root), never the working tree (it may be on another commit): a file with ``git -C `"$($Target.Root)`" show $($Target.Head):<path>``, a search with ``git -C `"$($Target.Root)`" grep -n <pattern> $($Target.Head)``."
}

function Format-FinderPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $Size,
        [Parameter(Mandatory)] $ReviewProfile,
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [string] $Lens
    )

    $lv = $script:Levels[$Level]
    $files = @($Size.Files | ForEach-Object { "- $($_.Path) ($($_.Bucket), +$($_.Added) -$($_.Deleted))" }) -join "`n"
    $notes = if ($ReviewProfile.notes) { "## Project notes`n`n$($ReviewProfile.notes)" } else { '' }

    $conv = @($ReviewProfile.conventions | Where-Object { Test-Path -LiteralPath (Join-Path $Target.Root $_) })
    $conventions = if ($conv.Count) {
        "## Project rules`n`nThe project's own rules are in: $($conv -join ', '). Read them when a finding depends on a project rule; a rule there outranks general practice."
    }
    else { '' }

    $cps = @($ReviewProfile.counterparts | Where-Object { $_.path -and (Test-Path -LiteralPath $_.path) })
    $counterparts = if ($cps.Count) {
        $rows = @($cps | ForEach-Object { "- $($_.path)$(if ($_.note) { ": $($_.note)" })" }) -join "`n"
        "## Counterpart repositories`n`nThis repository shares a contract with:`n`n$rows`n`nWhen the change touches data, a route or a file format the counterpart also reads or writes, read the counterpart's side (read-only) and report a mismatch as a finding on the line of THIS change that causes it."
    }
    else { '' }

    $diffCmd = "git -C `"$($Target.Root)`" diff $($Target.DiffArgs -join ' ')"
    $t = [System.IO.File]::ReadAllText((Join-Path $script:KitRoot 'prompts/finder.md'))
    $map = [ordered]@{
        '{{ROOT}}' = $Target.Root; '{{DIFF_CMD}}' = $diffCmd; '{{FILES}}' = $files; '{{SOURCE}}' = (Get-SourceForm $Target)
        '{{LENS}}' = $script:Lenses[$Lens]; '{{DEPTH}}' = $lv.Depth; '{{PROFILE}}' = $notes; '{{CONVENTIONS}}' = $conventions
        '{{COUNTERPARTS}}' = $counterparts; '{{CALLS}}' = [string] $lv.Calls; '{{CAP}}' = [string] $lv.Cap
    }
    foreach ($k in $map.Keys) { $t = $t.Replace($k, [string] $map[$k]) }
    return ($t -replace '(\r?\n){3,}', "`n`n")
}

function ConvertTo-Finding {
    <#
    .SYNOPSIS
        Valid findings from a finder's JSON array: a changed file, a positive line, a summary and a failure. The rest is dropped and counted.
    #>
    [CmdletBinding()]
    param([AllowNull()] $Items, [Parameter(Mandatory)] [string] $Root, [AllowEmptyCollection()] [string[]] $ChangedPaths = @())

    $kept = [System.Collections.Generic.List[object]]::new()
    $dropped = 0
    $rootNorm = $Root.Replace('\', '/').TrimEnd('/')
    foreach ($i in @($Items)) {
        if ($i -isnot [pscustomobject]) { $dropped++; continue }
        $path = ([string] $i.path).Replace('\', '/')
        if ($path.StartsWith("$rootNorm/", [StringComparison]::OrdinalIgnoreCase)) { $path = $path.Substring($rootNorm.Length + 1) }
        $path = $path -replace '^\./', ''
        $line = 0
        $ok = $path -and [int]::TryParse([string] $i.line, [ref] $line) -and $line -gt 0 -and $i.summary -and $i.failure
        if ($ok -and $ChangedPaths.Count -and ($ChangedPaths -notcontains $path)) { $ok = $false }
        if (-not $ok) { $dropped++; continue }

        $sev = ([string] $i.severity).ToLowerInvariant()
        if ($sev -notin 'high', 'medium', 'low') { $sev = 'medium' }
        $flat = { param($s) ([regex]::Replace([string] $s, '[\p{Cc}\p{Zl}\p{Zp}\s]+', ' ')).Trim() }
        $kept.Add([pscustomobject]@{ Path = $path; Line = $line; Severity = $sev; Summary = (& $flat $i.summary); Failure = (& $flat $i.failure) })
    }
    return [pscustomobject]@{ Findings = $kept.ToArray(); Dropped = $dropped }
}

function Merge-Finding {
    <#
    .SYNOPSIS
        One list from several passes: the same file within three lines is the same defect; the first report wins. Most severe first, then capped.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Findings = @(), [int] $Cap = 15)

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $Findings) {
        if ($out | Where-Object { $_.Path -eq $f.Path -and [Math]::Abs($_.Line - $f.Line) -le 3 }) { continue }
        $out.Add($f)
    }
    $rank = @{ high = 0; medium = 1; low = 2 }
    $sorted = @($out | Sort-Object -Stable { $rank[$_.Severity] })
    return [pscustomobject]@{ Findings = @($sorted | Select-Object -First $Cap); Total = $sorted.Count }
}

function Write-FindingsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [string] $SizeLine,
        [AllowEmptyCollection()] [object[]] $Findings = @(),
        [AllowEmptyCollection()] [string[]] $Notes = @()
    )

    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add("# Review of $(Split-Path $Target.Root -Leaf) $(if ($Target.Branch) { $Target.Branch } else { $Target.Head.Substring(0, 8) })")
    $l.Add('')
    $l.Add("Head: $($Target.Head)")
    $l.Add("Merge-base: $($Target.From)")
    $l.Add("Base-ref: $($Target.BaseRef)")
    $l.Add("Checkout: $(if (-not $Target.WorkTree) { 'commit' } elseif ($Target.Dirty) { 'local (dirty tree)' } else { 'local' })")
    $l.Add("Scope: $($Target.Reason)")
    $l.Add("Size: $SizeLine")
    $l.Add("Level: $Level")
    foreach ($n in $Notes) { $l.Add("Note: $n") }
    for ($i = 0; $i -lt $Findings.Count; $i++) {
        $f = $Findings[$i]
        $l.Add('')
        $l.Add("## F$($i + 1) $($f.Path):$($f.Line)")
        $l.Add("Severity: $($f.Severity)")
        $l.Add("Summary: $($f.Summary)")
        $l.Add("Failure: $($f.Failure)")
    }
    [System.IO.File]::WriteAllText($Path, (($l -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Format-RefutePrompt {
    param([Parameter(Mandatory)] $Finding, [Parameter(Mandatory)] $Target)

    $json = [ordered]@{ id = $Finding.Id; path = $Finding.Path; line = $Finding.Line; summary = $Finding.Summary; failure = $Finding.Failure } | ConvertTo-Json -Compress
    $t = [System.IO.File]::ReadAllText((Join-Path $script:KitRoot 'prompts/refute.md'))
    return $t.Replace('{{FINDING}}', $json).Replace('{{SOURCE}}', (Get-SourceForm $Target)).Replace('{{ID}}', [string] $Finding.Id).Replace(
        '{{REQUIREMENTS}}', 'No requirement text for this change.')
}

function Invoke-StepBatch {
    <#
    .SYNOPSIS
        Runs prompts as parallel headless steps, a few at a time, and records each in the ledger.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Jobs,   # @{ Name; Prompt }
        [Parameter(Mandatory)] $Target, [Parameter(Mandatory)] [string] $LogDirectory,
        [string] $Model, [string] $Thinking, [string] $Run, [int] $Parallel = 3, [int] $TimeoutSec = 1800
    )

    $results = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Jobs.Count; $i += $Parallel) {
        $batch = @($Jobs[$i..([Math]::Min($Jobs.Count, $i + $Parallel) - 1)])
        $steps = @($batch | ForEach-Object {
                Start-AgentStep -Prompt $_.Prompt -WorkingDirectory $Target.Root -LogDirectory $LogDirectory -Name $_.Name -Model $Model -Thinking $Thinking
            })
        foreach ($s in $steps) {
            $r = Wait-AgentStep -Step $s -TimeoutSec $TimeoutSec
            $provider = if ($r.Provider) { $r.Provider } else { Get-ProviderOf $Model }
            Add-LedgerEntry -Step $r.Name -Provider $provider -Model ($r.Model ?? $Model) -Tokens $r.Tokens -Usd $r.Usd -Repo $Target.Root -Run $Run
            $results.Add($r)
        }
    }
    return , $results.ToArray()
}

function Invoke-Review {
    <#
    .SYNOPSIS
        Reviews one change and returns a summary object. Never edits the repository; writes only under .review-kit/runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Base, [string] $Head,
        [ValidateSet('auto', 'low', 'medium', 'high', 'xhigh', 'max')] [string] $Level = 'auto',
        [ValidateSet('pi', 'coderabbit', 'both')] [string] $Backend = 'pi',
        [string] $Model, [string] $RefuteModel,
        [switch] $NoRefute, [switch] $DryRun, [switch] $Wait, [switch] $Full,
        [hashtable] $Budget,
        [string] $RunId, [datetime] $RunStarted = (Get-Date),
        [scriptblock] $Log = { param($m) Write-Host $m }
    )

    if (-not $Budget) { $Budget = Get-Budget }
    if (-not $Model) { $Model = $Budget.models.finder }
    if (-not $RefuteModel) { $RefuteModel = if ($Budget.models.refute) { $Budget.models.refute } else { $Model } }

    $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
    $profile_ = Get-ReviewProfile -Root $root
    $branch = ([string] (Invoke-Git $root @('branch', '--show-current') -AllowFail)).Trim()
    $last = Get-LastReview -Root $root -Branch $branch
    $baseArg = if ($Base) { $Base } elseif ($profile_.base) { $profile_.base } else { $null }
    $target = Resolve-ReviewTarget -Repo $root -Base $baseArg -Head $Head -Since $(if ($Base -or $Full) { $null } else { $last.head })

    $result = [ordered]@{
        Status = 'done'; Repo = $root; Head = $target.Head; From = $target.From; Level = $null; File = $null
        Findings = 0; Refuted = 0; Confirmed = 0; Unclear = 0; Tokens = [long] 0; Usd = [double] 0; Reason = $null
    }
    $finish = { param($status, $reason) $result.Status = $status; $result.Reason = $reason; & $Log "review: $status - $reason"; [pscustomobject] $result }

    if ($target.Empty) { return & $finish 'nothing' "no change between $($target.BaseRef) and HEAD; pass -Base <ref> to pick a range" }
    if (-not $Base -and -not $Full -and -not $target.Dirty -and $last -and $last.head -eq $target.Head) { return & $finish 'nothing' "head $($target.Head.Substring(0, 8)) was already reviewed: $($last.file)" }

    $numstat = @(Invoke-Git $root (@('diff', '--numstat') + $target.DiffArgs))
    $size = Get-DiffSize -Numstat $numstat -TestGlobs $profile_.tests -VendorGlobs $profile_.vendor
    $signals = @(Get-EffortSignal -Size $size -ReviewProfile $profile_)
    $band = Get-EffortBand -Size $size -Signals $signals
    $sizeLine = Format-SizeLine $size
    $lvl = if ($Level -eq 'auto') { $band } else { $Level }
    $result.Level = $lvl

    & $Log "Assessment: $($size.Files.Count) files, $sizeLine, signals: $(if ($signals.Count) { $signals -join ', ' } else { 'none' }) -> $band"
    & $Log "Scope: $($target.From.Substring(0, 8))..$(if ($target.WorkTree) { 'working tree' } else { $target.Head.Substring(0, 8) }) ($($target.Reason))"
    if ($Level -ne 'auto' -and $Level -ne $band) {
        $bands = 'low', 'medium', 'high', 'xhigh', 'max'
        $kind = if ($bands.IndexOf($Level) -lt $bands.IndexOf($band)) { 'UNDERKILL' } else { 'OVERKILL' }
        & $Log "${kind}: typed $Level, assessed $band; running $Level as typed"
    }
    if (-not ($size.Files | Where-Object { $_.Bucket -in 'prod', 'test' })) { return & $finish 'nothing' 'the change holds no code: only generated files and docs' }

    # A range this large is a wrong base far more often than a real change, and no pass can read it.
    if ($Level -eq 'auto' -and $size.Prod -gt $script:MaxAutoProd) {
        return & $finish 'too-large' "prod=$($size.Prod) lines is over the $($script:MaxAutoProd)-line limit for an automatic review; pass -Base <ref> for a smaller range, run ``ark baseline`` to start from here, or type a -Level to review it anyway"
    }

    $lv = $script:Levels[$lvl]
    $thinking = if ($Budget.models.thinking) { $Budget.models.thinking } else { $lv.Thinking }
    $usePi = $Backend -in 'pi', 'both'
    $useRabbit = $Backend -in 'coderabbit', 'both'
    $plan = "Plan: level $lvl, $(if ($usePi) { "$($lv.Lenses.Count) finder pass(es) [$($lv.Lenses -join ', ')] on $(if ($Model) { $Model } else { 'pi default model' })" } else { 'no pi finder' })" +
        "$(if ($useRabbit) { ', coderabbit' })$(if ($NoRefute) { ', no refute' } else { ", refute on $(if ($RefuteModel) { $RefuteModel } else { 'pi default model' })" })"
    & $Log $plan
    if ($DryRun) { return & $finish 'dry-run' 'nothing was run' }

    # A sweep shares one run id across reviews, so the run budget covers all of them.
    $stamp = [string] [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $run = if ($RunId) { $RunId } else { $stamp }
    $started = Get-Date
    $runs = Initialize-RunFolder -Root $root
    $logDir = Join-Path $runs $stamp
    $notes = [System.Collections.Generic.List[string]]::new()
    $all = [System.Collections.Generic.List[object]]::new()
    $changed = @($size.Files | ForEach-Object { $_.Path })

    if ($usePi) {
        $gate = Wait-LimitGate -Provider (Get-ProviderOf $Model) -Budget $Budget -Run $run -RunStarted $RunStarted -Wait:$Wait -Log $Log
        & $Log "budget: $($gate.Action) - $($gate.Reason)"
        if ($gate.Action -ne 'go') { return & $finish 'budget' $gate.Reason }

        $jobs = @($lv.Lenses | ForEach-Object { @{ Name = "finder-$_"; Prompt = (Format-FinderPrompt -Target $target -Size $size -ReviewProfile $profile_ -Level $lvl -Lens $_) } })
        $passes = Invoke-StepBatch -Jobs $jobs -Target $target -LogDirectory $logDir -Model $Model -Thinking $thinking -Run $run
        $failed = 0
        foreach ($r in $passes) {
            $result.Tokens += $r.Tokens; $result.Usd += $r.Usd
            if ($r.Error) { $failed++; $notes.Add("$($r.Name) failed: $($r.Error)"); & $Log "$($r.Name): FAILED $($r.Error)"; continue }
            $items = Get-JsonTail -Text $r.Text -Kind array
            if ($null -eq $items) { $failed++; $notes.Add("$($r.Name) returned no findings array"); & $Log "$($r.Name): no findings array in the reply ($($r.LogPath))"; continue }
            $c = ConvertTo-Finding -Items $items -Root $root -ChangedPaths $changed
            & $Log "$($r.Name): $($c.Findings.Count) findings$(if ($c.Dropped) { ", $($c.Dropped) dropped as malformed or outside the change" }), $($r.Tokens) tokens, $($r.Seconds) s"
            foreach ($f in $c.Findings) { $all.Add($f) }
        }
        if ($failed -eq $passes.Count) {
            $limit = @($passes | Where-Object LimitHit).Count -gt 0
            return & $finish $(if ($limit) { 'budget' } else { 'failed' }) "every finder pass failed: $($notes -join '; ')"
        }
    }

    if ($useRabbit) {
        $rb = Invoke-RabbitReview -Target $target -LogDirectory $logDir -Budget $Budget -Run $run
        & $Log "coderabbit: $($rb.Reason)"
        if (-not $rb.Ran) { $notes.Add("coderabbit skipped: $($rb.Reason)") }
        $c = ConvertTo-Finding -Items $rb.Findings -Root $root -ChangedPaths $changed
        foreach ($f in $c.Findings) { $all.Add($f) }
        if (-not $usePi -and -not $rb.Ran) { return & $finish 'failed' $rb.Reason }
    }

    $merged = Merge-Finding -Findings $all.ToArray() -Cap $lv.Cap
    if ($merged.Total -gt $merged.Findings.Count) { $notes.Add("reported $($merged.Findings.Count) of $($merged.Total) findings (cap at level $lvl)") }
    $name = "review-$(($branch ? $branch : $target.Head.Substring(0, 8)) -replace '[^A-Za-z0-9._-]', '_')-$stamp.md"
    $file = Join-Path $runs $name
    Write-FindingsFile -Path $file -Target $target -Level $lvl -SizeLine $sizeLine -Findings $merged.Findings -Notes $notes.ToArray()
    $result.File = $file
    $result.Findings = $merged.Findings.Count

    if ($NoRefute) { & $Log (Set-RefuteSkipped -Path $file -Reason '--no-refute') }
    elseif ($merged.Findings.Count) {
        $gate = Wait-LimitGate -Provider (Get-ProviderOf $RefuteModel) -Budget $Budget -Run $run -RunStarted $RunStarted -Wait:$Wait -Log $Log
        if ($gate.Action -ne 'go') { & $Log (Set-RefuteSkipped -Path $file -Reason "budget: $($gate.Reason)") }
        else {
            $doc = Read-FindingsFile -Path $file
            $jobs = @($doc.Findings | ForEach-Object { @{ Name = "refute-F$($_.Id)"; Prompt = (Format-RefutePrompt -Finding $_ -Target $target) } })
            $answers = Invoke-StepBatch -Jobs $jobs -Target $target -LogDirectory $logDir -Model $RefuteModel -Thinking 'low' -Run $run -TimeoutSec 900
            $verdicts = [System.Collections.Generic.List[object]]::new()
            foreach ($r in $answers) {
                $result.Tokens += $r.Tokens; $result.Usd += $r.Usd
                $v = Get-JsonTail -Text $r.Text -Kind object
                $id = [int] ($r.Name -replace '^refute-F', '')
                if ($v -and [string] $v.id -eq [string] $id -and ([string] $v.verdict).ToUpperInvariant() -in 'REFUTED', 'CONFIRMED', 'UNCLEAR') { $verdicts.Add($v) }
            }
            $line = Set-RefuteVerdict -Path $file -Verdicts $verdicts.ToArray() -Model $(if ($RefuteModel) { $RefuteModel } else { 'pi default model' })
            & $Log $line
            $after = Read-FindingsFile -Path $file
            $result.Refuted = @($after.Findings | Where-Object Refute -eq 'REFUTED').Count
            $result.Confirmed = @($after.Findings | Where-Object Refute -eq 'CONFIRMED').Count
            $result.Unclear = @($after.Findings | Where-Object Refute -eq 'UNCLEAR').Count
        }
    }

    Set-LastReview -Root $root -Branch $branch -Head $target.Head -File $file
    & $Log "Findings: $file"
    & $Log ('Spent: {0} tokens, {1:N2} USD (API-equivalent), {2} s' -f $result.Tokens, $result.Usd, [int] ((Get-Date) - $started).TotalSeconds)
    return [pscustomobject] $result
}

Export-ModuleMember -Function Get-ReviewProfile, Get-LastReview, Set-LastReview, Initialize-RunFolder, Format-FinderPrompt, ConvertTo-Finding, Merge-Finding, Write-FindingsFile,
    Format-RefutePrompt, Invoke-Review
