#!/bin/bash

set -e  # Exit on error

DOCKER_USER="marky731"
PROJECT_ROOT="/home/nbadmin/camera-project"
PANEL_DIR="$PROJECT_ROOT/camera-v2-panel"

echo "=================================="
echo "Building Missing Streaming Service"
echo "=================================="
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

# Build and push streaming-service
TAG="$DOCKER_USER/camera-project:streaming-service"

echo "Building: streaming-service"
echo "Context: $PANEL_DIR/CameraPanel.StreamingService"
echo "Tag: $TAG"
echo ""

cd "$PANEL_DIR/CameraPanel.StreamingService"

if [ ! -f "Dockerfile" ]; then
    echo "❌ Error: Dockerfile not found"
    exit 1
fi

docker build -t "$TAG" -f Dockerfile .

echo ""
echo "Pushing: $TAG"
docker push "$TAG"

echo ""
echo "=================================="
echo "✅ Streaming Service pushed!"
echo "=================================="
echo ""
echo "All images now complete:"
echo "  1. panel-api ✅"
echo "  2. panel-frontend ✅"
echo "  3. streaming-service ✅ (just pushed)"
echo "  4. recorder-scheduler ✅"
echo "  5. recorder ✅"
echo "  6. s3-uploader ✅"
echo "  7. playlist-manager ✅"
echo "  8. player-api ✅"
echo "  9. player-frontend ✅"
echo "  10. transcoder-combined ✅"
echo ""
echo "Ready for Phase 2 deployment!"
