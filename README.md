# Plectron

An HTML frontend for your PowerShell modules and scripts. Add it to an
existing project and each exported command or `.ps1` script becomes a tool,
with a generated form, live output, sortable object tables and a run history.

It is a plain PowerShell module with no dependencies. It runs on Windows PowerShell 5.1
and PowerShell 7+, on Windows, macOS and Linux.

```powershell
Install-Module Plectron          # or copy the Plectron/ folder into your repo
cd ./my-project
Start-Plectron -Module ./src/MyTools.psd1
```

Plectron prints a URL and opens your browser. Press Ctrl+C to stop.

## Using Plectron in your project

Plectron fits around your project as it is. You don't move scripts into it.

**A module's commands**: every exported function or cmdlet becomes a tool:

```powershell
Start-Plectron -Module ./src/MyTools.psd1    # a module in your repo
Start-Plectron -Module MyInstalledModule     # or an installed one
```

**A folder of scripts**:

```powershell
Start-Plectron -Path ./scripts
```

**One-off forms for a few commands**, a friendlier `Show-Command`:

```powershell
Show-Plectron Invoke-Deploy
Get-Command -Module MyTools -Verb Get | Show-Plectron
```

**A project file**: put `plectron.psd1` at the root of your repo. Plain
`Start-Plectron` (or `Start-Plectron -Path <repo>`) picks it up:

```powershell
@{
    Title    = 'Contoso Ops'                 # branding
    Logo     = './assets/logo.svg'
    Accent   = '#0a7cff'
    Modules  = @('./src/ContosoOps/ContosoOps.psd1')
    Scripts  = @('./scripts')                # loose scripts can sit next to the module
    Include  = @('*')                        # wildcards on command/script names
    Exclude  = @('*-Internal*')
    Setup    = './dev/Initialize.ps1'        # runs before every tool
    Engine   = 'pwsh'                        # or powershell.exe, or a full path
    Commands = @{                            # per-tool overrides
        'Invoke-Deploy' = @{ Title = 'Deploy'; Category = 'Release'; Icon = 'package'
                             Parameters = @{ Notes = @{ Widget = 'textarea' } } }
    }
}
```

All settings are optional. Paths are relative to the project file.

**Let your module open its own UI**: export a small function such as
`Start-ContosoUI` that imports Plectron and calls `Start-Plectron -Config`.
Your users then get a UI without needing to know Plectron exists.
[`examples/ContosoOps`](examples/ContosoOps) is a complete example project that does this.

### Getting Plectron into a project

| Option | How |
|---|---|
| PowerShell Gallery | `Install-Module Plectron`. List it under `RequiredModules`, or import it only in your UI helper. |
| Copy into the repo | Copy the `Plectron/` folder (no dependencies) to e.g. `tools/Plectron`, then `Import-Module ./tools/Plectron`. |
| Git submodule | `git submodule add https://github.com/kort3x/plectron tools/plectron`, then `Import-Module ./tools/plectron/Plectron`. |

## How a command becomes a form

Plectron reads the `param()` block and comment-based help. It never executes your
code to do so. Commands are described in a separate PowerShell process that imports
your module, so your module never loads into the session that runs Plectron.
Compiled cmdlets are described from their parameter metadata.

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

Literal default values are prefilled. Help keywords describe the tool:

| Help / attribute | Effect |
|---|---|
| `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` | shown next to the form |
| `.COMPONENT Network` | category in the sidebar |
| `.ROLE Hidden` (or `Internal`) | not shown as a tool |
| `[OutputType([SomeObject])]` | opens the Objects tab first |

Overrides take precedence in this order: `Commands` in `plectron.psd1`, then a
per-script `MyTool.plectron.psd1` sidecar file, then help keywords, then type-based defaults.
Override keys are `Title`, `Category`, `Icon`, `Description`, `Output`
(`table`/`text`/`auto`), `Hidden`, and per parameter `Label`, `Widget`
(`textarea`, `password`, `color`, `file`, …), `Order` and `Placeholder`. Icons:
terminal, star, disk, network, user, gear, chart, file, cloud, shield, mail,
database, clock, package, or an emoji.

## Running

Each run is a separate child process (`pwsh`, or `powershell.exe` for scripts
with `#requires -PSEdition Desktop`). For a module command, the child runs the
project's `Setup` script, imports the module and calls the command from the
project folder. The child sends every PowerShell stream to the browser as it happens:

- Output objects appear in the Objects tab as a sortable, filterable table. You
  can open any row as a JSON tree, and export the table as CSV or JSON.
- Errors, warnings, verbose, debug and information messages appear in the
  console. `Write-Host` colours are kept.
- `Write-Progress` shows as live progress bars, including nested ones.
- The exit code and any terminating error decide whether a run succeeded or failed.
  Runs can be cancelled.

Tools run without an interactive host, so `Read-Host` and other prompts fail.
Declare what you need as parameters instead. Each run starts in a fresh
process, so it does not see logins made in your own console session.

## History

Runs are stored per project in `~/.plectron/projects/<project>/runs/<id>/`:
`meta.json` holds the parameters and the outcome, and `events.ndjson` holds the
full output. Secret values are never written to disk; they show as `***`. You can open
old runs, replay them, or run them again with the same parameters. Only the
newest `-HistoryLimit` runs are kept (default 200).

## Security

- The server listens on `localhost` only.
- Each session gets a random token. The printed URL carries it once, and it is then
  exchanged for an HttpOnly, SameSite=Strict cookie.
- Requests with a foreign `Origin` or `Host` header are rejected. This blocks other
  websites and DNS-rebinding attacks.
- Only tools in the project's catalog can be run: discovered, included, not
  excluded and not hidden.
- Secrets reach the child process through a temporary file that only the
  current user can read. The child deletes it as soon as it has read it.

## Commands

| Command | |
|---|---|
| `Start-Plectron [[-Path] <dir>] [-Module <path\|name>[]] [-Config <file>] [-Title] [-Port] [-Engine] [-HistoryPath] [-HistoryLimit] [-NoBrowser] [-PassThru]` | Start serving. `-PassThru` returns at once instead of blocking. |
| `Show-Plectron [-Command] <name\|CommandInfo>[]` | Serve just these module commands (accepts pipeline input). |
| `Stop-Plectron [-Server]` | Stop one server, or all of them. Running tools are cancelled. |
| `Get-Plectron` | List the servers running in this session. |

## Development

```powershell
./tools/Check.ps1          # syntax + Windows PowerShell 5.1 compatibility (PSScriptAnalyzer)
Invoke-Pester ./tests      # unit + integration tests (Pester 5)
```

The browser smoke test drives headless Chrome against a running server on the
example project:

```powershell
$s = Start-Plectron ./examples/ContosoOps -NoBrowser -PassThru
node tests/e2e/smoke.mjs $s.Url
```

Layout:

- `Plectron/Private/Project.ps1`: `plectron.psd1` and parameters → project
- `Plectron/Private/Catalog.ps1`: scripts + module commands → the tool catalog
- `Plectron/Private/Discovery.ps1`: param blocks, help and cmdlet metadata → tool schemas
- `Plectron/RunHost/Describe.ps1`: child-side module describer
- `Plectron/RunHost/RunHost.ps1`: child-side host; streams → protocol events
- `Plectron/Private/Runner.ps1`, `History.ps1`: start, cancel and record runs
- `Plectron/Private/Server.ps1`: HTTP API, SSE, auth and static files
- `Plectron/www/`: the UI (vanilla JS modules, no build step)

Publishing: pushing a `v*` tag runs the tests and publishes to the PowerShell
Gallery. This needs the `PSGALLERY_API_KEY` repository secret.

## License

[MIT](LICENSE)
