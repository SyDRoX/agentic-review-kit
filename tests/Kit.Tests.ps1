#Requires -Version 7.0

BeforeAll {
    $script:Kit = Split-Path $PSScriptRoot -Parent
    foreach ($m in 'Scope', 'Harness', 'Limits', 'Findings', 'Rabbit', 'Review') { Import-Module (Join-Path $script:Kit "lib/$m.psm1") -Force }

    function New-TestRepo {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ark-test-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $dir
        git -C $dir init -q -b main
        git -C $dir config user.email test@example.invalid
        git -C $dir config user.name test
        git -C $dir config core.autocrlf false
        Set-Content (Join-Path $dir 'a.ts') "export const a = 1;"
        git -C $dir add -A; git -C $dir commit -q -m one
        return $dir
    }

    function Add-TestCommit([string] $Dir, [string] $File, [string] $Text) {
        $path = Join-Path $Dir $File
        $null = New-Item -ItemType Directory -Force (Split-Path $path -Parent)
        Set-Content $path $Text
        git -C $Dir add -A; git -C $Dir commit -q -m $File
        return (git -C $Dir rev-parse HEAD)
    }
}

Describe 'Scope: file buckets' {
    It 'puts <Path> in <Bucket>' -ForEach @(
        @{ Path = 'src/index.ts'; Bucket = 'prod' }
        @{ Path = 'test/api.test.ts'; Bucket = 'test' }
        @{ Path = 'src/replay.spec.ts'; Bucket = 'test' }
        @{ Path = 'tests/test_api.py'; Bucket = 'test' }
        @{ Path = 'Assets/Scripts/Tests/EditMode/SnakeTests.cs'; Bucket = 'test' }
        @{ Path = 'Assets/Scripts/Snake.cs'; Bucket = 'prod' }
        @{ Path = 'Assets/Scripts/Snake.cs.meta'; Bucket = 'generated' }
        @{ Path = 'Assets/Prefabs/Wall.prefab'; Bucket = 'generated' }
        @{ Path = 'Assets/Scenes/Main.unity'; Bucket = 'generated' }
        @{ Path = 'pnpm-lock.yaml'; Bucket = 'generated' }
        @{ Path = 'Assets/Asset Packages/Kit/Thing.cs'; Bucket = 'generated' }
        @{ Path = 'Assets/Plugins/Lib/Lib.cs'; Bucket = 'generated' }
        @{ Path = 'README.md'; Bucket = 'doc' }
        @{ Path = 'migrations/0001_initial.sql'; Bucket = 'prod' }
    ) {
        Get-FileBucket $Path | Should -Be $Bucket
    }

    It 'honours the profile test and vendor globs' {
        Get-FileBucket 'checks/api.ts' -TestGlobs @('checks/**') | Should -Be 'test'
        Get-FileBucket 'lib/copied/x.ts' -VendorGlobs @('lib/copied/**') | Should -Be 'generated'
    }
}

Describe 'Scope: diff size' {
    It 'counts only prod lines as size and reads renames and binaries' {
        $numstat = @(
            "10`t2`tsrc/index.ts"
            "40`t0`ttest/api.test.ts"
            "900`t0`tAssets/Prefabs/Wall.prefab"
            "-`t-`tAssets/Art/wall.png"
            "5`t5`tsrc/{old => new}/thing.ts"
            "3`t1`tREADME.md"
            "700`t0`tdata/export.json"
        )
        $s = Get-DiffSize -Numstat $numstat
        $s.Prod | Should -Be 22
        $s.ProdFiles | Should -Be 2
        $s.ProdDel | Should -Be 7
        $s.Test | Should -Be 40
        $s.Generated | Should -Be 1600
        $s.Doc | Should -Be 4
        ($s.Files | Where-Object Path -eq 'src/new/thing.ts') | Should -Not -BeNullOrEmpty
        Format-SizeLine $s | Should -Be 'prod=22 prodfiles=2 proddel=7 test=40 generated=1600 doc=4'
    }
}

Describe 'Scope: effort band' {
    It 'sizes prod=<Prod> files=<Files> as <Band>' -ForEach @(
        @{ Prod = 30; Files = 2; Band = 'low' }
        @{ Prod = 30; Files = 5; Band = 'medium' }
        @{ Prod = 300; Files = 6; Band = 'medium' }
        @{ Prod = 325; Files = 6; Band = 'medium' }
        @{ Prod = 340; Files = 6; Band = 'high' }
        @{ Prod = 870; Files = 6; Band = 'high' }
        @{ Prod = 900; Files = 6; Band = 'xhigh' }
        @{ Prod = 2000; Files = 30; Band = 'xhigh' }
        @{ Prod = 2500; Files = 30; Band = 'max' }
    ) {
        Get-EffortBand -Size ([pscustomobject]@{ Prod = $Prod; ProdFiles = $Files }) | Should -Be $Band
    }

    It 'takes the higher band at a boundary when a signal fires' {
        Get-EffortBand -Size ([pscustomobject]@{ Prod = 325; ProdFiles = 6 }) -Signals @('deletion-heavy') | Should -Be 'high'
    }

    It 'lifts a small change that touches a cross-repo contract to xhigh, and max only when large' {
        Get-EffortBand -Size ([pscustomobject]@{ Prod = 20; ProdFiles = 1 }) -Signals @('cross-repo contract') | Should -Be 'xhigh'
        Get-EffortBand -Size ([pscustomobject]@{ Prod = 2500; ProdFiles = 30 }) -Signals @('cross-repo contract') | Should -Be 'max'
    }
}

Describe 'Scope: signals' {
    It 'finds pins, migrations, contracts, hot paths and heavy deletion' {
        $size = Get-DiffSize -Numstat @("5`t40`tsrc/index.ts", "2`t0`tpackage.json", "9`t0`tmigrations/0012_add.sql", "3`t0`tsrc/dto/run.ts")
        $prof = [pscustomobject]@{ contracts = @('src/dto/**'); hot = @('src/index.ts'); counterparts = @([pscustomobject]@{ path = 'x' }) }
        $signals = @(Get-EffortSignal -Size $size -ReviewProfile $prof)
        $signals | Should -Contain 'cross-repo contract'
        $signals | Should -Contain 'dependency pin'
        $signals | Should -Contain 'schema migration'
        $signals | Should -Contain 'hot path'
        $signals | Should -Contain 'deletion-heavy'
    }

    It 'reports nothing for a plain change and no profile' {
        @(Get-EffortSignal -Size (Get-DiffSize -Numstat @("5`t0`tsrc/util.ts"))).Count | Should -Be 0
    }

    It 'matches globs across folders' {
        Test-GlobMatch 'Assets/Game/Net/Client.cs' @('Assets/**/Net/**') | Should -BeTrue
        Test-GlobMatch 'Assets/Game/Network.cs' @('Assets/**/Net/**') | Should -BeFalse
        Test-GlobMatch 'src/index.ts' @('src/*.ts') | Should -BeTrue
        Test-GlobMatch 'src/a/index.ts' @('src/*.ts') | Should -BeFalse
    }
}

Describe 'Scope: review target' {
    BeforeEach { $script:Repo = New-TestRepo }
    AfterEach { Remove-Item $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is empty on a clean branch that has not left its base' {
        (Resolve-ReviewTarget -Repo $script:Repo -Base main).Empty | Should -BeTrue
    }

    It 'reviews uncommitted edits against the base' {
        Add-Content (Join-Path $script:Repo 'a.ts') 'export const b = 2;'
        $t = Resolve-ReviewTarget -Repo $script:Repo -Base main
        $t.Empty | Should -BeFalse
        $t.WorkTree | Should -BeTrue
        $t.Dirty | Should -BeTrue
        $t.DiffArgs.Count | Should -Be 1
    }

    It 'starts at the previous review when that head is an ancestor' {
        $first = git -C $script:Repo rev-parse HEAD
        $second = Add-TestCommit $script:Repo 'b.ts' 'export const b = 2;'
        $null = Add-TestCommit $script:Repo 'c.ts' 'export const c = 3;'
        $t = Resolve-ReviewTarget -Repo $script:Repo -Base $first -Since $second
        $t.From | Should -Be $second
        $t.Reason | Should -Be 'head of the previous review'
    }

    It 'ignores a previous head that is no longer in the history' {
        $first = git -C $script:Repo rev-parse HEAD
        $null = Add-TestCommit $script:Repo 'b.ts' 'export const b = 2;'
        $t = Resolve-ReviewTarget -Repo $script:Repo -Base $first -Since '1111111111111111111111111111111111111111'
        $t.From | Should -Be $first
    }

    It 'reviews a fixed commit range with -Head' {
        $first = git -C $script:Repo rev-parse HEAD
        $second = Add-TestCommit $script:Repo 'b.ts' 'export const b = 2;'
        $t = Resolve-ReviewTarget -Repo $script:Repo -Base $first -Head $second
        $t.WorkTree | Should -BeFalse
        $t.DiffArgs | Should -Be @($first, $second)
    }
}

Describe 'Harness: pi stream' {
    It 'sums usage over turns and keeps the last text' {
        $lines = @(
            '{"type":"session","version":3,"id":"x"}'
            '{"type":"message_end","message":{"role":"user","content":"hi"}}'
            '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"working"}],"provider":"xai","model":"grok","usage":{"totalTokens":100,"cost":{"total":0.01}},"stopReason":"toolUse"}}'
            'not json'
            '{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"[]"}],"provider":"xai","model":"grok","usage":{"totalTokens":50,"cost":{"total":0.02}},"stopReason":"stop"}}'
            '{"type":"agent_settled","aborted":false}'
        )
        $r = ConvertFrom-PiStream -Lines $lines
        $r.Text | Should -Be '[]'
        $r.Tokens | Should -Be 150
        $r.Usd | Should -BeGreaterThan 0.029
        $r.Provider | Should -Be 'xai'
        $r.Error | Should -BeNullOrEmpty
        $r.Settled | Should -BeTrue
    }

    It 'flags a usage limit error' {
        $lines = @('{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"You have hit your ChatGPT usage limit (plus plan). Try again in ~42 min."}}')
        $r = ConvertFrom-PiStream -Lines $lines
        $r.Error | Should -Match 'usage limit'
        $r.LimitHit | Should -BeTrue
    }

    It 'reports an empty stream as an error' {
        (ConvertFrom-PiStream -Lines @()).Error | Should -Be 'no assistant message in the stream'
    }
}

Describe 'Harness: JSON tail' {
    It 'reads an array after prose and inside a fence' {
        $text = "I looked at [the diff].`n``````json`n[{`"path`":`"a.ts`",`"line`":3}]`n```````n"
        $v = Get-JsonTail -Text $text -Kind array
        $v.Count | Should -Be 1
        $v[0].path | Should -Be 'a.ts'
    }

    It 'reads an empty array' {
        $v = Get-JsonTail -Text 'Nothing found. []' -Kind array
        , $v | Should -BeOfType [array]
        $v.Count | Should -Be 0
    }

    It 'reads the last object and survives braces in strings' {
        $v = Get-JsonTail -Text 'note {"id":1} then {"id":2,"verdict":"REFUTED","note":"if (x) { return } at a.ts:3"}' -Kind object
        $v.id | Should -Be 2
        $v.verdict | Should -Be 'REFUTED'
    }

    It 'returns null when there is no JSON' {
        Get-JsonTail -Text 'no findings here' -Kind array | Should -BeNullOrEmpty
    }
}

Describe 'Limits: gate decision' {
    BeforeAll {
        $script:Budget = @{ five_h_pause = 0.8; week_stop = 0.7; quiet = @(); run = @{ max_usd = 2.0; max_tokens = $null; max_minutes = 60 }; self_metered = @{ xai = @{ five_h_usd = 5.0; week_usd = 25.0 } } }
        $script:Now = [datetime] '2026-11-13T12:00:00'
        function New-Usage($five, $week) {
            [pscustomobject]@{ Known = $true; Provider = 'openai-codex'; Plan = 'plus'; FiveH = $five; Week = $week; LimitReached = $false
                FiveHReset = $script:Now.AddHours(2); WeekReset = $script:Now.AddDays(3) }
        }
    }

    It 'goes when both windows are under their thresholds' {
        (Get-GateDecision -Usage (New-Usage 0.3 0.4) -Budget $script:Budget -Now $script:Now -RunStarted $script:Now).Action | Should -Be 'go'
    }

    It 'waits until the 5-hour reset at the pause threshold' {
        $d = Get-GateDecision -Usage (New-Usage 0.8 0.4) -Budget $script:Budget -Now $script:Now -RunStarted $script:Now
        $d.Action | Should -Be 'wait'
        $d.WaitUntil | Should -Be $script:Now.AddHours(2).AddMinutes(2)
    }

    It 'stops at the weekly threshold even when the 5-hour window is free' {
        (Get-GateDecision -Usage (New-Usage 0.1 0.7) -Budget $script:Budget -Now $script:Now -RunStarted $script:Now).Action | Should -Be 'stop'
    }

    It 'stops when the run budget is spent' {
        $spend = [pscustomobject]@{ Usd = 2.5; Tokens = 10 }
        $d = Get-GateDecision -Usage (New-Usage 0.1 0.1) -Budget $script:Budget -RunSpend $spend -Now $script:Now -RunStarted $script:Now
        $d.Action | Should -Be 'stop'
        $d.Reason | Should -Match 'run budget'
    }

    It 'stops when the run time is spent' {
        (Get-GateDecision -Usage (New-Usage 0.1 0.1) -Budget $script:Budget -Now $script:Now -RunStarted $script:Now.AddMinutes(-61)).Action | Should -Be 'stop'
    }

    It 'waits inside a quiet window' {
        $b = $script:Budget.Clone(); $b.quiet = @(, @('2026-11-13T09:00:00', '2026-11-13T18:00:00'))
        $d = Get-GateDecision -Usage (New-Usage 0.1 0.1) -Budget $b -Now $script:Now -RunStarted $script:Now
        $d.Action | Should -Be 'wait'
        $d.WaitUntil | Should -Be ([datetime] '2026-11-13T18:00:00')
    }

    It 'meters a provider that reports no quota against its cap, and never states a percentage' {
        $u = [pscustomobject]@{ Known = $false; Provider = 'xai'; Source = 'ledger'; FiveHUsd = 1.0; WeekUsd = 3.0; FiveHCapUsd = 5.0; WeekCapUsd = 25.0 }
        $d = Get-GateDecision -Usage $u -Budget $script:Budget -Now $script:Now -RunStarted $script:Now
        $d.Action | Should -Be 'go'
        $d.Reason | Should -Match 'not reported'
        $d.Reason | Should -Not -Match '%'
        $u.WeekUsd = 25.0
        (Get-GateDecision -Usage $u -Budget $script:Budget -Now $script:Now -RunStarted $script:Now).Action | Should -Be 'stop'
        $u.WeekUsd = 3.0; $u.FiveHUsd = 5.0
        (Get-GateDecision -Usage $u -Budget $script:Budget -Now $script:Now -RunStarted $script:Now).Action | Should -Be 'wait'
    }

    It 'does not spend blind when a reporting provider cannot be read' {
        $u = [pscustomobject]@{ Known = $false; Provider = 'openai-codex'; Source = 'provider'; Error = 'usage endpoint: timeout' }
        (Get-GateDecision -Usage $u -Budget $script:Budget -Now $script:Now -RunStarted $script:Now).Action | Should -Be 'wait'
    }
}

Describe 'Limits: budget file, ledger and Codex reply' {
    BeforeEach {
        $script:Home_ = Join-Path ([IO.Path]::GetTempPath()) ("ark-home-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:Home_
        $env:ARK_HOME = $script:Home_
    }
    AfterEach { Remove-Item Env:ARK_HOME; Remove-Item $script:Home_ -Recurse -Force -ErrorAction SilentlyContinue }

    It 'uses the defaults without a file' {
        $b = Get-Budget
        $b.five_h_pause | Should -Be 0.8
        $b.week_stop | Should -Be 0.7
        $b.self_metered.xai.week_usd | Should -Be 25.0
    }

    It 'overlays a partial file on the defaults' {
        Set-Content (Join-Path $script:Home_ 'budget.json') '{"week_stop":0.5,"run":{"max_usd":3},"models":{"finder":"openai-codex/x"},"self_metered":{"xai":{"week_usd":10}}}'
        $b = Get-Budget
        $b.week_stop | Should -Be 0.5
        $b.five_h_pause | Should -Be 0.8
        $b.run.max_usd | Should -Be 3
        $b.run.max_minutes | Should -BeNullOrEmpty
        $b.models.finder | Should -Be 'openai-codex/x'
        $b.self_metered.xai.week_usd | Should -Be 10
        $b.self_metered.xai.five_h_usd | Should -Be 5.0
    }

    It 'reads an empty quiet list from the file as no window' {
        Set-Content (Join-Path $script:Home_ 'budget.json') '{"quiet":[],"run":{"max_usd":null}}'
        $b = Get-Budget
        @($b.quiet).Count | Should -Be 0
        $u = [pscustomobject]@{ Known = $true; Provider = 'p'; FiveH = 0.1; Week = 0.1; LimitReached = $false; FiveHReset = (Get-Date); WeekReset = (Get-Date) }
        (Get-GateDecision -Usage $u -Budget $b).Action | Should -Be 'go'
    }

    It 'rejects a threshold outside (0, 1]' {
        Set-Content (Join-Path $script:Home_ 'budget.json') '{"week_stop":70}'
        { Get-Budget } | Should -Throw '*week_stop*'
    }

    It 'sums the ledger by provider, run and time' {
        Add-LedgerEntry -Step a -Provider xai -Model m -Tokens 100 -Usd 0.5 -Repo r -Run one
        Add-LedgerEntry -Step b -Provider xai -Model m -Tokens 200 -Usd 0.25 -Repo r -Run two
        Add-LedgerEntry -Step c -Provider openai-codex -Model m -Tokens 50 -Usd 0 -Repo r -Run two
        (Get-LedgerSpend -Provider xai).Usd | Should -Be 0.75
        (Get-LedgerSpend -Run two).Tokens | Should -Be 250
        (Get-LedgerSpend -Since (Get-Date).AddMinutes(5)).Steps | Should -Be 0
        (Get-ProviderUsage -Provider xai -Budget (Get-Budget)).WeekUsd | Should -Be 0.75
    }

    It 'reads the Codex usage reply' {
        $j = '{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":3,"reset_at":1794613259},"secondary_window":{"used_percent":29,"reset_at":1794939557}}}' | ConvertFrom-Json
        $u = ConvertFrom-CodexUsage $j
        $u.Known | Should -BeTrue
        $u.FiveH | Should -Be 0.03
        $u.Week | Should -Be 0.29
        $u.FiveHReset | Should -BeOfType [datetime]
        (ConvertFrom-CodexUsage ('{"plan_type":"plus"}' | ConvertFrom-Json)).Known | Should -BeFalse
    }

    It 'reads the Cursor usage reply as one period with no 5-hour window' {
        $j = '{"currentPeriodStart":"2026-11-07T15:43:30.516Z","nextResetTimestampUtc":"2026-11-14T15:43:30.516Z","usagePercent":36.85807150595883,"hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"cursorPlanName":"Premium","isUnified":true,"billingBrand":"SAND_BILLING_BRAND_GROK"}' | ConvertFrom-Json
        $u = ConvertFrom-CursorUsage $j
        $u.Known | Should -BeTrue
        [Math]::Round($u.Week, 4) | Should -Be 0.3686
        $u.FiveH | Should -BeNullOrEmpty
        $u.PeriodDays | Should -Be 7
        $u.Plan | Should -Be 'Premium'
        $u.LimitReached | Should -BeFalse
        $u | Add-Member Provider 'cursor'; $u | Add-Member Source 'provider'
        $line = Format-UsageLine $u
        $line | Should -Match '36\.9% used, remaining 100 - 36\.9 = 63\.1%'
        $line | Should -Match '7-day period'
        $line | Should -Match '5h window not reported'
    }

    It 'never reads a missing Cursor percentage as zero' {
        $u = ConvertFrom-CursorUsage ('{"cursorPlanName":"Premium","hasAvailableUsage":true}' | ConvertFrom-Json)
        $u.Known | Should -BeFalse
        $u.Error | Should -Match 'usagePercent'
        (ConvertFrom-CursorUsage ('{"usagePercent":null}' | ConvertFrom-Json)).Known | Should -BeFalse
    }

    It 'gates a one-period provider on the weekly stop and on exhausted usage, with no 5-hour wait' {
        $b = Get-Budget
        $u = [pscustomobject]@{ Known = $true; Provider = 'cursor'; Source = 'provider'; FiveH = $null; Week = 0.37; WeekReset = (Get-Date).AddDays(1); LimitReached = $false }
        $d = Get-GateDecision -Usage $u -Budget $b
        $d.Action | Should -Be 'go'
        $d.Reason | Should -Match '5h window not reported'
        $u.Week = 0.71
        (Get-GateDecision -Usage $u -Budget $b).Action | Should -Be 'stop'
        $u.Week = 0.10; $u.LimitReached = $true
        (Get-GateDecision -Usage $u -Budget $b).Action | Should -Be 'stop'
    }

    It 'enforces the Cursor pool for another provider only when the budget file says so' {
        (Get-Budget).cursor.applies_to.Count | Should -Be 0
        (Get-ProviderUsage -Provider xai -Budget (Get-Budget)).Source | Should -Be 'ledger'
        Set-Content (Join-Path $script:Home_ 'budget.json') '{"cursor":{"applies_to":["xai"]}}'
        @((Get-Budget).cursor.applies_to) | Should -Be @('xai')
    }

    It 'names the provider from the model id' {
        Get-ProviderOf 'openai-codex/gpt-x' | Should -Be 'openai-codex'
        Get-ProviderOf 'grok' | Should -BeNullOrEmpty
    }
}

Describe 'Review: findings' {
    It 'keeps valid findings inside the change and drops the rest' {
        $items = '[{"path":"src\\a.ts","line":"12","severity":"HIGH","summary":"s one","failure":"f\none"},
                   {"path":"C:/repo/src/b.ts","line":3,"severity":"weird","summary":"s","failure":"f"},
                   {"path":"src/other.ts","line":3,"severity":"low","summary":"s","failure":"f"},
                   {"path":"src/a.ts","line":0,"summary":"s","failure":"f"},
                   {"path":"src/a.ts","line":4,"summary":"","failure":"f"},
                   "junk"]' | ConvertFrom-Json
        $c = ConvertTo-Finding -Items $items -Root 'C:\repo' -ChangedPaths @('src/a.ts', 'src/b.ts')
        $c.Findings.Count | Should -Be 2
        $c.Dropped | Should -Be 4
        $c.Findings[0].Path | Should -Be 'src/a.ts'
        $c.Findings[0].Line | Should -Be 12
        $c.Findings[0].Severity | Should -Be 'high'
        $c.Findings[0].Failure | Should -Be 'f one'
        $c.Findings[1].Path | Should -Be 'src/b.ts'
        $c.Findings[1].Severity | Should -Be 'medium'
    }

    It 'merges near-duplicate lines, sorts by severity and caps' {
        $f = @(
            [pscustomobject]@{ Path = 'a.ts'; Line = 10; Severity = 'low'; Summary = 'first'; Failure = 'f' }
            [pscustomobject]@{ Path = 'a.ts'; Line = 12; Severity = 'high'; Summary = 'dup'; Failure = 'f' }
            [pscustomobject]@{ Path = 'a.ts'; Line = 40; Severity = 'high'; Summary = 'second'; Failure = 'f' }
            [pscustomobject]@{ Path = 'b.ts'; Line = 10; Severity = 'medium'; Summary = 'third'; Failure = 'f' }
        )
        $m = Merge-Finding -Findings $f -Cap 2
        $m.Total | Should -Be 3
        $m.Findings.Summary | Should -Be @('second', 'third')
    }

    It 'writes a file the findings module reads back and can stamp with verdicts' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ("ark-findings-" + [guid]::NewGuid().ToString('N') + '.md')
        try {
            $target = [pscustomobject]@{ Root = 'C:\repo'; Branch = 'main'; Head = 'a' * 40; From = 'b' * 40; BaseRef = 'origin/main'; WorkTree = $true; Dirty = $true; Reason = 'merge-base with origin/main' }
            $f = @(
                [pscustomobject]@{ Path = 'src/a.ts'; Line = 12; Severity = 'high'; Summary = 'sum one'; Failure = 'fail one' }
                [pscustomobject]@{ Path = 'src/b.ts'; Line = 3; Severity = 'low'; Summary = 'sum two'; Failure = 'fail two' }
            )
            Write-FindingsFile -Path $path -Target $target -Level high -SizeLine 'prod=1' -Findings $f -Notes @('a note')
            $doc = Read-FindingsFile -Path $path
            $doc.Head | Should -Be ('a' * 40)
            $doc.MergeBase | Should -Be ('b' * 40)
            $doc.Level | Should -Be 'high'
            $doc.Findings.Count | Should -Be 2
            $doc.Findings[1].Path | Should -Be 'src/b.ts'
            $doc.Findings[1].Summary | Should -Be 'sum two'

            $line = Set-RefuteVerdict -Path $path -Verdicts @([pscustomobject]@{ id = 1; verdict = 'refuted'; note = 'guard at a.ts:9' }) -Model 'xai/grok'
            $line | Should -Be 'Refute: 1 refuted, 0 confirmed, 1 unclear (xai/grok)'
            $after = Read-FindingsFile -Path $path
            $after.Findings[0].Refute | Should -Be 'REFUTED'
            $after.Findings[1].Refute | Should -Be 'UNCLEAR'
            @(Get-ActionableFinding -Findings $after.Findings).Count | Should -Be 1
        }
        finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    }

    It 'writes a file with no findings that still reads back' {
        $path = Join-Path ([IO.Path]::GetTempPath()) ("ark-findings-" + [guid]::NewGuid().ToString('N') + '.md')
        try {
            $target = [pscustomobject]@{ Root = 'C:\repo'; Branch = ''; Head = 'a' * 40; From = 'b' * 40; BaseRef = 'main'; WorkTree = $false; Dirty = $false; Reason = 'r' }
            Write-FindingsFile -Path $path -Target $target -Level low -SizeLine 'prod=1'
            (Read-FindingsFile -Path $path).Findings.Count | Should -Be 0
            (Get-Content $path -Raw) | Should -Match 'Checkout: commit'
        }
        finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Review: prompts' {
    BeforeAll {
        $script:Target = [pscustomobject]@{ Root = 'C:\repo'; Head = 'a' * 40; From = 'b' * 40; WorkTree = $false; DiffArgs = @(('b' * 40), ('a' * 40)) }
        $script:Size = Get-DiffSize -Numstat @("5`t1`tsrc/index.ts")
    }

    It 'fills every placeholder of the finder prompt at <Level>' -ForEach @(@{ Level = 'low' }, @{ Level = 'medium' }, @{ Level = 'high' }, @{ Level = 'xhigh' }, @{ Level = 'max' }) {
        $prof = [pscustomobject]@{ notes = 'Project note text.'; conventions = @(); counterparts = @() }
        $p = Format-FinderPrompt -Target $script:Target -Size $script:Size -ReviewProfile $prof -Level $Level -Lens correctness
        $p | Should -Not -Match '\{\{'
        $p | Should -Match 'Project note text\.'
        $p | Should -Match 'src/index\.ts \(prod, \+5 -1\)'
        $p | Should -Match ([regex]::Escape("diff $('b' * 40) $('a' * 40)"))
        $p | Should -Match 'never the working tree'
    }

    It 'fills the refute prompt and keeps the finding as one JSON line' {
        $f = [pscustomobject]@{ Id = 4; Path = 'src/a.ts'; Line = 9; Summary = 'has "quotes"'; Failure = 'then } breaks' }
        $p = Format-RefutePrompt -Finding $f -Target $script:Target
        $p | Should -Not -Match '\{\{'
        $p | Should -Match '"id":4,"path":"src/a.ts","line":9'
        $p | Should -Match ([regex]::Escape('has \"quotes\"'))
    }

    It 'ships a profile pair for every type' {
        foreach ($t in 'unity', 'ts-worker', 'python', 'generic') {
            $j = Get-Content (Join-Path $script:Kit "profiles/$t.json") -Raw | ConvertFrom-Json
            $j.type | Should -Be $t
            (Get-Content (Join-Path $script:Kit "profiles/$t.md") -Raw).Trim() | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Rabbit: output' {
    It 'takes findings from nested JSON and from JSON lines' {
        $nested = '{"review":{"comments":[{"fileName":"src/a.ts","startLine":7,"severity":"major","title":"Null deref","description":"x may be null"}]}}'
        $r = ConvertFrom-RabbitOutput -Text $nested
        $r.Count | Should -Be 1
        $r[0].path | Should -Be 'src/a.ts'
        $r[0].line | Should -Be 7
        $r[0].severity | Should -Be 'high'
        $r[0].summary | Should -Be '[coderabbit] Null deref'

        $lines = "starting review`n{`"file`":`"b.ts`",`"line`":3,`"message`":`"Leak`"}`ndone"
        $r = ConvertFrom-RabbitOutput -Text $lines
        $r.Count | Should -Be 1
        $r[0].severity | Should -Be 'low'
    }

    It 'returns nothing for plain text' {
        (ConvertFrom-RabbitOutput -Text 'No issues found.').Count | Should -Be 0
    }
}

Describe 'Audit: chunks' {
    BeforeAll { Import-Module (Join-Path $script:Kit 'lib/Audit.psm1') -Force }

    It 'keeps a folder that fits as one chunk' {
        $files = @([pscustomobject]@{ Path = 'src/a.ts'; Lines = 100 }, [pscustomobject]@{ Path = 'src/b.ts'; Lines = 200 })
        $c = @(Split-AuditChunk -Files $files -MaxLines 800)
        $c.Count | Should -Be 1
        $c[0].Lines | Should -Be 300
        $c[0].Files | Should -Be @('src/a.ts', 'src/b.ts')
        $c[0].Status | Should -Be 'todo'
    }

    It 'splits along folders, joins small neighbours and never exceeds the limit except for one big file' {
        $files = @(
            [pscustomobject]@{ Path = 'Assets/Scripts/Skills/A.cs'; Lines = 400 }
            [pscustomobject]@{ Path = 'Assets/Scripts/Skills/B.cs'; Lines = 300 }
            [pscustomobject]@{ Path = 'Assets/Scripts/UI/C.cs'; Lines = 100 }
            [pscustomobject]@{ Path = 'Assets/Scripts/UI/D.cs'; Lines = 100 }
            [pscustomobject]@{ Path = 'Assets/Scripts/Util/E.cs'; Lines = 150 }
            [pscustomobject]@{ Path = 'Assets/Scripts/Huge.cs'; Lines = 2000 }
            [pscustomobject]@{ Path = 'Assets/Scripts/Tiny.cs'; Lines = 20 }
        )
        $c = @(Split-AuditChunk -Files $files -MaxLines 800)
        ($c.Files | Sort-Object) | Should -Be (@($files.Path) | Sort-Object)
        @($c | Where-Object { $_.Lines -gt 800 -and @($_.Files).Count -gt 1 }).Count | Should -Be 0
        ($c | Where-Object { $_.Files -contains 'Assets/Scripts/Huge.cs' }).Files.Count | Should -Be 1
        ($c | Where-Object { $_.Files -contains 'Assets/Scripts/Skills/A.cs' }).Files | Should -Contain 'Assets/Scripts/Skills/B.cs'
        ($c | Where-Object { $_.Files -contains 'Assets/Scripts/UI/C.cs' }).Files | Should -Contain 'Assets/Scripts/Util/E.cs'
        $c.Id | Should -Be (1..$c.Count)
    }

    It 'gives the same chunks for the same files in any order' {
        $files = 1..40 | ForEach-Object { [pscustomobject]@{ Path = "src/m$($_ % 5)/f$_.ts"; Lines = 90 + $_ } }
        $a = Split-AuditChunk -Files $files -MaxLines 500 | ConvertTo-Json -Depth 4
        $b = Split-AuditChunk -Files ($files | Sort-Object Lines -Descending) -MaxLines 500 | ConvertTo-Json -Depth 4
        $a | Should -Be $b
    }

    It 'puts contract chunks first, then hot paths' {
        $files = @(
            [pscustomobject]@{ Path = 'src/a/x.ts'; Lines = 700 }
            [pscustomobject]@{ Path = 'src/hot/y.ts'; Lines = 700 }
            [pscustomobject]@{ Path = 'src/net/z.ts'; Lines = 700 }
        )
        $prof = [pscustomobject]@{ contracts = @('src/net/**'); hot = @('src/hot/**') }
        $c = @(Split-AuditChunk -Files $files -MaxLines 800 -ReviewProfile $prof)
        $c.Priority | Should -Be @(0, 1, 2)
        $c[0].Files | Should -Be @('src/net/z.ts')
    }

    It 'returns nothing for no files' {
        @(Split-AuditChunk -Files @()).Count | Should -Be 0
    }
}

Describe 'Audit: files and plan' {
    BeforeEach { $script:Repo = New-TestRepo }
    AfterEach { Remove-Item $script:Repo -Recurse -Force -ErrorAction SilentlyContinue }

    It 'lists own source files and leaves out tests, vendor code, docs and data' {
        $null = Add-TestCommit $script:Repo 'src/game/play er.ts' "a`nb`nc"
        $null = Add-TestCommit $script:Repo 'test/api.test.ts' 'x'
        $null = Add-TestCommit $script:Repo 'Assets/Plugins/Lib/Lib.cs' 'x'
        $null = Add-TestCommit $script:Repo 'copied/thing.ts' 'x'
        $null = Add-TestCommit $script:Repo 'README.md' 'x'
        $null = Add-TestCommit $script:Repo 'data/big.json' '{}'
        $prof = [pscustomobject]@{ tests = @(); vendor = @('copied/**') }
        $f = @(Get-AuditFile -Root $script:Repo -ReviewProfile $prof)
        ($f.Path | Sort-Object) | Should -Be @('a.ts', 'src/game/play er.ts')
        ($f | Where-Object Path -eq 'src/game/play er.ts').Lines | Should -Be 3
        @(Get-AuditFile -Root $script:Repo -ReviewProfile $prof -Paths @('src/**')).Count | Should -Be 1
        (Get-AuditFile -Root $script:Repo -ReviewProfile $prof -IncludeTests).Path | Should -Contain 'test/api.test.ts'
    }

    It 'writes a plan that reads back and reports measured cost only after a chunk is done' {
        $null = New-Item -ItemType Directory -Force (Join-Path $script:Repo '.review-kit/runs')
        $chunks = @(Split-AuditChunk -Files @([pscustomobject]@{ Path = 'a.ts'; Lines = 100 }, [pscustomobject]@{ Path = 'b/c.ts'; Lines = 900 }) -MaxLines 800)
        Write-AuditPlan -Root $script:Repo -Plan ([ordered]@{ head = 'x'; chunks = $chunks })
        $plan = Read-AuditPlan -Root $script:Repo
        @($plan.chunks).Count | Should -Be 2
        (Format-AuditPlan -Plan $plan)[-1] | Should -Match 'no measured cost'
        $plan.chunks[0].Status = 'done'; $plan.chunks[0].Tokens = 50000; $plan.chunks[0].Findings = 1
        $text = Format-AuditPlan -Plan $plan
        $text[-1] | Should -Match 'tokens per line over 1 done chunk'
        $text[-2] | Should -Match 'done 1; left 1 chunks'
    }
}

Describe 'Audit: prompt' {
    It 'asks for defects in existing code, lists files with sizes and adds the reads to the call budget' {
        $target = [pscustomobject]@{ Root = 'C:\repo'; Head = 'a' * 40; From = 'a' * 40; WorkTree = $true; DiffArgs = @() }
        $size = [pscustomobject]@{ Files = @([pscustomobject]@{ Path = 'src/a.ts'; Bucket = 'prod'; Added = 120; Deleted = 0 }, [pscustomobject]@{ Path = 'src/b.ts'; Bucket = 'prod'; Added = 80; Deleted = 0 }) }
        $prof = [pscustomobject]@{ notes = ''; conventions = @(); counterparts = @() }
        $p = Format-FinderPrompt -Target $target -Size $size -ReviewProfile $prof -Level medium -Lens correctness -Mode audit
        $p | Should -Not -Match '\{\{'
        $p | Should -Match 'There is no diff'
        $p | Should -Match 'however long it has been there'
        $p | Should -Match 'src/a\.ts \(120 lines\)'
        $p | Should -Match 'At most 22 tool calls'
        $p | Should -Not -Match 'git -C .* diff'
    }
}
