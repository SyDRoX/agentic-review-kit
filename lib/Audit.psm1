#Requires -Version 7.0

# Audit scope: the current code, divided by folder into chunks one finder pass can read in full.
# Independent of git history: a chunk is a list of files.

Import-Module (Join-Path $PSScriptRoot 'Scope.psm1')

$script:CodeExtension = '\.(cs|ts|tsx|js|jsx|mjs|cjs|py|sql|go|rs|java|kt|swift|c|h|cpp|hpp|shader|hlsl|compute|ps1|psm1|sh)$'

function Get-AuditFile {
    <#
    .SYNOPSIS
        Tracked source files that are the author's own code: no tests, vendor code, generated files or docs. -Paths narrows by glob.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        $ReviewProfile,
        [AllowEmptyCollection()] [string[]] $Paths = @(),
        [switch] $IncludeTests
    )

    $tests = @(if ($ReviewProfile) { $ReviewProfile.tests })
    $vendor = @(if ($ReviewProfile) { $ReviewProfile.vendor })
    $out = [System.Collections.Generic.List[object]]::new()
    # -z: paths with spaces or non-ASCII characters come through unquoted.
    $listed = (& git -C $Root -c core.quotepath=off ls-files -z) -join "`n"
    foreach ($path in ($listed -split "`0")) {
        $path = $path.Trim("`n")
        if (-not $path -or $path -notmatch $script:CodeExtension) { continue }
        if ($Paths.Count -and -not (Test-GlobMatch $path $Paths)) { continue }
        $bucket = Get-FileBucket $path $tests $vendor
        if ($bucket -ne 'prod' -and -not ($IncludeTests -and $bucket -eq 'test')) { continue }

        $full = Join-Path $Root $path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $lines = 0
        foreach ($null in [System.IO.File]::ReadLines($full)) { $lines++ }
        if ($lines -eq 0) { continue }
        $out.Add([pscustomobject]@{ Path = $path; Lines = $lines; Bucket = $bucket })
    }
    return $out.ToArray()
}

function Get-AuditPriority {
    param([Parameter(Mandatory)] [string] $Path, $ReviewProfile)

    if ($ReviewProfile -and @($ReviewProfile.contracts).Count -and (Test-GlobMatch $Path @($ReviewProfile.contracts))) { return 0 }
    if ($ReviewProfile -and @($ReviewProfile.hot).Count -and (Test-GlobMatch $Path @($ReviewProfile.hot))) { return 1 }
    return 2
}

function Split-AuditChunk {
    <#
    .SYNOPSIS
        Divides files into chunks of at most MaxLines, along the folder tree. A folder that fits is one chunk; one that does not
        is split into its subfolders; small neighbours under the same folder are joined. A file over the limit is a chunk alone.
        Pure: the same files give the same chunks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Files,   # Path, Lines
        [int] $MaxLines = 800,
        $ReviewProfile
    )

    $split = $null
    $split = {
        param([string] $prefix, [object[]] $files)

        $sum = ($files | Measure-Object Lines -Sum).Sum
        if ($sum -le $MaxLines -or $files.Count -eq 1) { return , @([pscustomobject]@{ Name = $prefix; Files = @($files); Lines = [int] $sum }) }

        $depth = if ($prefix) { $prefix.Split('/').Count } else { 0 }
        $direct = [System.Collections.Generic.List[object]]::new()
        $subs = [ordered]@{}
        foreach ($f in ($files | Sort-Object Path)) {
            $seg = $f.Path.Split('/')
            if ($seg.Count -eq $depth + 1) { $direct.Add($f); continue }
            $key = ($seg[0..$depth] -join '/')
            if (-not $subs.Contains($key)) { $subs[$key] = [System.Collections.Generic.List[object]]::new() }
            $subs[$key].Add($f)
        }

        $level = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $subs.Keys) { foreach ($c in (& $split $key $subs[$key].ToArray())) { $level.Add($c) } }
        foreach ($f in $direct) { $level.Add([pscustomobject]@{ Name = $f.Path; Files = @($f); Lines = [int] $f.Lines }) }

        # Join neighbours while they fit, so a folder of many small parts does not become many small reviews.
        $joined = [System.Collections.Generic.List[object]]::new()
        $acc = $null
        foreach ($c in $level) {
            if ($acc -and ($acc.Lines + $c.Lines) -le $MaxLines) {
                $acc = [pscustomobject]@{ Name = "$($acc.Name) + $($c.Name)"; Files = @($acc.Files) + @($c.Files); Lines = $acc.Lines + $c.Lines }
            }
            else {
                if ($acc) { $joined.Add($acc) }
                $acc = $c
            }
        }
        if ($acc) { $joined.Add($acc) }
        return , $joined.ToArray()
    }

    if (-not $Files.Count) { return @() }
    $chunks = & $split '' @($Files | Sort-Object Path)

    $n = 0
    $out = foreach ($c in $chunks) {
        $prio = ($c.Files | ForEach-Object { Get-AuditPriority $_.Path $ReviewProfile } | Measure-Object -Minimum).Minimum
        $name = if ($c.Name) { $c.Name } else { '(root)' }
        if ($name.Length -gt 90) { $name = $name.Substring(0, 87) + '...' }
        [pscustomobject]@{ Name = $name; Priority = [int] $prio; Lines = $c.Lines; Files = @($c.Files | ForEach-Object { $_.Path }) }
    }
    # Contracts first, then hot paths, then the rest; the order is the run order.
    return @($out | Sort-Object Priority, Name | ForEach-Object {
            $n++
            [pscustomobject]@{ Id = $n; Name = $_.Name; Priority = $_.Priority; Lines = $_.Lines; Files = $_.Files; Status = 'todo'
                File = $null; Findings = $null; Confirmed = $null; Unclear = $null; Refuted = $null; Tokens = $null; Head = $null; Note = $null }
        })
}

function Get-AuditPlanPath {
    param([Parameter(Mandatory)] [string] $Root)
    return (Join-Path $Root '.review-kit/runs/audit-plan.json')
}

function Read-AuditPlan {
    param([Parameter(Mandatory)] [string] $Root)

    $path = Get-AuditPlanPath $Root
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Write-AuditPlan {
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] $Plan)

    $path = Get-AuditPlanPath $Root
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Plan | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Format-AuditPlan {
    <#
    .SYNOPSIS
        The plan as lines of text: one row per chunk, then totals.
    #>
    param([Parameter(Mandatory)] $Plan)

    $label = @{ 0 = 'contract'; 1 = 'hot'; 2 = 'rest' }
    $rows = foreach ($c in $Plan.chunks) {
        $res = if ($c.Status -eq 'done') { "$($c.Findings) findings ($($c.Confirmed) confirmed, $($c.Unclear) unclear, $($c.Refuted) refuted)" } else { [string] $c.Note }
        '{0,3}  {1,-8} {2,-8} {3,5} lines {4,3} files  {5}{6}' -f $c.Id, $c.Status, $label[[int] $c.Priority], $c.Lines, @($c.Files).Count, $c.Name, $(if ($res) { "  -> $res" })
    }
    $done = @($Plan.chunks | Where-Object Status -eq 'done')
    $left = @($Plan.chunks | Where-Object Status -ne 'done')
    $tokens = ($done | Measure-Object Tokens -Sum).Sum
    $doneLines = ($done | Measure-Object Lines -Sum).Sum
    $leftLines = ($left | Measure-Object Lines -Sum).Sum
    $total = "Total: $(@($Plan.chunks).Count) chunks, $(($Plan.chunks | Measure-Object Lines -Sum).Sum) lines; done $($done.Count); left $($left.Count) chunks, $([int] $leftLines) lines"
    $rate = if ($doneLines -gt 0 -and $tokens -gt 0) {
        $perLine = $tokens / $doneLines
        'Measured: {0:N0} tokens per line over {1} done chunk(s); the rest would take about {2:N1}M tokens at that rate' -f $perLine, $done.Count, ($perLine * $leftLines / 1e6)
    }
    else { 'No chunk done yet, so there is no measured cost. Run one chunk to get a rate.' }
    return @($rows) + @('', $total, $rate)
}

Export-ModuleMember -Function Get-AuditFile, Get-AuditPriority, Split-AuditChunk, Get-AuditPlanPath, Read-AuditPlan, Write-AuditPlan, Format-AuditPlan
