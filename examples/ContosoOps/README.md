# Contoso Ops: a module that ships a Plectron UI

An ordinary PowerShell module (`src/ContosoOps`) that also gets a web UI.
Nothing in the module depends on Plectron, except the optional
`Start-ContosoUI` helper.

```
ContosoOps/
├── plectron.psd1              # what the UI exposes: title, logo, colour, overrides
├── assets/logo.svg
├── dev/Initialize.ps1         # runs before every tool
├── scripts/                   # loose scripts sit next to the module commands
│   └── Get-EnvironmentInfo.ps1
└── src/ContosoOps/            # the module itself
    ├── ContosoOps.psd1
    ├── Public/*.ps1           # exported functions become tools
    └── Private/*.ps1          # helpers: not exported, not shown
```

## Try it

From this folder:

```powershell
Import-Module ../../Plectron   # or: Install-Module Plectron
Start-Plectron                 # picks up ./plectron.psd1
```

Or let the module start its own UI:

```powershell
Import-Module ./src/ContosoOps
Start-ContosoUI
```

## How the tools are described

- **Category:** each function's `.COMPONENT` help keyword.
- **Hidden:** `.ROLE Hidden`. That's why `Start-ContosoUI` doesn't appear as a tool.
- **Table output:** `[OutputType()]` naming an object type opens the Objects tab first.
- **Titles, icons, widgets:** `Commands` in `plectron.psd1`, which overrides help keywords.

Every run starts a fresh PowerShell process. It runs `dev/Initialize.ps1`, imports
`src/ContosoOps`, then calls the command from the project folder.
