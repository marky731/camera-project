#!/bin/bash
# CloudCam 24/7 - Single-Node Docker Swarm Deployment Script for Testing
# Deploys entire system on localhost for testing purposes

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration for test server
TEST_SERVER_IP="172.17.12.200"
LOCALHOST_DOMAIN="localhost"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}CloudCam 24/7 - Single-Node Test Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "Test Server IP: ${GREEN}$TEST_SERVER_IP${NC}"
echo -e "Domain: ${GREEN}$LOCALHOST_DOMAIN${NC}"
echo -e "Target: ${YELLOW}Localhost testing only${NC}"
echo ""

# Function to load test environment variables
load_test_env_vars() {
    echo -e "${YELLOW}Loading test environment variables...${NC}"
    if [ -f .env.swarm.test ]; then
        export $(cat .env.swarm.test | grep -v '^#' | xargs)
        echo -e "${GREEN}✓ Test environment variables loaded${NC}"
    else
        echo -e "${RED}✗ Error: .env.swarm.test file not found${NC}"
        echo -e "${YELLOW}Please ensure .env.swarm.test exists with test configuration${NC}"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}✗ Docker is not installed${NC}"
        echo -e "${YELLOW}Please install Docker first:${NC}"
        echo -e "  sudo apt-get update"
        echo -e "  sudo apt-get install -y docker.io"
        echo -e "  sudo systemctl start docker"
        echo -e "  sudo usermod -aG docker \$USER"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker installed${NC}"
    
    # Check if user is in docker group
    if ! groups | grep -q docker; then
        echo -e "${YELLOW}⚠ User not in docker group. You may need to run:${NC}"
        echo -e "  sudo usermod -aG docker \$USER"
        echo -e "  Then logout and login again"
    fi
    
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}✗ Docker daemon not running or accessible${NC}"
        echo -e "${YELLOW}Try: sudo systemctl start docker${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Docker daemon running${NC}"
}

# Function to initialize or join swarm
init_swarm() {
    echo -e "${YELLOW}Setting up Docker Swarm...${NC}"
    
    if docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active; then
        echo -e "${GREEN}✓ Already part of a swarm${NC}"
        NODE_ID=$(docker info --format '{{.Swarm.NodeID}}')
        echo -e "Node ID: ${GREEN}$NODE_ID${NC}"
    else
        echo -e "${YELLOW}Initializing single-node swarm...${NC}"
        docker swarm init --advertise-addr $TEST_SERVER_IP
        echo -e "${GREEN}✓ Swarm initialized${NC}"
    fi
    
    # Show node status
    echo -e "${YELLOW}Swarm nodes:${NC}"
    docker node ls
}

# Function to create required directories
setup_directories() {
    echo -e "${YELLOW}Setting up directories...${NC}"
    
    # Create video storage directory
    sudo mkdir -p /mnt/camera-test-storage
    sudo chown -R $(whoami):$(whoami) /mnt/camera-test-storage
    echo -e "${GREEN}✓ Video storage directory created${NC}"
    
    # Create SSL directory if it doesn't exist
    mkdir -p ssl
    echo -e "${GREEN}✓ SSL directory ready${NC}"
}

# Function to create self-signed SSL certificates for testing
create_test_ssl_certs() {
    echo -e "${YELLOW}Creating self-signed SSL certificates for testing...${NC}"
    
    if [ ! -f ssl/test.crt ] || [ ! -f ssl/test.key ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout ssl/test.key \
            -out ssl/test.crt \
            -subj "/C=US/ST=Test/L=Test/O=CloudCam-Test/OU=IT/CN=localhost"
        echo -e "${GREEN}✓ Self-signed certificates created${NC}"
    else
        echo -e "${GREEN}✓ SSL certificates already exist${NC}"
    fi
}

# Function to create test nginx configuration
create_test_nginx_config() {
    echo -e "${YELLOW}Creating nginx configuration for localhost...${NC}"
    
    cat > nginx-test.conf << 'EOF'
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
        server player-frontend:80;
    }
    
    upstream playlist-manager {
        server playlist-manager:8082;
    }

    server {
        listen 80;
        listen 443 ssl;
        server_name localhost;

        ssl_certificate /etc/nginx/ssl/test.crt;
        ssl_certificate_key /etc/nginx/ssl/test.key;

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

        # Playlist Manager (direct access)
        location /playlist/ {
            proxy_pass http://playlist-manager/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
EOF
    echo -e "${GREEN}✓ Test nginx configuration created${NC}"
}

# Function to deploy database stack
deploy_databases() {
    echo -e "${YELLOW}Deploying database stack...${NC}"
    docker stack deploy -c docker-stack-databases-only.yml databases
    
    echo -e "${YELLOW}Waiting for databases to be ready...${NC}"
    sleep 30
    
    # Check database health
    while ! docker service ls --filter name=databases_panel-database --format "{{.Replicas}}" | grep -q "1/1"; do
        echo -e "${YELLOW}Waiting for panel database...${NC}"
        sleep 5
    done
    
    while ! docker service ls --filter name=databases_recording-jobs-db --format "{{.Replicas}}" | grep -q "1/1"; do
        echo -e "${YELLOW}Waiting for recording jobs database...${NC}"
        sleep 5
    done
    
    echo -e "${GREEN}✓ Databases deployed and ready${NC}"
}

# Function to deploy RabbitMQ
deploy_rabbitmq() {
    echo -e "${YELLOW}Deploying RabbitMQ...${NC}"
    
    # Create modified RabbitMQ stack for single-node
    cat > docker-stack-rabbitmq-test.yml << EOF
version: '3.8'

services:
  rabbitmq:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: guest
      RABBITMQ_DEFAULT_PASS: \${RABBITMQ_PASSWORD}
      RABBITMQ_ERLANG_COOKIE: test_cookie_for_clustering
    ports:
      - "5672:5672"
      - "15672:15672"
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks:
      - camera-network
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
        max_attempts: 3
      placement:
        constraints:
          - node.role == manager

volumes:
  rabbitmq_data:

networks:
  camera-network:
    external: true
EOF
    
    docker stack deploy -c docker-stack-rabbitmq-test.yml messaging
    
    echo -e "${YELLOW}Waiting for RabbitMQ to be ready...${NC}"
    sleep 20
    echo -e "${GREEN}✓ RabbitMQ deployed${NC}"
}

# Function to deploy application services
deploy_applications() {
    echo -e "${YELLOW}Deploying application services...${NC}"
    
    # Create single-node version of application stack
    # This will need to be modified from the original to remove worker node constraints
    cp docker-stack-app-https.yml docker-stack-app-test.yml
    
    # Remove worker node constraints and update for single-node deployment
    sed -i 's/node\.hostname == worker/node.role == manager/g' docker-stack-app-test.yml
    sed -i 's/172\.17\.12\.97/172.17.12.200/g' docker-stack-app-test.yml
    
    docker stack deploy -c docker-stack-app-test.yml app
    
    echo -e "${YELLOW}Waiting for application services...${NC}"
    sleep 30
    echo -e "${GREEN}✓ Application services deployed${NC}"
}

# Function to deploy nginx reverse proxy
deploy_nginx() {
    echo -e "${YELLOW}Deploying nginx reverse proxy...${NC}"
    
    # Create modified nginx stack for testing
    cat > docker-stack-nginx-test.yml << EOF
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx-test.conf:/etc/nginx/nginx.conf:ro
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
    
    docker stack deploy -c docker-stack-nginx-test.yml proxy
    
    echo -e "${GREEN}✓ Nginx proxy deployed${NC}"
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
    echo ""
    echo -e "${BLUE}Service Health:${NC}"
    docker service ps $(docker service ls -q) --no-trunc
}

# Function to display access information
show_access_info() {
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${BLUE}Access URLs:${NC}"
    echo -e "Panel UI:      ${GREEN}http://localhost${NC} or ${GREEN}https://localhost${NC}"
    echo -e "Player UI:     ${GREEN}http://localhost/player/${NC}"
    echo -e "RabbitMQ Mgmt: ${GREEN}http://localhost:15672${NC} (guest/test_rabbitmq_password)"
    echo ""
    echo -e "${BLUE}Direct Service Ports:${NC}"
    echo -e "Panel API:     ${GREEN}http://localhost:8084${NC}"
    echo -e "Streaming:     ${GREEN}http://localhost:8085${NC}"
    echo -e "Player API:    ${GREEN}http://localhost:8083${NC}"
    echo ""
    echo -e "${YELLOW}Note: Use self-signed certificates for HTTPS (accept security warnings)${NC}"
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo -e "Check services:  ${YELLOW}docker service ls${NC}"
    echo -e "View logs:       ${YELLOW}docker service logs <service-name>${NC}"
    echo -e "Scale service:   ${YELLOW}docker service scale app_recorder=2${NC}"
    echo -e "Remove stacks:   ${YELLOW}docker stack rm app messaging databases proxy${NC}"
}

# Main execution
main() {
    load_test_env_vars
    check_prerequisites
    init_swarm
    setup_directories
    create_test_ssl_certs
    create_test_nginx_config
    
    # Create camera network if it doesn't exist
    docker network create --driver overlay camera-network 2>/dev/null || true
    
    echo -e "${BLUE}Starting deployment process...${NC}"
    deploy_databases
    deploy_rabbitmq
    deploy_applications
    deploy_nginx
    
    check_deployment
    show_access_info
}

# Run main function
main "$@"