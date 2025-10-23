# CloudCam 24/7 - Test Server Deployment Guide

This guide explains how to deploy the entire CloudCam 24/7 system on a single test server using Docker Swarm for localhost testing.

## Overview

**Target**: Single-node Docker Swarm deployment for testing
**Domain**: localhost (not production domain)
**Server IP**: 172.17.12.200
**Purpose**: Full system testing without affecting production

## Prerequisites

1. **Docker Installation Required**
   - See `INSTALL_DOCKER.md` for installation instructions
   - Ensure you can run `docker` commands without sudo

## Quick Start

### Step 1: Install Docker
```bash
# Follow instructions in INSTALL_DOCKER.md or run:
sudo apt-get update && sudo apt-get install -y docker.io docker-compose
sudo systemctl start docker && sudo systemctl enable docker
sudo usermod -aG docker $USER
# Log out and log back in, then verify:
docker --version
```

### Step 2: Build Images
```bash
cd /home/nbadmin/camera-project/swarm-deployment
./build-images.sh
```

### Step 3: Deploy System
```bash
./deploy-single-node-test.sh
```

## What Gets Deployed

### Services Stack
- **Databases**: 4 PostgreSQL instances (all data)
- **RabbitMQ**: Message broker with management UI
- **Panel API**: Main management API
- **Panel Frontend**: React admin dashboard
- **Streaming Service**: Live MJPEG streaming
- **RecorderScheduler**: Recording job management
- **Recorder**: Video capture service
- **S3Uploader**: File upload service
- **PlaylistManager**: HLS playlist management
- **Player API**: Playback orchestration
- **Player Frontend**: Video playback UI
- **Nginx**: Reverse proxy with SSL

### Network Configuration
- All services on single Docker Swarm node
- Nginx reverse proxy at http://localhost and https://localhost
- Self-signed SSL certificates for testing
- Internal Docker networking for service communication

## Access URLs

After successful deployment:

| Service | URL | Notes |
|---------|-----|--------|
| **Panel UI** | http://localhost | Main admin interface |
| **Player UI** | http://localhost/player/ | Video playback interface |
| **Panel API** | http://localhost/api/ | REST API endpoints |
| **RabbitMQ Mgmt** | http://localhost:15672 | guest/test_rabbitmq_password |

### Direct Service Ports (for debugging)
- Panel API: http://localhost:8084
- Streaming: http://localhost:8085  
- Player API: http://localhost:8083
- All PostgreSQL databases: 5433, 5434, 5435, 5436

## Configuration Files

### Environment Variables
- `.env.swarm.test` - All environment configuration
- Uses test passwords and localhost URLs
- Separate from production environment

### Modified Deployment Files
- `deploy-single-node-test.sh` - Main deployment script
- `nginx-test.conf` - Nginx configuration for localhost
- `docker-stack-*-test.yml` - Modified stack files for single-node

## Storage Setup

### Video Storage
- Local directory: `/mnt/camera-test-storage`
- Replaces production NFS mount
- Automatically created with proper permissions

### Database Storage
- Docker volumes for persistent data
- Separate volume per database service
- Data survives container restarts

## Monitoring & Management

### Check Deployment Status
```bash
# List all stacks
docker stack ls

# List all services
docker service ls

# Check specific service
docker service ps <service-name>

# View service logs
docker service logs <service-name>
```

### Scale Services
```bash
# Scale recorder instances
docker service scale app_recorder=2

# Scale S3 uploaders
docker service scale app_s3-uploader=3
```

### Restart Services
```bash
# Update service (forces restart)
docker service update --force <service-name>
```

## Troubleshooting

### Common Issues

1. **Docker permission denied**
   ```bash
   sudo usermod -aG docker $USER
   # Then log out and log back in
   ```

2. **Services not starting**
   ```bash
   docker service logs <service-name>
   docker service ps <service-name> --no-trunc
   ```

3. **Database connection issues**
   - Check environment variables in `.env.swarm.test`
   - Verify database services are running: `docker service ls`

4. **SSL certificate warnings**
   - Expected with self-signed certificates
   - Click "Proceed to localhost (unsafe)" in browser

5. **Port conflicts**
   ```bash
   # Check what's using ports
   sudo netstat -tlpn | grep -E ':(80|443|5672|15672)'
   ```

### Reset Deployment
```bash
# Remove all stacks
docker stack rm app messaging databases proxy

# Clean up volumes (CAUTION: deletes all data)
docker volume prune

# Clean up networks
docker network prune

# Redeploy
./deploy-single-node-test.sh
```

## Testing Workflow

### 1. System Health Check
- Visit http://localhost - should show login page
- Check RabbitMQ management at http://localhost:15672
- Verify all services are running: `docker service ls`

### 2. Basic Functionality
- Register new user account
- Add test camera (use any RTSP URL for testing)
- Try live streaming feature
- Schedule a test recording

### 3. Service Communication
- Check RabbitMQ queues have activity
- Monitor logs for inter-service communication
- Verify database connections working

## Development Integration

### Code Changes
- Rebuild affected images: `./build-images.sh`
- Update specific service: `docker service update --image <new-image> <service>`
- Or full redeploy: remove stack and redeploy

### Database Changes
- Connect directly to databases on ports 5433-5436
- Use test credentials from `.env.swarm.test`
- Apply schema changes manually or via service restart

### Debugging
- All services log to Docker service logs
- Use `docker exec -it <container> /bin/bash` for service inspection
- RabbitMQ management UI shows message flows

## Differences from Production

| Aspect | Production | Test Deployment |
|--------|------------|-----------------|
| **Domain** | cam.narbulut.com | localhost |
| **SSL** | Valid certificates | Self-signed |
| **Nodes** | 2 nodes (manager + worker) | 1 node (manager only) |
| **Storage** | NFS mount | Local directory |
| **Database** | Production passwords | Test passwords |
| **Scaling** | Distributed across nodes | All on one node |

## Security Notes

⚠️ **This is for testing only!**
- Uses weak test passwords
- Self-signed SSL certificates
- Debug logging enabled
- All services on one machine
- Not suitable for production use

## Next Steps

After successful testing:
1. Verify all features work correctly
2. Test service scaling and failover
3. Validate recording and playback functionality
4. Check system performance under load
5. Use learnings to improve production deployment