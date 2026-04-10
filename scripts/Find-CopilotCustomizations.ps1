#Requires -Version 7.0
<#
.SYNOPSIS
  Scans GitHub repositories for Copilot / AI customization files and reports adoption.
.DESCRIPTION
  For each repository in the target organization, checks for the following
  customization files (per VS Code Copilot custom instructions documentation):

    .github/copilot-instructions.md      — Main Copilot chat instructions
    AGENTS.md (root)                     — Root-level agent instructions
    AGENTS.md (subfolders)               — Subfolder agent instructions (monorepo)
    .github/instructions/*.instructions.md  — File-based workspace instructions
    .github/agents/                      — Custom agent definition files
    CLAUDE.md (root)                     — Claude Code compatibility (root)
    .claude/CLAUDE.md                    — Claude Code compatibility (.claude/)
    CLAUDE.local.md                      — Local Claude instructions
    .claude/rules/                       — Claude format rules
    .github/copilot-setup-steps.yml      — Copilot coding agent environment setup

  Uses the git tree API (one call per repo) for efficiency. Falls back to targeted
  directory/file checks for truncated trees (very large repos).

  At the end of the run a summary table is printed showing the count and percentage
  of repos that have configured each customization type.

.PARAMETER Org
  GitHub organization login name (required).
.PARAMETER RepoListFile
  Path to a JSON file previously saved by Get-OrgRepos.ps1.
  If omitted, repos are fetched automatically using -Org.
.PARAMETER IncludeArchived
  Include archived repositories (only applies when fetching repos; ignored with -RepoListFile).
.PARAMETER IncludeForks
  Include forked repositories (only applies when fetching repos; ignored with -RepoListFile).
.PARAMETER OutputFile
  Path to export per-repo results as CSV (optional).
.PARAMETER Detailed
  Print a line for each repo as it is scanned (shows which repos have customizations).
.EXAMPLE
  # Scan org directly
  .\Find-CopilotCustomizations.ps1 -Org myorg

  # Use a pre-fetched repo list (faster if running multiple times)
  .\Get-OrgRepos.ps1 -Org myorg -OutputFile repos.json
  .\Find-CopilotCustomizations.ps1 -Org myorg -RepoListFile repos.json

  # Include archived repos, save CSV, show per-repo details
  .\Find-CopilotCustomizations.ps1 -Org myorg -IncludeArchived -OutputFile results.csv -Detailed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Org,
    [string]$RepoListFile,
    [switch]$IncludeArchived,
    [switch]$IncludeForks,
    [string]$OutputFile,
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# ─── Prerequisites ────────────────────────────────────────────────────────────
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required but not found in PATH.`nInstall it from https://cli.github.com/ and run 'gh auth login'."
}

Import-Module (Join-Path $PSScriptRoot 'modules\GitHubHelper.psm1') -Force

# ─── Load or fetch repo list ─────────────────────────────────────────────────
if ($RepoListFile) {
    Write-Host "Loading repo list from: $RepoListFile" -ForegroundColor Cyan
    $repos = @(Get-Content $RepoListFile -Raw | ConvertFrom-Json)
    Write-Host "Loaded $($repos.Count) repositories" -ForegroundColor Green
}
else {
    $repos = @(Get-GitHubOrgRepos -Org $Org -IncludeArchived:$IncludeArchived -IncludeForks:$IncludeForks)
}

$total = $repos.Count
if ($total -eq 0) {
    Write-Host "No repositories to scan." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Scanning $total repositories for Copilot customizations..." -ForegroundColor Cyan
if ($Detailed) { Write-Host "" }

# ─── Scan each repo ───────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[object]]::new()
$i = 0

foreach ($repo in $repos) {
    $i++

    # Derive owner and name from full_name if available, fall back to owner.login
    $owner    = if ($repo.owner -and $repo.owner.login) { $repo.owner.login }
                else { $repo.full_name.Split('/')[0] }
    $repoName = $repo.name
    $branch   = $repo.default_branch

    Write-Progress -Activity "Scanning repositories ($i / $total)" `
                   -Status $repo.full_name `
                   -PercentComplete ([int](($i / $total) * 100))

    $check = Get-RepoCopilotCustomizations -Owner $owner -RepoName $repoName -DefaultBranch $branch
    $check['FullName'] = $repo.full_name

    $results.Add($check)

    if ($Detailed) {
        $anyFound = @($check.Keys | Where-Object { $_ -notin @('Status', 'FullName') } | Where-Object { $check[$_] -eq $true })
        $icon  = switch ($check.Status) {
            'scanned'      { if ($anyFound.Count -gt 0) { '[+]' } else { '[ ]' } }
            'empty'        { '[E]' }
            'inaccessible' { '[!]' }
            'scan_failed'  { '[X]' }
        }
        $color = switch ($check.Status) {
            'scanned'      { if ($anyFound.Count -gt 0) { 'Green' } else { 'DarkGray' } }
            default        { 'Yellow' }
        }
        $detail = if ($anyFound.Count -gt 0) { "  ← $($anyFound -join ', ')" } else { '' }
        Write-Host "  $icon $($repo.full_name)$detail" -ForegroundColor $color
    }
}

Write-Progress -Activity "Scanning repositories" -Completed

# ─── Export CSV ───────────────────────────────────────────────────────────────
if ($OutputFile) {
    $results | ForEach-Object { [PSCustomObject]$_ } |
        Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Per-repo results saved to: $OutputFile" -ForegroundColor Cyan
}

# ─── Summary calculations ─────────────────────────────────────────────────────
$scanned = @($results | Where-Object { $_.Status -eq 'scanned' })
$nScanned = $scanned.Count

# Repos that could not be scanned (empty, inaccessible, failed)
$errorRepos = @($results | Where-Object { $_.Status -ne 'scanned' })
$nErrors    = $errorRepos.Count

# Ordered map: internal key → display label
$customizationDefs = [ordered]@{
    CopilotInstructions = '.github/copilot-instructions.md'
    AgentsMdRoot        = 'AGENTS.md (root)'
    AgentsMdSubfolders  = 'AGENTS.md (subfolders)'
    InstructionsMd      = '.github/instructions/*.instructions.md'
    GitHubAgentsDir     = '.github/agents/'
    ClaudeMdRoot        = 'CLAUDE.md (root)'
    ClaudeMdFolder      = '.claude/CLAUDE.md'
    ClaudeLocalMd       = 'CLAUDE.local.md'
    ClaudeRules         = '.claude/rules/'
    CopilotSetupSteps   = '.github/copilot-setup-steps.yml'
}

function Format-PctStr ([int]$n, [int]$of) {
    if ($of -eq 0) { return '    N/A' }
    return '{0,6:0.0}%' -f ($n / $of * 100)
}

$SEP  = '─' * 68
$COL1 = 45  # label column width
$COL2 = 6   # count column width

# Pre-build format strings using double-quoted interpolation so $COL1/$COL2
# are resolved before the -f operator ever sees the string — avoids the
# PowerShell precedence issue where -f binds tighter than +.
$fmtRow  = "  {0,-$COL1} {1,$COL2}  {2}"   # label | count | pct
$fmtRow2 = "  {0,-$COL1} {1,$COL2}"         # label | count (no pct)
$fmtSub  = "    {0,-$($COL1 - 2)} {1,$COL2}" # indented sub-row

# ─── Print summary table ──────────────────────────────────────────────────────
Write-Host ""
Write-Host $SEP -ForegroundColor DarkGray
Write-Host ($fmtRow -f 'Customization', 'Repos', "% of $nScanned scanned") -ForegroundColor White
Write-Host $SEP -ForegroundColor DarkGray

foreach ($key in $customizationDefs.Keys) {
    $count  = @($scanned | Where-Object { $_[$key] -eq $true }).Count
    $label  = $customizationDefs[$key]
    $pctStr = Format-PctStr $count $nScanned
    $pctVal = if ($nScanned -gt 0) { $count / $nScanned * 100 } else { 0 }
    $color  = if ($pctVal -ge 50) { 'Green' } elseif ($pctVal -ge 10) { 'Yellow' } else { 'DarkYellow' }

    Write-Host ($fmtRow -f $label, $count, $pctStr) -ForegroundColor $color
}

Write-Host $SEP -ForegroundColor DarkGray

# Repos with ANY customization (at least one key is $true)
$nAny = @($scanned | Where-Object {
    $r = $_
    @($customizationDefs.Keys | Where-Object { $r[$_] -eq $true }).Count -gt 0
}).Count
$nNone = $nScanned - $nAny

Write-Host ($fmtRow -f 'Repos WITH any customization',    $nAny,  (Format-PctStr $nAny  $nScanned)) -ForegroundColor Cyan
Write-Host ($fmtRow -f 'Repos WITHOUT any customization', $nNone, (Format-PctStr $nNone $nScanned)) -ForegroundColor Magenta

if ($nErrors -gt 0) {
    Write-Host ""
    Write-Host ($fmtRow -f 'Repos with scan errors (excluded above)', $nErrors, (Format-PctStr $nErrors $total)) -ForegroundColor Red

    # Break down error types
    $byStatus = $errorRepos | Group-Object Status
    foreach ($g in $byStatus) {
        $statusLabel = switch ($g.Name) {
            'empty'        { 'empty (no commits)' }
            'inaccessible' { 'inaccessible (404 / auth)' }
            'scan_failed'  { 'scan failed (unexpected error)' }
            default        { $g.Name }
        }
        Write-Host ($fmtSub -f "  └ $statusLabel", $g.Count) -ForegroundColor DarkRed
    }
}

Write-Host $SEP -ForegroundColor DarkGray
Write-Host ($fmtRow2 -f 'Total repositories in scope', $total) -ForegroundColor White
Write-Host $SEP -ForegroundColor DarkGray

# ─── Duration ─────────────────────────────────────────────────────────────────
$duration = New-TimeSpan -Start $startTime -End (Get-Date)
$durationStr = if ($duration.TotalHours -ge 1) {
    '{0}h {1}m {2}s' -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
} elseif ($duration.TotalMinutes -ge 1) {
    '{0}m {1}s' -f $duration.Minutes, $duration.Seconds
} else {
    '{0}s' -f $duration.Seconds
}
Write-Host "  Completed in $durationStr" -ForegroundColor DarkGray
Write-Host ""
