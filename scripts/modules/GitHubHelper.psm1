<#
.SYNOPSIS
  Shared GitHub API helpers: rate-limit detection, exponential backoff, and pagination.
  Requires the GitHub CLI (gh) to be installed and authenticated.
.NOTES
  Rate limiting strategy:
    - Primary rate limit (403/message contains "API rate limit exceeded"):
        Query /rate_limit to find reset epoch; wait until then + 5s buffer.
    - Secondary / anti-abuse rate limit (403 with "secondary rate limit"):
        Wait 60–90s (with jitter) per GitHub recommendations.
    - Other transient errors (5xx, unexpected):
        Exponential backoff starting at 2s, capped at 60s, max 5 retries.
    - Non-retryable (404 Not Found, 409 Empty Repo):
        Throw a tagged exception string for callers to classify.
#>

Set-StrictMode -Version Latest

# ─── Private helpers ─────────────────────────────────────────────────────────

function Invoke-GhApiRaw {
    <# Runs `gh api <endpoint>` and returns raw stdout lines + exit code. #>
    param([string]$Endpoint)
    $output   = & gh api $Endpoint 2>$null
    [PSCustomObject]@{ Lines = $output; ExitCode = $LASTEXITCODE }
}

function ConvertFrom-GhApiOutput {
    <# Joins gh api output lines and parses JSON. #>
    param([string[]]$Lines)
    $text = $Lines -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Get-PrimaryRateLimitWait {
    <#
    Queries /rate_limit endpoint to find how many seconds until the reset window.
    Returns at least 5 seconds; falls back to 65s if the endpoint is unreachable.
    #>
    $raw = Invoke-GhApiRaw 'rate_limit'
    if ($raw.ExitCode -eq 0) {
        try {
            $info     = ConvertFrom-GhApiOutput $raw.Lines
            $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            return [Math]::Max($info.rate.reset - $nowEpoch, 0) + 5
        } catch { }
    }
    return 65
}

# ─── Exported functions ───────────────────────────────────────────────────────

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
      Calls a GitHub API endpoint via gh with automatic rate-limit handling and retry.
    .PARAMETER Endpoint
      Full API path (without base URL), e.g. "repos/owner/repo/git/trees/main?recursive=1"
    .PARAMETER MaxRetries
      Maximum number of retry attempts after failures (default: 5).
    .OUTPUTS
      Parsed PSObject / array from the JSON response body.
    .EXAMPLE
      Invoke-GitHubApi "orgs/myorg/repos?per_page=100&page=1"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [int]$MaxRetries = 5
    )

    $attempt = 0
    $backoff  = 2   # seconds; doubles each non-rate-limit retry, capped at 60

    while ($attempt -le $MaxRetries) {
        $raw = Invoke-GhApiRaw $Endpoint

        if ($raw.ExitCode -eq 0) {
            return ConvertFrom-GhApiOutput $raw.Lines
        }

        # gh api outputs the HTTP response body (JSON) to stdout even on error
        $errorBody = $null
        try { $errorBody = ConvertFrom-GhApiOutput $raw.Lines } catch {}
        $msg = if ($errorBody -and $errorBody.message) { $errorBody.message } else { ($raw.Lines -join ' ') }

        if ($msg -match 'API rate limit exceeded') {
            # Primary rate limit — wait until the reset window
            $wait = Get-PrimaryRateLimitWait
            Write-Warning "  [rate-limit/primary] Waiting ${wait}s before retry $($attempt+1)/$MaxRetries..."
            Start-Sleep -Seconds $wait
        }
        elseif ($msg -match 'secondary rate limit') {
            # Secondary / anti-abuse limit — GitHub recommends >= 60s, add jitter
            $wait = 60 + (Get-Random -Minimum 0 -Maximum 30)
            Write-Warning "  [rate-limit/secondary] Waiting ${wait}s before retry $($attempt+1)/$MaxRetries..."
            Start-Sleep -Seconds $wait
        }
        elseif ($msg -match 'Not Found' -or ($errorBody -and $errorBody.status -eq '404')) {
            throw "GITHUB_NOT_FOUND: $Endpoint"
        }
        elseif ($msg -match 'Git Repository is empty' -or $msg -match '409' -or ($errorBody -and $errorBody.status -eq '409')) {
            throw "GITHUB_EMPTY_REPO: $Endpoint"
        }
        else {
            Write-Warning "  [api-error] $msg  (backoff ${backoff}s, attempt $($attempt+1)/$MaxRetries)"
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, 60)
        }

        $attempt++
    }

    throw "GitHub API call to '$Endpoint' failed after $MaxRetries retries."
}

function Get-GitHubPagedResults {
    <#
    .SYNOPSIS
      Fetches every page of a GitHub list endpoint and returns all items as one array.
    .PARAMETER BaseEndpoint
      Endpoint without pagination params, e.g. "orgs/myorg/repos"
    .PARAMETER QueryParams
      Additional query-string params (no leading ? or &), e.g. "type=all"
    .PARAMETER PageSize
      Items per page (default: 100; GitHub maximum for most endpoints).
    .OUTPUTS
      Object[] containing all items from all pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseEndpoint,
        [string]$QueryParams = '',
        [int]$PageSize = 100
    )

    $all  = [System.Collections.Generic.List[object]]::new()
    $page = 1

    do {
        $sep   = if ($BaseEndpoint -match '\?') { '&' } else { '?' }
        $query = "${BaseEndpoint}${sep}per_page=${PageSize}&page=${page}"
        if ($QueryParams) { $query += "&$QueryParams" }

        Write-Verbose "  [paginate] page $page — $query"
        $items = Invoke-GitHubApi -Endpoint $query

        if (-not $items -or $items.Count -eq 0) { break }
        $all.AddRange([object[]]$items)
        $page++
    } while ($items.Count -eq $PageSize)

    return $all.ToArray()
}

function Get-GitHubOrgRepos {
    <#
    .SYNOPSIS
      Returns all repositories for a GitHub organization.
    .PARAMETER Org
      GitHub organization login name.
    .PARAMETER IncludeArchived
      Include archived repositories (default: excluded).
    .PARAMETER IncludeForks
      Include forked repositories (default: excluded).
    .OUTPUTS
      Array of repository objects with at least: name, full_name, private, fork, archived,
      default_branch, pushed_at, owner.login.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Org,
        [switch]$IncludeArchived,
        [switch]$IncludeForks
    )

    Write-Host "  Fetching repository list for '$Org'..." -ForegroundColor Cyan
    $repos = Get-GitHubPagedResults -BaseEndpoint "orgs/$Org/repos" -QueryParams 'type=all'

    if (-not $IncludeArchived) { $repos = @($repos | Where-Object { -not $_.archived }) }
    if (-not $IncludeForks)    { $repos = @($repos | Where-Object { -not $_.fork }) }

    return $repos
}

function Get-RepoCopilotCustomizations {
    <#
    .SYNOPSIS
      Scans a single repository for Copilot / AI customization files.
    .DESCRIPTION
      Uses the git tree API (recursive=1) to retrieve all file paths in one call,
      then checks for known customization file patterns. Falls back to targeted
      directory/file checks when the tree response is truncated (very large repos).

      Status values:
        scanned      — tree checked successfully (may have 0 customizations)
        empty        — repository has no commits
        inaccessible — 404 (token lacks access or repo does not exist)
        scan_failed  — unexpected error during the scan

    .PARAMETER Owner
      Repository owner login (org or user).
    .PARAMETER RepoName
      Repository name (not full_name).
    .PARAMETER DefaultBranch
      The repo's default branch used for the tree lookup (e.g. "main").
    .OUTPUTS
      OrderedDictionary with keys: Status, CopilotInstructions, AgentsMdRoot,
      AgentsMdSubfolders, InstructionsMd, GitHubAgentsDir, ClaudeMdRoot,
      ClaudeMdFolder, ClaudeLocalMd, ClaudeRules, CopilotSetupSteps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$RepoName,
        [string]$DefaultBranch = 'main'
    )

    $r = [ordered]@{
        Status              = 'scanned'
        CopilotInstructions = $false
        AgentsMdRoot        = $false
        AgentsMdSubfolders  = $false
        InstructionsMd      = $false
        GitHubAgentsDir     = $false
        ClaudeMdRoot        = $false
        ClaudeMdFolder      = $false
        ClaudeLocalMd       = $false
        ClaudeRules         = $false
        CopilotSetupSteps   = $false
    }

    $branch = if ($DefaultBranch) { $DefaultBranch } else { 'main' }
    # URL-encode the branch name (handles slashes, spaces, etc.)
    $encodedBranch = [Uri]::EscapeDataString($branch)

    try {
        $treeResp = Invoke-GitHubApi "repos/$Owner/$RepoName/git/trees/${encodedBranch}?recursive=1"
        $paths    = @($treeResp.tree | Where-Object { $_.type -eq 'blob' } | Select-Object -ExpandProperty path)

        if ($treeResp.truncated) {
            Write-Verbose "  [truncated] $Owner/$RepoName — running targeted fallback checks"
            $paths = Get-RepoPathsFallback -Owner $Owner -RepoName $RepoName -KnownPaths $paths
        }

        $r.CopilotInstructions = '.github/copilot-instructions.md' -in $paths
        $r.AgentsMdRoot        = 'AGENTS.md' -in $paths
        $r.AgentsMdSubfolders  = [bool]@($paths | Where-Object { $_ -ne 'AGENTS.md' -and $_ -match '(^|/)AGENTS\.md$' })
        $r.InstructionsMd      = [bool]@($paths | Where-Object { $_ -match '^\.github/instructions/.*\.instructions\.md$' })
        $r.GitHubAgentsDir     = [bool]@($paths | Where-Object { $_ -match '^\.github/agents/' })
        $r.ClaudeMdRoot        = 'CLAUDE.md' -in $paths
        $r.ClaudeMdFolder      = '.claude/CLAUDE.md' -in $paths
        $r.ClaudeLocalMd       = 'CLAUDE.local.md' -in $paths
        $r.ClaudeRules         = [bool]@($paths | Where-Object { $_ -match '^\.claude/rules/' })
        $r.CopilotSetupSteps   = '.github/copilot-setup-steps.yml' -in $paths
    }
    catch {
        $msg      = $_.Exception.Message
        $r.Status = switch -Regex ($msg) {
            'GITHUB_EMPTY_REPO'  { 'empty';        break }
            'GITHUB_NOT_FOUND'   { 'inaccessible'; break }
            default              { 'scan_failed' }
        }
        Write-Verbose "  [$($r.Status)] $Owner/$RepoName — $msg"
    }

    return $r
}

# ─── Private — fallback for truncated git trees ───────────────────────────────

function Get-RepoPathsFallback {
    <#
    When the git tree response is truncated (> ~100k files or > 7 MB), we cannot
    rely on the partial tree for wildcard patterns. This function supplements the
    known paths with targeted API checks:
      1. Exact-path lookups for files with fixed locations.
      2. Directory listings for wildcard-pattern directories.
      3. One-level-deep subfolder check for AGENTS.md.
    #>
    param(
        [string]   $Owner,
        [string]   $RepoName,
        [string[]] $KnownPaths
    )

    $found = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$KnownPaths,
        [StringComparer]::OrdinalIgnoreCase
    )

    # 1. Exact-path files ─────────────────────────────────────────────────────
    foreach ($p in @(
        '.github/copilot-instructions.md',
        'AGENTS.md',
        '.github/copilot-setup-steps.yml',
        'CLAUDE.md',
        '.claude/CLAUDE.md',
        'CLAUDE.local.md'
    )) {
        if ($found.Contains($p)) { continue }
        try {
            $null = Invoke-GitHubApi "repos/$Owner/$RepoName/contents/$([Uri]::EscapeDataString($p))"
            $null = $found.Add($p)
        }
        catch { }  # GITHUB_NOT_FOUND is expected; silently skip
    }

    # 2. Wildcard directories — list one level deep ───────────────────────────
    foreach ($dir in @('.github/instructions', '.github/agents', '.claude/rules')) {
        # Skip if we already have entries under this directory from the partial tree
        if (@($found) | Where-Object { $_ -match "^$([regex]::Escape($dir))/" }) { continue }
        try {
            $items = Invoke-GitHubApi "repos/$Owner/$RepoName/contents/$dir"
            foreach ($item in $items) {
                if ($item.type -eq 'file') { $null = $found.Add($item.path) }
            }
        }
        catch { }
    }

    # 3. Subfolder AGENTS.md — check first-level directories only ─────────────
    $hasSubfolderAgents = @($found) | Where-Object { $_ -ne 'AGENTS.md' -and $_ -match '(^|/)AGENTS\.md$' }
    if (-not $hasSubfolderAgents) {
        try {
            $rootItems = Invoke-GitHubApi "repos/$Owner/$RepoName/contents/"
            foreach ($dir in ($rootItems | Where-Object { $_.type -eq 'dir' })) {
                try {
                    $null = Invoke-GitHubApi "repos/$Owner/$RepoName/contents/$($dir.path)/AGENTS.md"
                    $null = $found.Add("$($dir.path)/AGENTS.md")
                }
                catch { }
            }
        }
        catch { }
    }

    return @($found)
}

Export-ModuleMember -Function Invoke-GitHubApi, Get-GitHubPagedResults, Get-GitHubOrgRepos, Get-RepoCopilotCustomizations
