#!/bin/bash

# CeremonyClient Management Script
# This script automates the process of restarting ceremonyclient services,
# modifying configuration, and handling token transfers when in ring 0 or 1.

# Set up logging
LOG_FILE="/var/log/ceremonyclient_script.log"

# Function to log messages to both console and log file
log() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to handle errors
handle_error() {
    local error_message="$1"
    local exit_code="${2:-1}"  # Default exit code is 1
    log "ERROR: $error_message"
    exit "$exit_code"
}

# Function to check if a service is running
is_service_running() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name"; then
        return 0  # Service is running
    else
        return 1  # Service is not running
    fi
}

# Function to detect OS architecture and return appropriate client binary name
detect_os_arch() {
    # Detect OS
    case "$(uname -s)" in
        Linux*)     OS="linux";;
        Darwin*)    OS="darwin";;
        CYGWIN*|MINGW*|MSYS*) OS="windows";;
        *)          handle_error "Unsupported OS: $(uname -s)";;
    esac

    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) ARCH="amd64";;
        arm64|aarch64) ARCH="arm64";;
        *)          handle_error "Unsupported architecture: $arch";;
    esac

    # Set extension for Windows
    local ext=""
    if [ "$OS" = "windows" ]; then
        ext=".exe"
    fi

    echo "./qclient-2.0.4.1-${OS}-${ARCH}${ext}"
}

# Function to wait for files to be created
wait_for_files() {
    local directory="$1"
    local files=("${@:2}")
    local timeout=60  # Maximum wait time in seconds
    local interval=1  # Check interval in seconds
    local elapsed=0
    
    log "Waiting for files to be created: ${files[*]}"
    
    while [ $elapsed -lt $timeout ]; do
        local all_files_exist=true
        
        for file in "${files[@]}"; do
            if [ ! -f "$directory/$file" ]; then
                all_files_exist=false
                break
            fi
        done
        
        if $all_files_exist; then
            log "All files have been created successfully"
            return 0
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    handle_error "Timeout waiting for files to be created: ${files[*]}"
}

# Main loop to keep the script running continuously
while true; do
    # Configuration
    CLIENT_DIR="/root/ceremonyclient/node"
    CONFIG_DIR="$CLIENT_DIR/.config"
    CONFIG_FILE="$CONFIG_DIR/config.yml"
    KEYS_FILE="$CONFIG_DIR/keys.yml"
    QCLIENT=$(detect_os_arch)
    RECIPIENT="0x20cfb1c0dd85a87b62bd980996caef7884e31eda68e28e7ae78bd61f55ee250b"
    MAX_RING_CHECKS=20
    RING_CHECK_INTERVAL=70  # 70 seconds between checks
    BALANCE_CHECK_INTERVAL=180  # 3 minutes in seconds for merge completion
    INITIAL_WAIT_TIME=480  # 8 minutes in seconds

    # Main execution starts here
    log "Starting CeremonyClient management script"

    # Step 1: Stop the ceremonyclient service if it's running
    if is_service_running "ceremonyclient"; then
        log "Stopping ceremonyclient service..."
        sudo service ceremonyclient stop || handle_error "Failed to stop ceremonyclient service"
        log "CeremonyClient service stopped successfully"
    else
        log "CeremonyClient service is not running, skipping stop"
    fi

    # Step 2: Change directory and remove configuration files
    log "Changing directory to $CONFIG_DIR"
    cd "$CONFIG_DIR" || handle_error "Failed to change directory to $CONFIG_DIR"

    log "Removing configuration files"
    rm -f config.yml keys.yml
    log "Configuration files removed successfully"

    # Step 3: Start the ceremonyclient service to generate new config files
    log "Starting ceremonyclient service to generate new configuration files..."
    sudo service ceremonyclient start || handle_error "Failed to start ceremonyclient service"

    # Step 4: Wait for new configuration files to be created
    wait_for_files "$CONFIG_DIR" "config.yml" "keys.yml"
    log "New configuration files have been created"

    # Step 5: Stop the ceremonyclient service again
    log "Stopping ceremonyclient service to modify configuration..."
    sudo service ceremonyclient stop || handle_error "Failed to stop ceremonyclient service"

    # Step 6: Modify the config.yml file to enable excessive GOMAXPROCS
    log "Modifying config.yml to enable excessive GOMAXPROCS..."
    sed -i 's/allowExcessiveGOMAXPROCS: .*/allowExcessiveGOMAXPROCS: true/' "$CONFIG_FILE" || handle_error "Failed to modify config.yml"
    
    # Additional config modifications
    log "Applying additional config modifications..."
    sed -i 's|listenGrpcMultiaddr: ""|listenGrpcMultiaddr: "/ip4/127.0.0.1/tcp/8337"|' "$CONFIG_FILE" || handle_error "Failed to modify listenGrpcMultiaddr in config.yml"
    sed -i 's|listenRESTMultiaddr: ""|listenRESTMultiaddr: "/ip4/127.0.0.1/tcp/8338"|' "$CONFIG_FILE" || handle_error "Failed to modify listenRESTMultiaddr in config.yml"
    
    log "Configuration file successfully modified"

    # Step 7: Start the ceremonyclient service again
    log "Starting ceremonyclient service with modified configuration..."
    sudo service ceremonyclient start || handle_error "Failed to start ceremonyclient service"

    # Step 8: Wait for 8 minutes with countdown
    log "Starting countdown for $INITIAL_WAIT_TIME seconds..."
    
    # Simple countdown in decreasing seconds
    for ((sec=$INITIAL_WAIT_TIME; sec>0; sec--)); do
        echo -ne "Countdown: $sec seconds remaining\r"
        sleep 1
    done
    echo "" # Add a newline after countdown finishes
    log "Countdown complete, continuing with script"

    # Step 9: Check if node is in ring 0 or 1
    log "Changing directory to $CLIENT_DIR"
    cd "$CLIENT_DIR" || handle_error "Failed to change directory to $CLIENT_DIR"

    # Function to check if command was successful
    check_command() {
        if [ $? -ne 0 ]; then
            handle_error "$1 failed"
        else
            log "$1 completed successfully"
        fi
    }

    # Detect the appropriate binary based on OS and architecture
    NODE_BINARY="./node-2.0.6.3-linux-amd64"
    log "Using node binary: $NODE_BINARY"

    # Function to check the ring position
    check_ring_position() {
        # Ensure we're in the client directory
        cd "$CLIENT_DIR" || handle_error "Failed to change directory to $CLIENT_DIR"
        
        local node_info
        node_info=$("$NODE_BINARY" --node-info 2>&1)
        check_command "Getting node info"
        
        log "Node info output:"
        log "$node_info"
        
        # Extract the ring position using grep and awk
        local ring_position
        ring_position=$(echo "$node_info" | grep "Prover Ring:" | awk '{print $3}')
        
        if [[ -z "$ring_position" ]]; then
            log "Could not extract ring position from output"
            return 2
        fi
        
        log "Current ring position: $ring_position (target: 0 or 1)"
        
        # Check if ring position is 0 or 1
        if [[ "$ring_position" -eq 0 ]] || [[ "$ring_position" -eq 1 ]]; then
            log "Node is in ring $ring_position, proceeding with token operations"
            return 0
        else
            log "Node is in ring $ring_position, not in ring 0 or 1"
            return 1
        fi
    }

    in_required_ring=false
    
    log "Beginning ring position checks (will check up to $MAX_RING_CHECKS times)"
    for ((i=1; i<=MAX_RING_CHECKS; i++)); do
        log "Ring position check attempt $i of $MAX_RING_CHECKS"
        
        # Check if node is in ring 0 or 1
        if check_ring_position; then
            in_required_ring=true
            break
        elif [ $? -eq 2 ]; then
            log "Error determining ring position, will try again"
        fi
        
        if [ $i -eq $MAX_RING_CHECKS ]; then
            log "Node not in ring 0 or 1 after $MAX_RING_CHECKS attempts"
        else
            log "Node not in required ring, waiting $RING_CHECK_INTERVAL seconds before next check..."
            sleep $RING_CHECK_INTERVAL
        fi
    done

    # Step 10: Execute the token transfer script if node is in ring 0 or 1
    if $in_required_ring; then
        # Execute merge command
        log "Executing merge command..."
        "$QCLIENT" token merge all --config "$CONFIG_DIR" --public-rpc
        check_command "Token merge"

        # Wait for token merge to complete with countdown
        log "Waiting for $BALANCE_CHECK_INTERVAL seconds for merge to complete..."
        
        # Simple countdown in decreasing seconds
        for ((sec=$BALANCE_CHECK_INTERVAL; sec>0; sec--)); do
            echo -ne "Merge completion countdown: $sec seconds remaining\r"
            sleep 1
        done
        echo "" # Add a newline after countdown finishes
        log "Merge wait countdown complete, continuing with script"

        # Get coins and process all coins for transfer
        log "Getting coin addresses and balances..."
        log "Executing command: $QCLIENT token coins --config $CONFIG_DIR --public-rpc"
        COIN_OUTPUT=$("$QCLIENT" token coins --config "$CONFIG_DIR" --public-rpc 2>&1)
        check_command "Getting coins"

        log "Full coin output:"
        log "$COIN_OUTPUT"
        log "----------------------------------------"

        # Extract all addresses with non-zero balances and transfer from each
        # Parse all lines containing "QUIL" to get all coin addresses
        echo "$COIN_OUTPUT" | grep "QUIL" | while read -r line; do
            # Extract coin address using alternative methods since regex may cause issues
            COIN_ADDRESS=$(echo "$line" | grep -o "Coin [^ )]*" | awk '{print $2}')
            
            # Extract balance (the first field in the line)
            BALANCE=$(echo "$line" | awk '{print $1}')
            # Remove any non-numeric characters except decimal point
            BALANCE_CLEAN=$(echo "$BALANCE" | sed 's/[^0-9.]//g')
            
            # Check if balance is greater than zero
            if (( $(echo "$BALANCE_CLEAN > 0" | bc -l) )); then
                log "Found coin address with balance: $COIN_ADDRESS (Balance: $BALANCE_CLEAN QUIL)"
                
                # Execute transfer for this address
                log "Executing transfer from address: $COIN_ADDRESS"
                log "Transfer command: $QCLIENT token transfer $RECIPIENT $COIN_ADDRESS --config $CONFIG_DIR --public-rpc"
                "$QCLIENT" token transfer "$RECIPIENT" "$COIN_ADDRESS" --config "$CONFIG_DIR" --public-rpc 2>&1 | tee -a "$LOG_FILE"
                
                # Check if transfer was successful
                if [ $? -eq 0 ]; then
                    log "Transfer from $COIN_ADDRESS completed successfully"
                else
                    log "WARNING: Transfer from $COIN_ADDRESS may have failed"
                fi
                
                # Add a small delay between transfers to avoid potential rate limiting
                sleep 2
            else
                log "Skipping coin address $COIN_ADDRESS with zero balance"
            fi
        done

        # Verify transfers
        log "Verifying transfers..."
        FINAL_BALANCE=$("$QCLIENT" token balance --config "$CONFIG_DIR" --public-rpc 2>&1)
        log "Final balance output: $FINAL_BALANCE"

        # Check if balance shows successful transfers
        if echo "$FINAL_BALANCE" | grep -q "Total balance: "; then
            log "Transfers verified successfully"
            log "Final balance: $FINAL_BALANCE"
        else
            handle_error "Transfer verification failed"
        fi
    else
        log "Node did not reach ring 0 or 1, skipping token operations"
    fi

    log "Script iteration completed"
    log "Starting next iteration from the beginning..."
    sleep 5  # Brief pause before restarting
done