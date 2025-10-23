#!/bin/bash
# CloudCam 24/7 - Two-Node Docker Swarm Deployment Script
# Manager Node: 172.17.12.97 (this server)
# Worker Node: 172.17.12.98 (remote server)

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MANAGER_IP="172.17.12.97"
WORKER_IP="172.17.12.98"
DOMAIN_NAME="cam.narbulut.com"

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}CloudCam 24/7 - Two-Node Swarm Deployment${NC}"
echo -e "${BLUE}=========================================${NC}"
echo -e "Manager Node: ${GREEN}$MANAGER_IP${NC} (this server)"
echo -e "Worker Node: ${GREEN}$WORKER_IP${NC}"
echo -e "Domain: ${GREEN}$DOMAIN_NAME${NC}"
echo ""

# Function to check if running on manager node
check_manager_node() {
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    if [[ "$LOCAL_IP" != *"$MANAGER_IP"* ]]; then
        echo -e "${RED}Error: This script must be run on the manager node ($MANAGER_IP)${NC}"
        echo -e "Current IP: $LOCAL_IP"
        exit 1
    fi
}

# Function to load environment variables
load_env_vars() {
    echo -e "${YELLOW}Loading environment variables...${NC}"
    if [ -f .env.swarm ]; then
        export $(cat .env.swarm | grep -v '^#' | xargs)
        echo -e "${GREEN}✓ Environment variables loaded from .env.swarm${NC}"
        
        # Verify required variables are set
        REQUIRED_VARS=(
            "DB_PASSWORD"
            "PUBLIC_DB_PASSWORD" 
            "POSTGRES_PASSWORD"
            "RABBITMQ_PASSWORD"
            "INTERNAL_API_KEY"
            "JWT_SECRET_KEY"
            "S3_ENDPOINT"
            "S3_BUCKET_NAME"
            "S3_ACCESS_KEY"
            "S3_SECRET_KEY"
            "DOMAIN_NAME"
        )
        
        MISSING_VARS=()
        for var in "${REQUIRED_VARS[@]}"; do
            if [ -z "${!var}" ]; then
                MISSING_VARS+=("$var")
            fi
        done
        
        if [ ${#MISSING_VARS[@]} -gt 0 ]; then
            echo -e "${RED}✗ Missing required environment variables in .env.swarm:${NC}"
            for var in "${MISSING_VARS[@]}"; do
                echo -e "  - $var"
            done
            echo -e "${RED}Please check your .env.swarm file and ensure all required variables are set.${NC}"
            exit 1
        fi
        
    else
        echo -e "${RED}✗ Error: .env.swarm file is required but not found.${NC}"
        echo -e "${YELLOW}Please create .env.swarm file with all required environment variables.${NC}"
        echo -e "${YELLOW}See README.md for the required variables list.${NC}"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}✗ Docker is not installed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker installed${NC}"
    
    # Check if images exist
    echo -e "${YELLOW}Checking Docker images...${NC}"
    REQUIRED_IMAGES=(
        "camera-panel-api"
        "camera-panel-frontend"
        "camera-streaming-service"
        "camera-recorder-scheduler"
        "camera-recorder"
        "camera-s3-uploader"
        "camera-playlist-manager"
        "camera-player-api"
        "camera-player-frontend"
    )
    
    MISSING_IMAGES=()
    for img in "${REQUIRED_IMAGES[@]}"; do
        if ! docker image ls | grep -q "$img"; then
            MISSING_IMAGES+=("$img")
            echo -e "${YELLOW}  ⚠ Missing image: $img${NC}"
        else
            echo -e "${GREEN}  ✓ Found image: $img${NC}"
        fi
    done
    
    if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Some images are missing. Would you like to build them? (y/n)${NC}"
        read -r BUILD_CHOICE
        if [[ "$BUILD_CHOICE" == "y" || "$BUILD_CHOICE" == "Y" ]]; then
            build_images
        else
            echo -e "${RED}Cannot proceed without required images${NC}"
            exit 1
        fi
    fi
    
    # Check SSL certificates
    if [ ! -f "ssl/public.cer" ] || [ ! -f "ssl/private.key" ]; then
        echo -e "${YELLOW}⚠ SSL certificates not found in ssl/ directory${NC}"
        echo -e "  Expected: ssl/public.cer and ssl/private.key"
        echo -e "  Continue without SSL? (y/n)"
        read -r SSL_CHOICE
        if [[ "$SSL_CHOICE" != "y" && "$SSL_CHOICE" != "Y" ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✓ SSL certificates found${NC}"
    fi
    
    # Check nginx.conf
    if [ ! -f "nginx.conf" ]; then
        echo -e "${YELLOW}⚠ nginx.conf not found${NC}"
        echo -e "${RED}✗ Cannot proceed without nginx configuration${NC}"
        exit 1
    else
        echo -e "${GREEN}✓ nginx.conf found${NC}"
    fi
    
    # Check stack files
    for stack_file in "docker-stack-databases-only.yml" "docker-stack-rabbitmq-host.yml" "docker-stack-nginx.yml"; do
        if [ ! -f "$stack_file" ]; then
            echo -e "${RED}✗ Required stack file not found: $stack_file${NC}"
            exit 1
        else
            echo -e "${GREEN}✓ Found stack file: $stack_file${NC}"
        fi
    done
}

# Function to build Docker images
build_images() {
    echo -e "${YELLOW}Building Docker images...${NC}"
    
    if [ -f "../build-all-images.sh" ]; then
        echo -e "${BLUE}Using existing build script...${NC}"
        (cd .. && bash build-all-images.sh)
    else
        echo -e "${BLUE}Building images manually...${NC}"
        
        # Panel services
        echo -e "${YELLOW}Building Panel API...${NC}"
        docker build -t camera-panel-api:latest ../camera-v2-panel/CameraPanel.API/
        
        echo -e "${YELLOW}Building Panel Frontend...${NC}"
        docker build -t camera-panel-frontend:latest ../camera-v2-panel/camera-panel-frontend/
        
        echo -e "${YELLOW}Building Streaming Service...${NC}"
        docker build -t camera-streaming-service:latest ../camera-v2-panel/CameraPanel.StreamingService/
        
        # Camera-v2 services
        echo -e "${YELLOW}Building Recorder Scheduler...${NC}"
        docker build -t camera-recorder-scheduler:latest ../camera-v2/RecorderScheduler/
        
        echo -e "${YELLOW}Building Recorder...${NC}"
        docker build -t camera-recorder:latest ../camera-v2/Recorder/
        
        echo -e "${YELLOW}Building S3 Uploader...${NC}"
        docker build -t camera-s3-uploader:latest ../camera-v2/S3Uploader/
        
        echo -e "${YELLOW}Building Playlist Manager...${NC}"
        docker build -t camera-playlist-manager:latest ../camera-v2/PlaylistManager/
        
        echo -e "${YELLOW}Building Player API...${NC}"
        docker build -t camera-player-api:latest ../camera-v2/Player/Player.API/
        
        echo -e "${YELLOW}Building Player Frontend...${NC}"
        docker build -t camera-player-frontend:latest ../camera-v2/Player/Player.Frontend/
    fi
    
    echo -e "${GREEN}✓ All images built successfully${NC}"
}

# Function to initialize Docker Swarm
init_swarm() {
    echo -e "${YELLOW}Checking Docker Swarm status...${NC}"
    
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        echo -e "${GREEN}✓ Docker Swarm is already initialized${NC}"
        
        # Check if this is the manager
        if docker info 2>/dev/null | grep -q "Is Manager: true"; then
            echo -e "${GREEN}✓ This node is a manager${NC}"
        else
            echo -e "${RED}✗ This node is not a manager. Leaving swarm...${NC}"
            docker swarm leave --force
            echo -e "${YELLOW}Initializing new swarm...${NC}"
            docker swarm init --advertise-addr $MANAGER_IP
        fi
    else
        echo -e "${YELLOW}Initializing Docker Swarm...${NC}"
        docker swarm init --advertise-addr $MANAGER_IP
        echo -e "${GREEN}✓ Docker Swarm initialized${NC}"
    fi
    
    # Get worker join token
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Worker Node Setup Instructions${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo ""
    echo -e "${YELLOW}To join the worker node, run these commands on $WORKER_IP:${NC}"
    echo ""
    echo -e "${GREEN}1. First, run the setup script on the worker:${NC}"
    echo "   ./setup-worker.sh"
    echo ""
    echo -e "${GREEN}2. Then join the swarm with this command:${NC}"
    WORKER_TOKEN=$(docker swarm join-token -q worker)
    echo "   docker swarm join --token $WORKER_TOKEN $MANAGER_IP:2377"
    echo ""
    echo -e "${YELLOW}Press Enter after the worker node has joined the swarm...${NC}"
    read -r
    
    # Verify worker joined
    echo -e "${YELLOW}Verifying worker node...${NC}"
    WORKER_COUNT=$(docker node ls --format "{{.Hostname}}" | grep -v $(hostname) | wc -l)
    if [ "$WORKER_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Worker node(s) detected${NC}"
        docker node ls
    else
        echo -e "${YELLOW}⚠ No worker nodes detected. Continue anyway? (y/n)${NC}"
        read -r CONTINUE_CHOICE
        if [[ "$CONTINUE_CHOICE" != "y" && "$CONTINUE_CHOICE" != "Y" ]]; then
            exit 1
        fi
    fi
}

# Function to create Docker network
create_network() {
    echo -e "${YELLOW}Creating overlay network...${NC}"
    
    if docker network ls | grep -q "camera-network"; then
        echo -e "${GREEN}✓ Network 'camera-network' already exists${NC}"
    else
        docker network create --driver overlay --attachable camera-network
        echo -e "${GREEN}✓ Network 'camera-network' created${NC}"
    fi
}

# Function to label nodes for placement
label_nodes() {
    echo -e "${YELLOW}Labeling nodes for service placement...${NC}"
    
    # Label manager node
    MANAGER_HOSTNAME=$(hostname)
    docker node update --label-add role=manager $MANAGER_HOSTNAME
    echo -e "${GREEN}✓ Manager node labeled${NC}"
    
    # Label worker nodes
    for NODE in $(docker node ls --format "{{.Hostname}}" | grep -v $MANAGER_HOSTNAME); do
        docker node update --label-add role=worker $NODE
        echo -e "${GREEN}✓ Worker node '$NODE' labeled${NC}"
    done
}

# Function to deploy stacks
deploy_stacks() {
    echo -e "${YELLOW}Deploying service stacks...${NC}"
    
    # Deploy databases (manager only)
    echo -e "${BLUE}Deploying databases...${NC}"
    docker stack deploy -c docker-stack-databases-only.yml databases
    echo -e "${GREEN}✓ Databases stack deployed${NC}"
    
    # Wait for databases to be ready
    echo -e "${YELLOW}Waiting for databases to be ready (30s)...${NC}"
    sleep 30
    
    # Deploy RabbitMQ with host networking
    echo -e "${BLUE}Deploying RabbitMQ...${NC}"
    docker stack deploy -c docker-stack-rabbitmq-host.yml rabbitmq
    echo -e "${GREEN}✓ RabbitMQ stack deployed${NC}"
    
    # Wait for RabbitMQ
    echo -e "${YELLOW}Waiting for RabbitMQ to be ready (20s)...${NC}"
    sleep 20
    
    # Deploy Nginx proxy
    echo -e "${BLUE}Deploying Nginx reverse proxy...${NC}"
    docker stack deploy -c docker-stack-nginx.yml nginx
    echo -e "${GREEN}✓ Nginx stack deployed${NC}"
    
    # Deploy application services
    echo -e "${BLUE}Deploying application services...${NC}"
    
    # Create a temporary stack file with proper replica distribution
    cat > docker-stack-app-distributed.yml << 'EOF'
version: '3.8'

services:
  # Panel API - Manager only
  panel-api:
    image: camera-panel-api:latest
    environment:
      - ASPNETCORE_ENVIRONMENT=Development
      - ASPNETCORE_URLS=http://+:8080
      - ConnectionStrings__DefaultConnection=Host=panel-database;Database=CameraPanelDB;Username=postgres;Password=${DB_PASSWORD}
      - ConnectionStrings__PublicDatabase=Host=recording-jobs-db;Database=cloudcam_public;Username=cloudcam;Password=${PUBLIC_DB_PASSWORD}
      - RECORDER_SCHEDULER_URL=http://recorder-scheduler:8080
      - INTERNAL_API_KEY=${INTERNAL_API_KEY}
      - JwtSettings__SecretKey=${JWT_SECRET_KEY}
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # Panel Frontend - Manager only
  panel-frontend:
    image: camera-panel-frontend:latest
    environment:
      - REACT_APP_API_URL=https://${DOMAIN_NAME}/api
      - REACT_APP_STREAMING_URL=https://${DOMAIN_NAME}/stream
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # Streaming Service - Manager only
  streaming-service:
    image: camera-streaming-service:latest
    environment:
      - ASPNETCORE_ENVIRONMENT=Development
      - ASPNETCORE_URLS=http://+:8080
      - PanelApi__BaseUrl=http://panel-api:8080
      - INTERNAL_API_KEY=${INTERNAL_API_KEY}
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # RecorderScheduler - Manager only (needs Docker socket)
  recorder-scheduler:
    image: camera-recorder-scheduler:latest
    ports:
      - target: 8080
        published: 8081
        protocol: tcp
        mode: host
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__DefaultConnection: "Host=recording-jobs-db;Database=cloudcam_public;Username=cloudcam;Password=${PUBLIC_DB_PASSWORD}"
      ConnectionStrings__PrivateConnection: "Host=recorder-scheduler-db;Database=recorder_scheduler;Username=dev;Password=${POSTGRES_PASSWORD}"
      Docker__Endpoint: "unix:///var/run/docker.sock"
      RabbitMQ__Host: "172.17.12.97"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # Recorder - Distributed (1 on manager, 1 on worker)
  recorder:
    image: camera-recorder:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      RabbitMQ__Host: "172.17.12.97"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
      Recorder__DataPath: "/data"
      Recorder__FFmpegPath: "ffmpeg"
      ConnectionStrings__DefaultConnection: "Data Source=/app/local/recorder.db"
      Database__ConnectionString: "Data Source=/app/local/recorder.db"
    volumes:
      - /mnt/NBNAS/cameraswarm:/data
      - recorder_local:/app/local
    networks:
      - camera-network
    deploy:
      replicas: 2
      placement:
        max_replicas_per_node: 1
        preferences:
          - spread: node.labels.role

  # S3Uploader - Distributed (1 on manager, 1 on worker)
  s3-uploader:
    image: camera-s3-uploader:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      S3__Endpoint: "${S3_ENDPOINT}"
      S3__BucketName: "${S3_BUCKET_NAME}"
      S3__AccessKey: "${S3_ACCESS_KEY}"
      S3__SecretKey: "${S3_SECRET_KEY}"
      S3__UseSSL: "${S3_USE_SSL}"
      RabbitMQ__Host: "172.17.12.97"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
      S3Uploader__DataPath: "/data"
      S3Uploader__MaxConcurrentUploads: "5"
      S3Uploader__UploadTimeoutSeconds: "300"
    volumes:
      - /mnt/NBNAS/cameraswarm:/data:ro
    networks:
      - camera-network
    extra_hosts:
      - "nbpublic.narbulut.com:176.53.46.124"
    dns:
      - 8.8.8.8
      - 8.8.4.4
    deploy:
      replicas: 2
      placement:
        max_replicas_per_node: 1
        preferences:
          - spread: node.labels.role

  # PlaylistManager - Manager only
  playlist-manager:
    image: camera-playlist-manager:latest
    ports:
      - target: 8082
        published: 8082
        protocol: tcp
        mode: host
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__DefaultConnection: "Host=playlist-manager-db;Database=playlist_manager;Username=dev;Password=${POSTGRES_PASSWORD}"
      RabbitMQ__Host: "172.17.12.97"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
      PlaylistManager__S3BucketName: "${S3_BUCKET_NAME}"
      PlaylistManager__CDNBaseUrl: "${CDN_BASE_URL}"
      PlaylistManager__SignedUrlExpirationMinutes: "${SIGNED_URL_EXPIRATION_MINUTES}"
      PlaylistManager__S3Endpoint: "${S3_ENDPOINT}"
      PlaylistManager__S3AccessKey: "${S3_ACCESS_KEY}"
      PlaylistManager__S3SecretKey: "${S3_SECRET_KEY}"
      PlaylistManager__S3UseSSL: "${S3_USE_SSL}"
    volumes:
      - /mnt/NBNAS/cameraswarm:/data:ro
    networks:
      - camera-network
    extra_hosts:
      - "nbpublic.narbulut.com:176.53.46.124"
    dns:
      - 8.8.8.8
      - 8.8.4.4
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # Player API - Manager only
  player-api:
    image: camera-player-api:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ASPNETCORE_URLS: http://+:8080
      PlaylistManager__BaseUrl: "http://playlist-manager:8082"
      PlaylistManager__ExternalBaseUrl: "https://${DOMAIN_NAME}/playlist"
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

  # Player Frontend - Manager only
  player-frontend:
    image: camera-player-frontend:latest
    ports:
      - target: 3001
        published: 3001
        protocol: tcp
        mode: host
    environment:
      VITE_API_BASE_URL: "https://${DOMAIN_NAME}/player-api"
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager

networks:
  camera-network:
    external: true

volumes:
  recorder_local:
    driver: local
EOF

    docker stack deploy -c docker-stack-app-distributed.yml app
    echo -e "${GREEN}✓ Application stack deployed${NC}"
}

# Function to verify deployment
verify_deployment() {
    echo ""
    echo -e "${YELLOW}Verifying deployment...${NC}"
    sleep 10
    
    echo -e "${BLUE}Service Status:${NC}"
    docker service ls
    
    echo ""
    echo -e "${BLUE}Stack Status:${NC}"
    docker stack ls
    
    echo ""
    echo -e "${BLUE}Node Distribution:${NC}"
    for service in $(docker service ls --format "{{.Name}}"); do
        echo -e "${YELLOW}$service:${NC}"
        docker service ps $service --format "table {{.Node}}\t{{.CurrentState}}" | head -5
    done
    
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo -e "  Panel UI: ${GREEN}https://$DOMAIN_NAME${NC}"
    echo -e "  Player UI: ${GREEN}https://$DOMAIN_NAME/player/${NC}"
    echo -e "  RabbitMQ Management: ${GREEN}http://$MANAGER_IP:15672${NC}"
    echo ""
    echo -e "${BLUE}Service Distribution:${NC}"
    echo -e "  Manager Node ($MANAGER_IP):"
    echo -e "    - All databases (PostgreSQL)"
    echo -e "    - RabbitMQ"
    echo -e "    - Nginx Proxy"
    echo -e "    - Panel API, Frontend, Streaming"
    echo -e "    - RecorderScheduler"
    echo -e "    - PlaylistManager"
    echo -e "    - Player API & Frontend"
    echo -e "    - 1x Recorder instance"
    echo -e "    - 1x S3Uploader instance"
    echo ""
    echo -e "  Worker Node ($WORKER_IP):"
    echo -e "    - 1x Recorder instance"
    echo -e "    - 1x S3Uploader instance"
    echo ""
    echo -e "${YELLOW}Monitor services with:${NC}"
    echo "  docker service ls"
    echo "  docker stack ps app"
    echo "  docker stack ps databases"
    echo "  docker stack ps rabbitmq"
    echo "  docker stack ps nginx"
}

# Function to cleanup on failure
cleanup_on_failure() {
    echo -e "${RED}Deployment failed. Cleaning up...${NC}"
    docker stack rm app nginx rabbitmq databases 2>/dev/null || true
    exit 1
}

# Set trap for cleanup
trap cleanup_on_failure ERR

# Main execution
main() {
    check_manager_node
    load_env_vars
    check_prerequisites
    init_swarm
    create_network
    label_nodes
    deploy_stacks
    verify_deployment
}

# Run main function
main "$@"