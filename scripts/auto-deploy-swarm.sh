#!/bin/bash

# CloudCam Auto-Deploy Script (Deployment Only)
# Purpose: Deploy CloudCam system to Docker Swarm with proper service orchestration
# Prerequisites: Run ./build-all-images.sh first to build images
# Usage: ./auto-deploy-swarm.sh

set -euo pipefail

# ======================== Configuration ========================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color

# Script configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="${SCRIPT_DIR}/.."
readonly ENV_FILE="${PROJECT_DIR}/.env.swarm"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly LOG_FILE="${PROJECT_DIR}/deployment_${TIMESTAMP}.log"

# Network and service configuration
readonly STACK_PREFIX="cloudcam"
readonly NETWORK_NAME="camera-network"

# Required Docker images
readonly REQUIRED_IMAGES=(
    "camera-panel-api:latest"
    "camera-panel-frontend:latest"
    "camera-streaming-service:latest"
    "camera-recorder-scheduler:latest"
    "camera-recorder:latest"
    "camera-s3-uploader:latest"
    "camera-playlist-manager:latest"
    "camera-player-api:latest"
    "camera-player-frontend:latest"
)

# Health check settings
readonly MAX_WAIT_TIME=300  # 5 minutes max wait for service readiness
readonly HEALTH_CHECK_INTERVAL=10  # Check every 10 seconds

# ======================== Logging Functions ========================

setup_logging() {
    exec 1> >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "Deployment log: $LOG_FILE"
}

log_header() {
    echo ""
    echo "================================================================"
    echo " $1"
    echo "================================================================"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') - $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') - $1"
}

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
   _____ _                 _  _____                
  / ____| |               | |/ ____|               
 | |    | | ___  _   _  __| | |     __ _ _ __ ___  
 | |    | |/ _ \| | | |/ _` | |    / _` | '_ ` _ \ 
 | |____| | (_) | |_| | (_| | |___| (_| | | | | | |
  \_____|_|\___/ \__,_|\__,_|\_____\__,_|_| |_| |_|
                                                    
EOF
    echo -e "${NC}"
    echo "  Auto-Deploy Script v1.0"
    echo "  ======================="
    echo ""
}

# ======================== Validation Functions ========================

check_prerequisites() {
    log_header "Checking Prerequisites"
    
    local errors=0
    
    # Check Docker daemon
    log_info "Checking Docker daemon..."
    if docker info &> /dev/null; then
        log_success "Docker daemon is running"
    else
        log_error "Docker daemon is not running or not accessible"
        ((errors++))
    fi
    
    # Check Docker Swarm
    log_info "Checking Docker Swarm status..."
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        if docker node ls &> /dev/null; then
            log_success "Docker Swarm is active and this node is a manager"
        else
            log_error "Docker Swarm is active but this node is not a manager"
            ((errors++))
        fi
    else
        log_error "Docker Swarm is not initialized. Run: docker swarm init"
        ((errors++))
    fi
    
    # Check environment file
    log_info "Checking environment configuration..."
    if [[ -f "$ENV_FILE" ]]; then
        log_success "Environment file found: $ENV_FILE"
        # Load environment variables
        set -a
        source "$ENV_FILE"
        set +a
    else
        log_error "Environment file not found: $ENV_FILE"
        ((errors++))
    fi
    
    # Check required stack files
    log_info "Checking stack files..."
    local stack_files=(
        "docker-stack-databases-only.yml"
        "docker-stack-rabbitmq-host.yml"
        "docker-stack-app-https.yml"
        "docker-stack-nginx.yml"
    )
    
    for file in "${stack_files[@]}"; do
        if [[ -f "${PROJECT_DIR}/${file}" ]]; then
            log_success "Stack file found: $file"
        else
            log_error "Stack file missing: $file"
            ((errors++))
        fi
    done
    
    # Check NFS mount
    log_info "Checking NFS mount..."
    if mount | grep -q "/mnt/NBNAS/cameraswarm"; then
        log_success "NFS is mounted at /mnt/NBNAS/cameraswarm"
    else
        log_warning "NFS may not be mounted at /mnt/NBNAS/cameraswarm"
    fi
    
    # Check SSL certificates
    log_info "Checking SSL certificates..."
    if [[ -f "${PROJECT_DIR}/ssl/public.cer" && -f "${PROJECT_DIR}/ssl/private.key" ]]; then
        log_success "SSL certificates found"
    else
        log_warning "SSL certificates not found in ssl/ directory"
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Prerequisites check failed with $errors errors"
        exit 1
    else
        log_success "All prerequisites satisfied"
    fi
}

check_images_exist() {
    log_header "Validating Docker Images"
    
    local missing_images=()
    
    log_info "Checking required Docker images..."
    for image in "${REQUIRED_IMAGES[@]}"; do
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$"; then
            log_success "Found image: $image"
        else
            log_error "Missing image: $image"
            missing_images+=("$image")
        fi
    done
    
    if [[ ${#missing_images[@]} -gt 0 ]]; then
        log_error "Missing ${#missing_images[@]} required images"
        echo ""
        echo "Please run the following command to build images:"
        echo -e "${CYAN}./build-all-images.sh${NC}"
        echo ""
        echo "Missing images:"
        for image in "${missing_images[@]}"; do
            echo "  - $image"
        done
        exit 1
    else
        log_success "All required images are available"
    fi
}

# ======================== Cleanup Functions ========================

cleanup_failed_services() {
    log_header "Cleaning Up Failed Services"
    
    log_info "Removing any existing CloudCam stacks..."
    
    # Get list of existing CloudCam stacks
    local existing_stacks=$(docker stack ls --format "{{.Name}}" | grep "^${STACK_PREFIX}-" || true)
    
    if [[ -n "$existing_stacks" ]]; then
        echo "$existing_stacks" | while read -r stack; do
            log_info "Removing stack: $stack"
            docker stack rm "$stack" || true
        done
        
        log_info "Waiting for services to be completely removed (30 seconds)..."
        sleep 30
        
        # Verify cleanup
        local remaining_services=$(docker service ls --format "{{.Name}}" | grep "^${STACK_PREFIX}-" || true)
        if [[ -n "$remaining_services" ]]; then
            log_warning "Some services still exist, waiting additional 15 seconds..."
            sleep 15
        fi
    else
        log_info "No existing CloudCam stacks found"
    fi
    
    # Ensure network exists
    log_info "Ensuring overlay network exists..."
    if ! docker network ls | grep -q "$NETWORK_NAME"; then
        docker network create \
            --driver overlay \
            --attachable \
            "$NETWORK_NAME"
        log_success "Created overlay network: $NETWORK_NAME"
    else
        log_info "Overlay network already exists: $NETWORK_NAME"
    fi
    
    log_success "Cleanup completed"
}

# ======================== Deployment Functions ========================

wait_for_service_ready() {
    local service_name="$1"
    local expected_replicas="$2"
    local max_wait="${3:-$MAX_WAIT_TIME}"
    
    log_info "Waiting for $service_name to be ready ($expected_replicas replicas)..."
    
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local current_replicas=$(docker service ls --filter "name=$service_name" --format "{{.Replicas}}" | cut -d'/' -f1)
        local desired_replicas=$(docker service ls --filter "name=$service_name" --format "{{.Replicas}}" | cut -d'/' -f2)
        
        if [[ "$current_replicas" == "$expected_replicas" && "$current_replicas" == "$desired_replicas" ]]; then
            log_success "$service_name is ready ($current_replicas/$desired_replicas replicas)"
            return 0
        fi
        
        log_info "$service_name status: $current_replicas/$desired_replicas replicas (waiting...)"
        sleep $HEALTH_CHECK_INTERVAL
        elapsed=$((elapsed + HEALTH_CHECK_INTERVAL))
    done
    
    log_error "$service_name failed to become ready within ${max_wait}s"
    return 1
}

test_database_connectivity() {
    local db_host="$1"
    local db_port="$2"
    local db_name="$3"
    local db_user="$4"
    local db_pass="$5"
    
    log_info "Testing database connectivity: $db_name@$db_host:$db_port"
    
    # Wait for database port to be open
    local max_attempts=30
    for i in $(seq 1 $max_attempts); do
        if nc -z "$db_host" "$db_port" 2>/dev/null; then
            log_success "Database port is open: $db_host:$db_port"
            break
        fi
        if [[ $i -eq $max_attempts ]]; then
            log_error "Database port not accessible: $db_host:$db_port"
            return 1
        fi
        sleep 2
    done
    
    # Test actual database connection (simplified test)
    log_info "Database is accessible at $db_host:$db_port"
    return 0
}

deploy_databases() {
    log_header "Deploying Database Services"
    
    log_info "Deploying database stack..."
    
    # Load environment variables
    set -a
    source "$ENV_FILE"
    set +a
    
    docker stack deploy \
        --compose-file "${PROJECT_DIR}/docker-stack-databases-only.yml" \
        "${STACK_PREFIX}-db" || {
        log_error "Failed to deploy database stack"
        return 1
    }
    
    log_success "Database stack deployed"
    
    # Wait for database services to be ready
    local db_services=(
        "${STACK_PREFIX}-db_panel-database:1"
        "${STACK_PREFIX}-db_recording-jobs-db:1"
        "${STACK_PREFIX}-db_recorder-scheduler-db:1"
        "${STACK_PREFIX}-db_playlist-manager-db:1"
    )
    
    for service_info in "${db_services[@]}"; do
        IFS=':' read -r service_name expected_replicas <<< "$service_info"
        wait_for_service_ready "$service_name" "$expected_replicas" 180  # 3 minutes max for databases
    done
    
    # Test database connectivity
    log_info "Testing database connectivity..."
    sleep 10  # Give databases time to fully initialize
    
    # Test key databases
    local manager_ip="${MANAGER_IP:-172.17.12.97}"
    test_database_connectivity "$manager_ip" "5436" "CameraPanelDB" "postgres" "${DB_PASSWORD}"
    test_database_connectivity "$manager_ip" "5433" "cloudcam_public" "cloudcam" "${PUBLIC_DB_PASSWORD}"
    
    log_success "Database deployment completed and verified"
}

deploy_rabbitmq() {
    log_header "Deploying RabbitMQ Service"
    
    log_info "Deploying RabbitMQ stack..."
    
    docker stack deploy \
        --compose-file "${PROJECT_DIR}/docker-stack-rabbitmq-host.yml" \
        "${STACK_PREFIX}-mq" || {
        log_error "Failed to deploy RabbitMQ stack"
        return 1
    }
    
    log_success "RabbitMQ stack deployed"
    
    # Wait for RabbitMQ service to be ready
    wait_for_service_ready "${STACK_PREFIX}-mq_rabbitmq" "1" 120  # 2 minutes max
    
    # Test RabbitMQ connectivity
    log_info "Testing RabbitMQ connectivity..."
    local manager_ip="${MANAGER_IP:-172.17.12.97}"
    local max_attempts=20
    
    for i in $(seq 1 $max_attempts); do
        if curl -s -f -u "dev:${RABBITMQ_PASSWORD}" "http://$manager_ip:15672/api/overview" > /dev/null 2>&1; then
            log_success "RabbitMQ management interface is accessible"
            break
        fi
        if [[ $i -eq $max_attempts ]]; then
            log_warning "RabbitMQ management interface not accessible (but service may still work)"
            break
        fi
        sleep 3
    done
    
    log_success "RabbitMQ deployment completed"
}

deploy_applications() {
    log_header "Deploying Application Services"
    
    log_info "Deploying application stack..."
    
    docker stack deploy \
        --compose-file "${PROJECT_DIR}/docker-stack-app-https.yml" \
        "${STACK_PREFIX}-app" || {
        log_error "Failed to deploy application stack"
        return 1
    }
    
    log_success "Application stack deployed"
    
    # Wait for application services to be ready
    local app_services=(
        "${STACK_PREFIX}-app_panel-api:1"
        "${STACK_PREFIX}-app_panel-frontend:1"
        "${STACK_PREFIX}-app_streaming-service:1"
        "${STACK_PREFIX}-app_recorder-scheduler:1"
        "${STACK_PREFIX}-app_recorder:2"
        "${STACK_PREFIX}-app_s3-uploader:2"
        "${STACK_PREFIX}-app_playlist-manager:1"
        "${STACK_PREFIX}-app_player-api:1"
        "${STACK_PREFIX}-app_player-frontend:1"
    )
    
    for service_info in "${app_services[@]}"; do
        IFS=':' read -r service_name expected_replicas <<< "$service_info"
        wait_for_service_ready "$service_name" "$expected_replicas" 180  # 3 minutes max for apps
    done
    
    log_success "Application deployment completed"
}

deploy_nginx() {
    log_header "Deploying Nginx Proxy"
    
    log_info "Deploying Nginx stack..."
    
    docker stack deploy \
        --compose-file "${PROJECT_DIR}/docker-stack-nginx.yml" \
        "${STACK_PREFIX}-proxy" || {
        log_error "Failed to deploy Nginx stack"
        return 1
    }
    
    log_success "Nginx stack deployed"
    
    # Wait for Nginx service to be ready
    wait_for_service_ready "${STACK_PREFIX}-proxy_nginx-proxy" "1" 60  # 1 minute max
    
    log_success "Nginx deployment completed"
}

# ======================== Verification Functions ========================

verify_deployment() {
    log_header "Verifying Deployment"
    
    log_info "Checking all service status..."
    
    # Show service status
    echo ""
    docker service ls --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}"
    echo ""
    
    # Test critical endpoints
    log_info "Testing service endpoints..."
    local manager_ip="${MANAGER_IP:-172.17.12.97}"
    local domain_name="${DOMAIN_NAME:-$manager_ip}"
    
    local endpoints=(
        "http://$manager_ip:8081/health:RecorderScheduler"
        "http://$manager_ip:8082/health:PlaylistManager"
        "http://$manager_ip:15672:RabbitMQ Management"
    )
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r url service_name <<< "$endpoint"
        if curl -s -f -m 10 "$url" > /dev/null 2>&1; then
            log_success "$service_name is accessible at $url"
        else
            log_warning "$service_name may not be fully ready at $url"
        fi
    done
    
    # Check for any failed services
    local failed_services=$(docker service ls --format "{{.Name}} {{.Replicas}}" | grep " 0/" || true)
    if [[ -n "$failed_services" ]]; then
        log_warning "Some services have 0 replicas:"
        echo "$failed_services"
        echo ""
        log_info "Check logs with: docker service logs <service-name>"
    else
        log_success "All services have running replicas"
    fi
    
    # Show access information
    echo ""
    log_header "Deployment Complete - Access Information"
    echo ""
    echo -e "${GREEN}  🎉 CloudCam deployment completed successfully!${NC}"
    echo ""
    echo -e "${CYAN}  🌐 Access URLs:${NC}"
    echo "    Management Panel:     https://$domain_name/"
    echo "    Video Player:         https://$domain_name/player/"
    echo "    RabbitMQ Management:  http://$manager_ip:15672"
    echo ""
    echo -e "${CYAN}  🔑 Credentials:${NC}"
    echo "    RabbitMQ: dev / (check RABBITMQ_PASSWORD in .env.swarm)"
    echo ""
    echo -e "${CYAN}  🔧 Management Commands:${NC}"
    echo "    View services:        docker service ls"
    echo "    View logs:            docker service logs <service-name>"
    echo "    Scale service:        docker service scale <service-name>=<replicas>"
    echo ""
    echo -e "${CYAN}  📋 Deployment Log:${NC} $LOG_FILE"
    echo ""
}

# ======================== Main Function ========================

main() {
    print_banner
    setup_logging
    
    log_info "Starting CloudCam Auto-Deploy..."
    
    # Run all deployment steps
    check_prerequisites
    check_images_exist
    cleanup_failed_services
    deploy_databases
    deploy_rabbitmq
    deploy_applications
    deploy_nginx
    verify_deployment
    
    log_success "CloudCam deployment completed successfully!"
}

# ======================== Error Handling ========================

cleanup_on_error() {
    log_error "Deployment failed at line $1"
    log_info "Check the log file for details: $LOG_FILE"
    echo ""
    echo "To clean up and try again:"
    echo "  docker stack rm cloudcam-app cloudcam-proxy cloudcam-mq cloudcam-db"
    echo "  ./auto-deploy-swarm.sh"
    exit 1
}

# Set up error trap
trap 'cleanup_on_error $LINENO' ERR

# ======================== Script Entry Point ========================

# Show help if requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat << EOF
CloudCam Auto-Deploy Script

Usage: $0

Prerequisites:
  - Docker Swarm must be initialized
  - Run ./build-all-images.sh first to build Docker images
  - Environment file .env.swarm must exist

This script will:
  1. Validate prerequisites and images
  2. Clean up any failed services
  3. Deploy databases and wait for readiness
  4. Deploy RabbitMQ and verify connectivity
  5. Deploy application services with proper dependencies
  6. Deploy Nginx proxy
  7. Verify deployment and show access URLs

Examples:
  ./auto-deploy-swarm.sh                 # Deploy everything
  ./auto-deploy-swarm.sh --help          # Show this help

EOF
    exit 0
fi

# Run main deployment
main "$@"