Start-Transcript -Path "$env:TEMP\godot_nvim_log.txt" -Append

# Parse arguments from Godot
[string]$ScriptFile = $args[0]
[string]$Line = $args[1]
[string]$Col = $args[2]

# Normalize the path to be safe (replace \ with /)
$ScriptFile = $ScriptFile.Trim() -replace '\\', '/'

# Try to handle WSL UNC paths
if ($ScriptFile -match "wsl\.localhost/([^/]+)/(.+)") {
    $distro = $matches[1]
    $path = $matches[2]
    $wslPath = "/" + $path
}
# Handle local Windows paths (e.g., C:/Users/...)
elseif ($ScriptFile -match "^[A-Za-z]:/") {
    try {
        $wslPath = wsl wslpath -a "$ScriptFile"
    } catch {
        Write-Error "Failed to convert Windows path: $ScriptFile"
        exit 1
    }
}
else {
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
    # wsl -d Ubuntu -- bash -c "nohup setsid /opt/nvim-linux-x86_64/bin//nvim --listen 127.0.0.1:55555 --headless >/dev/null 2>&1 < /dev/null &"
    wsl -d Ubuntu -- tmux new-session -d -s nvim_server /opt/nvim-linux-x86_64/bin/nvim --listen 127.0.0.1:55555 --headless --cmd 'let g:neovide = 1'

    # Wait for nvim to start listening
    $maxWait = 10  # seconds
    $elapsed = 0
    do {
        Start-Sleep -Milliseconds 250
        $elapsed += 0.25
        Write-Host -NoNewline "."
        $headlessRunning = wsl -e bash -c "pgrep -f 'nvim --listen 127.0.0.1:55555'" 2>$null
    } while (-not $headlessRunning -and $elapsed -lt $maxWait)
    Write-Host "."

    if ($elapsed -gt $maxWait) {
        # quit if timeout
        Write-Host "Timeout starting nvim --listen"
        exit 1
    }

    function Wait-ForNvimServer {
        param(
            [string]$server = "127.0.0.1:55555",
            [int]$timeoutSeconds = 5
        )

        $start = Get-Date
        while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds($timeoutSeconds)) {
            try {
                # Try to run a simple command remotely (e.g., get version)
                $result = & nvim --server $server --headless --remote-expr "v:version" 2>$null
                if ($result -match '^\d+$') {
                    return $true
                }
            } catch {
                # ignore errors, just retry
            }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }

    # Usage:
    if (-not (Wait-ForNvimServer -server "127.0.0.1:55555" -timeoutSeconds 5)) {
        Write-Error "Neovim server not responding after timeout."
            exit 1
    }
}


# Check if Neovide is already running
$neovideRunning = Get-Process -Name "neovide" -ErrorAction SilentlyContinue

if (-not $neovideRunning) {
    Write-Host "Starting Neovide..."
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

# Send command to nvim
$remoteCmd = "<Esc>:e $wslPath<CR>:call cursor($Line,$Col)<CR>"
& nvim --server 127.0.0.1:55555 --remote-send $remoteCmd

Stop-Transcript
