#Requires -Version 7.0

# Optional second finder: the CodeRabbit CLI on the same diff. Its free tier allows a few reviews per hour,
# so every call is counted in the kit ledger and skipped once the hourly allowance is used.

Import-Module (Join-Path $PSScriptRoot 'Limits.psm1')

function Get-RabbitCommand {
    $cmd = Get-Command coderabbit -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $env:LOCALAPPDATA 'Programs/coderabbit/coderabbit.exe'
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $local)) { return $local }
    return $null
}

function Get-RabbitState {
    <#
    .SYNOPSIS
        Whether a CodeRabbit review may run now: installed, signed in, and under the hourly allowance.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Budget)

    $exe = Get-RabbitCommand
    if (-not $exe) { return [pscustomobject]@{ Ready = $false; Reason = 'coderabbit CLI not installed'; Exe = $null } }

    $status = (& $exe auth status 2>&1 | Out-String)
    if ($status -match 'signed out|not (logged|signed) in') {
        return [pscustomobject]@{ Ready = $false; Reason = 'coderabbit is signed out; run `coderabbit auth login`'; Exe = $exe }
    }

    $used = (Get-LedgerSpend -Since (Get-Date).AddHours(-1) -Provider 'coderabbit').Steps
    $perHour = [int] $Budget.coderabbit.per_hour
    if ($used -ge $perHour) {
        return [pscustomobject]@{ Ready = $false; Reason = "coderabbit hourly allowance used ($used of $perHour)"; Exe = $exe }
    }
    return [pscustomobject]@{ Ready = $true; Reason = "coderabbit $used of $perHour this hour"; Exe = $exe }
}

function ConvertFrom-RabbitOutput {
    <#
    .SYNOPSIS
        Findings from `coderabbit review --agent` output. The format is not pinned by the kit: every JSON object that names
        a file and a line is taken, whatever else surrounds it.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text)

    $found = [System.Collections.Generic.List[object]]::new()
    $pick = { param($o, [string[]] $names) foreach ($n in $names) { if ($null -ne $o.$n -and "$($o.$n)" -ne '') { return $o.$n } }; return $null }

    $visit = $null
    $visit = {
        param($node)
        if ($null -eq $node) { return }
        if ($node -is [array]) { foreach ($x in $node) { & $visit $x }; return }
        if ($node -isnot [pscustomobject]) { return }

        $path = & $pick $node @('file', 'path', 'fileName', 'filename', 'filePath')
        $line = & $pick $node @('line', 'startLine', 'lineStart', 'start_line', 'endLine')
        $text = & $pick $node @('title', 'summary', 'message', 'comment', 'description')
        if ($path -is [string] -and $text -and "$line" -match '^\d+$') {
            $detail = & $pick $node @('description', 'comment', 'details', 'suggestion', 'message')
            $sev = "$(& $pick $node @('severity', 'level', 'priority'))".ToLowerInvariant()
            $found.Add([pscustomobject]@{
                    path = $path; line = [int] $line
                    severity = $(switch -Regex ($sev) { 'critical|major|high' { 'high' } 'minor|medium' { 'medium' } default { 'low' } })
                    summary = "[coderabbit] $text"; failure = $(if ($detail -and "$detail" -ne "$text") { "$detail" } else { 'see the CodeRabbit comment' })
                })
            return
        }
        foreach ($p in $node.PSObject.Properties) { & $visit $p.Value }
    }

    $whole = $null
    try { $whole = $Text | ConvertFrom-Json -ErrorAction Stop -NoEnumerate } catch { }
    if ($null -ne $whole) { & $visit $whole }
    else {
        foreach ($l in ($Text -split '\r?\n')) {
            $t = $l.Trim()
            if (-not $t -or $t[0] -notin '{', '[') { continue }
            try { & $visit ($t | ConvertFrom-Json -ErrorAction Stop -NoEnumerate) } catch { }
        }
    }
    return , $found.ToArray()
}

function Invoke-RabbitReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [string] $LogDirectory,
        [Parameter(Mandatory)] [hashtable] $Budget,
        [string] $Run,
        [int] $TimeoutSec = 900
    )

    $state = Get-RabbitState -Budget $Budget
    if (-not $state.Ready) { return [pscustomobject]@{ Ran = $false; Reason = $state.Reason; Findings = @() } }

    $null = New-Item -ItemType Directory -Force -Path $LogDirectory
    $out = Join-Path $LogDirectory 'coderabbit.out.txt'
    $err = Join-Path $LogDirectory 'coderabbit.err.txt'
    $a = @('review', '--agent', '--fresh', '--base-commit', $Target.From)
    if (-not $Target.WorkTree) { $a += '--committed' }

    $p = Start-Process -FilePath $state.Exe -ArgumentList $a -WorkingDirectory $Target.Root -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $done = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $done) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { } }

    # Counted even when it fails: the service counts the attempt too.
    Add-LedgerEntry -Step 'coderabbit' -Provider 'coderabbit' -Model 'coderabbit-cli' -Tokens 0 -Usd 0 -Repo $Target.Root -Run $Run

    if (-not $done) { return [pscustomobject]@{ Ran = $false; Reason = "coderabbit timed out after $TimeoutSec s"; Findings = @() } }
    $text = if (Test-Path -LiteralPath $out) { [string] (Get-Content -LiteralPath $out -Raw) } else { '' }
    $findings = ConvertFrom-RabbitOutput -Text $text
    $reason = "coderabbit exit $($p.ExitCode), $($findings.Count) findings, raw output in $out"
    return [pscustomobject]@{ Ran = $true; Reason = $reason; Findings = $findings }
}

Export-ModuleMember -Function Get-RabbitCommand, Get-RabbitState, ConvertFrom-RabbitOutput, Invoke-RabbitReview
