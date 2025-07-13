Start-Transcript -Path "$env:TEMP\godot_nvim_log.txt" -Append

# Parse arguments from Godot
[string]$ScriptFile = $args[0]
[string]$Line = $args[1]
[string]$Col = $args[2]

$ScriptFile = $ScriptFile.Trim()

# Extract the relative WSL path from the UNC path
# E.g. \\wsl.localhost\Ubuntu\home\vhoyer\src\joe-adventure\file.gd
if ($ScriptFile -match "wsl\.localhost/([^/]+)/(.+)") {
    $distro = $matches[1]
    $path = $matches[2]
    $wslPath = "/" + $path
} elseif ($ScriptFile -like "\\wsl.localhost\*") {
    $parts = $ScriptFile -split "\\"
    $wslPath = "/" + ($parts[4..($parts.Length - 1)] -join "/")
} else {
    Write-Error "Unexpected path: $ScriptFile"
    exit 1
}

Write-Host "Converted WSL path: $wslPath"

# Default fallback
if (-not $Line) { $Line = 1 }
if (-not $Col) { $Col = 1 }


# Check if the nvim headless server is running inside WSL
$headlessRunning = wsl -e bash -c "pgrep -f 'nvim --listen 127.0.0.1:55555'" 2>$null

if (-not $headlessRunning) {
    Write-Host "Starting headless nvim server in WSL..."
    # Run the nvim headless server detached in background
    wsl -d Ubuntu -- bash -c "nohup nvim --listen 127.0.0.1:55555 --headless >/dev/null 2>&1 &"
}


# Check if Neovide is already running
$neovideRunning = Get-Process -Name "neovide" -ErrorAction SilentlyContinue

if (-not $neovideRunning) {
    # If Neovide is not running, start it
    Start-Process "neovide.exe" -ArgumentList "--server", "127.0.0.1:55555"
} else {
    # Bring existing Neovide window to front
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WinAPI {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

    $neovideProc = $neovideRunning | Select-Object -First 1
    [WinAPI]::SetForegroundWindow($neovideProc.MainWindowHandle) | Out-Null
}

# If Neovide is running, use --remote-send
$remoteCmd = "<Esc>:e $wslPath<CR>:call cursor($Line,$Col)<CR>"
& nvim --server 127.0.0.1:55555 --remote-send $remoteCmd

Stop-Transcript
