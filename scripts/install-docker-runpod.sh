#!/bin/bash

# Docker Installation Script for RunPod GPU Server
# Run this on your RunPod server to install Docker, Docker Compose, and NVIDIA Docker Runtime

set -e  # Exit on error

echo "=================================="
echo "Docker Installation for RunPod GPU"
echo "=================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    echo "Docker is already installed: $(docker --version)"
    read -p "Do you want to reinstall? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping Docker installation"
        SKIP_DOCKER=1
    fi
fi

# Install Docker
if [ -z "$SKIP_DOCKER" ]; then
    echo ""
    echo "Step 1: Installing Docker..."
    echo ""

    # Update package list
    apt-get update

    # Install prerequisites
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

    # Add Docker repository
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

    # Update package list
    apt-get update

    # Install Docker
    apt-get install -y docker-ce docker-ce-cli containerd.io

    # Start Docker (handle both systemd and non-systemd environments)
    if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null; then
        systemctl start docker
        systemctl enable docker
    else
        echo "Detected containerized environment (no systemd)"
        # Start Docker daemon manually
        dockerd &> /var/log/docker.log &
        sleep 3
    fi

    echo ""
    echo "✅ Docker installed: $(docker --version)"
fi

# Install Docker Compose
echo ""
echo "Step 2: Installing Docker Compose..."
echo ""

if command -v docker-compose &> /dev/null; then
    echo "Docker Compose already installed: $(docker-compose --version)"
else
    curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    echo "✅ Docker Compose installed: $(docker-compose --version)"
fi

# Verify NVIDIA GPU
echo ""
echo "Step 3: Verifying NVIDIA GPU..."
echo ""

if command -v nvidia-smi &> /dev/null; then
    nvidia-smi
    echo ""
    echo "✅ NVIDIA GPU detected"
else
    echo "❌ WARNING: nvidia-smi not found. GPU may not be available."
    echo "Make sure you're on a GPU-enabled RunPod instance."
    exit 1
fi

# Install NVIDIA Docker Runtime
echo ""
echo "Step 4: Installing NVIDIA Docker Runtime..."
echo ""

# Add NVIDIA Docker repository
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list

# Update and install
apt-get update
apt-get install -y nvidia-docker2

# Restart Docker (handle both systemd and non-systemd environments)
if command -v systemctl &> /dev/null && systemctl is-system-running &> /dev/null; then
    systemctl restart docker
else
    echo "Restarting Docker daemon manually..."
    pkill dockerd || true
    sleep 2
    dockerd &> /var/log/docker.log &
    sleep 3
fi

echo ""
echo "✅ NVIDIA Docker Runtime installed"

# Test GPU access
echo ""
echo "Step 5: Testing GPU access with Docker..."
echo ""

if docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi; then
    echo ""
    echo "=================================="
    echo "✅ SUCCESS! All components installed"
    echo "=================================="
    echo ""
    echo "Installed:"
    echo "  - Docker: $(docker --version)"
    echo "  - Docker Compose: $(docker-compose --version)"
    echo "  - NVIDIA Docker Runtime: ✅"
    echo "  - GPU Access: ✅"
    echo ""
    echo "Next steps:"
    echo "  1. Navigate to your camera-project directory"
    echo "  2. Configure .env file with your credentials"
    echo "  3. Run: docker-compose -f docker-compose.5090.yml pull"
    echo "  4. Run: docker-compose -f docker-compose.5090.yml up -d"
    echo ""
else
    echo ""
    echo "❌ ERROR: GPU test failed"
    echo "Docker is installed but cannot access GPU"
    echo "Please check NVIDIA drivers and try again"
    exit 1
fi
