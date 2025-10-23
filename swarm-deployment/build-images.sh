#!/bin/bash
# CloudCam 24/7 - Build all Docker images for swarm deployment

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PROJECT_ROOT="/home/nbadmin/camera-project"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudCam 24/7 - Building Docker Images${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Function to build image with error handling
build_image() {
    local SERVICE_NAME="$1"
    local BUILD_CONTEXT="$2"
    local DOCKERFILE_PATH="$3"
    
    echo -e "${YELLOW}Building $SERVICE_NAME...${NC}"
    
    if [ -f "$DOCKERFILE_PATH" ]; then
        cd "$BUILD_CONTEXT"
        if docker build -t "$SERVICE_NAME" -f "$DOCKERFILE_PATH" .; then
            echo -e "${GREEN}✓ $SERVICE_NAME built successfully${NC}"
        else
            echo -e "${RED}✗ Failed to build $SERVICE_NAME${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Dockerfile not found: $DOCKERFILE_PATH${NC}"
        return 1
    fi
    echo ""
}

# Build Panel API
echo -e "${BLUE}[1/9] Building Panel API${NC}"
build_image "camera-panel-api" \
    "$PROJECT_ROOT/camera-v2-panel/CameraPanel.API" \
    "$PROJECT_ROOT/camera-v2-panel/CameraPanel.API/Dockerfile"

# Build Panel Frontend
echo -e "${BLUE}[2/9] Building Panel Frontend${NC}"
build_image "camera-panel-frontend" \
    "$PROJECT_ROOT/camera-v2-panel/camera-panel-frontend" \
    "$PROJECT_ROOT/camera-v2-panel/camera-panel-frontend/Dockerfile"

# Build Streaming Service
echo -e "${BLUE}[3/9] Building Streaming Service${NC}"
build_image "camera-streaming-service" \
    "$PROJECT_ROOT/camera-v2-panel/CameraPanel.StreamingService" \
    "$PROJECT_ROOT/camera-v2-panel/CameraPanel.StreamingService/Dockerfile"

# Build RecorderScheduler
echo -e "${BLUE}[4/9] Building RecorderScheduler${NC}"
build_image "recorder-scheduler" \
    "$PROJECT_ROOT/camera-v2/RecorderScheduler" \
    "$PROJECT_ROOT/camera-v2/RecorderScheduler/Dockerfile"

# Build Recorder
echo -e "${BLUE}[5/9] Building Recorder${NC}"
build_image "recorder" \
    "$PROJECT_ROOT/camera-v2/Recorder" \
    "$PROJECT_ROOT/camera-v2/Recorder/Dockerfile"

# Build S3Uploader
echo -e "${BLUE}[6/9] Building S3Uploader${NC}"
build_image "s3-uploader" \
    "$PROJECT_ROOT/camera-v2/S3Uploader" \
    "$PROJECT_ROOT/camera-v2/S3Uploader/Dockerfile"

# Build PlaylistManager
echo -e "${BLUE}[7/9] Building PlaylistManager${NC}"
build_image "playlist-manager" \
    "$PROJECT_ROOT/camera-v2/PlaylistManager" \
    "$PROJECT_ROOT/camera-v2/PlaylistManager/Dockerfile"

# Build Player API
echo -e "${BLUE}[8/9] Building Player API${NC}"
build_image "player-api" \
    "$PROJECT_ROOT/camera-v2/Player/Player.API" \
    "$PROJECT_ROOT/camera-v2/Player/Player.API/Dockerfile"

# Build Player Frontend
echo -e "${BLUE}[9/9] Building Player Frontend${NC}"
build_image "player-frontend" \
    "$PROJECT_ROOT/camera-v2/Player/Player.Frontend" \
    "$PROJECT_ROOT/camera-v2/Player/Player.Frontend/Dockerfile"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}All images built successfully!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# List built images
echo -e "${BLUE}Built images:${NC}"
docker images --filter "reference=camera-*" --filter "reference=recorder*" --filter "reference=s3-*" --filter "reference=playlist-*" --filter "reference=player-*" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"

echo ""
echo -e "${YELLOW}Next step: Run the deployment script${NC}"
echo -e "${YELLOW}./deploy-single-node-test.sh${NC}"