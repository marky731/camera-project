#!/bin/bash
# Setup script for worker node (172.17.12.98)
# This script should be run on the worker node

set -e

echo "========================================="
echo "CloudCam Worker Node Setup Script"
echo "Target: 172.17.12.98"
echo "========================================="

# 1. Handle camera user with UID 1001 for NFS access
echo "Setting up user for NFS access (UID 1001)..."

# Check if UID 1001 is already taken
EXISTING_USER=$(getent passwd 1001 | cut -d: -f1)

if [ ! -z "$EXISTING_USER" ]; then
    if [ "$EXISTING_USER" = "camera" ]; then
        echo "✓ Camera user already exists with correct UID (1001)"
    else
        echo "ℹ UID 1001 is already assigned to user: $EXISTING_USER"
        echo "  This user will be used for NFS access"
    fi
    NFS_USER="$EXISTING_USER"
else
    # UID 1001 is free, create camera user
    if id -u camera >/dev/null 2>&1; then
        echo "Camera user exists with wrong UID, removing..."
        sudo userdel camera
    fi
    echo "Creating camera user with UID 1001..."
    sudo useradd -u 1001 -s /bin/bash camera
    NFS_USER="camera"
fi

echo "NFS operations will use user: $NFS_USER (UID 1001)"

# 2. Install NFS utilities if not present
echo ""
echo "Installing NFS utilities..."
if ! command -v mount.nfs &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y nfs-common
else
    echo "✓ NFS utilities already installed"
fi

# 3. Test NFS connectivity
echo ""
echo "Testing NFS server connectivity..."
ping -c 2 172.17.12.62 || { echo "✗ Cannot reach NFS server at 172.17.12.62"; exit 1; }
echo "✓ NFS server is reachable"

# 4. Create test mount point
echo ""
echo "Creating NFS test mount point..."
sudo mkdir -p /mnt/nfs-test

# 5. Test NFS mount
echo "Testing NFS mount..."
if sudo mount -t nfs -o vers=3,rw 172.17.12.62:/mnt/NBNAS/cameraswarm /mnt/nfs-test; then
    echo "✓ NFS mount successful"
    
    # 6. Test write permissions
    echo "Testing write permissions with $NFS_USER (UID 1001)..."
    TEST_FILE="/mnt/nfs-test/worker-node-test-$(date +%s).txt"
    
    if sudo -u "$NFS_USER" touch "$TEST_FILE" 2>/dev/null; then
        echo "✓ Write test successful!"
        sudo -u "$NFS_USER" echo "Test from worker node at $(date)" > "$TEST_FILE"
        echo "  Created file: $(basename $TEST_FILE)"
    else
        echo "⚠ Write test failed - permissions may need adjustment"
    fi
    
    # 7. Cleanup test mount
    echo "Cleaning up test mount..."
    sudo umount /mnt/nfs-test
    sudo rmdir /mnt/nfs-test
else
    echo "✗ NFS mount failed"
    echo "Please check:"
    echo "  1. NFS server is running"
    echo "  2. Export is configured correctly"
    echo "  3. Network connectivity"
    exit 1
fi

# 8. Create permanent mount point
echo ""
echo "Creating permanent NFS mount point..."
sudo mkdir -p /mnt/NBNAS/cameraswarm

# 9. Join Docker Swarm
echo ""
echo "Joining Docker Swarm cluster..."
echo "You need to run the join command on this worker node."
echo ""
echo "On the manager node (172.17.12.97), run:"
echo "  docker swarm join-token worker"
echo ""
echo "Then run the provided command here on the worker node."
echo ""
echo "Example command will look like:"
echo "  docker swarm join --token SWMTKN-1-xxx... 172.17.12.97:2377"
echo ""

# Optionally, try to join automatically if token is provided
if [ ! -z "$1" ]; then
    echo "Join token provided, attempting to join swarm..."
    sudo docker swarm join --token "$1" 172.17.12.97:2377
    if [ $? -eq 0 ]; then
        echo "✓ Successfully joined Docker Swarm!"
    else
        echo "✗ Failed to join swarm. Please check the token and try manually."
    fi
else
    echo "To join automatically, run this script with the token:"
    echo "  ./setup-worker.sh SWMTKN-1-xxx..."
fi

echo ""
echo "========================================="
echo "Worker node setup completed!"
echo "========================================="
echo ""
echo "Summary:"
echo "  - User $NFS_USER (UID 1001) configured for NFS"
echo "  - NFS mount test successful"
echo "  - Ready to join Docker Swarm"
echo ""
echo "Next steps:"
echo "  1. Join Docker Swarm (if not already done)"
echo "  2. Return to manager node (172.17.12.97)"
echo "  3. Run deployment script"