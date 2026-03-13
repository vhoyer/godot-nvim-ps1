# godot-nvim-link

A bridge script that integrates Godot's external editor with Neovim. When Godot
opens a script file, this script starts a headless Neovim server (per project,
identified by a hash of the project root path) and connects a terminal UI
client to it — or reuses an existing one — preventing duplicate tabs on rapid
invocations. To wire it up, go to **Editor > Editor Settings > Text Editor >
External** in Godot and set the following:

- **Exec Path**: the full path to the script — `godot_nvim.sh` (Linux) or `godot_nvim.ps1` (Windows/WSL)
- **Exec Flags**: `{file} {line} {col}`
