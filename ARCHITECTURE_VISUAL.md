# CloudCam 24/7 - Visual Architecture Diagrams

## System-Wide Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CLOUDCAM 24/7 VIDEO PIPELINE                         │
└─────────────────────────────────────────────────────────────────────────┘

PHASE 1: RECORDING & CAPTURE
┌──────────────────────────────────────────────────────────────────────────┐
│ RecorderScheduler                                                        │
│ • Quartz job scheduling                                                  │
│ • Publishes StartRecordingMessage every hour                             │
│ • Tracks recording jobs in PostgreSQL                                    │
└──────────────────────────────────────────────────────────────────────────┘
                           │
                           ▼ [recording.requests queue]
┌──────────────────────────────────────────────────────────────────────────┐
│ Recorder Service (FFmpeg)                                                │
│                                                                          │
│  RabbitMQConsumer ──► StartRecordingMessage                             │
│         │                                                                │
│         ▼                                                                │
│  RecordingService ───► FFmpegManager                                    │
│         │                    │                                           │
│         │                    ▼                                           │
│         │              [FFmpeg Process]                                  │
│         │                    │                                           │
│         │                    ├─ RTSP Input ──► Segment Detection        │
│         │                    │                 (regex parsing)          │
│         │                    │                                           │
│         │                    ├─ HLS Output ──► 10s .ts segments         │
│         │                    │                 + playlist.m3u8          │
│         │                    │                                           │
│         │                    └─ Error Handling ──► Premature exits      │
│         │                       (stall detection)  (diagnostics)        │
│         │                                                                │
│         ▼ (via OutboxService + SQLite)                                  │
│    [Transactional Message Publishing]                                   │
│         │                                                                │
│         ├──► SegmentReadyMessage ──► segment.ready queue                │
│         │    (per 10-second segment)                                    │
│         │                                                                │
│         ├──► RecordingStartedMessage ──► recording.events.fanout        │
│         │                                                                │
│         ├──► RecordingStoppedMessage ──► recording.events.fanout        │
│         │                                                                │
│         ├──► PlaylistCreatedMessage ──► playlist.created queue          │
│         │                                                                │
│         └──► RecordingPrematureExitMessage ──► recording.premature_exits
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
        Files written to: /data/{jobId}/{recordingId}/*.ts


PHASE 2: UPLOAD & STORAGE  
┌──────────────────────────────────────────────────────────────────────────┐
│ S3Uploader Service                                                       │
│                                                                          │
│  RabbitMQConsumer (Dual Consumer)                                       │
│        │                                                                 │
│        ├─ segment.ready queue ────► ProcessSegmentReadyMessage()        │
│        │  (per segment)                    │                             │
│        │                                   ▼                             │
│        │                            [Upload to S3/MinIO]                │
│        │                            {recordingId}/0.ts                  │
│        │                            {recordingId}/1.ts                  │
│        │                            etc.                                 │
│        │                                                                 │
│        │                                                                 │
│        └─ recording.events.s3uploader ─► ProcessRecordingStoppedMessage│
│           (RecordingStoppedMessage)             │                        │
│                                                 ▼                        │
│                                         [Batch Upload Remaining]        │
│                                         [Upload Playlist]               │
│                                                 │                        │
│                                                 ▼                        │
│                                    PublishPlaylistUploadedMessage()     │
│                                    ──► playlist.events queue             │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
        Files read from: /data/{jobId}/{recordingId}/*.ts
        Files written to: nbpublic.narbulut.com (MinIO)
                         berkin-test bucket


PHASE 3: MANIFEST & AVAILABILITY
┌──────────────────────────────────────────────────────────────────────────┐
│ PlaylistManager Service                                                  │
│                                                                          │
│  RabbitMQConsumer ──► PlaylistUploadedMessage                           │
│         │                  (from S3Uploader)                             │
│         ▼                                                                │
│  PostgreSQL Database                                                     │
│  • Store playlist metadata                                               │
│  • Index segments by recording                                           │
│  • Generate signed URLs                                                  │
│         │                                                                │
│         ▼                                                                │
│  REST API (Port 8082)                                                   │
│  • GET /playlists/{recordingId}                                          │
│  • GET /segments/{recordingId}                                           │
│  • GET /signed-url/{s3Key}                                               │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘


PHASE 4: PLAYBACK
┌──────────────────────────────────────────────────────────────────────────┐
│ Player Services (Port 8083 API, Port 3001 Frontend)                     │
│                                                                          │
│  Player.API ──► PlaylistManager API                                     │
│       │              │                                                   │
│       │              ▼                                                    │
│       │         Get playlist segments & signed URLs                     │
│       │              │                                                   │
│       ▼              ▼                                                    │
│  Player.Frontend (React 18 + Video.js)                                  │
│       │              │                                                   │
│       │              ▼                                                    │
│       │         Load HLS manifest                                       │
│       │         Stream segments from S3                                 │
│       │         Display video player                                    │
│       │                                                                  │
│       └──────────► User watches recording                               │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## RabbitMQ Message Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                     RABBITMQ VIRTUAL HOST                       │
│                      (cloudcam vhost)                           │
│                                                                 │
│  QUEUES:                                                        │
│                                                                 │
│  ┌──────────────────────────┐     ┌─────────────────────────┐ │
│  │ recording.requests       │     │ segment.ready           │ │
│  │ (durable)                │     │ (durable)               │ │
│  │                          │     │                         │ │
│  │ Source:                  │     │ Source:                 │ │
│  │  RecorderScheduler       │     │  Recorder/OutboxService │ │
│  │                          │     │                         │ │
│  │ Consumer:                │     │ Consumer:               │ │
│  │  Recorder                │     │  S3Uploader             │ │
│  │                          │     │  (per segment)          │ │
│  │ Message Type:            │     │                         │ │
│  │  StartRecordingMessage   │     │ Message Type:           │ │
│  │                          │     │  SegmentReadyMessage    │ │
│  └──────────────────────────┘     └─────────────────────────┘ │
│                                                                 │
│  ┌──────────────────────────┐     ┌─────────────────────────┐ │
│  │ playlist.created         │     │ recording.premature_    │ │
│  │ (durable)                │     │ exits (durable)         │ │
│  │                          │     │                         │ │
│  │ Source:                  │     │ Source:                 │ │
│  │  Recorder/OutboxService  │     │  Recorder/OutboxService │ │
│  │                          │     │                         │ │
│  │ Consumer:                │     │ Consumer:               │ │
│  │  PlaylistManager         │     │  (monitoring)           │ │
│  │                          │     │                         │ │
│  │ Message Type:            │     │ Message Type:           │ │
│  │  PlaylistCreatedMessage  │     │  RecordingPrematureExit │ │
│  └──────────────────────────┘     └─────────────────────────┘ │
│                                                                 │
│  EXCHANGES:                                                     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ recording.events.fanout (Fanout Exchange)               │  │
│  │ (durable)                                               │  │
│  │                                                          │  │
│  │ Messages:                                                │  │
│  │  • RecordingStartedMessage                              │  │
│  │  • RecordingStoppedMessage                              │  │
│  │  • RecordingPrematureExitMessage                        │  │
│  │                                                          │  │
│  │ Bindings:                                                │  │
│  │  └─ recording.events.s3uploader queue ◄───────────┐    │  │
│  │  └─ (future) other service queues                │    │  │
│  │                                                   │    │  │
│  └─────────────────────────────────────────────────────────┘  │
│        ▲                                                       │
│        │                                                       │
│    Published by:                                               │
│    Recorder/OutboxService                                     │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ playlist.events (Fanout Exchange)                       │  │
│  │ (durable)                                               │  │
│  │                                                          │  │
│  │ Messages:                                                │  │
│  │  • PlaylistUploadedMessage                              │  │
│  │                                                          │  │
│  │ Bindings:                                                │  │
│  │  └─ (future) consumer queue                             │  │
│  │                                                          │  │
│  └─────────────────────────────────────────────────────────┘  │
│        ▲                                                       │
│        │                                                       │
│    Published by:                                               │
│    S3Uploader                                                  │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ recording.events.s3uploader (Queue)                     │  │
│  │ (durable, fanout-bound)                                 │  │
│  │                                                          │  │
│  │ Consumer:                                                │  │
│  │  S3Uploader (listens for recording lifecycle)          │  │
│  │                                                          │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Recorder FFmpeg Integration

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    RECORDER SERVICE INTERNALS                           │
└─────────────────────────────────────────────────────────────────────────┘

MESSAGE RECEIVED: StartRecordingMessage
{
  "RecordingJobId": "550e8400-e29b-41d4-a716-446655440000",
  "RecordingId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "RtspUrl": "rtsp://camera.local:554/stream/main",
  "Resolution": "1920x1080",
  "DurationSeconds": 3600,
  "TargetEndTime": "2025-10-23T11:00:00Z",
  ...
}
         │
         ▼
┌──────────────────────────────┐
│ RecordingService             │
│ • Create RecordingSession    │
│ • Store in SQLite            │
│ • Publish RecordingStarted   │
└──────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ FFmpegManager.StartRecordingAsync()                  │
│                                                      │
│ 1. Create output directory:                          │
│    /data/550e8400.../f47ac10b.../                   │
│                                                      │
│ 2. Build FFmpeg command:                             │
│    ffmpeg \                                          │
│      -rtsp_transport tcp \                           │
│      -rtsp_flags prefer_tcp \                        │
│      -timeout 30000000 \                             │
│      -i "rtsp://camera.local:554/stream/main" \     │
│      -t 3600 \                                       │
│      -vf scale=1920:1080 \                           │
│      -c:v libx264 -crf 34 -preset medium \           │
│      -an \                                           │
│      -f hls \                                        │
│      -hls_time 10 \                                  │
│      -hls_flags append_list \                        │
│      -hls_list_size 0 \                              │
│      -hls_segment_filename ".../%d.ts" \             │
│      "...playlist.m3u8"                              │
│                                                      │
│ 3. Start process & monitor                           │
│                                                      │
└──────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────┐
│ FFmpeg Process (Running)                             │
│                                                      │
│ RTSP Connection                                      │
│     │                                                 │
│     ├─► Frame 0........Frame 1000      [RTSP Stress] │
│     │   time: 0s         time: 40s                   │
│     │                                                 │
│     └─► Video Encoding ──► HLS Segments              │
│         (libx264)          10s each                  │
│                                                      │
│ FFmpeg Outputs:                                      │
│ STDOUT: (mostly quiet)                               │
│ STDERR: (progress & HLS info)                        │
│   [hls @ ...] Opening '.../0.ts' for writing         │
│   Output #0, hls, to '.../playlist.m3u8':            │
│   ... (frame progress) ...                           │
│   [hls @ ...] Opening '.../1.ts' for writing         │
│   ... (frame progress) ...                           │
│   [hls @ ...] Opening '.../2.ts' for writing         │
│   ... (frame progress) ...                           │
│                                                      │
└──────────────────────────────────────────────────────┘
         │
         ├─ Stderr Output Stream ─────────────────────┐
         │                                            │
         ▼                                            ▼
┌────────────────────────────────┐      ┌─────────────────────────┐
│ HandleFFmpegOutput()           │      │ CheckForSegmentCompletion│
│ Real-time log collection       │      │ Regex: Opening '...' for│
│                                │      │ Fires OnSegmentCompleted│
└────────────────────────────────┘      └─────────────────────────┘
                                                   │
                                                   ▼
                                         ┌──────────────────────────┐
                                         │ OnSegmentCompleted Event │
                                         │ (Fire & Forget Pattern)  │
                                         │                          │
                                         │ → RecordingService       │
                                         │   • Load RecordingSession│
                                         │   • Create SegmentInfo   │
                                         │   • Save to SQLite       │
                                         │   • Create message:      │
                                         │                          │
                                         │   SegmentReadyMessage {  │
                                         │     FileName: "0.ts",    │
                                         │     FilePath: "...0.ts", │
                                         │     FileSize: 1048576,   │
                                         │     ...                  │
                                         │   }                      │
                                         │   • Add to OutboxService │
                                         │                          │
                                         └──────────────────────────┘
                                                   │
                                                   ▼
                                         ┌──────────────────────────┐
                                         │ OutboxService            │
                                         │ (Background processor)   │
                                         │                          │
                                         │ 1. Query SQLite for     │
                                         │    unsent messages      │
                                         │ 2. Publish to RabbitMQ  │
                                         │ 3. Mark as Sent         │
                                         │ 4. Retry on failure     │
                                         │                          │
                                         └──────────────────────────┘
                                                   │
                                                   ▼
                                         ┌──────────────────────────┐
                                         │ RabbitMQ                 │
                                         │ segment.ready queue      │
                                         └──────────────────────────┘
                                                   │
                                                   ▼
                                         ┌──────────────────────────┐
                                         │ S3Uploader               │
                                         │ Consumes & Uploads      │
                                         └──────────────────────────┘


FILES CREATED DURING RECORDING:

/data/550e8400-e29b-41d4-a716-446655440000/
  └── f47ac10b-58cc-4372-a567-0e02b2c3d479/
      ├── 0.ts                 (10 sec segment)
      ├── 1.ts                 (10 sec segment)
      ├── 2.ts                 (10 sec segment)
      ├── ...
      ├── 359.ts               (final segment)
      └── playlist.m3u8        (HLS manifest)

          #EXTM3U
          #EXT-X-VERSION:3
          #EXT-X-TARGETDURATION:10
          #EXT-X-MEDIA-SEQUENCE:0
          #EXTINF:10.0,
          0.ts
          #EXTINF:10.0,
          1.ts
          ...
          #EXT-X-ENDLIST
```

---

## S3Uploader Dual Consumer Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    S3UPLOADER SERVICE INTERNALS                         │
└─────────────────────────────────────────────────────────────────────────┘

RabbitMQConsumer (Dual Consumer Setup)
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  CONSUMER 1: SetupSegmentReadyConsumer()                                │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                                                                  │  │
│  │ Listens on: segment.ready queue                                 │  │
│  │ Triggered: Per each segment (every 10 seconds)                  │  │
│  │ Concurrency: Limited by MaxConcurrentUploads (default: 5)      │  │
│  │                                                                  │  │
│  │ Message: SegmentReadyMessage                                    │  │
│  │ {                                                               │  │
│  │   "FileName": "0.ts",                                           │  │
│  │   "FilePath": "/data/.../f47ac10b.../0.ts",                   │  │
│  │   "FileSize": 1048576,                                          │  │
│  │   "RecordingId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",      │  │
│  │   ...                                                           │  │
│  │ }                                                               │  │
│  │                                                                  │  │
│  │ Processing:                                                     │  │
│  │   1. Parse FilePath → validate against DataPath                │  │
│  │   2. Check file exists and is readable                         │  │
│  │   3. Upload to S3: s3://{bucket}/{recordingId}/0.ts           │  │
│  │   4. Acknowledge ✓ or Requeue ✗                                │  │
│  │                                                                  │  │
│  │ Retry Logic:                                                    │  │
│  │   - Max retries: configured in RabbitMQ settings               │  │
│  │   - Requeue delay: exponential backoff (RabbitMQ native)       │  │
│  │                                                                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  CONSUMER 2: SetupRecordingStoppedConsumer()                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                                                                  │  │
│  │ Listens on: recording.events.s3uploader (fanout-bound)         │  │
│  │ Triggered: Once per recording completion                        │  │
│  │ Concurrency: Sequential (batch operation)                       │  │
│  │                                                                  │  │
│  │ Message: RecordingStoppedMessage                                │  │
│  │ {                                                               │  │
│  │   "RecordingJobId": "550e8400-e29b-41d4-a716-446655440000",  │  │
│  │   "RecordingId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",     │  │
│  │   "StoppedAt": "2025-10-23T11:00:00Z",                        │  │
│  │   "IsError": false,                                             │  │
│  │   ...                                                           │  │
│  │ }                                                               │  │
│  │                                                                  │  │
│  │ Processing:                                                     │  │
│  │   1. Locate recording directory:                               │  │
│  │      /data/{jobId}/{recordingId}/                              │  │
│  │   2. List all remaining .ts files NOT YET uploaded             │  │
│  │   3. Batch upload to S3                                         │  │
│  │   4. Upload playlist.m3u8                                       │  │
│  │   5. Publish PlaylistUploadedMessage                           │  │
│  │      to playlist.events exchange                                │  │
│  │   6. Acknowledge ✓ or Requeue ✗                                │  │
│  │                                                                  │  │
│  │ Output Message: PlaylistUploadedMessage                         │  │
│  │ {                                                               │  │
│  │   "PlaylistPath": "{jobId}/{recordingId}/playlist.m3u8",      │  │
│  │   "S3Key": "segment-uuid/playlist.m3u8",                      │  │
│  │   "SegmentCount": 360,                                          │  │
│  │   "UploadedSegments": ["..../0.ts", ..., "..../359.ts"],      │  │
│  │   "UploadedAt": "2025-10-23T11:00:00Z"                        │  │
│  │ }                                                               │  │
│  │                                                                  │  │
│  │ Error Handling:                                                 │  │
│  │   - Old messages (>2 hours): Skip to prevent zombie processing │  │
│  │   - Empty recordings: Acknowledge to prevent infinite requeue  │  │
│  │   - Upload failures: Requeue for retry                         │  │
│  │                                                                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
                    │                              │
                    ▼                              ▼
            [S3/MinIO Upload]         [playlist.events exchange]
                    │                              │
            nbpublic.narbulut.com               ▼
            berkin-test bucket          [PlaylistManager]
                    │                              │
                    ├─ Recording_id/              ▼
                    │  ├─ 0.ts                [PostgreSQL]
                    │  ├─ 1.ts                Store playlists
                    │  ├─ ...                 & metadata
                    │  ├─ 359.ts
                    │  └─ playlist.m3u8
                    │
                    └─ READY FOR PLAYBACK


PREFETCH & CONCURRENCY MANAGEMENT:

RabbitMQ Prefetch Count = MaxConcurrentUploads (5)
    └─ Consumer 1: Takes up to 5 segment.ready messages
    └─ Consumer 2: Takes up to 5 recording.events messages
    └─ Total concurrent uploads: ~5 files at once (tunable)

Queue.BasicQos(prefetchSize: 0, prefetchCount: 5, global: false)
    └─ Prevents consumer from being overwhelmed
    └─ Allows other consumers to work on other messages
    └─ On ACK, broker sends next message
```

---

## Docker Compose Service Dependencies

```
┌───────────────────────────────────────────────────────────────────────┐
│                    DOCKER COMPOSE SERVICE GRAPH                       │
└───────────────────────────────────────────────────────────────────────┘

STARTUP ORDER (depends_on with health checks):

1. Databases (Parallel)
   ┌──────────────────────────────┐
   │ recording-jobs-public-db     │  PostgreSQL:5433
   ├──────────────────────────────┤
   │ User: cloudcam               │
   │ DB: cloudcam_public          │
   │ Health check: pg_isready ✓   │
   └──────────────────────────────┘
                │
   ┌──────────────────────────────┐
   │ recorder-scheduler-db        │  PostgreSQL:5434
   ├──────────────────────────────┤
   │ User: dev                    │
   │ DB: recorder_scheduler       │
   │ Health check: pg_isready ✓   │
   └──────────────────────────────┘
                │
   ┌──────────────────────────────┐
   │ playlist-manager-db          │  PostgreSQL:5435
   ├──────────────────────────────┤
   │ User: dev                    │
   │ DB: playlist_manager         │
   │ Health check: pg_isready ✓   │
   └──────────────────────────────┘

2. Message Broker
   ┌──────────────────────────────────────┐
   │ rabbitmq:3.13-management             │  RabbitMQ:5672 (AMQP)
   ├──────────────────────────────────────┤                  :15672 (UI)
   │ User: dev / Password: ${RABBIT...}   │
   │ Virtual Host: cloudcam               │
   │ Health check: rabbitmq-diagnostics   │
   │ Status: HEALTHY ✓                    │
   └──────────────────────────────────────┘

3. Backend Services (Parallel, depends_on databases + rabbitmq)

   ┌────────────────────────────┐
   │ recorder-scheduler         │  Port 8081
   ├────────────────────────────┤
   │ Depends on:                │
   │ • recording-jobs-public-db │ (HEALTHY)
   │ • recorder-scheduler-db    │ (HEALTHY)
   │ • rabbitmq                 │ (HEALTHY)
   │ Network: bridge            │
   │ Volumes: /var/run/docker.sock
   └────────────────────────────┘

   ┌────────────────────────────┐
   │ recorder                   │  (No external port)
   ├────────────────────────────┤
   │ Depends on:                │
   │ • rabbitmq                 │ (HEALTHY)
   │ Network: bridge            │
   │ Volumes:                   │
   │ • recorder_data:/data (rw) │
   └────────────────────────────┘

   ┌────────────────────────────┐
   │ s3-uploader                │  (No external port)
   ├────────────────────────────┤
   │ Depends on:                │
   │ • rabbitmq                 │ (HEALTHY)
   │ Network: host (external S3)│
   │ Volumes:                   │
   │ • recorder_data:/data (ro) │
   └────────────────────────────┘

   ┌────────────────────────────┐
   │ playlist-manager           │  Port 8082
   ├────────────────────────────┤
   │ Depends on:                │
   │ • playlist-manager-db      │ (HEALTHY)
   │ • rabbitmq                 │ (HEALTHY)
   │ Network: bridge            │
   │ Volumes:                   │
   │ • recorder_data:/data (ro) │
   └────────────────────────────┘

4. Frontend Services (Parallel)

   ┌────────────────────────────┐
   │ player-api                 │  Port 8083
   ├────────────────────────────┤
   │ Depends on:                │
   │ • playlist-manager         │
   │ Network: bridge            │
   └────────────────────────────┘

   ┌────────────────────────────┐
   │ player-frontend            │  Port 3001
   ├────────────────────────────┤
   │ Depends on:                │
   │ • player-api               │
   │ Network: bridge            │
   │ Environment:               │
   │ • VITE_API_BASE_URL        │
   └────────────────────────────┘


VOLUME STRATEGY:

┌─ recorder_data (named volume)
│  ├─ recorder: /data (rw) ──────► Writes segments
│  ├─ s3-uploader: /data (ro) ──► Reads segments for upload
│  └─ playlist-manager: /data (ro) ─► Reads for local serving
│
└─ Database volumes (named)
   ├─ recording_jobs_public_db_data
   ├─ recorder_scheduler_db_data
   ├─ playlist_manager_db_data
   └─ rabbitmq_data


NETWORK CONNECTIVITY:

Within Docker Network (bridge mode):
  • Recorder ──► rabbitmq:5672
  • S3Uploader ──► localhost:5672 (host mode)
  • PlaylistManager ──► rabbitmq:5672
  • Player.API ──► playlist-manager:8082

External to Docker:
  • S3Uploader ──► nbpublic.narbulut.com:9000 (MinIO)
  • User browser ──► localhost:3001 (Player Frontend)
  • Developer ──► localhost:5433+ (Database ports for debugging)
```

---

## File System Layout During Recording

```
HOST FILESYSTEM:
└─ Docker Volume: recorder_data
   │
   └─ /data/ (inside container)
      │
      ├─ 550e8400-e29b-41d4-a716-446655440000/
      │  │  (Recording Job ID)
      │  │
      │  ├─ f47ac10b-58cc-4372-a567-0e02b2c3d479/
      │  │  │  (Recording ID)
      │  │  │
      │  │  ├─ 0.ts                                     (10 sec, ~1-2 MB)
      │  │  ├─ 1.ts                                     (10 sec)
      │  │  ├─ 2.ts                                     (10 sec)
      │  │  ├─ ...                                      (360 files total)
      │  │  ├─ 359.ts                                   (final segment)
      │  │  │
      │  │  └─ playlist.m3u8
      │  │     #EXTM3U
      │  │     #EXT-X-VERSION:3
      │  │     #EXT-X-TARGETDURATION:10
      │  │     #EXT-X-MEDIA-SEQUENCE:0
      │  │     #EXTINF:10.0,
      │  │     0.ts
      │  │     ...
      │  │
      │  ├─ a1b2c3d4-e5f6-47g8-h9i0-j1k2l3m4n5o6/
      │  │  └─ (another recording)
      │  │
      │  └─ recorder.db
      │     (SQLite database - session tracking)
      │
      └─ (other job directories...)


TOTAL STORAGE PER RECORDING:
  • Duration: 1 hour
  • Segments: 360 (10 seconds each)
  • File size: ~1.5-2.5 GB (depending on bitrate & quality)
  • CRF 34: Produces medium quality, smaller files
  • Typical bitrate: 2-3 Mbps


S3 STORAGE LAYOUT (after upload):
─ s3://berkin-test/
  └─ f47ac10b-58cc-4372-a567-0e02b2c3d479/
     ├─ 0.ts
     ├─ 1.ts
     ├─ ...
     ├─ 359.ts
     └─ playlist.m3u8
```

---

## Message Lifecycle Timeline

```
TIME    COMPONENT             EVENT                    QUEUE/VOLUME
──────────────────────────────────────────────────────────────────────
T+0s    RecorderScheduler     Publish StartRecording   recording.requests
        
T+1s    Recorder              Consume StartRecording   
        RabbitMQConsumer      Create RecordingSession
        RecordingService      Send RecordingStarted    recording.events
        FFmpegManager         Start FFmpeg process
        OutboxService         Persist messages to DB

T+2s    FFmpeg               Starting RTSP connection
        FFmpegManager        Detecting playlist creation
        OutboxService        [Polling interval: 10s]

T+10s   FFmpeg               First segment ready
        FFmpegManager        ParseOutput: Opening '0.ts'
        OnSegmentCompleted   Fire event
        RecordingService     Create SegmentInfo in DB
                            Create SegmentReadyMessage

T+11s   OutboxService        Publish SegmentReady      segment.ready
        
T+12s   S3Uploader          Consume SegmentReady
        RabbitMQConsumer     Download /data/.../0.ts
        S3Service            Upload to S3
                            ACK to RabbitMQ

T+20s   FFmpeg              Second segment ready (0.ts complete)
        FFmpegManager       OnSegmentCompleted event
        OutboxService       Publish to RabbitMQ
        S3Uploader          Consume & upload 1.ts

...continuing every 10 seconds...

T+3600s FFmpeg              Recording duration reached
        Process.Exit()       Exit code: 0
        HandleProcessExit    Detect completion
        RecordingService     Send RecordingStopped     recording.events

T+3601s OutboxService        Publish RecordingStopped  recording.events
        
T+3602s S3Uploader          Consume RecordingStopped
        ProcessRecStopped    Upload remaining .ts files
                            Upload playlist.m3u8
                            Publish PlaylistUploaded   playlist.events

T+3603s PlaylistManager      Consume PlaylistUploaded
        RabbitMQConsumer     Create Playlist DB entry
        REST API            Now queryable for playback

T+3610s Player API           Request /playlists/{uuid}
        PlaylistManager      Return playlist + signed URLs
        Player Frontend      Load HLS manifest
        AJAX                Fetch segments from S3
        Video.js            Play recording
```

---

**Visual Architecture Diagrams**
**CloudCam 24/7 GPU Transcoder Integration**
**Created: 2025-10-23**
