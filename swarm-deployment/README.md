# CloudCam 24/7 - Docker Swarm Deployment

This folder contains all files needed for Docker Swarm deployment of the CloudCam 24/7 system across two nodes.

## Files Structure

```
swarm-deployment/
├── deploy-two-node-swarm.sh          # Main deployment script
├── docker-stack-databases-only.yml   # PostgreSQL databases stack
├── docker-stack-rabbitmq-host.yml    # RabbitMQ with host networking
├── docker-stack-nginx.yml            # HTTPS reverse proxy
├── docker-stack-app-https.yml        # Application services stack
├── nginx.conf                         # Nginx configuration
├── .env.swarm                         # Environment variables
├── ssl/                              # SSL certificates directory
│   ├── public.cer
│   └── private.key
└── README.md                         # This file
```

## Architecture

### Manager Node (172.17.12.97)
- All PostgreSQL databases (data consistency)
- RabbitMQ (host networking for cross-node access)
- Nginx reverse proxy
- Panel API, Frontend, Streaming Service
- RecorderScheduler (needs Docker socket access)
- PlaylistManager, Player API & Frontend
- 1x Recorder instance
- 1x S3Uploader instance

### Worker Node (172.17.12.98)
- 1x Recorder instance (distributed)
- 1x S3Uploader instance (distributed)

## Pre-requisites

1. **Manager Node Setup**:
   - Docker Swarm initialized
   - All Docker images built
   - SSL certificates in `ssl/` directory
   - `.env.swarm` file configured (see setup below)

2. **Worker Node Setup**:
   - Docker installed
   - NFS client configured for `/mnt/NBNAS/cameraswarm`
   - Network connectivity to manager node

## Environment Setup

⚠️ **IMPORTANT**: The `.env.swarm` file contains sensitive credentials and is required for deployment.

1. **Copy the template**:
   ```bash
   cp .env.swarm.template .env.swarm
   ```

2. **Edit `.env.swarm`** with your actual values:
   - Database passwords
   - JWT secret keys
   - S3/MinIO credentials
   - Domain name
   - API keys

3. **Never commit `.env.swarm`** to version control (it's in .gitignore)

## Deployment Steps

### 1. On Manager Node

```bash
cd swarm-deployment
./deploy-two-node-swarm.sh
```

The script will:
- Load environment variables from `.env.swarm`
- Check prerequisites (images, SSL, configs)
- Initialize/verify Docker Swarm
- Provide worker join token

### 2. On Worker Node

Run the setup script first:
```bash
./setup-worker.sh
```

Then join the swarm:
```bash
docker swarm join --token SWMTKN-1-xxx... 172.17.12.97:2377
```

### 3. Continue Deployment

After worker joins, press Enter on the manager node to continue deployment.

## Environment Variables

All environment variables are defined in `.env.swarm`. See `.env.swarm.template` for a complete list of required variables:

- **Database Configuration**: DB_PASSWORD, PUBLIC_DB_PASSWORD, POSTGRES_PASSWORD
- **Security**: JWT_SECRET_KEY, INTERNAL_API_KEY, RABBITMQ_PASSWORD  
- **External Services**: DOMAIN_NAME, S3_ENDPOINT, S3_BUCKET_NAME, S3_ACCESS_KEY, S3_SECRET_KEY
- **Service URLs**: Various internal service URLs for Docker networking

## Service URLs

After deployment:
- **Panel UI**: https://cam.narbulut.com
- **Player UI**: https://cam.narbulut.com/player/
- **RabbitMQ Management**: http://172.17.12.97:15672

## Monitoring

```bash
# Check service status
docker service ls

# Check service distribution
docker service ps <service-name>

# View logs
docker service logs <service-name>

# Stack overview
docker stack ls
docker stack ps <stack-name>
```

## Troubleshooting

1. **Database Connection Issues**:
   - Check environment variables match database passwords
   - Verify service names resolve in Docker network

2. **S3 Uploader Failing**:
   - Check S3 credentials in environment
   - Verify NFS mount on both nodes

3. **Authentication Issues**:
   - Verify JWT_SECRET_KEY is set correctly
   - Check database connectivity and seeding

## Scaling

To add more worker nodes:
1. Get worker token: `docker swarm join-token worker`
2. Setup new node with NFS access
3. Join swarm with token
4. Services will automatically distribute

To scale services:
```bash
docker service scale app_recorder=4 app_s3-uploader=4
```