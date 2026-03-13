#!/usr/bin/env bash

# Log file
LOG_FILE="/tmp/godot_nvim_log.txt"
exec >> "$LOG_FILE" 2>&1

NVIM_BIN="${NVIM_BIN:-/opt/nvim-linux-x86_64/bin/nvim}"

# Parse arguments from Godot
SCRIPT_FILE="$1"
LINE="${2:-1}"
COL="${3:-1}"

# Find Godot project root by walking up the directory tree
get_godot_project_root() {
    local file_path="$1"
    local current_dir
    current_dir="$(dirname "$file_path")"

    echo "Starting search from: $current_dir"

    while [[ -n "$current_dir" && "$current_dir" != "/" ]]; do
        local project_file="$current_dir/project.godot"
        echo "Checking: $project_file"

        if [[ -f "$project_file" ]]; then
            echo "  FOUND!"
            echo "$current_dir"
            return 0
        fi

        current_dir="$(dirname "$current_dir")"
    done

    echo "Not found, using fallback"
    dirname "$file_path"
}

get_project_name() {
    basename "$1"
}

get_server_port() {
    local project_path="$1"
    local hash=0
    local i char_val
    for (( i=0; i<${#project_path}; i++ )); do
        printf -v char_val '%d' "'${project_path:$i:1}"
        hash=$(( (hash * 31 + char_val) % 1000 ))
    done
    echo $(( 55555 + hash ))
}

wait_for_nvim_server() {
    local server="$1"
    local timeout="${2:-5}"
    local start now result
    start="$(date +%s)"

    while true; do
        now="$(date +%s)"
        if (( now - start >= timeout )); then
            return 1
        fi

        result="$("$NVIM_BIN" --server "$server" --headless --remote-expr "v:version" 2>/dev/null)"
        if [[ "$result" =~ ^[0-9]+$ ]]; then
            return 0
        fi

        sleep 0.2
    done
}

# Path is already a native Linux path, no conversion needed
NVIM_PATH="$SCRIPT_FILE"

echo "Path: $NVIM_PATH"

# Detect Godot project root and generate unique identifiers
PROJECT_ROOT="$(get_godot_project_root "$NVIM_PATH")"
PROJECT_NAME="$(get_project_name "$PROJECT_ROOT")"
SERVER_PORT="$(get_server_port "$PROJECT_ROOT")"
SERVER_ADDRESS="127.0.0.1:$SERVER_PORT"
TMUX_SESSION_NAME="nvim_server_$PROJECT_NAME"

echo "Project: $PROJECT_NAME"
echo "Server: $SERVER_ADDRESS"
echo "Tmux session: $TMUX_SESSION_NAME"

# Check if the nvim headless server is running for THIS project
HEADLESS_RUNNING="$(pgrep -f "nvim --listen $SERVER_ADDRESS" 2>/dev/null)"

if [[ -z "$HEADLESS_RUNNING" ]]; then
    echo "Starting headless nvim server for project '$PROJECT_NAME' at $SERVER_ADDRESS..."
    tmux new-session -d -s "$TMUX_SESSION_NAME" "$NVIM_BIN" --listen "$SERVER_ADDRESS" --headless

    # Wait for nvim to start listening (poll up to 10 seconds)
    MAX_WAIT_MS=10000
    ELAPSED_MS=0
    while [[ -z "$HEADLESS_RUNNING" && $ELAPSED_MS -lt $MAX_WAIT_MS ]]; do
        sleep 0.25
        ELAPSED_MS=$(( ELAPSED_MS + 250 ))
        printf "."
        HEADLESS_RUNNING="$(pgrep -f "nvim --listen $SERVER_ADDRESS" 2>/dev/null)"
    done
    echo "."

    if [[ $ELAPSED_MS -ge $MAX_WAIT_MS ]]; then
        echo "Timeout starting nvim --listen $SERVER_ADDRESS"
        exit 1
    fi

    if ! wait_for_nvim_server "$SERVER_ADDRESS" 5; then
        echo "Neovim server not responding after timeout."
        exit 1
    fi
fi

# Create a project-specific wrapper script
WRAPPER_SCRIPT="/tmp/godot-nvim-client-$PROJECT_NAME.sh"
echo "Creating wrapper script at $WRAPPER_SCRIPT..."

cat > "$WRAPPER_SCRIPT" << WRAPPER_EOF
#!/usr/bin/env zsh
[ -f ~/.zprofile ] && source ~/.zprofile
[ -f ~/.zshrc ] && source ~/.zshrc
# Remove title hooks registered via add-zsh-hook
add-zsh-hook -d preexec vhoyer_termsupport_preexec 2>/dev/null
add-zsh-hook -d precmd vhoyer_termsupport_precmd 2>/dev/null
printf '\033]0;gd:$PROJECT_NAME\007'
exec $NVIM_BIN --server $SERVER_ADDRESS --remote-ui
WRAPPER_EOF
chmod +x "$WRAPPER_SCRIPT"

if [[ ! -f "$WRAPPER_SCRIPT" ]]; then
    echo "Failed to create wrapper script at $WRAPPER_SCRIPT"
    exit 1
fi

echo "Wrapper script created successfully at $WRAPPER_SCRIPT"

# Lock mechanism: prevent multiple rapid invocations from opening duplicate tabs.
# mkdir is atomic on Linux, making it a reliable lock primitive.
LOCK_DIR="/tmp/godot-nvim-tab-lock-$PROJECT_NAME"

# Remove stale lock older than 30 seconds (handles crashes/unexpected exits)
find "$LOCK_DIR" -maxdepth 0 -mmin +0.5 -exec rmdir '{}' \; 2>/dev/null

if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Lock acquired for '$PROJECT_NAME'"

    # Check if nvim UI client is connected to THIS project's server
    NVIM_CLIENT_RUNNING="$(pgrep -f "nvim.*--server.*$SERVER_ADDRESS.*--remote-ui" 2>/dev/null)"

    if [[ -z "$NVIM_CLIENT_RUNNING" ]]; then
        TITLE_ARG="gd:$PROJECT_NAME"
        echo "Opening terminal with nvim client for '$PROJECT_NAME'..."

        # Try common terminal emulators
        if command -v kgx &>/dev/null; then
            kgx --title="$TITLE_ARG" -e "$WRAPPER_SCRIPT" &
        elif command -v kitty &>/dev/null; then
            kitty --title "$TITLE_ARG" "$WRAPPER_SCRIPT" &
        elif command -v alacritty &>/dev/null; then
            alacritty --title "$TITLE_ARG" -e "$WRAPPER_SCRIPT" &
        elif command -v gnome-terminal &>/dev/null; then
            gnome-terminal --title="$TITLE_ARG" -- "$WRAPPER_SCRIPT" &
        elif command -v xterm &>/dev/null; then
            xterm -title "$TITLE_ARG" -e "$WRAPPER_SCRIPT" &
        else
            echo "No supported terminal emulator found (tried: kitty, alacritty, gnome-terminal, kgx, xterm)"
            rmdir "$LOCK_DIR" 2>/dev/null
            exit 1
        fi
    else
        echo "Client for '$PROJECT_NAME' already running, bringing to front..."
        if command -v wmctrl &>/dev/null; then
            wmctrl -a "gd:$PROJECT_NAME" 2>/dev/null || true
        fi
    fi

    # Release the lock
    rmdir "$LOCK_DIR" 2>/dev/null
else
    echo "Tab open already in progress for '$PROJECT_NAME' (lock held), skipping..."
fi

# Send command to the project-specific nvim server
REMOTE_CMD="<C-\><C-n>:e $NVIM_PATH<CR>:call cursor($LINE,$COL)<CR>"
"$NVIM_BIN" --server "$SERVER_ADDRESS" --remote-send "$REMOTE_CMD"
