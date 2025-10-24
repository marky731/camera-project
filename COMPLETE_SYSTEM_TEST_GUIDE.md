# Complete System Test Guide - Phase 1 with Panel

## Overview

This guide shows you how to test the **complete system** including:
- ✅ camera-v2 services (Recorder, Transcoder, S3Uploader, etc.)
- ✅ camera-v2-panel (Admin Panel)
- ✅ **ALL isolated from production** - safe to test!

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    TEST SERVER (172.17.12.200)                    │
│                          LOCALHOST ONLY                           │
└──────────────────────────────────────────────────────────────────┘

camera-v2/ (Core Services):
├─ PostgreSQL DBs (ports 5433-5435)
│  └─ cloudcam_public_local, recorder_scheduler_local, playlist_manager_local
├─ RabbitMQ (ports 5672, 15672)
│  └─ vhost: cloudcam_local
├─ RecorderScheduler (port 8081)
├─ Recorder
├─ TranscoderBridge (port 8084)
├─ Transcoder (port 8080) --no-gpu mode
├─ S3Uploader → YOUR Wasabi bucket
├─ PlaylistManager (port 8082)
├─ Player API (port 8083)
└─ Player Frontend (port 3001)

camera-v2-panel/ (Admin Panel):
├─ PostgreSQL (port 5436)
│  └─ CameraPanelDB
├─ Panel API (port 8084) → connects to camera-v2 LOCAL DBs via host.docker.internal
├─ Panel Frontend (port 3000)
└─ Streaming Service (port 8085)
```

## Complete Isolation from Production

| Component | Production | Your Test | Connection Method |
|-----------|------------|-----------|-------------------|
| **camera-v2 DBs** | cloudcam_public @ prod | cloudcam_public_local @ localhost:5433 | Local Docker containers |
| **Panel DB** | CameraPanelDB @ prod | CameraPanelDB @ localhost:5436 | Local Docker container |
| **RabbitMQ** | cloudcam @ prod | cloudcam_local @ localhost | Local Docker container |
| **S3 Storage** | Production bucket | YOUR test bucket | Via .env credentials |
| **RecorderScheduler** | prod API | localhost:8081 | Panel uses host.docker.internal |

## Step-by-Step Setup

### 1. Setup camera-v2 Services

```bash
cd /home/nbadmin/camera-project/camera-v2

# Create .env file
cp .env.example .env
nano .env
```

**Fill in camera-v2/.env:**
```bash
# PostgreSQL Local
POSTGRES_PASSWORD_LOCAL=choose_strong_password

# RabbitMQ Local
RABBITMQ_PASSWORD_LOCAL=choose_strong_rabbitmq_pass

# Wasabi S3 (YOUR test bucket)
S3_ENDPOINT_LOCAL=s3.wasabisys.com
S3_BUCKET_NAME_LOCAL=your-test-bucket-name
S3_ACCESS_KEY=your_wasabi_access_key
S3_SECRET_KEY=your_wasabi_secret_key
S3_USE_SSL_LOCAL=true
S3_CDN_BASE_URL_LOCAL=https://s3.wasabisys.com/your-test-bucket-name
```

### 2. Setup Panel

```bash
cd /home/nbadmin/camera-project/camera-v2-panel

# Create .env file
cp .env.example .env
nano .env
```

**Fill in camera-v2-panel/.env:**
```bash
# Panel's own DB
DB_PASSWORD=choose_panel_db_password

# Connect to camera-v2 LOCAL public DB
# ⚠️ MUST match POSTGRES_PASSWORD_LOCAL from camera-v2/.env
POSTGRES_PASSWORD_LOCAL=same_password_as_camera_v2

# Production DB password (ignored by override)
PUBLIC_DB_PASSWORD=ignored

# Panel API keys
INTERNAL_API_KEY=your_api_key_here
JWT_SECRET_KEY=YourSuperSecretKeyThatIsAtLeast32CharactersLong!
```

### 3. Start camera-v2 Services First

```bash
cd /home/nbadmin/camera-project/camera-v2

# Start all camera-v2 services
docker-compose up -d

# Wait for all services to be healthy (30-60 seconds)
watch docker-compose ps
# Press Ctrl+C when all show "healthy" or "running"

# Check logs for migration success
docker-compose logs recorder-scheduler | grep "migrations applied"
docker-compose logs playlist-manager | grep "migrations applied"
```

**Expected output:**
```
✓ All 11 services running
✓ Databases: healthy
✓ RabbitMQ: healthy
✓ Migrations applied successfully
```

### 4. Start Panel Services

```bash
cd /home/nbadmin/camera-project/camera-v2-panel

# Start Panel services
docker-compose up -d

# Check Panel logs
docker-compose logs -f api
```

**Look for:**
```
Successfully connected to public database: cloudcam_public_local
Successfully connected to RecorderScheduler: http://host.docker.internal:8081
Panel API started successfully
```

### 5. Verify Complete System

#### Check All Services

```bash
# camera-v2 services
cd /home/nbadmin/camera-project/camera-v2
docker-compose ps

# Panel services
cd /home/nbadmin/camera-project/camera-v2-panel
docker-compose ps
```

**Expected: All services "healthy" or "running"**

#### Access Web Interfaces

**camera-v2 Services:**
- RabbitMQ Management: http://localhost:15672
  - User: `local_dev`
  - Pass: (your RABBITMQ_PASSWORD_LOCAL)
- Player Frontend: http://localhost:3001
- Transcoder API: http://localhost:8080/health

**Panel Services:**
- Panel Frontend: http://localhost:3000
- Panel API: http://localhost:8084/health
- Streaming Service: http://localhost:8085/health

#### Test Database Connections

```bash
# Test camera-v2 public DB
docker exec -it camera-v2-recording-jobs-public-db psql -U local_user -d cloudcam_public_local -c "SELECT COUNT(*) FROM recording_jobs;"

# Test Panel DB
docker exec -it camera-panel-db psql -U postgres -d CameraPanelDB -c "\dt"
```

## Testing the Complete Flow

### 1. Create Recording Job via Panel

1. Open http://localhost:3000
2. Login to Panel (or register new user)
3. Navigate to "Recording Jobs"
4. Click "Create New Recording Job"
5. Fill in:
   - Camera RTSP URL
   - Resolution: 1920x1080
   - Duration: 60 seconds (1 minute test)
6. Submit

### 2. Monitor the Pipeline

**Watch RabbitMQ Messages:**
1. Open http://localhost:15672
2. Go to "Queues" tab
3. Watch messages flow:
   - `segment.transcode.queue` ← Raw segments from Recorder
   - `segment.upload.queue` ← Transcoded segments to S3Uploader

**Watch Service Logs:**

```bash
# Terminal 1: Recorder
cd /home/nbadmin/camera-project/camera-v2
docker-compose logs -f recorder

# Terminal 2: TranscoderBridge
docker-compose logs -f transcoder-bridge

# Terminal 3: Transcoder
docker-compose logs -f transcoder

# Terminal 4: S3Uploader
docker-compose logs -f s3-uploader
```

**Expected Log Flow:**
```
[Recorder] Starting recording for job {id}
[Recorder] Segment completed: 0.ts
[Recorder] Published segment.raw.ready message

[TranscoderBridge] Received raw segment message
[TranscoderBridge] Calling transcoder API: POST /enqueue

[Transcoder] ⚠️ NO-GPU mode: 0.ts (would transcode if GPU available)
[Transcoder] ✓ Acknowledgment sent

[TranscoderBridge] Received completion callback
[TranscoderBridge] Published segment.transcoded.ready message

[S3Uploader] Received transcoded segment message
[S3Uploader] ✓ Successfully uploaded segment: 0.ts
```

### 3. Verify S3 Upload

Check your Wasabi test bucket:
```
your-test-bucket/
└─ {recording-id}/
    ├─ 0.ts
    ├─ 1.ts
    ├─ 2.ts
    ...
```

### 4. View Recording in Panel

1. Go back to Panel: http://localhost:3000
2. Navigate to "Recordings" or "Playlist Manager"
3. Find your recording
4. Click "Play" to view

## Troubleshooting

### Panel Can't Connect to camera-v2 DBs

**Symptom:** Panel API logs show connection errors

**Solution:**
```bash
# Verify camera-v2 DB is accessible on host
docker exec -it camera-v2-recording-jobs-public-db psql -U local_user -d cloudcam_public_local -c "SELECT 1;"

# Check Panel is using correct password
cd /home/nbadmin/camera-project/camera-v2-panel
cat .env | grep POSTGRES_PASSWORD_LOCAL

# Should match camera-v2/.env
cd /home/nbadmin/camera-project/camera-v2
cat .env | grep POSTGRES_PASSWORD_LOCAL
```

### Services Can't Start

```bash
# Check port conflicts
sudo netstat -tuln | grep -E "5433|5434|5435|5436|8080|8081|8082|8083|8084|8085|3000|3001"

# Restart everything
cd /home/nbadmin/camera-project/camera-v2
docker-compose down -v
docker-compose up -d

cd /home/nbadmin/camera-project/camera-v2-panel
docker-compose down -v
docker-compose up -d
```

### Transcoder Not Working

```bash
# Check transcoder is running in no-GPU mode
docker-compose logs transcoder | grep "NO-GPU"

# Should see: "⚠️ NO-GPU TEST MODE (Phase 1)"
```

### S3 Upload Fails

```bash
# Test S3 credentials
docker-compose logs s3-uploader | grep -i "error"

# Verify bucket exists in Wasabi
# Check .env has correct S3_BUCKET_NAME_LOCAL
```

## Port Reference

| Service | Port | URL |
|---------|------|-----|
| **camera-v2** | | |
| PostgreSQL (Public) | 5433 | - |
| PostgreSQL (Scheduler) | 5434 | - |
| PostgreSQL (Playlist) | 5435 | - |
| RabbitMQ | 5672 | - |
| RabbitMQ Management | 15672 | http://localhost:15672 |
| RecorderScheduler API | 8081 | http://localhost:8081 |
| Transcoder API | 8080 | http://localhost:8080 |
| PlaylistManager API | 8082 | http://localhost:8082 |
| Player API | 8083 | http://localhost:8083 |
| Player Frontend | 3001 | http://localhost:3001 |
| **camera-v2-panel** | | |
| PostgreSQL (Panel) | 5436 | - |
| Panel API | 8084 | http://localhost:8084 |
| Streaming Service | 8085 | http://localhost:8085 |
| Panel Frontend | 3000 | http://localhost:3000 |

## Cleanup

### Stop Everything

```bash
# Stop camera-v2
cd /home/nbadmin/camera-project/camera-v2
docker-compose down

# Stop Panel
cd /home/nbadmin/camera-project/camera-v2-panel
docker-compose down
```

### Reset All Data

```bash
# ⚠️ This deletes ALL local test data!

# Reset camera-v2
cd /home/nbadmin/camera-project/camera-v2
docker-compose down -v

# Reset Panel
cd /home/nbadmin/camera-project/camera-v2-panel
docker-compose down -v
```

## Safety Verification

**Before testing, verify isolation:**

```bash
# Check camera-v2 is using LOCAL settings
cd /home/nbadmin/camera-project/camera-v2
grep "_local" docker-compose.override.yml
# Should see: lots of "_local" suffixes

# Check Panel is using override file
cd /home/nbadmin/camera-project/camera-v2-panel
cat docker-compose.override.yml | grep "host.docker.internal"
# Should see: connections to host.docker.internal (localhost)
```

**Verify no production connections:**
```bash
# Check Panel NOT connecting to production
cd /home/nbadmin/camera-project/camera-v2-panel
docker-compose config | grep "172.17.12.97"
# Should see: NONE (using host.docker.internal instead)
```

## Summary

✅ **Complete System Testing:**
- camera-v2: All 11 services
- camera-v2-panel: All 4 services
- Total: 15 services running locally

✅ **100% Isolated from Production:**
- Different database names (_local suffix)
- Different Docker volumes (_local suffix)
- Different RabbitMQ vhost (cloudcam_local)
- Your test S3 bucket (not production)
- Panel connects via localhost (host.docker.internal)

✅ **Safe to Test:**
- No risk to production data
- No risk to production services
- Complete test environment on localhost

**Start testing! Create recordings via Panel and watch them flow through the complete pipeline!** 🚀
