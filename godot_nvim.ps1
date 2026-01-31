Start-Transcript -Path "$env:TEMP\godot_nvim_log.txt" -Append

# Parse arguments from Godot
[string]$ScriptFile = $args[0]
[string]$Line = $args[1]
[string]$Col = $args[2]

# Helper function to find the Godot project root
function Get-GodotProjectRoot {
    param([string]$filePath)

    # Start from the file's directory
    $currentDir = Split-Path -Parent $filePath

    # Walk up the directory tree looking for project.godot
    while ($currentDir -and $currentDir -ne "/" -and $currentDir -ne "") {
        $projectFile = Join-Path $currentDir "project.godot"
        $checkCmd = "wsl -e bash -c `"test -f '$projectFile' && echo 'found' || echo 'notfound'`""
        $result = Invoke-Expression $checkCmd 2>$null

        if ($result -match "found") {
            return $currentDir
        }

        $currentDir = Split-Path -Parent $currentDir
    }

    # Fallback: use the file's parent directory
    return Split-Path -Parent $filePath
}

function Get-ProjectName {
    param([string]$projectPath)
    return Split-Path -Leaf $projectPath
}

function Get-ServerPort {
    param([string]$projectPath)

    # Generate a stable port number from the project path
    # Use a simple hash to map project path to port range 55555-56555
    $hash = 0
    foreach ($char in $projectPath.ToCharArray()) {
        $hash = ($hash * 31 + [int]$char) % 1000
    }

    return 55555 + $hash
}

# Helper function to check if nvim server is responsive
function Wait-ForNvimServer {
    param(
        [string]$server,
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

# Detect Godot project root and generate unique identifiers
$projectRoot = Get-GodotProjectRoot -filePath $wslPath
$projectName = Get-ProjectName -projectPath $projectRoot
$serverPort = Get-ServerPort -projectPath $projectRoot
$serverAddress = "127.0.0.1:$serverPort"
$tmuxSessionName = "nvim_server_$projectName"

Write-Host "Project: $projectName"
Write-Host "Server: $serverAddress"
Write-Host "Tmux session: $tmuxSessionName"

# Default fallback
if (-not $Line) { $Line = 1 }
if (-not $Col) { $Col = 1 }

# Check if the nvim headless server is running for THIS project
$headlessRunning = wsl -e bash -c "pgrep -f 'nvim --listen $serverAddress'" 2>$null

if (-not $headlessRunning) {
    Write-Host "Starting headless nvim server for project '$projectName' at $serverAddress..."
    wsl -d Ubuntu -- tmux new-session -d -s "$tmuxSessionName" /opt/nvim-linux-x86_64/bin/nvim --listen "$serverAddress" --headless

    # Wait for nvim to start listening
    $maxWait = 10  # seconds
    $elapsed = 0
    do {
        Start-Sleep -Milliseconds 250
        $elapsed += 0.25
        Write-Host -NoNewline "."
        $headlessRunning = wsl -e bash -c "pgrep -f 'nvim --listen $serverAddress'" 2>$null
    } while (-not $headlessRunning -and $elapsed -lt $maxWait)
    Write-Host "."

    if ($elapsed -gt $maxWait) {
        # quit if timeout
        Write-Host "Timeout starting nvim --listen $serverAddress"
        exit 1
    }

    # Wait for server to be responsive
    if (-not (Wait-ForNvimServer -server "$serverAddress" -timeoutSeconds 5)) {
        Write-Error "Neovim server not responding after timeout."
        exit 1
    }
}

# Create a project-specific wrapper script
$wrapperScript = "/tmp/godot-nvim-client-$projectName.sh"
Write-Host "Creating wrapper script at $wrapperScript..."

# Use printf to create the script (avoids heredoc issues with PowerShell)
# Each line is passed as a separate argument to printf, avoiding newline handling problems
$createCmd = "printf '%s\n' '#!/usr/bin/env zsh' '[ -f ~/.zprofile ] && source ~/.zprofile' '[ -f ~/.zshrc ] && source ~/.zshrc' 'exec nvim --server $serverAddress --remote-ui' > '$wrapperScript' && chmod +x '$wrapperScript'"

wsl -e bash -c $createCmd

# Verify the script was created successfully
$scriptExists = wsl -e bash -c "test -f '$wrapperScript' && echo 'exists' || echo 'missing'"
if ($scriptExists -notmatch "exists") {
    Write-Error "Failed to create wrapper script at $wrapperScript"
    Write-Error "This might be a WSL permission issue or /tmp directory problem"
    exit 1
}

Write-Host "Wrapper script created successfully at $wrapperScript"

# Check if nvim UI client is connected to THIS project's server
$nvimClientRunning = wsl -e bash -c "pgrep -f 'nvim.*--server.*$serverAddress.*--remote-ui'" 2>$null

# Check if Windows Terminal is running
$terminalRunning = Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue

if (-not $nvimClientRunning) {
    $titleArg = "gd:$projectName"

    # Nvim client is not running, need to start it
    if (-not $terminalRunning) {
        Write-Host "Starting Windows Terminal with nvim client for '$projectName'..."
        Start-Process "wt.exe" -ArgumentList "-p", "Ubuntu", "--title", $titleArg, "--", "wsl", "-d", "Ubuntu", "zsh", "-l", "$wrapperScript"
    } else {
        Write-Host "Opening new tab in Terminal for '$projectName'..."
        Start-Process "wt.exe" -ArgumentList "-w", "0", "new-tab", "-p", "Ubuntu", "--title", $titleArg, "--", "wsl", "-d", "Ubuntu", "zsh", "-l", "$wrapperScript"
    }
} else {
    # Nvim client is already running, just bring Terminal to front
    Write-Host "Client for '$projectName' already running, bringing Terminal to front..."

    # Keep Win32 API code for SetForegroundWindow
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WinAPI {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

    $terminalProc = $terminalRunning | Select-Object -First 1
    [WinAPI]::SetForegroundWindow($terminalProc.MainWindowHandle) | Out-Null
}

# Send command to the project-specific nvim server
$remoteCmd = "<C-\><C-n>:e $wslPath<CR>:call cursor($Line,$Col)<CR>"
& nvim --server "$serverAddress" --remote-send $remoteCmd

Stop-Transcript
