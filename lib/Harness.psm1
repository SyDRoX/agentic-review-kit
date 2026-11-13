#Requires -Version 7.0

# Runs one headless agent step and reads its result. The only harness-specific code in the kit.
# pi: `pi -p --mode json`, prompt on stdin, JSONL events on stdout.

$script:LimitPattern = 'usage limit|rate.?limit|quota|too many requests|\b429\b|insufficient credits|usage_not_included'

function Get-PiCommand {
    <#
    .SYNOPSIS
        File and leading arguments that start pi without a shell wrapper, so stdin and stdout can be redirected.
    #>
    [CmdletBinding()]
    param()

    if ($env:ARK_PI_COMMAND) { return [pscustomobject]@{ File = $env:ARK_PI_COMMAND; Args = @() } }

    $cmd = Get-Command pi -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw 'pi not found on PATH (https://pi.dev); set ARK_PI_COMMAND to its executable' }
    if ($cmd.CommandType -eq 'Application' -and $cmd.Source -match '\.exe$') { return [pscustomobject]@{ File = $cmd.Source; Args = @() } }

    # The pi shim is a script that runs `node pi-launcher.js`; start node directly.
    $launcher = Join-Path (Split-Path $cmd.Source -Parent) 'pi-launcher.js'
    if (Test-Path -LiteralPath $launcher) { return [pscustomobject]@{ File = 'node'; Args = @("`"$launcher`"") } }
    throw "cannot start pi from $($cmd.Source): no pi-launcher.js beside it; set ARK_PI_COMMAND"
}

function ConvertFrom-PiStream {
    <#
    .SYNOPSIS
        Reduces a pi JSONL event stream to the last assistant text, the summed usage and any error.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Lines)

    $r = [ordered]@{
        Text = ''; Tokens = [long] 0; Usd = [double] 0; Provider = $null; Model = $null; Turns = 0
        StopReason = $null; Error = $null; LimitHit = $false; Settled = $false
    }
    foreach ($line in $Lines) {
        if (-not $line -or $line[0] -ne '{') { continue }
        try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }

        if ($e.type -eq 'agent_settled') { $r.Settled = $true; continue }
        if ($e.type -ne 'message_end' -or $e.message.role -ne 'assistant') { continue }

        $m = $e.message
        $r.Turns++
        if ($m.usage) {
            $r.Tokens += [long] ($m.usage.totalTokens ?? 0)
            $r.Usd += [double] ($m.usage.cost.total ?? 0)
        }
        if ($m.provider) { $r.Provider = [string] $m.provider }
        if ($m.model) { $r.Model = [string] $m.model }
        $r.StopReason = [string] $m.stopReason

        $text = (@($m.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
        if ($text) { $r.Text = $text }
        if ($m.stopReason -eq 'error' -or $m.errorMessage) { $r.Error = [string] ($m.errorMessage ?? 'provider error') }
        elseif ($text) { $r.Error = $null }
    }

    if (-not $r.Error -and -not $r.Turns) { $r.Error = 'no assistant message in the stream' }
    if ($r.Error -and $r.Error -imatch $script:LimitPattern) { $r.LimitHit = $true }
    return [pscustomobject] $r
}

function Start-AgentStep {
    <#
    .SYNOPSIS
        Starts one read-only headless step. The agent may read files and run shell commands; it has no edit or write tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $LogDirectory,
        [Parameter(Mandatory)] [string] $Name,
        [string] $Model,
        [string] $Thinking
    )

    $null = New-Item -ItemType Directory -Force -Path $LogDirectory
    $base = Join-Path $LogDirectory $Name
    [System.IO.File]::WriteAllText("$base.prompt.md", $Prompt, [System.Text.UTF8Encoding]::new($false))

    $pi = Get-PiCommand
    # No context files: the prompt names what to read, so a run does not depend on which agent instructions the machine has.
    $a = @($pi.Args) + @('-p', '--mode', 'json', '--no-session', '--no-skills', '--no-mcp', '--no-extensions', '--no-context-files',
        '--no-prompt-templates', '--tools', 'read,grep,find,ls,bash')
    if ($Model) { $a += @('--model', $Model) }
    if ($Thinking) { $a += @('--thinking', $Thinking) }

    $p = Start-Process -FilePath $pi.File -ArgumentList $a -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden `
        -RedirectStandardInput "$base.prompt.md" -RedirectStandardOutput "$base.jsonl" -RedirectStandardError "$base.err.txt"

    return [pscustomobject]@{ Name = $Name; Process = $p; OutPath = "$base.jsonl"; ErrPath = "$base.err.txt"; Started = [datetime]::UtcNow }
}

function Wait-AgentStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Step, [int] $TimeoutSec = 1800)

    $left = [Math]::Max(1, $TimeoutSec - [int] ([datetime]::UtcNow - $Step.Started).TotalSeconds)
    $done = $Step.Process.WaitForExit($left * 1000)
    if (-not $done) {
        try { Stop-Process -Id $Step.Process.Id -Force -ErrorAction Stop } catch { }
    }

    $lines = if (Test-Path -LiteralPath $Step.OutPath) { @(Get-Content -LiteralPath $Step.OutPath -Encoding utf8) } else { @() }
    $r = ConvertFrom-PiStream -Lines $lines
    $seconds = [int] ([datetime]::UtcNow - $Step.Started).TotalSeconds
    if (-not $done) { $r.Error = "timed out after $TimeoutSec s" }
    elseif ($Step.Process.ExitCode -ne 0 -and -not $r.Error) {
        $err = if (Test-Path -LiteralPath $Step.ErrPath) { (Get-Content -LiteralPath $Step.ErrPath -Raw) } else { '' }
        $r.Error = "exit $($Step.Process.ExitCode): $(([string] $err).Trim() -replace '\s+', ' ')"
        if ($r.Error -imatch $script:LimitPattern) { $r.LimitHit = $true }
    }

    $r | Add-Member -NotePropertyName Name -NotePropertyValue $Step.Name
    $r | Add-Member -NotePropertyName Seconds -NotePropertyValue $seconds
    $r | Add-Member -NotePropertyName LogPath -NotePropertyValue $Step.OutPath
    return $r
}

function Get-JsonTail {
    <#
    .SYNOPSIS
        The last JSON value of the wanted kind in a reply. Models wrap answers in prose and code fences; this ignores both.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text, [ValidateSet('array', 'object')] [string] $Kind = 'object')

    if (-not $Text) { return $null }
    $open = if ($Kind -eq 'array') { '[' } else { '{' }
    $close = if ($Kind -eq 'array') { ']' } else { '}' }

    $end = $Text.LastIndexOf($close)
    while ($end -ge 0) {
        $start = $Text.LastIndexOf($open, $end)
        while ($start -ge 0) {
            $candidate = $Text.Substring($start, $end - $start + 1)
            try {
                $v = $candidate | ConvertFrom-Json -ErrorAction Stop -NoEnumerate
                if (($Kind -eq 'array' -and $v -is [array]) -or ($Kind -eq 'object' -and $v -is [pscustomobject])) { return , $v }
            }
            catch { }
            if ($start -eq 0) { break }
            $start = $Text.LastIndexOf($open, $start - 1)
        }
        if ($end -eq 0) { break }
        $end = $Text.LastIndexOf($close, $end - 1)
    }
    return $null
}

Export-ModuleMember -Function Get-PiCommand, ConvertFrom-PiStream, Start-AgentStep, Wait-AgentStep, Get-JsonTail
