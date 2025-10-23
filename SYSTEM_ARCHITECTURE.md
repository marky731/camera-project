# CloudCam 24/7 System Architecture

## System Overview
CloudCam 24/7 is a comprehensive cloud-based video surveillance system designed for continuous recording, live streaming, and playback of IP camera feeds. The system uses microservices architecture with Docker containerization and supports multi-tenant SaaS operations.

## Architecture Diagram
```
┌─────────────────────────────────────────────────────────────────┐
│              Nginx Reverse Proxy (HTTPS Gateway)                │
│                     cam.narbulut.com:443                        │
└────────┬──────────┬──────────┬──────────┬──────────┬───────────┘
         ↓          ↓          ↓          ↓          ↓
    [/api/*]   [/stream/*]  [/player/*] [/player-api/*]  [/*]
         ↓          ↓          ↓          ↓          ↓
┌────────┴──────────┴──────────┴──────────┴──────────┴───────────┐
│  Panel API   │ Streaming │ Player      │ Player API │  Panel    │
│  (.NET 9)    │ Service   │ Frontend    │ (.NET 9)   │ Frontend  │
│  Port 8084   │ Port 8085 │ Port 3001   │ Port 8083  │ Port 3000 │
└──────┬───────┴─────┬─────┴──────┬──────┴─────┬──────┴───────────┘
       │              │               │
       ▼              ▼               ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Orchestration & Processing                     │
├──────────────────┬───────────────────┬──────────────────────────┤
│ RecorderScheduler│  RabbitMQ (5672)  │  PlaylistManager (8082)  │
│  (Port 8081)     │    Message Bus     │   HLS Manifest Service   │
└────────┬─────────┴─────────┬─────────┴──────────┬───────────────┘
         │                   │                    │
         ▼                   ▼                    ▼
┌────────────────┬───────────────────┬───────────────────┐
│    Recorder    │   S3 Uploader     │   Player API      │
│    Service     │    Service        │   (uses PM)       │
└────────────────┴───────────────────┴───────────────────┘
┌──────────────────────────────┼──────────┼──────────┼───────────┐
│         Storage Layer         │          │          │           │
├────────────┬──────────────────┼──────────┼──────────┼───────────┤
│ PostgreSQL │   PostgreSQL     │  NFS     │   MinIO  │           │
│  (Panel)   │   (Shared)       │  Mount   │   (S3)   │           │
└────────────┴──────────────────┴──────────┴──────────┴───────────┘
```

## Service Components

### 1. Management Layer

#### Panel API (Port 8084)
- **Purpose**: Central management API for cameras, users, licenses
- **Technology**: .NET 9, Entity Framework Core
- **Database**: PostgreSQL (CameraPanelDB)
- **Features**: JWT auth, multi-tenant, role-based access

#### Panel Frontend (Port 3000)
- **Purpose**: Admin dashboard and camera management UI
- **Technology**: React 19, TypeScript, Chakra UI
- **Features**: Real-time thumbnails, recording control, license management
- **Access**: Served via Nginx at `/`

#### Streaming Service (Port 8085)
- **Purpose**: Live MJPEG streaming from RTSP cameras
- **Technology**: .NET 9, FFmpeg
- **Pattern**: Pub-sub with channels for multi-client streaming

### 2. Recording Pipeline

#### RecorderScheduler (Port 8081)
- **Purpose**: Schedules WHEN recordings should start/stop
- **Technology**: .NET 9, Quartz.NET
- **Features**: Cron scheduling, retry mechanism, message publishing
- **Important**: Does NOT manage Docker containers - communicates with Recorder service via RabbitMQ messages only

#### Recorder Service
- **Purpose**: Handles HOW to capture RTSP streams using FFmpeg
- **Technology**: .NET 9, FFmpeg, SQLite
- **Pattern**: Event-driven with outbox pattern
- **Deployment**: Runs as independent service, NOT containerized by RecorderScheduler

#### S3Uploader Service
- **Purpose**: Uploads segments to object storage
- **Technology**: .NET 9, MinIO client
- **Features**: Concurrent uploads, retry logic

#### PlaylistManager (Port 8082)
- **Purpose**: Manages HLS playlists and signed URLs
- **Technology**: .NET 9, PostgreSQL
- **Features**: Time-range queries, manifest generation

### 3. Playback Layer

#### Player API (Port 8083)
- **Purpose**: Playback orchestration and manifest serving
- **Technology**: .NET 9, ASP.NET Core
- **Integration**: PlaylistManager client

#### Player Frontend (Port 3001)
- **Purpose**: Video playback interface
- **Technology**: React 18, TypeScript, Material-UI, Video.js, HLS.js
- **Features**: Timeline navigation, calendar picker, 24-hour timeline
- **Access**: Served via Nginx at `/player/`

## Data Flow Patterns

### Recording Flow
```
RecorderScheduler → RabbitMQ (recording.requests) → Recorder Service
                                                          ↓
                                                    Camera (RTSP)
                                                          ↓
                                                    FFmpeg Process
                                                          ↓
HLS Segments → NFS Storage (/mnt/NBNAS/cameraswarm) → S3Uploader
                     ↓                                      ↓
            RabbitMQ (segment.uploads)              MinIO/S3 Storage
                     ↓                                      ↓
            PlaylistManager ← RabbitMQ (playlist.created) ←┘
```

### Live Streaming Flow
```
User → Panel Frontend → Streaming Service → FFmpeg (RTSP→MJPEG)
         ↓                    ↓
    Thumbnail Capture    StreamBroadcaster → Subscribers
```

### Playback Flow
```
User → Player Frontend → Player API → PlaylistManager
            ↓                              ↓
       Video.js ← Signed URLs ← S3/CDN ← Manifest
```

## Communication Patterns

### Synchronous (HTTP/REST)
- Panel Frontend ↔ Panel API (JWT auth via /api)
- Panel API → RecorderScheduler (internal API key)
- Player Frontend ↔ Player API (via /player-api)
- Player API → PlaylistManager (http://playlist-manager:8082)
- Streaming Service → Panel API (internal service calls)

### Asynchronous (RabbitMQ)
- **Exchanges**: 
  - `recording.events.fanout` - Broadcast events
- **Queues**:
  - `recording.requests` - Start commands
  - `recording.premature_exits` - Failures
  - `segment.uploads` - Upload tasks
  - `playlist.created` - Playlist events

### Database Architecture

#### Dual Database Pattern
- **Public Database** (`cloudcam_public` on port 5433)
  - Shared RecordingJobs table
  - Accessed by Panel API and RecorderScheduler
  - Postgres user: cloudcam

#### Service-Specific Databases
- **Panel Database** (`CameraPanelDB` on port 5436)
  - Users, Organizations, Cameras, Licenses
  - Postgres user: postgres
  
- **RecorderScheduler Database** (`recorder_scheduler` on port 5434)
  - Recordings (session tracking)
  - RecordingRetryStates
  - Postgres user: dev
  
- **PlaylistManager Database** (`playlist_manager` on port 5435)
  - MasterPlaylists, Playlists
  - Postgres user: dev
  
- **Recorder Local** (SQLite per instance)
  - RecordingSessions, SegmentInfo
  - Local to each Recorder instance

## Deployment Architecture

### Docker Compose (Development)
- Service containerization
- Local PostgreSQL instances
- Development networking
- Volume mounts for data

### Docker Swarm (Production)

#### Multi-Stack Deployment
- **docker-stack-databases-only.yml**: All PostgreSQL databases
- **docker-stack-rabbitmq-host.yml**: RabbitMQ with host networking
- **docker-stack-nginx.yml**: HTTPS reverse proxy
- **docker-stack-app-https.yml**: Application services

#### Node Distribution
```yaml
Manager Node (172.17.12.97):
  - All PostgreSQL databases (data consistency)
  - RabbitMQ (host networking for cross-node access)
  - RecorderScheduler (Docker socket access)
  - Panel API, Streaming Service
  - Nginx reverse proxy
  
Worker Nodes:
  - Recorder instances (scalable)
  - S3Uploader instances (scalable)
  
Shared Resources:
  - NFS Mount: /mnt/NBNAS/cameraswarm (video storage)
  - External Network: camera-network
```

#### Production URLs & Routing
- **Public Access**: https://cam.narbulut.com
- **Nginx Reverse Proxy**: 
  - `/` → panel-frontend:80 (React app)
  - `/api/` → panel-api:8080 (Backend API)
  - `/stream/` → streaming-service:8080
  - `/player/` → player-frontend:3001
  - `/player-api/` → player-api:8080
  - `/playlist/` → playlist-manager:8082
- **Internal Communication**: Services use Docker DNS names
- **RabbitMQ**: Hardcoded IP 172.17.12.97 (host networking)

## Security Architecture

### Authentication & Authorization
- **Users**: JWT tokens with role claims
- **Services**: Internal API keys
- **Roles**: SuperAdmin, OrgAdmin, OrgUser

### Network Security
- Docker network isolation
- HTTPS termination at proxy
- Service-to-service authentication
- No direct database access

### Data Security
- Password hashing (BCrypt)
- Signed URLs for S3 access
- Multi-tenant data isolation
- Audit logging

## Scalability Design

### Horizontal Scaling
- **Stateless**: Panel API, Player API, S3Uploader
- **Scalable**: Recorder (multiple instances)
- **Singleton**: RecorderScheduler (Quartz limitation)

### Performance Optimizations
- Database connection pooling
- Efficient query indexes
- Message queue decoupling
- CDN for video delivery
- Thumbnail caching

### Resource Management
- Docker resource limits
- Concurrent upload limits
- FFmpeg process management
- Connection pooling

## Monitoring & Observability

### Logging
- Structured logging (Serilog)
- Service-specific log files
- Error tracking
- Performance metrics

### Health Checks
- Service health endpoints
- Database connectivity
- Message queue status
- Storage accessibility

### Metrics
- Recording success rates
- Upload performance
- Stream quality
- API response times

## Data Models

### Core Entities
- **User**: Authentication and roles
- **Organization**: Multi-tenant isolation
- **Camera**: RTSP configuration
- **License**: Recording capabilities
- **RecordingJob**: Recording configuration
- **Recording**: Session tracking
- **Playlist**: HLS manifest data

### Relationships
```
Organization 1→N Camera
Camera 1→1 License
Camera 1→N RecordingJob
RecordingJob 1→N Recording
Recording 1→N Segment
MasterPlaylist 1→N Playlist
```

## Technology Stack Summary

### Backend
- **.NET 9**: All services use .NET 9
- **PostgreSQL**: Relational data
- **SQLite**: Local session data (Recorder)
- **RabbitMQ**: Message broker
- **Docker**: Containerization
- **FFmpeg**: Video processing

### Frontend
- **React**: UI framework (Panel: React 19, Player: React 18)
- **TypeScript**: Type safety
- **Chakra UI**: Panel Frontend component library
- **Material-UI (MUI)**: Player Frontend component library
- **Video.js**: Video playback engine
- **HLS.js**: HLS protocol support
- **Vite**: Build tooling for Player Frontend
- **React Scripts**: Build tooling for Panel Frontend (based on Webpack)

### Infrastructure
- **Docker Swarm**: Orchestration
- **Nginx**: Reverse proxy
- **MinIO**: S3 storage
- **NFS**: Shared storage
- **SSL Certificates**: Custom certificates (public.cer/private.key)

## Key Design Patterns

### Architectural Patterns
- **Microservices**: Service separation
- **Event-Driven**: Async communication
- **API Gateway**: Unified entry
- **Saga Pattern**: Distributed transactions

### Implementation Patterns
- **Outbox Pattern**: Reliable messaging
- **Retry Pattern**: Failure recovery
- **Circuit Breaker**: Service resilience
- **CQRS**: Command/query separation

## Current Implementation Reality

### Important Clarifications for Claude Sessions
1. **RecorderScheduler vs Recorder Separation**
   - RecorderScheduler: Manages WHEN to record (scheduling logic)
   - Recorder: Manages HOW to record (FFmpeg execution)
   - Communication: Message-based only via RabbitMQ
   - No direct process management between services

2. **Docker Integration Status**
   - RecorderScheduler contains unused Docker API code (dead code not registered in DI container)
   - RecorderScheduler does NOT manage Docker containers
   - Recorder service runs independently as a separate service
   - Communication between RecorderScheduler and Recorder is message-based via RabbitMQ only

3. **Message Flow Reality**
   - RecorderScheduler publishes StartRecordingMessage to recording.requests queue
   - Recorder service consumes messages and manages FFmpeg processes
   - No StopRecordingMessage exists - recordings run to completion
   - Job deletion doesn't terminate active recordings

4. **Network Architecture**
   - RabbitMQ uses host networking with hardcoded IP (172.17.12.97)
   - Services internally use Docker DNS names
   - Nginx provides HTTPS termination at cam.narbulut.com
   - NFS mount at /mnt/NBNAS/cameraswarm for shared storage

## System Constraints

### Current Limitations
1. Single-quality recording only
2. No redundant recording
3. Quartz single-instance limitation (no clustering)
4. SQLite concurrency limits in Recorder
5. MJPEG streaming only (no WebRTC)
6. **No active recording termination on job deletion** - deleting recording jobs only prevents future recordings, active FFmpeg processes continue until completion
7. **No cross-service recording status visibility** - RecorderScheduler cannot query active recording status from Recorder service
8. **No StopRecordingMessage** - no mechanism exists to terminate specific active recordings
9. Unused Docker integration code in RecorderScheduler (dead code)
10. Hardcoded IP addresses for RabbitMQ access

### Future Enhancements
1. Multi-bitrate adaptive streaming
2. AI-powered analytics
3. Distributed job scheduling
4. Real-time alerts
5. Mobile applications
6. Cloud-native redesign (Kubernetes)

## Disaster Recovery

### Backup Strategy
- Database backups (PostgreSQL)
- S3 replication
- Configuration backups
- Service state snapshots

### Recovery Procedures
- Service restart sequences
- Database restoration
- Message queue recovery
- Recording resumption

## Compliance & Standards

### Video Standards
- HLS (HTTP Live Streaming)
- H.264/H.265 codecs
- RTSP/RTP protocols
- MJPEG streaming

### Security Standards
- JWT RFC 7519
- TLS 1.2+
- OWASP guidelines
- GDPR compliance ready