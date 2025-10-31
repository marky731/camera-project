# Phase 2: RTX 5090 GPU Server Deployment

**Status**: ✅ Ready for Deployment
**Target**: RunPod server with RTX 5090
**Date**: 2025-10-31

---

## Summary

All Docker images are already pushed to Docker Hub under `marky731/camera-project`. You're ready to deploy to the RTX 5090 GPU server!

## What's Ready

✅ **10/10 Docker images pushed to Docker Hub**
- All core recording/transcoding services: ✅
- transcoder-combined (4.23GB with CUDA): ✅
- streaming-service (806MB): ✅ Just pushed!

✅ **Configuration files created**
- `camera-v2/docker-compose.5090.yml` - GPU-enabled compose file
- `camera-v2/.env.5090` - Environment template

---

## Quick Deployment Steps

### 1. On Your Current Test Server (Optional - Build Streaming Service)

```bash
# Only if you need live streaming (optional)
cd /home/nbadmin/camera-project
./scripts/build-streaming-service.sh
```

### 2. On RunPod GPU Server

```bash
# Setup
mkdir -p /workspace/camera-v2
cd /workspace/camera-v2

# Copy files from test server
# (docker-compose.5090.yml and .env.5090)
```

### 3. Configure Environment

```bash
# Edit .env file
cp .env.5090 .env
nano .env

# Update these values:
# - POSTGRES_PASSWORD
# - RABBITMQ_PASSWORD
# - S3_ACCESS_KEY
# - S3_SECRET_KEY
# - RUNPOD_IP (your RunPod public IP)
```

### 4. Deploy

```bash
# Pull all images from Docker Hub
docker-compose -f docker-compose.5090.yml pull

# Start services
docker-compose -f docker-compose.5090.yml up -d

# Verify GPU access
docker exec camera-v2-transcoder-combined nvidia-smi

# Check logs
docker-compose -f docker-compose.5090.yml logs -f transcoder-combined
```

---

## Key Differences: Phase 1 vs Phase 2

| Aspect | Phase 1 (Test Server) | Phase 2 (5090 GPU Server) |
|--------|----------------------|---------------------------|
| Images | Built locally | Pulled from Docker Hub |
| GPU | `--no-gpu` flag | GPU enabled |
| Transcoding | Skipped (pass-through) | Full GPU transcoding |
| Environment | Development | Production |
| S3 | Wasabi test | Production MinIO |

---

## Verification Checklist

After deployment on RTX 5090 server:

### GPU Check
```bash
# Should show RTX 5090
docker exec camera-v2-transcoder-combined nvidia-smi

# Logs should show GPU init
docker logs camera-v2-transcoder-combined 2>&1 | grep -i "gpu\|cuda\|nvenc"
```

### Service Health
```bash
# All services healthy
docker-compose -f docker-compose.5090.yml ps

# Transcoder API
curl http://localhost:8080/health

# Bridge API
curl http://localhost:8084/health

# RabbitMQ Management
open http://localhost:15672
# Login: dev / <RABBITMQ_PASSWORD>
```

### End-to-End Test
```bash
# Monitor transcoding with GPU
watch -n 1 nvidia-smi

# Check transcoder logs for GPU usage
docker logs -f camera-v2-transcoder-combined | grep -i "nvenc\|gpu"

# Verify S3 uploads
docker logs camera-v2-s3-uploader | grep "Upload successful"
```

---

## Troubleshooting

### GPU Not Accessible

**Error**: `CUDA not found` or `No NVIDIA GPU`

**Solution**:
```bash
# Check nvidia-docker runtime
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi

# If fails, install nvidia-docker2
apt-get update
apt-get install -y nvidia-docker2
systemctl restart docker
```

### Images Not Pulling

**Error**: `manifest not found`

**Solution**:
```bash
# Login to Docker Hub
docker login
# Username: marky731
# Password: <your_docker_hub_token>

# Manually pull
docker pull marky731/camera-project:transcoder-combined
```

### Streaming Service Missing (Optional)

If you need live streaming, build and push it:

```bash
# On test server
cd /home/nbadmin/camera-project
./scripts/build-streaming-service.sh

# On 5090 server, re-pull
docker-compose -f docker-compose.5090.yml pull
```

---

## Performance Expectations

With RTX 5090:

- **Throughput**: 1,500-2,500+ segments/minute
- **GPU Utilization**: 60-90%
- **Transcoding Quality**: 3-5 Mbps (configurable in transcoder.c)
- **Latency**: <100ms per segment
- **Memory**: ~2GB per container

---

## Files Summary

### Created Files

1. **`camera-v2/docker-compose.5090.yml`**
   - Uses Docker Hub images (no local builds)
   - GPU enabled for transcoder
   - Production environment settings

2. **`camera-v2/.env.5090`**
   - Template for 5090 server environment
   - Fill in your credentials before deployment

3. **`scripts/build-streaming-service.sh`**
   - Builds missing streaming-service (optional)
   - Only needed if you want live MJPEG streams

### Transfer to RunPod

```bash
# On test server
cd /home/nbadmin/camera-project/camera-v2
tar czf 5090-deployment.tar.gz docker-compose.5090.yml .env.5090

# Copy to RunPod
scp -P <PORT> 5090-deployment.tar.gz root@<RUNPOD_IP>:/workspace/

# On RunPod
cd /workspace
tar xzf 5090-deployment.tar.gz
mv docker-compose.5090.yml docker-compose.yml
mv .env.5090 .env
nano .env  # Edit with your credentials
```

---

## Next Steps

### Phase 2A: On Current Test Server (Preparation)

1. ✅ **All images pushed to Docker Hub** - Complete!
   - 10/10 services ready on `marky731/camera-project`
   - streaming-service: ✅ Built and pushed

2. **Package deployment files**
   ```bash
   cd /home/nbadmin/camera-project/camera-v2
   tar czf 5090-deployment.tar.gz docker-compose.5090.yml .env.5090
   ```

3. **Transfer to RunPod** (replace with your RunPod details)
   ```bash
   # Get RunPod connection details from RunPod dashboard
   # Example: scp -P 12345 5090-deployment.tar.gz root@1.2.3.4:/workspace/
   scp -P <RUNPOD_SSH_PORT> 5090-deployment.tar.gz root@<RUNPOD_IP>:/workspace/
   ```

### Phase 2B: On RunPod GPU Server (Deployment)

**When you SSH into RunPod and start working there, follow these steps:**

#### Step 1: Extract Deployment Files
```bash
cd /workspace
tar xzf 5090-deployment.tar.gz

# Create working directory
mkdir -p camera-v2
mv docker-compose.5090.yml camera-v2/docker-compose.yml
mv .env.5090 camera-v2/.env
cd camera-v2
```

#### Step 2: Configure Environment Variables
```bash
# Edit .env file with production credentials
nano .env

# Required values to update:
# - POSTGRES_PASSWORD=<strong_password>
# - RABBITMQ_PASSWORD=<strong_password>
# - S3_ACCESS_KEY=<your_minio_key>
# - S3_SECRET_KEY=<your_minio_secret>
# - RUNPOD_IP=<your_runpod_public_ip>

# Verify environment file
cat .env
```

#### Step 3: Verify GPU Access
```bash
# Check NVIDIA GPU is available
nvidia-smi

# Should show RTX 5090 or available GPU
# If not found, install NVIDIA drivers

# Test Docker GPU access
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi

# If error, install nvidia-docker2:
# apt-get update && apt-get install -y nvidia-docker2
# systemctl restart docker
```

#### Step 4: Pull All Docker Images
```bash
# Login to Docker Hub (if images are private)
docker login
# Username: marky731
# Password: <your_docker_hub_token>

# Pull all images (this will take time - ~8GB total)
docker-compose pull

# Verify images pulled
docker images | grep marky731
```

#### Step 5: Start Services
```bash
# Start all services in background
docker-compose up -d

# Watch logs during startup
docker-compose logs -f

# Ctrl+C to exit logs when all services healthy
```

#### Step 6: Verify Deployment
```bash
# Check all services are running
docker-compose ps

# Should show all services as "Up" or "healthy"

# Check transcoder GPU access
docker exec camera-v2-transcoder-combined nvidia-smi

# Should show GPU being used by processes

# Check transcoder logs for GPU initialization
docker logs camera-v2-transcoder-combined 2>&1 | grep -i "gpu\|cuda\|nvenc" | tail -20

# Expected: "CUDA initialized", "NVENC available", etc.
```

#### Step 7: Test Service Endpoints
```bash
# Test Transcoder API
curl http://localhost:8080/health

# Test TranscoderBridge
curl http://localhost:8084/health

# Test Player API
curl http://localhost:8083/health

# Access RabbitMQ Management UI (from browser)
# http://<RUNPOD_IP>:15672
# Login: dev / <RABBITMQ_PASSWORD from .env>
```

#### Step 8: Monitor GPU Transcoding
```bash
# Open GPU monitor in one terminal
watch -n 1 nvidia-smi

# In another terminal, watch transcoder logs
docker logs -f camera-v2-transcoder-combined

# Look for:
# - Segments being processed
# - GPU utilization increasing
# - NVENC encoder working
# - Completion callbacks
```

#### Step 9: Verify End-to-End Pipeline

**Option A: If you have Panel API access (create recording job)**
```bash
# Access Panel Frontend
# http://<RUNPOD_IP>:3000

# Create a camera and recording schedule
# Monitor the pipeline:
# 1. Recorder creates raw segments
# 2. TranscoderBridge receives messages
# 3. Transcoder processes with GPU
# 4. S3Uploader uploads to MinIO
```

**Option B: Manual test with sample video**
```bash
# Create test segment (if needed)
# Place in /data directory accessible to recorder container
docker exec camera-v2-recorder-scheduler ls /data
```

#### Step 10: Troubleshooting (If Issues)

**If services fail to start:**
```bash
# Check logs
docker-compose logs <service-name>

# Common issues:
# - Database connection: Check POSTGRES_PASSWORD in .env
# - RabbitMQ connection: Check RABBITMQ_PASSWORD in .env
# - S3 connection: Check S3_ACCESS_KEY and S3_SECRET_KEY
```

**If GPU not working:**
```bash
# Check CUDA version
nvcc --version

# Check Docker runtime
docker info | grep -i runtime

# Restart transcoder with GPU debug
docker-compose restart transcoder-combined
docker logs -f camera-v2-transcoder-combined
```

**If transcoding fails:**
```bash
# Check transcoder logs
docker logs camera-v2-transcoder-combined | tail -50

# Check bridge logs
docker logs camera-v2-transcoder-bridge

# Check RabbitMQ queues
docker exec camera-v2-rabbitmq rabbitmqctl list_queues
```

### Phase 2C: Production Readiness

Once everything is working:

1. **Set up monitoring**
   - Create health check script (see health-check.sh example above)
   - Set up log rotation
   - Configure alerting

2. **Backup strategy**
   - Database dumps: `docker exec camera-v2-recording-jobs-public-db pg_dump ...`
   - Volume backups
   - .env file backup

3. **Performance tuning**
   - Adjust S3Uploader__MaxConcurrentUploads based on network
   - Monitor GPU temperature and utilization
   - Scale services if needed

4. **Security hardening**
   - Change default passwords
   - Configure firewall rules
   - Enable SSL/TLS for internal communication (if needed)

---

## Quick Reference Commands (For RunPod)

```bash
# Status check
docker-compose ps

# View logs
docker-compose logs -f [service-name]

# Restart service
docker-compose restart [service-name]

# Stop all
docker-compose down

# Start all
docker-compose up -d

# GPU check
docker exec camera-v2-transcoder-combined nvidia-smi

# Database access
docker exec -it camera-v2-recording-jobs-public-db psql -U cloudcam -d cloudcam_public

# RabbitMQ queues
docker exec camera-v2-rabbitmq rabbitmqctl list_queues

# Disk usage
docker system df
df -h

# Update images (after push new version)
docker-compose pull
docker-compose up -d
```

---

**Status**: ✅ Ready to deploy! All prerequisites met. Follow Phase 2B steps when on RunPod server. 🎉
