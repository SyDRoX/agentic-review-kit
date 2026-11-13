#Requires -Version 7.0

# Budget: what a run may spend, and whether the next step may start.
#
# Three layers, checked before every step:
#   plan window  - the provider's own 5-hour and weekly use, where the provider reports it
#   self-metered - a spend cap from the kit's own ledger, for providers that report nothing
#   run          - a cap on this run alone
#
# A percentage is never estimated. A provider that reports no quota is shown as "not reported".

$script:Defaults = @{
    five_h_pause = 0.80
    week_stop    = 0.70
    quiet        = @()
    run          = @{ max_usd = $null; max_tokens = $null; max_minutes = $null }
    self_metered = @{ xai = @{ five_h_usd = 5.0; week_usd = 25.0 } }
    models       = @{ finder = $null; refute = $null; thinking = $null }
    coderabbit   = @{ per_hour = 3 }
    cursor       = @{ applies_to = @() }
    allocation   = @{}
    role_takeover = $false
}

function Get-KitHome {
    if ($env:ARK_HOME) { return $env:ARK_HOME }
    return (Join-Path $HOME '.agentic-review-kit')
}

function Merge-Table {
    param([hashtable] $Base, $Over)

    $out = @{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    if ($null -eq $Over) { return $out }
    $props = if ($Over -is [hashtable]) { $Over.Keys } else { $Over.PSObject.Properties.Name }
    foreach ($k in $props) {
        # Plain assignments: an `if` used as an expression turns an empty array into null.
        $v = $null
        if ($Over -is [hashtable]) { $v = $Over[$k] } else { $v = $Over.$k }
        if ($out[$k] -is [hashtable] -and ($v -is [hashtable] -or $v -is [pscustomobject])) { $out[$k] = Merge-Table $out[$k] $v }
        elseif ($v -is [pscustomobject]) { $out[$k] = Merge-Table @{} $v }
        else { $out[$k] = $v }
    }
    return $out
}

function Get-Budget {
    <#
    .SYNOPSIS
        Defaults overlaid with budget.json from the kit home (or -Path).
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not $Path) { $Path = Join-Path (Get-KitHome) 'budget.json' }
    $b = Merge-Table $script:Defaults $null
    if (Test-Path -LiteralPath $Path) {
        $b = Merge-Table $script:Defaults (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    foreach ($k in 'five_h_pause', 'week_stop') {
        if ($b[$k] -le 0 -or $b[$k] -gt 1) { throw "budget $k must be in (0, 1], got $($b[$k])" }
    }
    foreach ($p in @($b.allocation.Keys)) {
        $rule = $b.allocation[$p]
        if ($rule -isnot [hashtable] -or (-not $rule.week_points -and -not $rule.usd)) { throw "budget allocation.$p needs week_points or usd" }
        if ($rule.week_points -and ($rule.week_points -le 0 -or $rule.week_points -gt 100)) { throw "budget allocation.$p.week_points must be in (0, 100], got $($rule.week_points)" }
        if ($rule.usd -and $rule.usd -le 0) { throw "budget allocation.$p.usd must be above 0, got $($rule.usd)" }
    }
    return $b
}

# Allocation: a share of a provider's allowance that the kit may spend in total, counted from the first gated step.
# What is spent stays spent through every 5-hour and weekly reset. Only `ark allocation reset` starts a new count.

function Get-AllocationPath { return (Join-Path (Get-KitHome) 'allocation.json') }

function Read-AllocationState {
    $out = @{}
    $path = Get-AllocationPath
    if (Test-Path -LiteralPath $path) {
        # A state file that cannot be read must stop the run: starting from zero would hand the allocation out again.
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        foreach ($p in $j.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    return $out
}

function Write-AllocationState {
    param([Parameter(Mandatory)] [hashtable] $State)

    $null = New-Item -ItemType Directory -Force -Path (Get-KitHome)
    $path = Get-AllocationPath
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Step-Allocation {
    <#
    .SYNOPSIS
        The allocation count after one more weekly reading. Pure. Readings are fractions of the weekly allowance.
        Inside one week the rise since the previous reading is added. After a weekly reset the whole new reading is
        added, so the count never falls. Use between the last reading and the reset was not seen and is not counted.
    #>
    [CmdletBinding()]
    param($State, [Parameter(Mandatory)] [double] $Week, $WeekReset, [datetime] $Now = (Get-Date))

    $iso = { param($d) if ($d) { ([datetime] $d).ToUniversalTime().ToString('o') } else { $null } }
    if (-not $State) {
        return [pscustomobject]@{ kind = 'points'; started = (& $iso $Now); baseline = $Week; last = $Week; reset = (& $iso $WeekReset); consumed = [double] 0; resets = 0 }
    }
    $rolled = if ($State.reset -and $WeekReset) { (([datetime] $WeekReset).ToUniversalTime() - ([datetime] $State.reset).ToUniversalTime()).TotalHours -gt 1 }
    else { $Week -lt [double] $State.last }
    $add = if ($rolled) { $Week } else { [Math]::Max([double] 0, $Week - [double] $State.last) }
    return [pscustomobject]@{
        kind = 'points'; started = $State.started; baseline = $State.baseline; last = $Week
        reset = $(if ($WeekReset) { & $iso $WeekReset } else { $State.reset })
        consumed = [Math]::Round([double] $State.consumed + $add, 4); resets = [int] $State.resets + [int] [bool] $rolled
    }
}

function Get-AllocationStatus {
    <#
    .SYNOPSIS
        How much of a provider's allocation is spent, or null when the budget sets none. Records the reading unless
        -ReadOnly. A points allocation needs a reported weekly percentage: without one Known is false.
    #>
    [CmdletBinding()]
    param([string] $Provider, [Parameter(Mandatory)] [hashtable] $Budget, $Usage, [datetime] $Now = (Get-Date), [switch] $ReadOnly)

    if (-not $Provider -or -not $Budget.allocation -or -not $Budget.allocation[$Provider]) { return $null }
    $rule = $Budget.allocation[$Provider]
    $all = Read-AllocationState
    $st = $all[$Provider]

    if ($rule.week_points) {
        $limit = [double] $rule.week_points / 100
        if ($st -and $st.kind -ne 'points') { $st = $null }
        if (-not $Usage -or -not $Usage.Known -or $null -eq $Usage.Week) {
            return [pscustomobject]@{ Provider = $Provider; Kind = 'points'; Known = $false; Limit = $limit; Consumed = $(if ($st) { [double] $st.consumed } else { $null }); Started = $st.started; Resets = $st.resets }
        }
        $st = Step-Allocation -State $st -Week $Usage.Week -WeekReset $Usage.WeekReset -Now $Now
        if (-not $ReadOnly) { $all[$Provider] = $st; Write-AllocationState $all }
        return [pscustomobject]@{ Provider = $Provider; Kind = 'points'; Known = $true; Limit = $limit; Consumed = [double] $st.consumed; Started = $st.started; Resets = $st.resets }
    }

    # A spend allocation is counted from the kit's ledger, which no reset touches.
    if (-not $st -or $st.kind -ne 'usd') {
        $st = [pscustomobject]@{ kind = 'usd'; started = $Now.ToUniversalTime().ToString('o') }
        if (-not $ReadOnly) { $all[$Provider] = $st; Write-AllocationState $all }
    }
    $spent = (Get-LedgerSpend -Since ([datetime] $st.started) -Provider $Provider).Usd
    return [pscustomobject]@{ Provider = $Provider; Kind = 'usd'; Known = $true; Limit = [double] $rule.usd; Consumed = $spent; Started = $st.started; Resets = 0 }
}

function Format-Allocation {
    param([Parameter(Mandatory)] $Allocation)

    $since = if ($Allocation.Started) { ' since {0:ddd d MMM HH:mm}' -f ([datetime] $Allocation.Started).ToLocalTime() } else { '' }
    if ($Allocation.Kind -eq 'usd') { return ('allocation {0:N2} of {1:N2} USD spent{2}' -f $Allocation.Consumed, $Allocation.Limit, $since) }
    if (-not $Allocation.Known) {
        $had = if ($null -ne $Allocation.Consumed) { '; last count {0:N1} points' -f ($Allocation.Consumed * 100) } else { '' }
        return ('allocation of {0:N0} points cannot be measured now: no weekly percentage reported{1}' -f ($Allocation.Limit * 100), $had)
    }
    $resets = if ($Allocation.Resets) { ", across $($Allocation.Resets) weekly reset(s)" } else { '' }
    return ('allocation {0:N1} of {1:N0} points spent{2}{3}' -f ($Allocation.Consumed * 100), ($Allocation.Limit * 100), $since, $resets)
}

function Sync-Allocation {
    <#
    .SYNOPSIS
        Reads each provider's use once more and records it, so the steps that just ended are counted before a reset can hide them.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Providers = @(), [Parameter(Mandatory)] [hashtable] $Budget)

    foreach ($p in @($Providers | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not $Budget.allocation[$p]) { continue }
        $null = Get-AllocationStatus -Provider $p -Budget $Budget -Usage (Get-ProviderUsage -Provider $p -Budget $Budget)
    }
}

function Get-ProviderOf {
    param([string] $Model)

    if ($Model -and $Model.Contains('/')) { return $Model.Split('/')[0] }
    return $null
}

function Add-LedgerEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Step, [string] $Provider, [string] $Model, [long] $Tokens, [double] $Usd, [string] $Repo, [string] $Run)

    $dir = Get-KitHome
    $null = New-Item -ItemType Directory -Force -Path $dir
    $row = [ordered]@{
        at = [datetime]::UtcNow.ToString('o'); run = $Run; step = $Step; provider = $Provider; model = $Model
        tokens = $Tokens; usd = [Math]::Round($Usd, 6); repo = $Repo
    }
    Add-Content -LiteralPath (Join-Path $dir 'ledger.jsonl') -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
}

function Get-LedgerSpend {
    <#
    .SYNOPSIS
        Sum of ledger rows since a time, optionally for one provider or one run.
    #>
    [CmdletBinding()]
    param([datetime] $Since = [datetime]::MinValue, [string] $Provider, [string] $Run)

    $path = Join-Path (Get-KitHome) 'ledger.jsonl'
    $usd = [double] 0; $tokens = [long] 0; $steps = 0
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path -Encoding utf8) {
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($Provider -and $e.provider -ne $Provider) { continue }
            if ($Run -and $e.run -ne $Run) { continue }
            if (([datetime] $e.at).ToUniversalTime() -lt $Since.ToUniversalTime()) { continue }
            $usd += [double] $e.usd; $tokens += [long] $e.tokens; $steps++
        }
    }
    return [pscustomobject]@{ Usd = $usd; Tokens = $tokens; Steps = $steps }
}

function Get-CodexUsage {
    <#
    .SYNOPSIS
        5-hour and weekly use of the ChatGPT plan pi is logged in to, from the provider's own usage endpoint.
        The token goes only to chatgpt.com.
    #>
    [CmdletBinding()]
    param()

    try {
        $token = (& pi auth print-bearer-token --provider openai-codex 2>$null | Select-Object -Last 1)
        if (-not $token) { return [pscustomobject]@{ Known = $false; Error = 'pi is not logged in to openai-codex' } }

        $headers = @{ Authorization = "Bearer $token" }
        $agentDir = if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR } else { Join-Path $HOME '.pi/agent' }
        $authPath = Join-Path $agentDir 'auth.json'
        if (Test-Path -LiteralPath $authPath) {
            $acc = (Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json).'openai-codex'.accountId
            if ($acc) { $headers['ChatGPT-Account-Id'] = $acc }
        }

        $j = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -Headers $headers -TimeoutSec 20
        return ConvertFrom-CodexUsage $j
    }
    catch {
        return [pscustomobject]@{ Known = $false; Error = "usage endpoint: $($_.Exception.Message)" }
    }
}

function ConvertFrom-CodexUsage {
    param([Parameter(Mandatory)] $Json)

    $rl = $Json.rate_limit
    if (-not $rl -or -not $rl.primary_window) { return [pscustomobject]@{ Known = $false; Error = 'usage reply has no rate_limit windows' } }
    $at = { param($w) if ($w -and $w.reset_at) { [DateTimeOffset]::FromUnixTimeSeconds([long] $w.reset_at).LocalDateTime } else { $null } }
    return [pscustomobject]@{
        Known = $true; Error = $null; Plan = [string] $Json.plan_type
        FiveH = [double] $rl.primary_window.used_percent / 100; FiveHReset = (& $at $rl.primary_window)
        Week = [double] ($rl.secondary_window.used_percent ?? 0) / 100; WeekReset = (& $at $rl.secondary_window)
        LimitReached = [bool] $rl.limit_reached
    }
}

function Get-CursorAuthPath {
    <#
    .SYNOPSIS
        Where the Cursor Agent CLI keeps its credentials, by the same rule the CLI uses: a per-user config folder named
        after the product. Returns null when the CLI is not installed or has never logged in.
    #>
    [CmdletBinding()]
    param()

    $installed = (Get-Command agent, cursor-agent -ErrorAction SilentlyContinue | Select-Object -First 1) -or
        ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'cursor-agent')))
    if (-not $installed) { return $null }

    $path = if ($IsWindows) {
        $roaming = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData/Roaming' }
        Join-Path $roaming 'Cursor/auth.json'
    }
    elseif ($IsMacOS) { Join-Path $HOME '.cursor/auth.json' }
    else { Join-Path $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }) 'cursor/auth.json' }
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return $null
}

function ConvertFrom-CursorUsage {
    <#
    .SYNOPSIS
        Reads a GetSandUsageStatus reply. One billing period, no 5-hour window. A field the reply does not carry stays
        unknown: a missing percentage is never read as zero.
    #>
    param([Parameter(Mandatory)] $Json)

    $has = { param($n) $Json.PSObject.Properties.Name -contains $n }
    if (-not (& $has 'usagePercent') -or $null -eq $Json.usagePercent) {
        return [pscustomobject]@{ Known = $false; Error = 'the reply carries no usagePercent' }
    }
    $when = { param($n) if ((& $has $n) -and $Json.$n) { ([datetimeoffset] $Json.$n).LocalDateTime } else { $null } }
    $start = & $when 'currentPeriodStart'
    $reset = & $when 'nextResetTimestampUtc'
    return [pscustomobject]@{
        Known = $true; Error = $null
        Plan = $(if (& $has 'cursorPlanName') { [string] $Json.cursorPlanName } else { $null })
        Brand = $(if (& $has 'billingBrand') { [string] $Json.billingBrand } else { $null })
        Unified = $(if (& $has 'isUnified') { [bool] $Json.isUnified } else { $null })
        FiveH = $null; FiveHReset = $null
        Week = [double] $Json.usagePercent / 100; WeekReset = $reset; PeriodStart = $start
        PeriodDays = $(if ($start -and $reset) { [Math]::Round(($reset - $start).TotalDays, 1) } else { $null })
        LimitReached = $(if (& $has 'hasAvailableUsage') { -not [bool] $Json.hasAvailableUsage } else { $false })
    }
}

function Get-CursorUsage {
    <#
    .SYNOPSIS
        Use of the subscription pool the Cursor Agent CLI is logged in to, from the usage call the CLI itself makes.
        The call is not a documented interface and can change with any CLI release. It runs no model.
        The token is read into memory and sent only to api2.cursor.sh. A rejected token is reported, never refreshed.
    #>
    [CmdletBinding()]
    param()

    $path = Get-CursorAuthPath
    if (-not $path) { return [pscustomobject]@{ Known = $false; Error = 'Cursor Agent CLI is not installed or not logged in' } }
    try {
        $token = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).accessToken
        if (-not $token) { return [pscustomobject]@{ Known = $false; Error = 'no access token in the Cursor credential file' } }
        $headers = @{ Authorization = "Bearer $token"; 'Connect-Protocol-Version' = '1' }
        $j = Invoke-RestMethod -Method Post -Uri 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus' -Headers $headers `
            -ContentType 'application/json' -Body '{}' -TimeoutSec 20
        return ConvertFrom-CursorUsage $j
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        $why = if ($status -in 401, 403) { "the Cursor login was rejected ($status); log in again with the Cursor Agent CLI" } else { "usage call failed: $($_.Exception.Message)" }
        return [pscustomobject]@{ Known = $false; Error = $why }
    }
}

function Get-ProviderUsage {
    <#
    .SYNOPSIS
        What is known about a provider's remaining plan allowance.
        openai-codex reports percentages. Others report none, so the kit meters its own spend against a cap.
    #>
    [CmdletBinding()]
    param([string] $Provider, [Parameter(Mandatory)] [hashtable] $Budget, [datetime] $Now = (Get-Date))

    if ($Provider -eq 'openai-codex') {
        $u = Get-CodexUsage
        $u | Add-Member -NotePropertyName Provider -NotePropertyValue $Provider
        $u | Add-Member -NotePropertyName Source -NotePropertyValue 'provider'
        return $u
    }

    # The Cursor pool is a quota for another route only when the budget file says so: the kit cannot prove that
    # two logins draw on one allowance.
    $viaCursor = $Provider -and $Provider -ne 'cursor' -and (@($Budget.cursor.applies_to) -contains $Provider)
    if ($Provider -eq 'cursor' -or $viaCursor) {
        $u = Get-CursorUsage
        $u | Add-Member -NotePropertyName Provider -NotePropertyValue $(if ($viaCursor) { "$Provider (Cursor pool)" } else { 'cursor' })
        $u | Add-Member -NotePropertyName Source -NotePropertyValue 'provider'
        return $u
    }

    $cap = if ($Provider) { $Budget.self_metered[$Provider] } else { $null }
    $five = Get-LedgerSpend -Since $Now.AddHours(-5) -Provider $Provider
    $week = Get-LedgerSpend -Since $Now.AddDays(-7) -Provider $Provider
    return [pscustomobject]@{
        Known = $false; Provider = $Provider; Source = 'ledger'; Error = $null
        FiveHUsd = $five.Usd; WeekUsd = $week.Usd
        FiveHCapUsd = $(if ($cap) { $cap.five_h_usd } else { $null }); WeekCapUsd = $(if ($cap) { $cap.week_usd } else { $null })
    }
}

function Get-GateDecision {
    <#
    .SYNOPSIS
        Whether a step may start now. Action is go, wait (until WaitUntil) or stop. Pure: all inputs are arguments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Usage,
        [Parameter(Mandatory)] [hashtable] $Budget,
        $RunSpend,
        [datetime] $RunStarted = (Get-Date),
        [datetime] $Now = (Get-Date)
    )

    $al = $Usage.Allocation
    $alText = if ($al -and $al.Known) { '; ' + (Format-Allocation $al) } else { '' }
    $decide = { param($action, $reason, $until, $kind) [pscustomobject]@{ Action = $action; Reason = $(if ($action -eq 'go') { $reason + $alText } else { $reason }); WaitUntil = $until; Kind = $kind } }
    $run = $Budget.run

    if ($RunSpend) {
        if ($run.max_usd -and $RunSpend.Usd -ge $run.max_usd) { return & $decide 'stop' ('run budget spent: {0:N2} of {1:N2} USD' -f $RunSpend.Usd, $run.max_usd) $null }
        if ($run.max_tokens -and $RunSpend.Tokens -ge $run.max_tokens) { return & $decide 'stop' "run budget spent: $($RunSpend.Tokens) of $($run.max_tokens) tokens" $null }
    }
    if ($run.max_minutes -and ($Now - $RunStarted).TotalMinutes -ge $run.max_minutes) { return & $decide 'stop' "run time spent: $($run.max_minutes) min" $null }

    foreach ($q in @($Budget.quiet | Where-Object { $_ })) {
        $a = [datetime] $q[0]; $b = [datetime] $q[1]
        if ($a -le $Now -and $Now -lt $b) { return & $decide 'wait' ('quiet window until {0:ddd HH:mm}' -f $b) $b }
    }

    if ($al) {
        # No quota reading at all means the allocation cannot be enforced, so nothing runs. A failed read falls through to the wait below.
        if (-not $al.Known -and $Usage.Source -eq 'ledger') {
            return & $decide 'stop' "$($al.Provider): $(Format-Allocation $al). Set a usd allocation, or map the provider to a pool that reports one" $null 'allocation-unknown'
        }
        if ($al.Known -and $al.Consumed -ge $al.Limit) { return & $decide 'stop' "$($al.Provider): $(Format-Allocation $al); 'ark allocation reset' starts a new count" $null 'allocation' }
    }

    if ($Usage.Known) {
        if ($Usage.Week -ge $Budget.week_stop) {
            return & $decide 'stop' ('weekly use {0:P0} is at the {1:P0} stop; resets {2:ddd HH:mm}' -f $Usage.Week, $Budget.week_stop, $Usage.WeekReset) $null
        }
        # A provider with one period and no 5-hour window: nothing to wait for inside the period.
        if ($null -eq $Usage.FiveH) {
            if ($Usage.LimitReached) { return & $decide 'stop' ('{0}: the provider reports no usage left; resets {1:ddd HH:mm}' -f $Usage.Provider, $Usage.WeekReset) $null }
            return & $decide 'go' ('period {0:P0} used; 5h window not reported by {1}' -f $Usage.Week, $Usage.Provider) $null
        }
        if ($Usage.LimitReached -or $Usage.FiveH -ge $Budget.five_h_pause) {
            $until = if ($Usage.FiveHReset) { $Usage.FiveHReset.AddMinutes(2) } else { $Now.AddMinutes(30) }
            return & $decide 'wait' ('5h use {0:P0} is at the {1:P0} pause until {2:ddd HH:mm}' -f $Usage.FiveH, $Budget.five_h_pause, $until) $until
        }
        return & $decide 'go' ('5h {0:P0}, week {1:P0}' -f $Usage.FiveH, $Usage.Week) $null
    }

    if ($Usage.Source -eq 'ledger') {
        if ($Usage.WeekCapUsd -and $Usage.WeekUsd -ge $Usage.WeekCapUsd) {
            return & $decide 'stop' ('{0}: weekly self-metered cap spent, {1:N2} of {2:N2} USD' -f $Usage.Provider, $Usage.WeekUsd, $Usage.WeekCapUsd) $null
        }
        if ($Usage.FiveHCapUsd -and $Usage.FiveHUsd -ge $Usage.FiveHCapUsd) {
            return & $decide 'wait' ('{0}: 5h self-metered cap spent, {1:N2} of {2:N2} USD' -f $Usage.Provider, $Usage.FiveHUsd, $Usage.FiveHCapUsd) $Now.AddMinutes(30)
        }
        $cap = if ($Usage.WeekCapUsd) { 'self-metered {0:N2} of {1:N2} USD this week' -f $Usage.WeekUsd, $Usage.WeekCapUsd } else { 'no cap set' }
        return & $decide 'go' "plan quota not reported by $($Usage.Provider ?? 'the default provider'); $cap" $null
    }

    # The provider reports quota but the read failed: do not spend blind.
    return & $decide 'wait' "usage unknown ($($Usage.Error)); retry in 10 min" $Now.AddMinutes(10)
}

function Wait-LimitGate {
    <#
    .SYNOPSIS
        Blocks until a step may start. Returns the last decision: go, or stop. Without -Wait a wait is returned as it is.
    #>
    [CmdletBinding()]
    param(
        [string] $Provider,
        [Parameter(Mandatory)] [hashtable] $Budget,
        [string] $Run,
        [datetime] $RunStarted = (Get-Date),
        [switch] $Wait,
        [scriptblock] $Log = { param($m) Write-Host $m }
    )

    while ($true) {
        $usage = Get-ProviderUsage -Provider $Provider -Budget $Budget
        $usage | Add-Member -NotePropertyName Allocation -NotePropertyValue (Get-AllocationStatus -Provider $Provider -Budget $Budget -Usage $usage) -Force
        $spend = if ($Run) { Get-LedgerSpend -Run $Run } else { $null }
        $d = Get-GateDecision -Usage $usage -Budget $Budget -RunSpend $spend -RunStarted $RunStarted
        if ($d.Action -ne 'wait' -or -not $Wait) { return $d }

        if (Test-Path -LiteralPath (Join-Path (Get-KitHome) 'STOP')) { return [pscustomobject]@{ Action = 'stop'; Reason = 'STOP file found'; WaitUntil = $null } }
        & $Log "budget: $($d.Reason); sleeping"
        $seconds = [Math]::Max(60, [Math]::Min(900, [int] ($d.WaitUntil - (Get-Date)).TotalSeconds))
        Start-Sleep -Seconds $seconds
    }
}

function Format-UsageLine {
    param([Parameter(Mandatory)] $Usage)

    if ($Usage.Known -and $null -eq $Usage.FiveH) {
        $used = [Math]::Round($Usage.Week * 100, 1)
        $period = if ($Usage.PeriodDays) { "$($Usage.PeriodDays)-day period" } else { 'period of unreported length' }
        return ('{0} ({1}, {2}): {3}% used, remaining 100 - {3} = {4}%; {5} resets {6:ddd d MMM HH:mm}; 5h window not reported' -f
            $Usage.Provider, ($Usage.Plan ?? 'plan not reported'), ($Usage.Brand ?? 'brand not reported'), $used, [Math]::Round(100 - $used, 1), $period, $Usage.WeekReset)
    }
    if ($Usage.Known) {
        return ('{0} ({1}): 5h {2:P0} used, resets {3:ddd HH:mm}; week {4:P0} used, resets {5:ddd HH:mm}' -f
            $Usage.Provider, $Usage.Plan, $Usage.FiveH, $Usage.FiveHReset, $Usage.Week, $Usage.WeekReset)
    }
    if ($Usage.Source -eq 'ledger') {
        $cap = if ($Usage.WeekCapUsd) { ' of {0:N2}' -f $Usage.WeekCapUsd } else { ', no cap set' }
        return ('{0}: plan quota not reported by the provider; kit ledger {1:N2} USD in 5h, {2:N2}{3} USD this week (API-equivalent)' -f
            $Usage.Provider, $Usage.FiveHUsd, $Usage.WeekUsd, $cap)
    }
    return "$($Usage.Provider): usage unknown ($($Usage.Error))"
}

Export-ModuleMember -Function Get-KitHome, Get-Budget, Get-ProviderOf, Add-LedgerEntry, Get-LedgerSpend, Get-CodexUsage, ConvertFrom-CodexUsage,
    Get-CursorAuthPath, Get-CursorUsage, ConvertFrom-CursorUsage,
    Get-ProviderUsage, Get-GateDecision, Wait-LimitGate, Format-UsageLine,
    Get-AllocationPath, Step-Allocation, Get-AllocationStatus, Format-Allocation, Sync-Allocation
