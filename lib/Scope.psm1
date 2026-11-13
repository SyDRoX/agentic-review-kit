#Requires -Version 7.0

# What is reviewed (a commit range or the working tree), how big it is, and how hard to look.

$script:Bands = @('low', 'medium', 'high', 'xhigh', 'max')

function Invoke-Git {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string[]] $GitArgs, [switch] $AllowFail)

    $out = & git -C $Repo @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFail) { return $null }
        throw "git $($GitArgs -join ' ') failed in $Repo"
    }
    return $out
}

function ConvertTo-GlobRegex {
    param([Parameter(Mandatory)] [string] $Glob)

    $g = $Glob.Replace('\', '/')
    $rx = [regex]::Escape($g).Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    return "^$rx$"
}

function Test-GlobMatch {
    param([Parameter(Mandatory)] [string] $Path, [AllowEmptyCollection()] [string[]] $Globs)

    $p = $Path.Replace('\', '/')
    foreach ($g in $Globs) {
        if ($g -and $p -imatch (ConvertTo-GlobRegex $g)) { return $true }
    }
    return $false
}

function Get-DefaultBase {
    param([Parameter(Mandatory)] [string] $Repo)

    $ref = Invoke-Git $Repo @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD') -AllowFail
    if ($ref) { return ([string] $ref).Trim() }
    foreach ($c in 'origin/main', 'origin/master', 'main', 'master') {
        if (Invoke-Git $Repo @('rev-parse', '--verify', '-q', $c) -AllowFail) { return $c }
    }
    throw "no base branch found in $Repo; pass -Base"
}

function Resolve-ReviewTarget {
    <#
    .SYNOPSIS
        Resolves what to review. Without -Head the working tree is reviewed, uncommitted edits included.
        -Since is the head of the previous review: when it is still an ancestor of the head, the range
        starts there, so a second review reads only what changed since the first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [string] $Base,
        [string] $Head,
        [string] $Since
    )

    $root = ([string] (Invoke-Git $Repo @('rev-parse', '--show-toplevel'))).Trim()
    $headSha = ([string] (Invoke-Git $root @('rev-parse', $(if ($Head) { $Head } else { 'HEAD' })))).Trim()
    $dirty = [bool] (Invoke-Git $root @('status', '--porcelain', '--untracked-files=no'))
    $workTree = -not $Head

    $baseRef = if ($Base) { $Base } else { Get-DefaultBase $root }
    $from = Invoke-Git $root @('merge-base', $baseRef, $headSha) -AllowFail
    if (-not $from) { $from = Invoke-Git $root @('rev-parse', '--verify', '-q', "$baseRef^{commit}") -AllowFail }
    if (-not $from) { throw "base '$baseRef' does not resolve in $root" }
    $from = ([string] $from).Trim()

    $reason = "merge-base with $baseRef"
    if ($Since) {
        $sinceSha = Invoke-Git $root @('rev-parse', '--verify', '-q', "$Since^{commit}") -AllowFail
        if ($sinceSha) {
            $sinceSha = ([string] $sinceSha).Trim()
            # A rewritten history can leave the previous head outside this branch; then the range would be meaningless.
            & git -C $root merge-base --is-ancestor $sinceSha $headSha 2>$null
            if ($LASTEXITCODE -eq 0) {
                $from = $sinceSha
                $reason = 'head of the previous review'
            }
        }
    }

    $empty = $from -eq $headSha -and -not ($workTree -and $dirty)
    $diffArgs = if ($workTree) { @($from) } else { @($from, $headSha) }

    return [pscustomobject]@{
        Root = $root; BaseRef = $baseRef; From = $from; Head = $headSha; WorkTree = $workTree; Dirty = $dirty
        Empty = $empty; Reason = $reason; DiffArgs = $diffArgs
        Branch = ([string] (Invoke-Git $root @('branch', '--show-current') -AllowFail)).Trim()
    }
}

function Get-FileBucket {
    param([Parameter(Mandatory)] [string] $Path, [AllowEmptyCollection()] [string[]] $TestGlobs = @(), [AllowEmptyCollection()] [string[]] $VendorGlobs = @())

    $p = $Path.Replace('\', '/').ToLowerInvariant()
    # Third-party code is not the author's to fix; its size says nothing about the change.
    if ($p -match '(^|/)(node_modules|vendor|third[ _-]?party|plugins|asset packages|textmesh pro)/') { return 'generated' }
    if ($VendorGlobs.Count -and (Test-GlobMatch $Path $VendorGlobs)) { return 'generated' }
    if ($p -match '(^|/)(test|tests|__tests__|editmode|playmode)/' -or $p -match '(tests?\.cs|_test\.(py|go)|(^|/)test_[^/]+\.py|\.(test|spec)\.[jt]sx?)$') { return 'test' }
    if ($TestGlobs.Count -and (Test-GlobMatch $Path $TestGlobs)) { return 'test' }
    if ($p -match '(package-lock|packages-lock|pnpm-lock|uv\.lock)' -or $p -match '\.(lock|meta)$' -or $p -match '\.min\.(js|css)$') { return 'generated' }
    # Unity serialized assets are diffable YAML, but their size says nothing about review effort.
    if ($p -match '\.(prefab|unity|asset|mat|anim|controller|overridecontroller|physicmaterial|mixer|lighting|playable|spriteatlas|fbx|png|jpg|wav|ogg|ttf)$') { return 'generated' }
    if ($p -match '\.(md|txt)$') { return 'doc' }
    return 'prod'
}

function Get-DiffSize {
    <#
    .SYNOPSIS
        Buckets a numstat into prod / test / generated / doc. Only prod counts as size.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Numstat,
        [AllowEmptyCollection()] [string[]] $TestGlobs = @(),
        [AllowEmptyCollection()] [string[]] $VendorGlobs = @()
    )

    $s = [ordered]@{ Prod = 0; ProdFiles = 0; ProdDel = 0; Test = 0; Generated = 0; Doc = 0; Files = @() }
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Numstat) {
        if (-not $line) { continue }
        $c = $line -split "`t", 3
        if ($c.Count -lt 3) { continue }
        $path = $c[2]
        # A rename prints "old => new" or "dir/{old => new}/file"; the new name is the one that exists.
        if ($path -match '\{[^{}]* => ([^{}]*)\}') { $path = ($path -replace '\{[^{}]* => ([^{}]*)\}', '$1').Replace('//', '/') }
        elseif ($path -match ' => (.+)$') { $path = $Matches[1] }

        $binary = $c[0] -eq '-'
        $add = if ($binary) { 0 } else { [int] $c[0] }
        $del = if ($binary) { 0 } else { [int] $c[1] }
        $bucket = if ($binary) { 'generated' } else { Get-FileBucket $path $TestGlobs $VendorGlobs }
        # A large JSON file is a fixture or an export, not code.
        if ($bucket -eq 'prod' -and $path -match '\.json$' -and ($add + $del) -gt 500) { $bucket = 'generated' }

        $n = $add + $del
        switch ($bucket) {
            'prod' { $s.Prod += $n; $s.ProdFiles++; $s.ProdDel += $del }
            'test' { $s.Test += $n }
            'generated' { $s.Generated += $n }
            'doc' { $s.Doc += $n }
        }
        $files.Add([pscustomobject]@{ Path = $path; Bucket = $bucket; Added = $add; Deleted = $del })
    }
    $s.Files = $files.ToArray()
    return [pscustomobject] $s
}

function Get-EffortSignal {
    <#
    .SYNOPSIS
        Boost signals that outrank the line count: a contract surface, a dependency pin, a schema migration,
        the release path, a hot path, heavy deletion. Profile globs add the repo's own contract and hot paths.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Size, $ReviewProfile)

    $signals = [System.Collections.Generic.List[string]]::new()
    $paths = @($Size.Files | ForEach-Object { $_.Path })
    $contracts = @(if ($ReviewProfile) { $ReviewProfile.contracts })
    $hot = @(if ($ReviewProfile) { $ReviewProfile.hot })
    $hasCounterpart = [bool] ($ReviewProfile -and @($ReviewProfile.counterparts).Count)

    if ($contracts.Count -and ($paths | Where-Object { Test-GlobMatch $_ $contracts })) {
        $signals.Add($(if ($hasCounterpart) { 'cross-repo contract' } else { 'contract surface' }))
    }
    if ($paths | Where-Object { $_ -match '(^|/)(package\.json|pyproject\.toml|requirements[^/]*\.txt|manifest\.json|packages-lock\.json|wrangler\.toml)$|\.asmdef$' }) {
        $signals.Add('dependency pin')
    }
    if ($paths | Where-Object { $_ -match '(^|/)migrations?/.+\.(sql|py|ts)$' }) { $signals.Add('schema migration') }
    if ($paths | Where-Object { $_ -match '(^|/)\.github/workflows/|(^|/)(release|deploy|publish)[^/]*\.(ps1|sh|ya?ml|js|ts|py)$' }) { $signals.Add('release path') }
    if ($hot.Count -and ($Size.Files | Where-Object { $_.Bucket -eq 'prod' -and (Test-GlobMatch $_.Path $hot) })) { $signals.Add('hot path') }
    if ($Size.Prod -gt 0 -and $Size.ProdDel -gt 0.25 * $Size.Prod) { $signals.Add('deletion-heavy') }

    return $signals.ToArray()
}

function Get-EffortBand {
    <#
    .SYNOPSIS
        Highest band any trigger reaches. Within 10% of a line threshold and with no signal, the lower band wins,
        so the same diff gets the same depth on every run.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Size, [AllowEmptyCollection()] [string[]] $Signals = @())

    $prod = $Size.Prod; $files = $Size.ProdFiles
    $slack = if ($Signals.Count) { 1.0 } else { 1.1 }
    $band = if ($prod -le 50 -and $files -le 3) { 'low' }
    elseif ($prod -le 300 * $slack -and $files -le 10) { 'medium' }
    elseif ($prod -le 800 * $slack) { 'high' }
    else { 'xhigh' }

    $floor = 'low'
    foreach ($s in $Signals) {
        $need = switch ($s) {
            'cross-repo contract' { 'xhigh' }
            'dependency pin' { 'high' }
            'schema migration' { 'high' }
            'release path' { 'high' }
            'contract surface' { 'high' }
            'hot path' { 'high' }
            'deletion-heavy' { 'medium' }
            default { 'low' }
        }
        if ($script:Bands.IndexOf($need) -gt $script:Bands.IndexOf($floor)) { $floor = $need }
    }
    if ($script:Bands.IndexOf($floor) -gt $script:Bands.IndexOf($band)) { $band = $floor }
    if ($band -eq 'xhigh' -and $prod -gt 2000) { $band = 'max' }
    return $band
}

function Format-SizeLine {
    param([Parameter(Mandatory)] $Size)

    return "prod=$($Size.Prod) prodfiles=$($Size.ProdFiles) proddel=$($Size.ProdDel) test=$($Size.Test) generated=$($Size.Generated) doc=$($Size.Doc)"
}

function Step-Band {
    param([Parameter(Mandatory)] [string] $Band, [Parameter(Mandatory)] [int] $By)

    $i = [Math]::Max(0, [Math]::Min($script:Bands.Count - 1, $script:Bands.IndexOf($Band) + $By))
    return $script:Bands[$i]
}

Export-ModuleMember -Function Invoke-Git, Test-GlobMatch, Get-DefaultBase, Resolve-ReviewTarget, Get-FileBucket, Get-DiffSize,
    Get-EffortSignal, Get-EffortBand, Format-SizeLine, Step-Band
