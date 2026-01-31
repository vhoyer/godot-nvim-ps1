# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.


## Common Mistakes

- pwsh is not available since we are editing this project inside a wsl, do not try to call it


## Project Overview

This is a PowerShell bridge script (`godot_nvim.ps1`) that integrates Godot with Neovim on Windows with WSL. When Godot opens a file (via its external editor setting), this script:

1. Converts Windows/WSL paths to proper WSL paths
2. Detects the Godot project root by walking up the directory tree to find `project.godot`
3. Generates project-specific identifiers (port, tmux session name) from the project path
4. Starts a per-project headless Neovim server in WSL (if not already running)
5. Opens or focuses a Windows Terminal tab with the Neovim client connected to the project server
6. Sends remote commands to open the file at the specified line/column

**Key Feature**: Each Godot project gets its own isolated Neovim server and Windows Terminal tab, allowing you to work on multiple Godot projects simultaneously without conflicts.

## Architecture

### Flow
1. **Godot** → calls PowerShell script with `$ScriptFile`, `$Line`, `$Col` arguments
2. **Path Conversion** → handles both WSL UNC paths (`wsl.localhost/...`) and Windows paths (`C:/...`)
3. **Project Detection** → walks directory tree to find `project.godot` and determine project root
4. **ID Generation** → creates unique port (55555-56555), tmux session name, and tab title per project
5. **Headless Server** → starts project-specific `nvim --listen 127.0.0.1:{port}` in tmux (if not running)
6. **Windows Terminal** → opens new tab or focuses existing tab with Neovim client connected to server
7. **Remote Command** → sends file open command to the project-specific server

### Key Components

**Project Root Detection** (godot_nvim.ps1:8-47)
- `Get-GodotProjectRoot` walks up directory tree from the opened file
- Uses direct WSL command invocation: `& wsl -e test -f $projectFile`
- Checks `$LASTEXITCODE` (0 = found, 1 = not found) for reliability
- Includes debug logging to track search progress
- Falls back to file's parent directory if `project.godot` not found

**Project Identification** (godot_nvim.ps1:42-59)
- `Get-ProjectName`: extracts directory name from project root path
- `Get-ServerPort`: generates stable port (55555-56555) via hash of project path
- Ensures consistent identifiers across script invocations for the same project

**Path Handling** (godot_nvim.ps1:84-108)
- WSL UNC path pattern: `wsl.localhost/{distro}/{path}` → `/{path}`
- Windows path pattern: `[A-Za-z]:/...` converted via `wsl wslpath -a`
- All paths normalized to Unix-style forward slashes

**Headless Server Management** (godot_nvim.ps1:124-153)
- Checks for existing `nvim --listen 127.0.0.1:{port}` process via `pgrep`
- Starts in project-specific tmux session: `nvim_server_{projectName}`
- Uses Ubuntu WSL distribution
- Polls up to 10 seconds for server startup
- Validates server responsiveness with `Wait-ForNvimServer` function

**Wrapper Script Creation** (godot_nvim.ps1:155-173)
- Creates project-specific wrapper at `/tmp/godot-nvim-client-{projectName}.sh`
- Sources user's zsh profile for proper environment
- Connects to project-specific server: `nvim --server 127.0.0.1:{port} --remote-ui`

**Windows Terminal Management** (godot_nvim.ps1:175-210)
- Checks for existing Neovim client connected to project-specific server
- Opens new Windows Terminal tab with title `gd:{projectName}`
- Uses Ubuntu profile with zsh login shell
- If client already running, uses Win32 API `SetForegroundWindow` to focus Terminal

**Remote Command Execution** (godot_nvim.ps1:212-214)
- Sends `<C-\><C-n>:e {path}<CR>:call cursor({line},{col})<CR>` to project-specific server
- Ensures normal mode, opens file, positions cursor

## Development Context

### Environment
- **Host**: Windows with PowerShell
- **WSL**: Ubuntu distribution (hardcoded in script)
- **Neovim**: Located at `/opt/nvim-linux-x86_64/bin/nvim` in WSL
- **Terminal**: Windows Terminal (`wt.exe`) with Ubuntu profile

### Multi-Project Support
Each Godot project is isolated with:
- **Unique port**: Hash-derived from project path (55555-56555 range)
- **Unique tmux session**: `nvim_server_{projectName}`
- **Unique Terminal tab**: Title shows `gd:{projectName}`
- **Project-specific wrapper**: `/tmp/godot-nvim-client-{projectName}.sh`

This allows multiple Godot projects to be open simultaneously without server conflicts.

### Logging
All script output is logged to `$env:TEMP\godot_nvim_log.txt` via `Start-Transcript`

Debug output includes:
- Directory tree walking: "Starting search from: ...", "Checking: ...", "Exit code: ..."
- Project detection: "Project: {name}", "Server: 127.0.0.1:{port}"
- Tmux session: "Tmux session: nvim_server_{projectName}"

### Godot Integration
Configure Godot's external editor setting to call:
```
powershell.exe -File "path\to\godot_nvim.ps1" {file} {line} {col}
```

## Debugging

Check the transcript log at `%TEMP%\godot_nvim_log.txt` for:
- Path conversion results
- Project root detection (directory walking with exit codes)
- Server startup status and port assignment
- Windows Terminal process detection
- Remote command execution

Common issues:
- **Wrong project detected**: Check debug output showing directory walk. Ensure `project.godot` exists at expected location.
- **Port conflicts**: Hash collision rare but possible. Check if port already in use by another process.
- **WSL distro name mismatch**: Script hardcodes `Ubuntu` distribution
- **Neovim installation path**: Script expects `/opt/nvim-linux-x86_64/bin/nvim`
- **Server timeout**: WSL startup slow, increase timeout in script
- **Multiple projects**: Each project gets separate server; verify project name in log matches expectation
- **Godot LSP issues**:
  - LSP exits and disconnects after a few seconds of inactivity
  - Signal connections created by Godot may not append correctly to opened files (Godot likely uses different method, probably not fixable without engine recompilation)

## Known Limitations

- Project detection relies on finding `project.godot` file; subprojects or non-standard structures may fail
- Port hash collision theoretically possible (1/1000 chance) for many projects
- Windows Terminal tab focus may not work reliably if Terminal is minimized
- Godot's built-in behavior for appending code (like signal connections) may conflict with external editor workflow
