#Requires -Version 7.0
<#
.SYNOPSIS
    Installs the ark-review skill for every agent harness found on this machine and creates the kit home.

.DESCRIPTION
    The skill is a thin launcher: it points back at this checkout, so `git pull` here updates every harness at once.
    Skill folders: ~/.agents/skills (pi, Codex and other Agent Skills hosts) and ~/.claude/skills (Claude Code).
    A skill folder this script did not write is left alone unless -Force is given.

.PARAMETER Force
    Replace an existing ark-review folder that carries no install stamp.
#>
[CmdletBinding()]
param([switch] $Force)

$ErrorActionPreference = 'Stop'
$kit = $PSScriptRoot.Replace('\', '/')
$stampName = '.agentic-review-kit.json'
$source = Join-Path $PSScriptRoot 'skills/ark-review/SKILL.md'
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()

$hosts = @(
    @{ Name = 'Agent Skills (pi, Codex)'; Dir = Join-Path $HOME '.agents/skills'; Present = (Test-Path (Join-Path $HOME '.pi')) -or (Test-Path (Join-Path $HOME '.codex')) -or (Test-Path (Join-Path $HOME '.agents')) }
    @{ Name = 'Claude Code'; Dir = Join-Path $HOME '.claude/skills'; Present = (Test-Path (Join-Path $HOME '.claude')) }
)

foreach ($h in $hosts) {
    if (-not $h.Present) { Write-Host "skip    $($h.Name): not installed"; continue }
    $target = Join-Path $h.Dir 'ark-review'
    if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath (Join-Path $target $stampName)) -and -not $Force) {
        Write-Host "skip    $target (not installed by this script; use -Force to replace)"
        continue
    }
    $null = New-Item -ItemType Directory -Force -Path $target
    $text = [System.IO.File]::ReadAllText($source).Replace('{{KIT}}', $kit)
    [System.IO.File]::WriteAllText((Join-Path $target 'SKILL.md'), $text, [System.Text.UTF8Encoding]::new($false))
    [ordered]@{ kit = $kit; version = $version; installedAt = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $target $stampName)
    Write-Host "wrote   $target"
}

$kitHome = if ($env:ARK_HOME) { $env:ARK_HOME } else { Join-Path $HOME '.agentic-review-kit' }
$null = New-Item -ItemType Directory -Force -Path $kitHome
$to = Join-Path $kitHome 'budget.json'
if (Test-Path -LiteralPath $to) { Write-Host "kept    $to" }
else { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'budget.example.json') -Destination $to; Write-Host "wrote   $to" }

Write-Host ''
Write-Host "agentic-review-kit $version installed from $kit"
Write-Host "Next: edit $kitHome/budget.json (models and limits), then run: pwsh -File `"$kit/ark.ps1`" usage"
