# GitHub Governance Scripts

PowerShell scripts for scanning GitHub organizations. Uses the
[GitHub CLI](https://cli.github.com/) (`gh`) for all API calls with built-in
pagination, rate-limit detection, and exponential backoff.

## Prerequisites

- **PowerShell 7+** — `pwsh` must be in your PATH
- **GitHub CLI** — install from [cli.github.com](https://cli.github.com/)
- **Authentication** — run `gh auth login` and ensure your token has:
  - `repo` scope (to read repo contents)
  - `read:org` scope (to list organization repositories)

Verify your setup:

```powershell
gh auth status
```

---

## Scripts

### `Get-OrgRepos.ps1`

Lists all repositories in a GitHub organization with a summary table.
Optionally saves the list as JSON for use with `Find-CopilotCustomizations.ps1`.

```powershell
# Basic usage — displays a table of all non-archived, non-forked repos
.\Get-OrgRepos.ps1 -Org myorg

# Save repo list to JSON (recommended before running the scanner)
.\Get-OrgRepos.ps1 -Org myorg -OutputFile repos.json

# Include archived and forked repos
.\Get-OrgRepos.ps1 -Org myorg -IncludeArchived -IncludeForks -OutputFile repos.json
```

**Parameters**

| Parameter          | Required | Default   | Description                                      |
|--------------------|----------|-----------|--------------------------------------------------|
| `-Org`             | Yes      | —         | GitHub organization login name                   |
| `-OutputFile`      | No       | —         | Save repo list as JSON for the scanner           |
| `-IncludeArchived` | No       | Excluded  | Include archived repositories                    |
| `-IncludeForks`    | No       | Excluded  | Include forked repositories                      |

---

### `Find-CopilotCustomizations.ps1`

Scans every repository in the organization for Copilot and AI customization
files, then prints a summary table showing adoption numbers and percentages.

```powershell
# Scan org directly (fetches repo list automatically)
.\Find-CopilotCustomizations.ps1 -Org myorg

# Use a pre-fetched repo list (faster for repeated runs)
.\Get-OrgRepos.ps1 -Org myorg -OutputFile repos.json
.\Find-CopilotCustomizations.ps1 -Org myorg -RepoListFile repos.json

# Show per-repo progress and export results to CSV
.\Find-CopilotCustomizations.ps1 -Org myorg -Detailed -OutputFile results.csv

# Include archived repos
.\Find-CopilotCustomizations.ps1 -Org myorg -IncludeArchived
```

**Parameters**

| Parameter          | Required | Default   | Description                                           |
|--------------------|----------|-----------|-------------------------------------------------------|
| `-Org`             | Yes      | —         | GitHub organization login name                        |
| `-RepoListFile`    | No       | —         | JSON file from `Get-OrgRepos.ps1` (skips re-fetching) |
| `-IncludeArchived` | No       | Excluded  | Include archived repositories                         |
| `-IncludeForks`    | No       | Excluded  | Include forked repositories                           |
| `-OutputFile`      | No       | —         | Export per-repo results to CSV                        |
| `-Detailed`        | No       | Off       | Print a result line for every repo as it is scanned   |

**Example output**

```
────────────────────────────────────────────────────────────────────
  Customization                                 Repos  % of 62 scanned
────────────────────────────────────────────────────────────────────
  .github/copilot-instructions.md                  45   72.6%
  AGENTS.md (root)                                 23   37.1%
  AGENTS.md (subfolders)                            4    6.5%
  .github/instructions/*.instructions.md           12   19.4%
  .github/agents/                                   5    8.1%
  CLAUDE.md (root)                                  8   12.9%
  .claude/CLAUDE.md                                 3    4.8%
  CLAUDE.local.md                                   1    1.6%
  .claude/rules/                                    2    3.2%
  .github/copilot-setup-steps.yml                   7   11.3%
────────────────────────────────────────────────────────────────────
  Repos WITH any customization                     52   83.9%
  Repos WITHOUT any customization                  10   16.1%

  Repos with scan errors (excluded above)           3    4.8%
    └ empty (no commits)                            2
    └ inaccessible (404 / auth)                     1
────────────────────────────────────────────────────────────────────
  Total repositories in scope                      65
────────────────────────────────────────────────────────────────────
```

---

## Customization Files Detected

| File / Pattern                              | Description                                              |
|---------------------------------------------|----------------------------------------------------------|
| `.github/copilot-instructions.md`           | Main Copilot chat instructions (always-on)               |
| `AGENTS.md` (repo root)                     | Root-level agent instructions (multi-agent support)      |
| `AGENTS.md` (any subfolder)                 | Subfolder agent instructions for monorepos               |
| `.github/instructions/*.instructions.md`   | File-based workspace instructions with `applyTo` patterns |
| `.github/agents/` (any files)               | Custom agent / tool definition files                     |
| `CLAUDE.md` (repo root)                     | Claude Code compatibility — root file                    |
| `.claude/CLAUDE.md`                         | Claude Code compatibility — `.claude/` folder            |
| `CLAUDE.local.md`                           | Local-only Claude instructions (not committed)           |
| `.claude/rules/` (any files)                | Claude format rules directory                            |
| `.github/copilot-setup-steps.yml`           | Copilot coding agent environment setup                   |

See the [VS Code custom instructions docs](https://code.visualstudio.com/docs/copilot/customization/custom-instructions)
for full details on each file type.

---

## How Rate Limiting Is Handled

The `GitHubHelper` module (`scripts/modules/GitHubHelper.psm1`) automatically handles GitHub API rate limits:

| Scenario                        | Behaviour                                                          |
|---------------------------------|--------------------------------------------------------------------|
| **Primary rate limit** (5k/hr)  | Queries `/rate_limit` for reset time; sleeps until window resets   |
| **Secondary rate limit**        | Sleeps 60–90 s (with random jitter) per GitHub's recommendation    |
| **Transient server errors**     | Exponential backoff: 2 s → 4 s → 8 s → 16 s → 60 s, up to 5 retries |
| **404 Not Found / 409 Empty**   | Recorded as `inaccessible` / `empty`; no retry (non-recoverable)  |

---

## Module Reference — `GitHubHelper.psm1`

The shared module can be imported independently in your own scripts:

```powershell
Import-Module .\scripts\modules\GitHubHelper.psm1

# Single API call with retry/backoff
$data = Invoke-GitHubApi "repos/myorg/myrepo/contents/.github"

# All pages of a list endpoint
$repos = Get-GitHubPagedResults "orgs/myorg/repos" -QueryParams "type=all"

# Repo list with filtering
$repos = Get-GitHubOrgRepos -Org myorg -IncludeArchived

# Customization check for one repo
$check = Get-RepoCopilotCustomizations -Owner myorg -RepoName myrepo -DefaultBranch main
```
