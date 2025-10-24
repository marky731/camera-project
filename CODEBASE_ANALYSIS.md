# CloudCam 24/7 - Codebase Structure & Architecture Analysis

**Project**: GPU Transcoder Integration for CloudCam 24/7
**Analysis Date**: 2025-10-23
**Scope**: camera-v2 directory - Recorder, S3Uploader, PlaylistManager, Player services
**Focus**: Understanding existing patterns for TranscoderBridge implementation

---

## 1. OVERALL DIRECTORY STRUCTURE

```
camera-v2/
├── Recorder/                      # Recording service (FFmpeg orchestrator)
│   ├── Services/                  # Core business logic
│   ├── Models/                    # Data models & messages
│   ├── Configuration/             # Config classes
│   ├── Data/                      # SQLite Entity Framework context
│   ├── Migrations/                # Database migrations
│   ├── Program.cs                 # Service entry point
│   ├── Dockerfile                 # Multi-stage .NET 9 build
│   ├── appsettings.json           # Configuration
│   └── Recorder.csproj            # Project file
│
├── S3Uploader/                    # S3 upload service
│   ├── Services/                  # RabbitMQ consumer, S3Service
│   ├── Models/                    # Message definitions
│   ├── Configuration/             # Config classes
│   ├── Program.cs                 # Entry point
│   ├── Dockerfile                 # .NET 9 aspnet
│   ├── appsettings.json           # S3/RabbitMQ config
│   └── S3Uploader.csproj          # Project file
│
├── PlaylistManager/               # HLS playlist management
│   ├── Services/                  # RabbitMQ consumer
│   ├── Controllers/               # API endpoints
│   ├── Data/                      # EF Core DbContext
│   ├── Models/                    # Playlist models
│   └── Migrations/                # Database migrations
│
├── Player/                        # Playback services
│   ├── Player.API/                # .NET 9 API
│   ├── Player.Frontend/           # React 18 UI (Vite)
│   └── SERVICE_ANALYSIS.md
│
├── RecorderScheduler/             # Scheduling service
│   ├── Jobs/                      # Quartz job definitions
│   ├── Services/                  # RabbitMQ publisher
│   ├── Models/                    # Message/Job models
│   └── Dockerfile
│
└── docker-compose.yml             # Development orchestration
```

---

## 2. EXISTING SERVICES OVERVIEW

### 2.1 Recorder Service

**Location**: `/home/nbadmin/camera-project/camera-v2/Recorder`

**Purpose**: 
- Listens for recording requests on RabbitMQ
- Manages FFmpeg processes for RTSP stream capture
- Generates HLS segments (10-second TS files)
- Publishes segment completion messages

**Key Components**:

| Component | File | Responsibility |
|-----------|------|-----------------|
| FFmpegManager | `Services/FFmpegManager.cs` | FFmpeg process lifecycle, segment/playlist detection, stall detection |
| RabbitMQConsumer | `Services/RabbitMQConsumer.cs` | Consumes `recording.requests` queue, event handlers |
| RecordingService | `Services/RecordingService.cs` | Orchestrates recording flow, manages database state |
| OutboxService | `Services/OutboxService.cs` | Transactional message publishing (outbox pattern) |
| CameraHeartbeatService | `Services/CameraHeartbeatService.cs` | Network diagnostics for RTSP cameras |

**Technology Stack**:
- .NET 9 with Serilog logging
- RabbitMQ.Client 6.8.1 for messaging
- Entity Framework Core with SQLite (local to container)
- FFmpeg executable for video processing

**Directory Structure**:
```
Recorder/
├── Configuration/
│   ├── RecorderConfiguration.cs      # FFmpeg paths, timeouts, RTSP settings
│   └── RabbitMQConfiguration.cs      # Connection params, queue names
├── Data/
│   └── RecorderContext.cs            # SQLite DbContext
├── Models/
│   ├── Messages.cs                   # StartRecordingMessage, SegmentReadyMessage, etc.
│   ├── OutboxMessage.cs              # Outbox pattern + QueueNames/MessageTypes
│   ├── RecordingSession.cs           # Session tracking
│   └── SegmentInfo.cs                # Segment metadata
├── Services/
│   ├── FFmpegManager.cs              # 703 lines - FFmpeg orchestration
│   ├── IFFmpegManager.cs             # Interface
│   ├── RabbitMQConsumer.cs           # Message consumption
│   ├── RecordingService.cs           # Main orchestration
│   ├── OutboxService.cs              # Message persistence
│   └── CameraHeartbeatService.cs     # Network checks
└── Program.cs                        # Dependency injection setup
```

---

### 2.2 S3Uploader Service

**Location**: `/home/nbadmin/camera-project/camera-v2/S3Uploader`

**Purpose**:
- Consumes segment notifications from RabbitMQ
- Uploads TS segment files to MinIO/Wasabi S3
- Uploads final HLS playlist manifest
- Publishes playlist completion messages

**Key Components**:

| Component | File | Responsibility |
|-----------|------|-----------------|
| S3Service | `Services/S3Service.cs` | MinIO client operations, file uploads |
| RabbitMQConsumer | `Services/RabbitMQConsumer.cs` | Consumes `segment.ready` queue, RecordingStopped events |
| IS3Service | `Services/IS3Service.cs` | Interface for S3 operations |

**Technology Stack**:
- .NET 9 with Serilog
- Minio client library for S3 operations
- Host networking mode (docker-compose)
- Concurrent upload management (configurable max concurrency)

**Directory Structure**:
```
S3Uploader/
├── Configuration/
│   └── S3UploaderConfiguration.cs    # DataPath, MaxConcurrentUploads, timeout
├── Models/
│   └── Messages.cs                   # SegmentReadyMessage, RecordingStoppedMessage
├── Services/
│   ├── S3Service.cs                  # Upload logic, bucket management
│   ├── IS3Service.cs                 # Interface
│   ├── RabbitMQConsumer.cs           # 468 lines - dual queue consumer
│   └── IRabbitMQConsumer.cs          # Interface
└── Program.cs                        # Hosted service setup
```

**Configuration Files**:
- `appsettings.json`: S3 credentials (endpoint, bucket, access keys)
- `docker-compose.yml`: Environment variables for S3 endpoint flexibility

---

### 2.3 PlaylistManager Service

**Location**: `/home/nbadmin/camera-project/camera-v2/PlaylistManager`

**Purpose**:
- Consumes playlist completion events
- Maintains database of playlists and segments
- Generates signed URLs for playback
- Serves manifest files to Player API

**Key Features**:
- PostgreSQL database for playlist persistence
- RabbitMQ consumer for playlist.created and other events
- REST API for playlist queries
- Supports time-range queries for segment retrieval

---

### 2.4 Player Services

**Location**: `/home/nbadmin/camera-project/camera-v2/Player`

**Purpose**:
- Player.API: REST API for playback orchestration
- Player.Frontend: React UI for video playback

**Integration Points**:
- Calls PlaylistManager for manifest/segment lists
- Generates signed S3 URLs for segment retrieval

---

## 3. CURRENT RabbitMQ MESSAGE PATTERNS

### 3.1 Queue & Exchange Configuration

**Exchanges**:
- `recording.events.fanout` (Fanout): Broadcasts recording lifecycle events
- `playlist.events` (Fanout): Playlist completion events
- (No explicit exchange for segment messages - direct queue binding)

**Queues**:

| Queue Name | Type | Source | Consumer | Purpose |
|-----------|------|--------|----------|---------|
| `recording.requests` | Direct | RecorderScheduler | Recorder | Start recording commands |
| `segment.ready` | Direct | Recorder (OutboxService) | S3Uploader | Individual segment ready notifications |
| `recording.events.s3uploader` | Fanout bound | Recorder (OutboxService) | S3Uploader | Recording started/stopped lifecycle |
| `recording.premature_exits` | Direct | Recorder (OutboxService) | *(not consumed)* | Premature recording exit logs |
| `playlist.created` | Direct | Recorder (OutboxService) | PlaylistManager | Playlist file created |
| `playlist.events` | Fanout | S3Uploader | PlaylistManager | Playlist upload notifications |

---

### 3.2 Message Models & Flow

**StartRecordingMessage** (RecorderScheduler → Recorder)
```csharp
{
  "MessageId": "guid-string",
  "Timestamp": "2025-10-23T10:00:00Z",
  "RecordingJobId": "guid",
  "RecordingId": "guid",
  "RtspUrl": "rtsp://camera:554/stream",
  "Resolution": "1920x1080",
  "SegmentInterval": 10,
  "PathPrefix": null,
  "CameraId": "guid",
  "RunHours": "0-24",
  "ScheduledStartTime": "2025-10-23T10:00:00Z",
  "DurationSeconds": 3600,
  "TargetEndTime": "2025-10-23T11:00:00Z"
}
```

**SegmentReadyMessage** (Recorder → S3Uploader)
```csharp
{
  "MessageId": "guid-string",
  "Timestamp": "2025-10-23T10:00:10Z",
  "RecordingJobId": "guid",
  "RecordingId": "guid",
  "FileName": "0.ts",
  "FilePath": "/data/{jobId}/{recordingId}/0.ts",  // Absolute path
  "FileSize": 1048576,
  "Checksum": "abc123...",
  "SegmentStart": "2025-10-23T10:00:00Z",
  "SegmentEnd": "2025-10-23T10:00:10Z",
  "SegmentDuration": 10
}
```

**RecordingStoppedMessage** (Recorder → S3Uploader)
```csharp
{
  "MessageId": "guid-string",
  "Timestamp": "2025-10-23T11:00:00Z",
  "RecordingJobId": "guid",
  "RecordingId": "guid",
  "ContainerId": "...",
  "StoppedAt": "2025-10-23T11:00:00Z",
  "Reason": null,
  "IsError": false
}
```

**PlaylistUploadedMessage** (S3Uploader → PlaylistManager)
```csharp
{
  "MessageId": "guid-string",
  "Timestamp": "2025-10-23T11:00:00Z",
  "RecordingJobId": "guid",
  "RecordingId": "guid",
  "PlaylistPath": "{recordingJobId}/{recordingId}/playlist.m3u8",
  "S3Key": "segment-uuid/playlist.m3u8",
  "UploadedAt": "2025-10-23T11:00:00Z",
  "SegmentCount": 360,
  "UploadedSegments": ["guid/0.ts", "guid/1.ts", ...]
}
```

**Other Messages**:
- `RecordingStartedMessage`: Sent when FFmpeg starts successfully
- `RecordingPrematureExitMessage`: Sent on unexpected FFmpeg termination (with detailed diagnostics)
- `PlaylistCreatedMessage`: Sent when HLS playlist.m3u8 is created

---

### 3.3 Consumer Implementation Pattern

**RabbitMQ Consumer Architecture** (Used in Recorder, S3Uploader, PlaylistManager):

```csharp
// 1. Connection Factory Setup
var factory = new ConnectionFactory 
{
    HostName = config.Host,
    Port = config.Port,
    UserName = config.Username,
    Password = config.Password,
    VirtualHost = config.VirtualHost,
    AutomaticRecoveryEnabled = true,
    NetworkRecoveryInterval = TimeSpan.FromSeconds(10)
};

// 2. Queue Declaration (Idempotent)
_channel.QueueDeclare(
    queue: queueName,
    durable: true,          // Survives broker restart
    exclusive: false,       // Multiple consumers
    autoDelete: false       // Not auto-deleted
);

// 3. Consumer Setup
var consumer = new EventingBasicConsumer(_channel);
consumer.Received += async (model, ea) => 
{
    // Message handling
    var message = JsonSerializer.Deserialize<MessageType>(body);
    
    // Process message
    var success = await ProcessMessage(message);
    
    if (success)
        _channel.BasicAck(ea.DeliveryTag, false);
    else
        _channel.BasicNack(ea.DeliveryTag, false, true); // Requeue on failure
};

// 4. Consumer Registration
_channel.BasicConsume(
    queue: queueName,
    autoAck: false,         // Manual acknowledgment
    consumer: consumer
);
```

---

## 4. DOCKER-COMPOSE CONFIGURATION

**File**: `/home/nbadmin/camera-project/camera-v2/docker-compose.yml`

**Services**: 10 services for development environment

### Database Services
```yaml
recording-jobs-public-db:        # Shared RecordingJobs
recorder-scheduler-db:           # Private to RecorderScheduler
playlist-manager-db:             # Private to PlaylistManager
rabbitmq:                        # Message broker
```

### Application Services
```yaml
recorder-scheduler:              # Port 8081 (Quartz scheduling)
recorder:                        # (No external port) - internal service
s3-uploader:                     # network_mode: host (for external S3 access)
playlist-manager:                # Port 8082
player-api:                      # Port 8083
player-frontend:                 # Port 3001
```

### Volume Mounts Strategy

| Service | Volume | Mount Path | Access | Purpose |
|---------|--------|-----------|--------|---------|
| recorder | recorder_data | /data | Read-Write | Video segment output |
| s3-uploader | recorder_data | /data | Read-Only | Upload segments |
| playlist-manager | recorder_data | /data | Read-Only | Local manifest serving |

**RabbitMQ Service**:
```yaml
environment:
  RABBITMQ_DEFAULT_USER: dev
  RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
  RABBITMQ_DEFAULT_VHOST: cloudcam
ports:
  - "5672:5672"   # AMQP protocol
  - "15672:15672" # Management UI
```

**Important Notes**:
- S3Uploader uses `network_mode: host` for better external connectivity
- All services connect to RabbitMQ via internal Docker DNS
- Database ports exposed for development debugging
- Environment variables override appsettings.json via .NET configuration system

---

## 5. FFmpegManager DETAILED ANALYSIS

**File**: `/home/nbadmin/camera-project/camera-v2/Recorder/Services/FFmpegManager.cs` (703 lines)

### 5.1 Core Responsibilities

1. **FFmpeg Process Lifecycle**
   - Starts FFmpeg process with specified RTSP source and HLS output
   - Monitors process health
   - Gracefully stops or kills on signal
   - Detects stalled processes (no frame updates for 10s)

2. **Segment Detection**
   - Parses FFmpeg stderr output for segment creation logs
   - Pattern: `Opening '/path/to/segment.ts' for writing`
   - Fires `OnSegmentCompleted` event for each new segment

3. **Playlist Detection**
   - Detects playlist creation via two patterns:
     - HLS output setup: `Output #0, hls, to '/path/to/playlist.m3u8':`
     - Temporary file creation: `Opening '.../playlist.m3u8.tmp' for writing`
   - Fires `OnPlaylistCreated` event once per session

4. **Premature Exit Detection**
   - Compares actual end time vs target end time
   - If early exit, performs camera heartbeat check
   - Generates detailed diagnostics with:
     - Last 15 FFmpeg output lines
     - System actions log
     - Frame count and duration
     - Exit code analysis

5. **Process Monitoring**
   - Stall detection timer (10-second intervals)
   - Tracks last frame count update timestamp
   - Tracks last FFmpeg output timestamp
   - Terminates stalled processes automatically

### 5.2 FFmpeg Command Generation

**Key Command Structure**:
```bash
ffmpeg \
  -rtsp_transport tcp \
  -rtsp_flags prefer_tcp \
  -timeout 30000000 \
  -reorder_queue_size 0 \
  -buffer_size 1024000 \
  -analyzeduration 3000000 \
  -probesize 5000000 \
  -i "rtsp://..." \
  -t 3600 \
  -vf scale=1920:1080 \
  -c:v libx264 -crf 34 -preset medium \
  -an \
  -f hls \
  -hls_time 10 \
  -hls_flags append_list \
  -hls_list_size 0 \
  -hls_segment_filename "/data/{jobId}/{recordingId}/%d.ts" \
  "/data/{jobId}/{recordingId}/playlist.m3u8"
```

**Optimization Parameters**:
- `crf 34`: Quality/compression tradeoff (lower = better, but larger)
- `preset medium`: CPU load vs quality balance
- `hls_time 10`: 10-second segments (HLS standard)
- `scale=1920:1080`: Video resolution scaling
- `an`: Audio disabled for reduced file size

### 5.3 Event System

FFmpegManager uses events for decoupled communication:

```csharp
public event Func<Guid, string, Task> OnSegmentCompleted;      // (sessionId, segmentPath)
public event Func<Guid, string?, Task> OnRecordingCompleted;    // (sessionId, errorMessage)
public event Func<RecordingPrematureExitMessage, Task> OnPrematureExit;
public event Func<Guid, string, Task> OnPlaylistCreated;        // (sessionId, playlistPath)
```

**Event Firing Pattern**:
```csharp
// Fire-and-forget with error handling
_ = Task.Run(async () => {
    try {
        await OnSegmentCompleted(sessionId, segmentPath);
    } catch (Exception ex) {
        _logger.LogError(ex, "Error handling event");
    }
});
```

### 5.4 Current File Output Structure

**Output Directory**: `/data/{RecordingJobId}/{RecordingId}/`

**Files Generated**:
- `0.ts`, `1.ts`, `2.ts`, ... : HLS segment files (10 seconds each)
- `playlist.m3u8`: HLS master playlist

**Example Path**: `/data/550e8400-e29b-41d4-a716-446655440000/f47ac10b-58cc-4372-a567-0e02b2c3d479/0.ts`

---

## 6. CONSUMER/PUBLISHER IMPLEMENTATION PATTERNS

### 6.1 Publishing Pattern (OutboxService in Recorder)

**Pattern**: Outbox Pattern for guaranteed delivery

```csharp
// 1. Transactional message persistence
using var transaction = await context.Database.BeginTransactionAsync();
{
    var outboxMessage = new OutboxMessage
    {
        RecordingSessionId = sessionId,
        MessageType = "SegmentReady",
        MessagePayload = JsonConvert.SerializeObject(message),
        QueueName = QueueNames.SegmentReady,
        CreatedAt = DateTime.UtcNow,
        Sent = false
    };
    
    context.OutboxMessages.Add(outboxMessage);
    await context.SaveChangesAsync();
    await transaction.CommitAsync();
}

// 2. Background processor (OutboxService) polls database
while (!cancellationToken.IsCancellationRequested)
{
    var unsentMessages = await context.OutboxMessages
        .Where(m => !m.Sent)
        .ToListAsync();
    
    foreach (var outboxMsg in unsentMessages)
    {
        try
        {
            // Publish to RabbitMQ
            _channel.BasicPublish(
                exchange: "",
                routingKey: outboxMsg.QueueName,
                body: Encoding.UTF8.GetBytes(outboxMsg.MessagePayload)
            );
            
            outboxMsg.Sent = true;
            outboxMsg.SentAt = DateTime.UtcNow;
            await context.SaveChangesAsync();
        }
        catch (Exception ex)
        {
            outboxMsg.RetryCount++;
            outboxMsg.LastRetryAt = DateTime.UtcNow;
            outboxMsg.ErrorMessage = ex.Message;
            await context.SaveChangesAsync();
        }
    }
    
    await Task.Delay(_config.OutboxProcessIntervalMs);
}
```

**Benefits**:
- Guarantees message delivery even if service crashes
- Handles RabbitMQ broker temporary unavailability
- Implements retry logic with backoff
- Maintains idempotency tracking

---

### 6.2 Consuming Pattern (S3Uploader Example)

**Two-Consumer Setup**: Handles both segment uploads and recording completion

```csharp
// Consumer 1: Individual segment ready notifications
private void SetupSegmentReadyConsumer()
{
    var consumer = new EventingBasicConsumer(_channel);
    consumer.Received += async (model, ea) => 
    {
        var message = JsonSerializer.Deserialize<SegmentReadyMessage>(body);
        var success = await ProcessSegmentReadyMessage(message);
        
        if (success)
            _channel.BasicAck(ea.DeliveryTag, false);
        else
            _channel.BasicNack(ea.DeliveryTag, false, true); // Requeue
    };
    
    _channel.BasicConsume(queue: "segment.ready", autoAck: false, consumer: consumer);
}

// Consumer 2: Recording completion (batch upload)
private void SetupRecordingStoppedConsumer()
{
    var consumer = new EventingBasicConsumer(_channel);
    consumer.Received += async (model, ea) => 
    {
        // Determine message type dynamically
        using var doc = JsonDocument.Parse(message);
        if (doc.RootElement.TryGetProperty("StoppedAt", out _))
        {
            var stoppedMsg = JsonSerializer.Deserialize<RecordingStoppedMessage>(message);
            var success = await ProcessRecordingStoppedMessage(stoppedMsg);
            
            if (success)
                _channel.BasicAck(ea.DeliveryTag, false);
            else
                _channel.BasicNack(ea.DeliveryTag, false, true);
        }
    };
    
    _channel.BasicConsume(queue: "recording.events.s3uploader", autoAck: false, consumer: consumer);
}
```

**Key Patterns**:
- Manual acknowledgment (`autoAck: false`)
- Requeue on failure (`BasicNack(..., requeue: true)`)
- Type detection via JSON property checking
- Dual queues for different event types
- Prefetch count matching max concurrent uploads

---

## 7. CONFIGURATION MANAGEMENT

### 7.1 Recorder Configuration (appsettings.json)

```json
{
  "Recorder": {
    "DataPath": "/data",
    "FFmpegPath": "ffmpeg",
    "RecordingDurationSeconds": 3620,
    "SegmentMonitorIntervalMs": 5000,
    "OutboxProcessIntervalMs": 10000,
    "LogLevel": "Information",
    "RtspTransport": "tcp",
    "RtspTimeoutSeconds": 10,
    "RtspFlags": "prefer_tcp",
    "EnableRtspDebugLogging": false
  },
  "RabbitMQ": {
    "Host": "rabbitmq",
    "Port": 5672,
    "Username": "dev",
    "Password": "dev123",
    "VirtualHost": "cloudcam",
    "RequestsQueue": "recording.requests",
    "PrefetchCount": 1,
    "ConnectionRetryDelayMs": 5000,
    "MaxConnectionRetries": 10
  },
  "Database": {
    "ConnectionString": "Data Source=/data/recorder.db"
  }
}
```

### 7.2 S3Uploader Configuration

```json
{
  "S3": {
    "Endpoint": "nbpublic.narbulut.com",
    "BucketName": "berkin-test",
    "AccessKey": "${S3_ACCESS_KEY}",
    "SecretKey": "${S3_SECRET_KEY}",
    "UseSSL": true
  },
  "RabbitMQ": {
    "Host": "localhost",  // host networking mode
    "Port": 5672,
    "Username": "dev",
    "Password": "dev123",
    "VirtualHost": "cloudcam"
  },
  "S3Uploader": {
    "DataPath": "/data",
    "MaxConcurrentUploads": 5,
    "UploadTimeoutSeconds": 30
  }
}
```

**Environment Variable Overrides**:
- RabbitMQ credentials
- S3 endpoint and bucket name
- Access keys (never in version control)

---

## 8. KEY ARCHITECTURAL PATTERNS

### 8.1 Service-to-Service Communication

**Asynchronous via RabbitMQ**:
- No direct HTTP calls between Recorder and S3Uploader
- Loose coupling enables independent scaling
- Message-based contract versioning
- Dead-letter queue support for failures

**Synchronous HTTP**:
- Player API → PlaylistManager
- RecorderScheduler → Panel API
- Limited to control plane operations (not data plane)

### 8.2 Data Flow

```
RecorderScheduler
    ↓ (StartRecordingMessage)
    ↓ recording.requests queue
    ↓
Recorder Service
    ├─→ FFmpeg process (RTSP capture)
    │   ├─→ /data/{jobId}/{recordingId}/0.ts
    │   ├─→ /data/{jobId}/{recordingId}/1.ts
    │   └─→ /data/{jobId}/{recordingId}/playlist.m3u8
    │
    ├─→ OutboxService publishes:
    │   ├─→ segment.ready queue (for each segment)
    │   ├─→ recording.events.fanout exchange
    │   └─→ recording.premature_exits queue
    │
    ↓
S3Uploader Service
    ├─→ Consumes segment.ready (individual uploads)
    │   └─→ Upload to S3: {recordingId}/0.ts
    │
    ├─→ Consumes recording.events.fanout
    │   ├─→ RecordingStoppedMessage (batch upload remaining)
    │   └─→ Publishes PlaylistUploadedMessage
    │
    ↓
PlaylistManager Service
    ├─→ Consumes playlist.events
    │   └─→ Store playlist metadata
    │   └─→ Generate signed URLs
    │
    ↓
Player API/Frontend
    ├─→ Query PlaylistManager for segments
    └─→ Stream from S3
```

### 8.3 Error Handling Strategies

**Consumer Level**:
- Try-catch with logging
- Requeue on transient failures
- Dead-letter on permanent failures (after max retries)
- Skip old messages to prevent zombie processing

**Service Level**:
- Health checks on RabbitMQ connection
- Automatic recovery enabled
- Backoff delays for reconnection
- Logging for diagnostics

**Database Level**:
- SQLite for Recorder (local state only)
- PostgreSQL for shared state (PlaylistManager)
- Outbox pattern ensures message delivery

---

## 9. EXISTING SERVICE ANALYSIS DOCUMENTS

The codebase contains service-specific analysis files:

- `/camera-v2/Recorder/SERVICE_ANALYSIS.md` - Detailed Recorder architecture
- `/camera-v2/S3Uploader/SERVICE_ANALYSIS.md` - S3Uploader patterns
- `/camera-v2/PlaylistManager/SERVICE_ANALYSIS.md` - Playlist management
- `/camera-v2/Player/SERVICE_ANALYSIS.md` - Playback services

---

## 10. SUMMARY TABLE: SERVICES & PATTERNS

| Service | Port | Language | Queue Reads | Queue Writes | Database | Key Feature |
|---------|------|----------|-------------|--------------|----------|------------|
| RecorderScheduler | 8081 | C# .NET 9 | N/A | recording.requests | PostgreSQL | Quartz scheduling |
| Recorder | Internal | C# .NET 9 | recording.requests | segment.ready, events, exits | SQLite | FFmpeg orchestration |
| S3Uploader | N/A (host net) | C# .NET 9 | segment.ready, events | playlist.events | N/A | MinIO uploads |
| PlaylistManager | 8082 | C# .NET 9 | playlist.events | N/A | PostgreSQL | HLS manifest mgmt |
| Player API | 8083 | C# .NET 9 | N/A | N/A | N/A | Playback API |
| Player Frontend | 3001 | React 18 | N/A | N/A | N/A | Video UI |

---

## 11. CRITICAL TECHNICAL DETAILS FOR TranscoderBridge INTEGRATION

### 11.1 Message Modification Points
- **Recorder Output**: Change `-c:v copy` (from libx264) to skip encoding
- **Message Type**: Add `RawSegmentReadyMessage` to distinguish from final segments
- **Queue Routing**: Route to new `segment.raw.ready` queue instead of `segment.ready`

### 11.2 File Path Management
- Absolute paths in messages: `/data/{jobId}/{recordingId}/{filename}`
- TranscoderBridge needs direct file access via volume mounts
- S3Uploader needs to access both `/data` (Phase 1 raw) and transcoder output (Phase 2)

### 11.3 RabbitMQ Integration Points
- Outbox pattern for reliable publishing
- Fanout exchange for event broadcasting
- Direct queue binding for specific messages
- Durable queues for persistence

### 11.4 HTTP Callback Pattern for Transcoder
- Transcoder HTTP API: `POST /enqueue` with job details
- Callback URL in request: `http://transcoder-bridge:8081/completed`
- Webhook receiving: Controller endpoint for callback handling
- Metadata pass-through for traceability

### 11.5 Docker Volume Strategy
- Recorder writes to: `recorder_data:/data`
- Transcoder reads from: `recorder_data:/data` (read-only)
- Transcoder writes to: `transcoder_output:/workspace/output` (new volume)
- S3Uploader reads from both volumes

---

## 12. RECOMMENDED FILES TO REVIEW BEFORE IMPLEMENTATION

**Essential Reading** (in order):
1. `camera-v2/Recorder/Services/FFmpegManager.cs` - Understand segment detection
2. `camera-v2/Recorder/Services/OutboxService.cs` - Understand message publishing
3. `camera-v2/S3Uploader/Services/RabbitMQConsumer.cs` - Understand consumer pattern
4. `camera-v2/Recorder/Models/Messages.cs` - Understand message structure
5. `camera-v2/docker-compose.yml` - Understand service orchestration

**Reference Files**:
- `camera-v2/Recorder/Program.cs` - DI/Hosted service pattern
- `camera-v2/RecorderScheduler/Models/Messages.cs` - Message definitions
- `camera-v2/Recorder/Configuration/*.cs` - Configuration patterns
- `.env` file (if exists) - Environment variables for local testing

---

**Document Created**: 2025-10-23
**Absolute Paths Used Throughout**
**Ready for TranscoderBridge Implementation Planning**
