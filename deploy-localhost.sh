#!/bin/bash
# CloudCam 24/7 - Localhost Docker Swarm Deployment Script
# Deploys entire system on localhost for testing purposes

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudCam 24/7 - Localhost Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Function to load localhost environment variables
load_env_vars() {
    echo -e "${YELLOW}Loading localhost environment variables...${NC}"
    if [ -f .env.swarm.local ]; then
        export $(cat .env.swarm.local | grep -v '^#' | xargs)
        echo -e "${GREEN}✓ Localhost environment variables loaded${NC}"
    else
        echo -e "${RED}✗ Error: .env.swarm.local file not found${NC}"
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
    
    # Check if user can access docker
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}✗ Docker daemon not running or accessible${NC}"
        echo -e "${YELLOW}Try: sudo systemctl start docker${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker daemon running${NC}"
}

# Function to initialize single-node swarm
init_swarm() {
    echo -e "${YELLOW}Setting up Docker Swarm...${NC}"
    
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
        echo -e "${GREEN}✓ Already part of a swarm${NC}"
    else
        echo -e "${YELLOW}Initializing single-node swarm...${NC}"
        docker swarm init --advertise-addr 127.0.0.1
        echo -e "${GREEN}✓ Swarm initialized${NC}"
    fi
    
    # Show node status
    echo -e "${YELLOW}Swarm nodes:${NC}"
    docker node ls
}

# Function to create required directories
setup_directories() {
    echo -e "${YELLOW}Setting up directories...${NC}"
    
    # Create local video storage directory in project folder
    mkdir -p ./storage/localhost-cameraswarm
    echo -e "${GREEN}✓ Local video storage directory created${NC}"
    
    # Create SSL directory
    mkdir -p ./ssl
    echo -e "${GREEN}✓ SSL directory ready${NC}"
}

# Function to create self-signed SSL certificates
create_ssl_certs() {
    echo -e "${YELLOW}Creating self-signed SSL certificates...${NC}"
    
    if [ ! -f ssl/localhost.crt ] || [ ! -f ssl/localhost.key ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout ssl/localhost.key \
            -out ssl/localhost.crt \
            -subj "/C=US/ST=Test/L=Test/O=CloudCam-Local/OU=IT/CN=localhost"
        echo -e "${GREEN}✓ Self-signed certificates created${NC}"
    else
        echo -e "${GREEN}✓ SSL certificates already exist${NC}"
    fi
}

# Function to create localhost nginx configuration
create_nginx_config() {
    echo -e "${YELLOW}Creating nginx configuration for localhost...${NC}"
    
    cat > nginx-localhost.conf << 'EOF'
events {
    worker_connections 1024;
}

http {
    upstream panel-api {
        server panel-api:8080;
    }
    
    upstream streaming-service {
        server streaming-service:8080;
    }
    
    upstream player-api {
        server player-api:8080;
    }
    
    upstream panel-frontend {
        server panel-frontend:80;
    }
    
    upstream player-frontend {
        server player-frontend:3001;
    }
    
    upstream playlist-manager {
        server playlist-manager:8082;
    }

    server {
        listen 80;
        listen 443 ssl;
        server_name localhost;

        ssl_certificate /etc/nginx/ssl/localhost.crt;
        ssl_certificate_key /etc/nginx/ssl/localhost.key;

        # Panel Frontend (React app)
        location / {
            proxy_pass http://panel-frontend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Panel API
        location /api/ {
            proxy_pass http://panel-api/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Streaming Service
        location /stream/ {
            proxy_pass http://streaming-service/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_buffering off;
        }

        # Player Frontend
        location /player/ {
            proxy_pass http://player-frontend/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Player API
        location /player-api/ {
            proxy_pass http://player-api/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Playlist Manager
        location /playlist/ {
            proxy_pass http://playlist-manager/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF
    echo -e "${GREEN}✓ Nginx configuration created${NC}"
}

# Function to create localhost docker stacks
create_localhost_stacks() {
    echo -e "${YELLOW}Creating localhost-specific Docker stacks...${NC}"
    
    # Create localhost application stack (modified from original)
    cat > docker-stack-app-localhost.yml << 'EOF'
version: '3.8'

services:
  # Panel API Backend
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
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # Panel Frontend
  panel-frontend:
    image: camera-panel-frontend:latest
    environment:
      - REACT_APP_API_URL=http://localhost/api
      - REACT_APP_STREAMING_URL=http://localhost/stream
    networks:
      - camera-network
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # Streaming Service
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
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # RecorderScheduler
  recorder-scheduler:
    image: recorder-scheduler:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__DefaultConnection: "Host=recording-jobs-db;Database=cloudcam_public;Username=cloudcam;Password=${PUBLIC_DB_PASSWORD}"
      ConnectionStrings__PrivateConnection: "Host=recorder-scheduler-db;Database=recorder_scheduler;Username=dev;Password=${POSTGRES_PASSWORD}"
      RabbitMQ__Host: "rabbitmq"
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
      restart_policy:
        condition: on-failure

  # Recorder
  recorder:
    image: recorder:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      RabbitMQ__Host: "rabbitmq"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
      Recorder__DataPath: "/data"
      Recorder__FFmpegPath: "ffmpeg"
      ConnectionStrings__DefaultConnection: "Data Source=/app/local/recorder.db"
      Database__ConnectionString: "Data Source=/app/local/recorder.db"
    volumes:
      # Use local directory for video storage (simulates NFS mount)
      - ./storage/localhost-cameraswarm:/data
      # Local volume for SQLite database (matches production)
      - recorder_local:/app/local
    networks:
      - camera-network
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # PlaylistManager
  playlist-manager:
    image: playlist-manager:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__DefaultConnection: "Host=playlist-manager-db;Database=playlist_manager;Username=dev;Password=${POSTGRES_PASSWORD}"
      RabbitMQ__Host: "rabbitmq"
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
      # Use local directory for video storage (read-only, simulates NFS mount)
      - ./storage/localhost-cameraswarm:/data:ro
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

  # Player API
  player-api:
    image: player-api:latest
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ASPNETCORE_URLS: http://+:8080
      PlaylistManager__BaseUrl: "http://playlist-manager:8082"
      PlaylistManager__ExternalBaseUrl: "http://localhost/playlist"
    networks:
      - camera-network
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

  # Player Frontend
  player-frontend:
    image: player-frontend:latest
    environment:
      VITE_API_BASE_URL: "http://localhost/player-api"
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

networks:
  camera-network:
    external: true

volumes:
  recorder_local:
    driver: local
EOF

    # Create localhost RabbitMQ stack (simplified)
    cat > docker-stack-rabbitmq-localhost.yml << 'EOF'
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3.13-management
    hostname: rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: dev
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
      RABBITMQ_DEFAULT_VHOST: cloudcam
    ports:
      - "5672:5672"
      - "15672:15672"
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks:
      - camera-network
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      restart_policy:
        condition: on-failure

networks:
  camera-network:
    external: true

volumes:
  rabbitmq_data:
    driver: local
EOF

    # Create localhost nginx stack
    cat > docker-stack-nginx-localhost.yml << 'EOF'
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx-localhost.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
    networks:
      - camera-network
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
      placement:
        constraints:
          - node.role == manager

networks:
  camera-network:
    external: true
EOF

    echo -e "${GREEN}✓ Localhost Docker stacks created${NC}"
}

# Function to build images
build_images() {
    echo -e "${YELLOW}Building Docker images...${NC}"
    if [ -f "./swarm-deployment/build-images.sh" ]; then
        cd swarm-deployment
        chmod +x build-images.sh
        ./build-images.sh
        cd ..
        echo -e "${GREEN}✓ Images built${NC}"
    else
        echo -e "${YELLOW}⚠ No build script found, assuming images exist${NC}"
    fi
}

# Function to deploy all stacks
deploy_stacks() {
    echo -e "${YELLOW}Deploying Docker stacks...${NC}"
    
    # Create network
    docker network create --driver overlay camera-network 2>/dev/null || echo "Network already exists"
    
    # Deploy databases
    echo -e "${YELLOW}Deploying databases...${NC}"
    docker stack deploy -c ./swarm-deployment/docker-stack-databases-only.yml databases
    
    # Wait for databases
    echo -e "${YELLOW}Waiting for databases...${NC}"
    sleep 30
    
    # Deploy RabbitMQ
    echo -e "${YELLOW}Deploying RabbitMQ...${NC}"
    docker stack deploy -c docker-stack-rabbitmq-localhost.yml messaging
    
    # Wait for RabbitMQ
    echo -e "${YELLOW}Waiting for RabbitMQ...${NC}"
    sleep 20
    
    # Deploy applications
    echo -e "${YELLOW}Deploying applications...${NC}"
    docker stack deploy -c docker-stack-app-localhost.yml app
    
    # Wait for applications
    echo -e "${YELLOW}Waiting for applications...${NC}"
    sleep 30
    
    # Deploy nginx
    echo -e "${YELLOW}Deploying nginx...${NC}"
    docker stack deploy -c docker-stack-nginx-localhost.yml proxy
    
    echo -e "${GREEN}✓ All stacks deployed${NC}"
}

# Function to check deployment status
check_deployment() {
    echo -e "${YELLOW}Checking deployment status...${NC}"
    echo ""
    echo -e "${BLUE}Docker Stacks:${NC}"
    docker stack ls
    echo ""
    echo -e "${BLUE}Services:${NC}"
    docker service ls
}

# Function to display access information
show_access_info() {
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}Localhost Deployment Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo -e "Panel UI:      ${GREEN}http://localhost${NC}"
    echo -e "Panel UI SSL:  ${GREEN}https://localhost${NC} (self-signed)"
    echo -e "Player UI:     ${GREEN}http://localhost/player/${NC}"
    echo -e "RabbitMQ Mgmt: ${GREEN}http://localhost:15672${NC} (dev/dev123)"
    echo ""
    echo -e "${YELLOW}Note: Accept self-signed certificate warnings for HTTPS${NC}"
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo -e "Check services:  ${YELLOW}docker service ls${NC}"
    echo -e "View logs:       ${YELLOW}docker service logs <service-name>${NC}"
    echo -e "Remove stacks:   ${YELLOW}docker stack rm app messaging databases proxy${NC}"
    echo -e "Stop swarm:      ${YELLOW}docker swarm leave --force${NC}"
}

# Main execution
main() {
    load_env_vars
    check_prerequisites
    init_swarm
    setup_directories
    create_ssl_certs
    create_nginx_config
    create_localhost_stacks
    build_images
    deploy_stacks
    check_deployment
    show_access_info
}

# Run main function
main "$@"