#Requires -Version 7.0
<#
.SYNOPSIS
  Lists all repositories in a GitHub organization.
.DESCRIPTION
  Uses the GitHub CLI (gh) to retrieve repositories from a GitHub org,
  with built-in pagination, rate-limit detection, and exponential backoff.
  Results are displayed as a table and optionally saved as JSON for use
  with Find-CopilotCustomizations.ps1.
.PARAMETER Org
  GitHub organization login name (required).
.PARAMETER OutputFile
  Path to save the full repo list as JSON. Pass this file to
  Find-CopilotCustomizations.ps1 with -RepoListFile to skip re-fetching.
.PARAMETER IncludeArchived
  Include archived repositories (default: excluded).
.PARAMETER IncludeForks
  Include forked repositories (default: excluded).
.EXAMPLE
  # Basic usage
  .\Get-OrgRepos.ps1 -Org myorg

  # Save repo list for use with the customization scanner
  .\Get-OrgRepos.ps1 -Org myorg -OutputFile repos.json

  # Include archived and forked repos
  .\Get-OrgRepos.ps1 -Org myorg -IncludeArchived -IncludeForks -OutputFile repos.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Org,
    [string]$OutputFile,
    [switch]$IncludeArchived,
    [switch]$IncludeForks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# ─── Prerequisites ────────────────────────────────────────────────────────────
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required but not found in PATH.`nInstall it from https://cli.github.com/ and run 'gh auth login'."
}

Import-Module (Join-Path $PSScriptRoot 'modules\GitHubHelper.psm1') -Force

# ─── Fetch repos ─────────────────────────────────────────────────────────────
$repos = Get-GitHubOrgRepos -Org $Org -IncludeArchived:$IncludeArchived -IncludeForks:$IncludeForks

Write-Host ""
Write-Host "Found $($repos.Count) repositor$(if ($repos.Count -eq 1) {'y'} else {'ies'})" -ForegroundColor Green

if ($repos.Count -eq 0) {
    Write-Host "No repositories match the current filters." -ForegroundColor Yellow
    exit 0
}

# ─── Display table ───────────────────────────────────────────────────────────
$repos |
    Select-Object -Property `
        name,
        @{ N = 'visibility';     E = { if ($_.private) { 'private' } else { 'public' } } },
        @{ N = 'archived';       E = { $_.archived } },
        @{ N = 'fork';           E = { $_.fork } },
        @{ N = 'default_branch'; E = { $_.default_branch } },
        @{ N = 'last_push';      E = { if ($_.pushed_at) { [datetime]$_.pushed_at | Get-Date -Format 'yyyy-MM-dd' } else { 'never' } } } |
    Format-Table -AutoSize

# ─── Save JSON ───────────────────────────────────────────────────────────────
if ($OutputFile) {
    $repos | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "Repo list saved to: $OutputFile" -ForegroundColor Cyan
    Write-Host "Pass it to Find-CopilotCustomizations.ps1 with -RepoListFile '$OutputFile'" -ForegroundColor DarkCyan
}

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
