# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a PowerShell bridge script (`godot_nvim.ps1`) that integrates Godot with Neovim/Neovide on Windows with WSL. When Godot opens a file (via its external editor setting), this script:

1. Converts Windows/WSL paths to proper WSL paths
2. Starts a headless Neovim server in WSL (if not already running)
3. Launches or focuses Neovide (the Neovim GUI)
4. Sends remote commands to open the file at the specified line/column

## Architecture

### Flow
1. **Godot** → calls PowerShell script with `$ScriptFile`, `$Line`, `$Col` arguments
2. **Path Conversion** → handles both WSL UNC paths (`wsl.localhost/...`) and Windows paths (`C:/...`)
3. **Headless Server** → starts `nvim --listen 127.0.0.1:55555` in WSL via tmux (if not running)
4. **Neovide GUI** → starts or focuses existing Neovide window connected to the server
5. **Remote Command** → sends file open command to the headless server

### Key Components

**Path Handling** (godot_nvim.ps1:8-29)
- WSL UNC path pattern: `wsl.localhost/{distro}/{path}`
- Windows path pattern: `[A-Za-z]:/...` converted via `wsl wslpath -a`

**Headless Server Management** (godot_nvim.ps1:38-89)
- Checks for existing `nvim --listen 127.0.0.1:55555` process via `pgrep`
- Starts in tmux session named `nvim_server` if not running
- Includes `--cmd 'let g:neovide = 1'` for Neovide compatibility
- Waits up to 10 seconds for server startup with polling
- Validates server responsiveness with `--remote-expr "v:version"`

**Neovide Window Management** (godot_nvim.ps1:92-113)
- Checks for existing Neovide process
- Uses Win32 API `SetForegroundWindow` to focus existing window
- Connects to server at `127.0.0.1:55555`

**Remote Command Execution** (godot_nvim.ps1:116-117)
- Sends `<C-\><C-n>:e {path}<CR>:call cursor({line},{col})<CR>` to server
- Ensures normal mode, opens file, positions cursor

## Development Context

### Environment
- **Host**: Windows with PowerShell
- **WSL**: Ubuntu distribution (hardcoded as `Ubuntu` in line 43)
- **Neovim**: Located at `/opt/nvim-linux-x86_64/bin/nvim` in WSL
- **Neovide**: Windows executable (`neovide.exe`) in PATH

### Logging
All script output is logged to `$env:TEMP\godot_nvim_log.txt` via `Start-Transcript`

### Godot Integration
Configure Godot's external editor setting to call:
```
powershell.exe -File "path\to\godot_nvim.ps1" {file} {line} {col}
```

## Debugging

Check the transcript log at `%TEMP%\godot_nvim_log.txt` for:
- Path conversion results
- Server startup status
- Neovide process detection
- Remote command execution

Common issues:
- WSL distro name mismatch (currently hardcoded to `Ubuntu`)
- Neovim installation path differs from `/opt/nvim-linux-x86_64/bin/nvim`
- Server timeout if WSL is slow to start
- Port 55555 conflicts with other services
- Godot's LSP exits and disconnects with a few seconds of inactivity
- Signal connections created by Godot are not appended correctly to the file that this scripts open. This probably happens because godot appends the contents of files through a different method and not through this script, probably not fixable without recompiling the engine
