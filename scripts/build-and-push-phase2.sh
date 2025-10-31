#!/bin/bash

set -e  # Exit on error

DOCKER_USER="marky731"
PROJECT_ROOT="/home/nbadmin/camera-project"
CAMERA_V2="$PROJECT_ROOT/camera-v2"

echo "=================================="
echo "Phase 2: Building & Pushing Images"
echo "=================================="
echo ""
echo "Docker Hub User: $DOCKER_USER"
echo "Project Root: $PROJECT_ROOT"
echo ""

# Verify Docker login
echo "Verifying Docker Hub authentication..."
docker info | grep Username || {
    echo "Error: Not logged in to Docker Hub"
    echo "Run: docker login"
    exit 1
}

echo "✅ Docker Hub authentication verified"
echo ""

# Function to build and push
build_and_push() {
    local name=$1
    local context=$2
    local dockerfile=$3
    local tag="$DOCKER_USER/$name:latest"

    echo ""
    echo "-----------------------------------"
    echo "Building: $name"
    echo "Context: $context"
    echo "Dockerfile: $dockerfile"
    echo "Tag: $tag"
    echo "-----------------------------------"

    cd "$context"

    if [ ! -f "$dockerfile" ]; then
        echo "❌ Error: Dockerfile not found at $context/$dockerfile"
        return 1
    fi

    docker build -t "$tag" -f "$dockerfile" .

    echo ""
    echo "Pushing: $tag"
    docker push "$tag"

    echo "✅ $name pushed successfully"
}

# Build and push all services
echo ""
echo "Starting build and push process..."
echo "This will take 30-60 minutes depending on your internet speed."
echo ""

# 1. RecorderScheduler
echo ""
echo "[1/7] RecorderScheduler"
build_and_push "camera-v2-recorder-scheduler" "$CAMERA_V2/RecorderScheduler" "Dockerfile"

# 2. Recorder
echo ""
echo "[2/7] Recorder"
build_and_push "camera-v2-recorder" "$CAMERA_V2/Recorder" "Dockerfile"

# 3. S3Uploader
echo ""
echo "[3/7] S3Uploader"
build_and_push "camera-v2-s3-uploader" "$CAMERA_V2/S3Uploader" "Dockerfile"

# 4. PlaylistManager
echo ""
echo "[4/7] PlaylistManager"
build_and_push "camera-v2-playlist-manager" "$CAMERA_V2/PlaylistManager" "Dockerfile"

# 5. Player API
echo ""
echo "[5/7] Player API"
build_and_push "camera-v2-player-api" "$CAMERA_V2/Player/Player.API" "Dockerfile"

# 6. Player Frontend (production build)
echo ""
echo "[6/7] Player Frontend"
build_and_push "camera-v2-player-frontend" "$CAMERA_V2/Player/Player.Frontend" "Dockerfile"

# 7. Transcoder Combined (IMPORTANT: This is the GPU image)
echo ""
echo "[7/7] Transcoder Combined (GPU-enabled)"
echo "⚠️  This image is ~2.2GB and includes CUDA runtime"
build_and_push "camera-v2-transcoder-combined" "$PROJECT_ROOT" "Dockerfile.transcoder-combined"

echo ""
echo "=================================="
echo "✅ All images built and pushed!"
echo "=================================="
echo ""
echo "Pushed images:"
echo "  1. $DOCKER_USER/camera-v2-recorder-scheduler:latest"
echo "  2. $DOCKER_USER/camera-v2-recorder:latest"
echo "  3. $DOCKER_USER/camera-v2-s3-uploader:latest"
echo "  4. $DOCKER_USER/camera-v2-playlist-manager:latest"
echo "  5. $DOCKER_USER/camera-v2-player-api:latest"
echo "  6. $DOCKER_USER/camera-v2-player-frontend:latest"
echo "  7. $DOCKER_USER/camera-v2-transcoder-combined:latest"
echo ""
echo "Next steps:"
echo "1. View images on Docker Hub: https://hub.docker.com/u/$DOCKER_USER"
echo "2. Copy docker-compose.prod.yml to RunPod server"
echo "3. Copy .env file with production credentials"
echo "4. Run: docker-compose -f docker-compose.prod.yml up -d"
echo ""
echo "See PHASE2_RUNPOD_DEPLOYMENT.md for complete deployment guide"
echo ""
