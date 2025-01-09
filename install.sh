#!/bin/bash

# Exit on error
set -e

echo "Starting Ceremony Client installation..."

# Function to display countdown
countdown() {
    local seconds=$1
    while [ $seconds -gt 0 ]; do
        echo -ne "Waiting for config file creation: $seconds seconds remaining...\r"
        sleep 1
        : $((seconds--))
    done
    echo -e "\nContinuing with installation..."
}

# Check and remove existing directory
if [ -d "$HOME/ceremonyclient" ]; then
    echo "Found existing ceremonyclient directory. Removing..."
    rm -rf "$HOME/ceremonyclient"
fi

# Clone and setup repository
echo "Cloning ceremony client repository..."
cd ~
git clone https://github.com/QuilibriumNetwork/ceremonyclient.git
cd ceremonyclient
git pull
git checkout release

# Setup node directory
cd ~/ceremonyclient/node

# Determine OS type and architecture
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    release_os="linux"
    if [[ $(uname -m) == "aarch64" ]]; then
        release_arch="arm64"
    else
        release_arch="amd64"
    fi
else
    release_os="darwin"
    release_arch="arm64"
fi

echo "Detected OS: $release_os, Architecture: $release_arch"

# Function to download files if not present
download_files() {
    local file_list=$1
    for file in $file_list; do
        version=$(echo "$file" | cut -d '-' -f 2)
        if [[ ! -f "./$file" ]]; then
            echo "Downloading $file..."
            curl -L -o "$file" "https://releases.quilibrium.com/$file"
            if [ $? -ne 0 ]; then
                echo "Error downloading $file"
                exit 1
            fi
        else
            echo "$file already exists, skipping download"
        fi
    done
}

# Fetch and process release files
echo "Fetching release files..."
release_files=$(curl -s https://releases.quilibrium.com/release | grep "$release_os-$release_arch")
download_files "$release_files"

# Fetch and process qclient-release files
echo "Fetching qclient files..."
qclient_files=$(curl -s https://releases.quilibrium.com/qclient-release | grep "$release_os-$release_arch")
download_files "$qclient_files"

# Set executable permissions
echo "Setting executable permissions..."
chmod +x qclient-*-"$release_os"-"$release_arch"
chmod +x node-*-"$release_os"-"$release_arch"

# Create systemd service
echo "Creating systemd service..."
sudo bash -c 'cat > /lib/systemd/system/ceremonyclient.service <<EOF
[Unit]
Description=Ceremony Client Go App Service

[Service]
Type=simple
Restart=always
RestartSec=5s
WorkingDirectory=/root/ceremonyclient/node
Environment=GOEXPERIMENT=arenas
ExecStart=/root/ceremonyclient/node/node-2.0.5.1-linux-amd64

[Install]
WantedBy=multi-user.target
EOF'

# Reload systemd and start service
echo "Reloading systemd daemon and starting service..."
sudo systemctl daemon-reload
sudo service ceremonyclient restart

# Wait for config file creation
echo "Waiting for config file to be created..."
countdown 60

# Update config file
echo "Updating config file..."
CONFIG_FILE="$HOME/ceremonyclient/node/.config/config.yml"

if [ -f "$CONFIG_FILE" ]; then
    sed -i 's|maxFrames: -1|maxFrames: 1000|' "$CONFIG_FILE"
    sed -i 's|listenGrpcMultiaddr: ""|listenGrpcMultiaddr: "/ip4/127.0.0.1/tcp/8337"|' "$CONFIG_FILE"
    sed -i 's|listenRESTMultiaddr: ""|listenRESTMultiaddr: "/ip4/127.0.0.1/tcp/8338"|' "$CONFIG_FILE"
    echo "Config file updated successfully"
else
    echo "Warning: Config file not found at $CONFIG_FILE"
fi

echo "Installation completed!"
echo "Opening service logs..."
sudo journalctl -u ceremonyclient.service -f --no-hostname -o cat
