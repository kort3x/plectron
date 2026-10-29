# Plectron

A pretty HTML front end for your PowerShell scripts. Point it at a folder of
`.ps1` files and every script becomes a tool with a generated form, live
output, sortable object tables and a run history.

It is a plain PowerShell module with no dependencies. It runs on Windows PowerShell 5.1
and PowerShell 7+, on Windows, macOS and Linux.

```powershell
Import-Module ./Plectron
Start-Plectron -Path ./examples
```

Plectron prints a URL and opens your browser. Press Ctrl+C to stop.

## How a script becomes a form

Plectron reads the script's `param()` block and comment-based help. It never
executes the script to do so.

| Declaration | Form field |
|---|---|
| `[string]` | text box |
| `[int]`, `[double]`, … with `[ValidateRange()]` | number with min/max |
| `[switch]`, `[bool]` | toggle |
| `[ValidateSet()]` or an enum | drop-down |
| `[ValidateSet()]` on an array | multi-select pills |
| `[string[]]` and other arrays | tag input |
| `[datetime]` | date/time picker |
| `[securestring]` | password field |
| `[pscredential]` | user name + password |
| `[ValidatePattern()]` | checked before running |
| `[Parameter(Mandatory)]` | required |
| `ParameterSetName` | switcher between parameter sets |

Literal default values are prefilled. `.SYNOPSIS`, `.DESCRIPTION`,
`.PARAMETER` and `.EXAMPLE` help is shown next to the form.

### Sidecar overrides (optional)

To customise a script's tool, put `MyTool.plectron.psd1` next to `MyTool.ps1`:

```powershell
@{
    Title    = 'Folder sizes'
    Category = 'Files'          # groups tools in the sidebar
    Icon     = 'disk'           # terminal, star, disk, network, user, gear, chart, file,
                                # cloud, shield, mail, database, clock, package, or an emoji
    Output   = 'table'          # table | text | auto: which tab to show first
    Hidden   = $false
    Parameters = @{
        Path = @{ Label = 'Folder'; Placeholder = '~/Downloads'; Order = 1 }
        Note = @{ Widget = 'textarea' }   # textarea | password | color | file | …
    }
}
```

## Running

Each run is a separate child process (`pwsh`, or `powershell.exe` for scripts
with `#requires -PSEdition Desktop`). The child sends every PowerShell stream to the
browser as it happens:

- Output objects appear in the Objects tab as a sortable, filterable table. You
  can open any row as a JSON tree, and export the table as CSV or JSON.
- Errors, warnings, verbose, debug and information messages appear in the
  console. `Write-Host` colours are kept.
- `Write-Progress` shows as live progress bars, including nested ones.
- The exit code and any terminating error decide whether a run succeeded or failed.
  Runs can be cancelled.

Scripts run without an interactive host, so `Read-Host` and other prompts fail.
Declare what you need as parameters instead.

Use `-Engine` to pick the PowerShell executable:
`Start-Plectron -Engine powershell.exe` or `-Engine /usr/local/bin/pwsh`.

## History

Runs are stored in `~/.plectron/runs/<id>/`: `meta.json` holds the parameters
and the outcome, and `events.ndjson` holds the full output. Secret values are
never written to disk; they show as `***`. You can open old runs, replay them,
or run them again with the same parameters. Only the newest `-HistoryLimit`
runs are kept (default 200).

## Security

- The server listens on `localhost` only.
- Each session gets a random token. The printed URL carries it once, and it is then
  exchanged for an HttpOnly, SameSite=Strict cookie.
- Requests with a foreign `Origin` or `Host` header are rejected. This blocks other
  websites and DNS-rebinding attacks.
- Only scripts that were discovered under `-Path` can be run.
- Secrets reach the child process through a temporary file that only the
  current user can read. The child deletes it as soon as it has read it.

## Commands

| Command | |
|---|---|
| `Start-Plectron [-Path] [-Port] [-Engine] [-HistoryPath] [-HistoryLimit] [-NoBrowser] [-PassThru]` | Start serving. `-PassThru` returns at once instead of blocking. |
| `Stop-Plectron [-Server]` | Stop one server, or all of them. Running tools are cancelled. |
| `Get-Plectron` | List the servers running in this session. |

## Development

```powershell
./tools/Check.ps1          # syntax + Windows PowerShell 5.1 compatibility (PSScriptAnalyzer)
Invoke-Pester ./tests      # unit + integration tests (Pester 5)
```

The browser smoke test drives headless Chrome against a running server on
`./examples`:

```powershell
$s = Start-Plectron ./examples -NoBrowser -PassThru
node tests/e2e/smoke.mjs $s.Url
```

Layout:

- `Plectron/Private/Discovery.ps1`: script → tool schema (AST + sidecar)
- `Plectron/RunHost/RunHost.ps1`: child-side host; streams → protocol events
- `Plectron/Private/Runner.ps1`, `History.ps1`: start, cancel and record runs
- `Plectron/Private/Server.ps1`: HTTP API, SSE, auth and static files
- `Plectron/www/`: the UI (vanilla JS modules, no build step)
