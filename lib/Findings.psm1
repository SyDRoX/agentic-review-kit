#Requires -Version 7.0

$script:FindingHeader = '^## F(\d+) (.+):(\d+)\s*$'
$script:ValidVerdicts = @('REFUTED', 'CONFIRMED', 'UNCLEAR')

function Split-FindingsLines {
    param([string] $Text)

    $crlf = $Text.Contains("`r`n")
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($Text -split '\r?\n')) { $lines.Add($l) }

    # a trailing newline yields a phantom empty last element; drop it and restore on write.
    $trailing = $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq ''
    if ($trailing) { $lines.RemoveAt($lines.Count - 1) }

    return [pscustomobject]@{ Lines = $lines; Crlf = $crlf; Trailing = $trailing }
}

function ConvertTo-PlainLine {
    param([string] $Text)

    return ([regex]::Replace([string] $Text, '[\p{Cc}\p{Zl}\p{Zp}\s]+', ' ')).Trim()
}

function Test-ContinuationLine {
    param([string] $Line)

    # a field may be hard-wrapped with no indent, so any non-field, non-heading line continues the field above.
    return $Line.Trim() -ne '' -and $Line -notmatch '^[A-Za-z][A-Za-z-]*:(\s|$)' -and $Line -notmatch '^#'
}

function Get-HeaderEnd {
    param([System.Collections.Generic.List[string]] $Lines)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $script:FindingHeader) { return $i }
    }

    return $Lines.Count
}

function Read-FindingsFile {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)] [string] $Path)

    $doc = Split-FindingsLines -Text ([System.IO.File]::ReadAllText($Path))
    $lines = $doc.Lines
    $headerEnd = Get-HeaderEnd -Lines $lines

    $head = $null; $mergeBase = $null; $baseRef = $null; $level = $null; $ticket = $null
    $refuteState = 'absent'
    for ($i = 0; $i -lt $headerEnd; $i++) {
        $l = $lines[$i]
        if ($l -match '^Head:\s*(\S+)') { $head = $Matches[1] }
        elseif ($l -match '^Merge-base:\s*(\S+)') { $mergeBase = $Matches[1] }
        elseif ($l -match '^Base-ref:\s*(\S+)') { $baseRef = $Matches[1] }
        elseif ($l -match '^Level:\s*(\S+)') { $level = $Matches[1] }
        elseif ($l -match '^Ticket:\s*(\S+)') { $ticket = $Matches[1] }
        elseif ($l -match '^Refute:\s*skipped\b') { $refuteState = 'skipped' }
        elseif ($l -match '^Refute:\s*\d+ refuted') { $refuteState = 'done' }
    }

    $findings = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $field = $null
    for ($i = $headerEnd; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($cur -and (Test-ContinuationLine $l)) {
            if ($field) { $cur[$field] = (([string] $cur[$field]) + ' ' + $l.Trim()).Trim() }
            continue
        }

        $field = $null
        if ($l -match $script:FindingHeader) {
            if ($cur) { $findings.Add([pscustomobject] $cur) }
            $p = $Matches[2]
            $repo = if ($ticket) { ($p -split '/')[0] } else { $null }
            $cur = [ordered]@{
                Id = [int] $Matches[1]; Path = $p; Line = [int] $Matches[3]; Repo = $repo
                Severity = $null; Summary = $null; Failure = $null; Refute = $null; RefuteNote = $null
            }
        }
        elseif ($cur) {
            if ($l -match '^Severity:\s*(\S+)') { $cur.Severity = $Matches[1] }
            elseif ($l -match '^Summary:\s*(.*)$') { $cur.Summary = $Matches[1]; $field = 'Summary' }
            elseif ($l -match '^Failure:\s*(.*)$') { $cur.Failure = $Matches[1]; $field = 'Failure' }
            elseif ($l -match '^Refute:\s*(REFUTED|CONFIRMED|UNCLEAR)(?:\s+-\s+(.*))?$') {
                $cur.Refute = $Matches[1]
                $cur.RefuteNote = $Matches[2]
                $field = 'RefuteNote'
            }
        }
    }
    if ($cur) { $findings.Add([pscustomobject] $cur) }

    return [pscustomobject]@{
        Head = $head; MergeBase = $mergeBase; BaseRef = $baseRef; Level = $level; Ticket = $ticket
        RefuteState = $refuteState; Findings = [pscustomobject[]] $findings.ToArray()
    }
}

function Write-FindingsLines {
    param([string] $Path, $Doc)

    $nl = if ($Doc.Crlf) { "`r`n" } else { "`n" }
    $text = ($Doc.Lines -join $nl) + $(if ($Doc.Trailing) { $nl } else { '' })

    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Set-HeaderRefuteLine {
    param($Doc, [string] $NewLine)

    $lines = $Doc.Lines
    $headerEnd = Get-HeaderEnd -Lines $lines

    $i = 0
    while ($i -lt $headerEnd) {
        if ($lines[$i] -match '^Refute:') {
            $lines.RemoveAt($i); $headerEnd--
            while ($i -lt $headerEnd -and (Test-ContinuationLine $lines[$i])) { $lines.RemoveAt($i); $headerEnd-- }
        }
        else { $i++ }
    }

    # after Level, so Head stays within the first 20 lines.
    $at = -1
    for ($i = 0; $i -lt $headerEnd; $i++) {
        if ($lines[$i] -match '^Level:') { $at = $i + 1 }
    }
    if ($at -lt 0) {
        $at = $headerEnd
        while ($at -gt 0 -and $lines[$at - 1].Trim() -eq '') { $at-- }
    }

    $lines.Insert($at, $NewLine)
}

function Set-RefuteVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Verdicts,
        [Parameter(Mandatory)] [string] $Model
    )

    $current = Read-FindingsFile -Path $Path
    $ids = @($current.Findings | ForEach-Object { $_.Id })

    $byId = @{}
    foreach ($v in $Verdicts) {
        $id = [int] $v.id
        if ($ids -notcontains $id) { throw "Verdict for unknown finding id $id" }

        $verdict = ([string] $v.verdict).Trim().ToUpperInvariant()
        if ($script:ValidVerdicts -notcontains $verdict) { throw "Unknown verdict '$($v.verdict)' for finding $id" }

        $note = ([string] $v.note) -replace '\s*[\r\n]+\s*', ' '
        $byId[$id] = @{ Verdict = $verdict; Note = $note.Trim() }
    }

    $counts = @{ REFUTED = 0; CONFIRMED = 0; UNCLEAR = 0 }
    foreach ($id in $ids) {
        if (-not $byId.ContainsKey($id)) { $byId[$id] = @{ Verdict = 'UNCLEAR'; Note = 'no verdict returned' } }
        $counts[$byId[$id].Verdict]++
    }

    $doc = Split-FindingsLines -Text ([System.IO.File]::ReadAllText($Path))
    $lines = $doc.Lines
    $out = [System.Collections.Generic.List[string]]::new()
    $headerEnd = Get-HeaderEnd -Lines $lines

    for ($i = 0; $i -lt $headerEnd; $i++) { $out.Add($lines[$i]) }

    $block = [System.Collections.Generic.List[string]]::new()
    $blockId = $null
    $flush = {
        if ($null -eq $blockId) { return }

        $end = $block.Count
        while ($end -gt 0 -and $block[$end - 1].Trim() -eq '') { $end-- }

        for ($k = 0; $k -lt $end; $k++) { $out.Add($block[$k]) }

        $r = $byId[$blockId]
        $out.Add($(if ($r.Note) { "Refute: $($r.Verdict) - $($r.Note)" } else { "Refute: $($r.Verdict)" }))

        for ($k = $end; $k -lt $block.Count; $k++) { $out.Add($block[$k]) }
    }

    $inRefute = $false
    for ($i = $headerEnd; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($inRefute -and (Test-ContinuationLine $l)) { continue }

        $inRefute = $false
        if ($l -match $script:FindingHeader) {
            & $flush
            $block = [System.Collections.Generic.List[string]]::new()
            $blockId = [int] $Matches[1]
            $block.Add($l)
        }
        elseif ($l -match '^Refute:') {
            $inRefute = $true
        }
        else {
            $block.Add($l)
        }
    }
    & $flush

    $doc.Lines = $out
    $summary = "Refute: $($counts.REFUTED) refuted, $($counts.CONFIRMED) confirmed, $($counts.UNCLEAR) unclear ($(ConvertTo-PlainLine $Model))"
    Set-HeaderRefuteLine -Doc $doc -NewLine $summary
    Write-FindingsLines -Path $Path -Doc $doc

    return $summary
}

function Set-RefuteSkipped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Reason
    )

    $doc = Split-FindingsLines -Text ([System.IO.File]::ReadAllText($Path))
    $lines = $doc.Lines
    # verdicts from an earlier refute would make a fix round skip findings this header says were never refuted.
    $i = Get-HeaderEnd -Lines $lines
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match '^Refute:') {
            $lines.RemoveAt($i)
            while ($i -lt $lines.Count -and (Test-ContinuationLine $lines[$i])) { $lines.RemoveAt($i) }
        }
        else { $i++ }
    }

    $line = "Refute: skipped ($(ConvertTo-PlainLine $Reason))"
    Set-HeaderRefuteLine -Doc $doc -NewLine $line
    Write-FindingsLines -Path $Path -Doc $doc

    return $line
}

function Get-ActionableFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings,
        [string] $Repo
    )

    foreach ($f in $Findings) {
        if ($f.Refute -eq 'REFUTED') { continue }
        if ($Repo -and $f.Repo -ne $Repo) { continue }
        $f
    }
}

Export-ModuleMember -Function Read-FindingsFile, Set-RefuteVerdict, Set-RefuteSkipped, Get-ActionableFinding
