# GPU Transcoder Integration - Implementation Plan

**Project**: CloudCam 24/7 GPU Transcoder Integration
**Created**: 2025-10-23
**Status**: 🔴 Phase 1 - Test Server (No GPU)
**Document Version**: 3.0

---

## 🎯 Two-Phase Implementation Strategy

### **Phase 1: Test Server (Current) - Bridge Functionality** 🔴
**Goal**: Verify TranscoderBridge ↔ Transcoder API communication works
**Environment**: Test server WITHOUT GPU
**Focus**: Message flow, webhooks, RabbitMQ, HTTP API integration
**No actual transcoding** - just orchestration testing

### **Phase 2: GPU Server (Later) - Transcoding Validation** ⏸️
**Goal**: Test actual GPU transcoding functionality
**Environment**: Server WITH RTX 5090
**Focus**: NVENC/NVDEC encoding quality and performance
**Note**: Migration planning NOT needed - will move working code manually

---

## 📊 Phase 1 Progress - Bridge Development

**Legend**: 🔴 Not Started | 🟡 In Progress | 🟢 Complete | 🔵 Blocked | ⚠️ Issue

| Step | Component | Status | Priority | Notes |
|------|-----------|--------|----------|-------|
| 1 | TranscoderBridge Service | 🟢 Complete | Critical | All files created |
| 2 | Recorder Modifications | 🟢 Complete | Critical | FFmpeg + messages |
| 3 | S3Uploader Modifications | 🟢 Complete | Critical | Queue binding updated |
| 4 | Docker Compose Setup | 🟢 Complete | Critical | Both services added |
| 5 | Add --no-gpu to transcoder.c | 🟢 Complete | For Testing | Flag implemented |
| 6 | Local Isolation Config | 🟢 Complete | Critical | Override files created |
| 7 | Panel Integration | 🟢 Complete | Optional | Panel isolated from prod |
| 8 | Pre-flight Check | 🟢 Complete | Final Check | All verifications passed |
| 9 | End-to-End Testing | 🟡 Ready to Start | Validation | User to begin testing |

---

## 🔧 Step 1: TranscoderBridge Service

### Directory Structure
```
camera-v2/TranscoderBridge/
├── TranscoderBridge.csproj
├── Program.cs
├── appsettings.json
├── Dockerfile
├── Models/
│   ├── RawSegmentReadyMessage.cs
│   ├── TranscodedSegmentReadyMessage.cs
│   ├── TranscodeJobRequest.cs
│   └── TranscodeCompletionCallback.cs
├── Services/
│   ├── TranscoderApiClient.cs
│   ├── RabbitMQConsumer.cs
│   ├── RabbitMQPublisher.cs
│   └── TranscoderBridgeService.cs
└── Controllers/
    └── WebhookController.cs
```

**Note**: No SymlinkManager - using direct volume mounts instead

### Key Files to Create

**1. TranscoderBridge.csproj**
```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="RabbitMQ.Client" Version="6.8.1" />
  </ItemGroup>
</Project>
```

**2. appsettings.json**
```json
{
  "Transcoder": {
    "ApiUrl": "http://transcoder:8080",
    "ApiTimeoutSeconds": 30
  },
  "RabbitMQ": {
    "Host": "rabbitmq",
    "Port": 5672,
    "Username": "dev",
    "Password": "${RABBITMQ_PASSWORD}",
    "VirtualHost": "cloudcam"
  },
  "TranscoderBridge": {
    "DataPath": "/data",
    "OutputPath": "/workspace/output",
    "WebhookPort": 8081,
    "CallbackBaseUrl": "http://transcoder-bridge:8081"
  }
}
```

**3. Program.cs**
```csharp
using TranscoderBridge.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddSingleton<TranscoderApiClient>();
builder.Services.AddSingleton<RabbitMQPublisher>();
builder.Services.AddSingleton<RabbitMQConsumer>();
builder.Services.AddHostedService<TranscoderBridgeService>();

var app = builder.Build();
app.MapControllers();
app.Run("http://0.0.0.0:8081");
```

**Service Files**: Implement 4 services based on existing patterns in Recorder/S3Uploader:
- `TranscoderApiClient.cs` - HTTP POST to transcoder
- `RabbitMQConsumer.cs` - Consume segment.raw.ready
- `RabbitMQPublisher.cs` - Publish segment.transcoded.ready
- `TranscoderBridgeService.cs` - Main orchestration

**TranscoderBridgeService API Request Format**:
```csharp
// Send to transcoder API:
{
  "inputPath": message.FilePath,  // Full path: /data/{jobId}/{recordingId}/raw/0.ts
  "callbackUrl": "http://transcoder-bridge:8081/completed",
  "metadata": {
    "recordingJobId": "...",
    "recordingId": "...",
    "fileName": "0.ts",
    "filePath": message.FilePath,  // Pass through for callback
    "segmentStart": "...",
    "segmentDuration": 10
  }
}
```

**WebhookController Callback Handling**:
```csharp
// When transcoder calls back with outputFile:
// Phase 1: outputFile = inputFile (raw segment path)
// Phase 2: outputFile = transcoded file path

var outputPath = Path.Combine(_config["TranscoderBridge:DataPath"]!, callback.OutputFile);
// OR if callback returns full path, use it directly

message.FilePath = outputPath;  // S3Uploader will read from this path
```

---

## 🔧 Step 2: Recorder Modifications

### Changes Required

**File**: `camera-v2/Recorder/Services/FFmpegManager.cs`

**Line ~79**: Change codec from libx264 to copy
```csharp
// BEFORE:
command.Append("-c:v libx264 -crf 34 -preset medium ");

// AFTER:
command.Append("-c:v copy ");
```

**Line ~46**: Add `/raw` subdirectory
```csharp
// BEFORE:
var outputDir = Path.Combine(_config.DataPath, session.RecordingJobId.ToString(), session.RecordingId.ToString());

// AFTER:
var outputDir = Path.Combine(_config.DataPath, session.RecordingJobId.ToString(), session.RecordingId.ToString(), "raw");
```

**File**: `camera-v2/Recorder/Models/Messages.cs`

Add new message type:
```csharp
public class RawSegmentReadyMessage
{
    public Guid RecordingJobId { get; set; }
    public Guid RecordingId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string FilePath { get; set; } = string.Empty;
    public long FileSize { get; set; }
    public DateTime SegmentStart { get; set; }
    public DateTime SegmentEnd { get; set; }
    public int SegmentDuration { get; set; }
}
```

**File**: `camera-v2/Recorder/Services/RecordingService.cs`

Change queue name from `segment.ready` to `segment.raw.ready` in message publishing logic.

---

## 🔧 Step 3: S3Uploader Modifications

### Code Changes

**File**: `camera-v2/S3Uploader/Services/RabbitMQConsumer.cs`

**Change queue binding**:
```csharp
// BEFORE:
channel.QueueBind("segment.upload.queue", "segment.ready", "");

// AFTER:
channel.QueueBind("segment.upload.queue", "segment.transcoded.ready", "");
```

**Add message model**: `TranscodedSegmentReadyMessage` (same as in TranscoderBridge)

**Update file path logic** to use `message.FilePath` directly (already contains full path from TranscoderBridge)

### S3 Configuration (Two Buckets)

**File**: `camera-v2/S3Uploader/appsettings.json`

Update S3 section to support test bucket:
```json
{
  "S3": {
    "Endpoint": "s3.wasabisys.com",
    "BucketName": "your-test-bucket",
    "AccessKey": "${S3_ACCESS_KEY}",
    "SecretKey": "${S3_SECRET_KEY}",
    "UseSSL": true
  }
}
```

**Environment-based Configuration**:

**Phase 1 (Test Server - Wasabi)**:
```yaml
# docker-compose.yml
s3-uploader:
  environment:
    S3__Endpoint: "s3.wasabisys.com"
    S3__BucketName: "your-wasabi-test-bucket"
    S3__AccessKey: "${WASABI_ACCESS_KEY}"
    S3__SecretKey: "${WASABI_SECRET_KEY}"
    S3__UseSSL: "true"
```

**Phase 2 (GPU Server - Production MinIO)**:
```yaml
# docker-compose.yml (on GPU server)
s3-uploader:
  environment:
    S3__Endpoint: "nbpublic.narbulut.com"
    S3__BucketName: "berkin-test"
    S3__AccessKey: "${MINIO_ACCESS_KEY}"
    S3__SecretKey: "${MINIO_SECRET_KEY}"
    S3__UseSSL: "true"
```

**Add to .env file (Test Server)**:
```bash
WASABI_ACCESS_KEY=your_wasabi_access_key
WASABI_SECRET_KEY=your_wasabi_secret_key
```

### Docker Volume Mounts

**Add volume mount in docker-compose.yml**:
```yaml
s3-uploader:
  volumes:
    - recorder_data:/data:ro  # Existing - for raw segments in Phase 1
    - transcoder_output:/workspace/output:ro  # NEW - for transcoded files in Phase 2
```

---

## 🔧 Step 4: Docker Compose Setup

**File**: `camera-v2/docker-compose.yml`

Add these services:

```yaml
  transcoder:
    build:
      context: ..
      dockerfile: Dockerfile.transcoder
    container_name: camera-v2-transcoder
    volumes:
      - recorder_data:/data:ro           # Direct access to recorder files
      - transcoder_output:/workspace/output
    ports:
      - "8080:8080"
    restart: unless-stopped

  transcoder-bridge:
    build: ./TranscoderBridge
    container_name: camera-v2-transcoder-bridge
    depends_on:
      rabbitmq:
        condition: service_healthy
      transcoder:
        condition: service_started
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      Transcoder__ApiUrl: "http://transcoder:8080"
      RabbitMQ__Host: "rabbitmq"
      RabbitMQ__Port: "5672"
      RabbitMQ__Username: "dev"
      RabbitMQ__Password: "${RABBITMQ_PASSWORD}"
      RabbitMQ__VirtualHost: "cloudcam"
      TranscoderBridge__DataPath: "/data"
      TranscoderBridge__OutputPath: "/workspace/output"
      TranscoderBridge__CallbackBaseUrl: "http://transcoder-bridge:8081"
    volumes:
      - recorder_data:/data:ro
      - transcoder_output:/workspace/output
    ports:
      - "8081:8081"
    restart: unless-stopped

volumes:
  transcoder_output:
```

**File**: `Dockerfile.transcoder`

```dockerfile
FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

RUN apt-get update && apt-get install -y \
    ffmpeg libavformat-dev libavcodec-dev libavutil-dev \
    libavfilter-dev libswresample-dev libmicrohttpd-dev \
    libcurl4-openssl-dev libcjson-dev build-essential curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY ./transcoder.c ./Makefile ./
RUN make clean && make

WORKDIR /workspace
RUN mkdir -p tsfiles output

EXPOSE 8080
CMD ["/app/transcoder"]
```

**⚠️ Phase 1 Note**: This Dockerfile uses CUDA base image but will work on test server when running transcoder with `--no-gpu` flag (see Step 5). The same binary works for both Phase 1 (no GPU) and Phase 2 (with GPU).

---

## 🔧 Step 5: Modify transcoder.c for Phase 1 (No-GPU Mode)

Add `--no-gpu` flag to transcoder.c to run without GPU hardware for testing.

**File**: `transcoder.c`

**Add global variable** (after includes, around line 80):
```c
static int no_gpu_mode = 0;  // Test mode flag
```

**Modify main() function** to accept flag (around line 650):
```c
int main(int argc, char *argv[]) {
    // Check for no-GPU mode
    if (argc > 1 && strcmp(argv[1], "--no-gpu") == 0) {
        no_gpu_mode = 1;
        printf("⚠️  Running in NO-GPU mode (testing only - file copy instead of transcode)\n");
    }

    // ... rest of existing main() code
}
```

**Modify worker_thread()** to skip GPU transcoding (around line 450, in processing loop):
```c
if (no_gpu_mode) {
    // Phase 1 testing: Just acknowledge, send back input path for S3 upload
    printf("⚠️  NO-GPU mode: Received %s - would transcode if GPU available\n", job.filename);

    // In no-GPU mode, send back the INPUT path (raw segment)
    // This allows S3Uploader to upload the raw file for testing
    // In Phase 2, this will be the transcoded output path instead

    // Immediately send completion callback (no actual work)
    notify_completion(job.callback_url,
                     job.filename,           // inputFile
                     job.filename,           // outputFile = inputFile (Phase 1)
                     0,                      // frame_count = 0 (no processing)
                     1,                      // processing_time_ms = 1ms (instant)
                     job.metadata_json,
                     "completed");

    printf("✅ Acknowledgment sent - S3Uploader will upload raw segment\n");
} else {
    // Phase 2: Normal GPU transcoding
    // ... existing NVDEC/NVENC code ...
    // Will send actual transcoded output path
}
```

**Note**:
- **Phase 1**: Sends input path back → S3Uploader uploads **raw segment**
- **Phase 2**: Sends output path back → S3Uploader uploads **transcoded segment**

**Update docker-compose.yml** to use no-GPU mode in Phase 1:
```yaml
transcoder:
  build:
    context: ..
    dockerfile: Dockerfile.transcoder
  container_name: camera-v2-transcoder
  volumes:
    - recorder_data:/data:ro
    - transcoder_output:/workspace/output
  ports:
    - "8080:8080"
  command: ["/app/transcoder", "--no-gpu"]  # Phase 1: No GPU mode
  restart: unless-stopped
  # For Phase 2 on GPU server, remove command line or change to:
  # command: ["/app/transcoder"]  # Will use GPU
```

---

## 🔧 Step 6: Testing Checklist (Phase 1)

### Bridge Communication Test
- [ ] Start all services: `docker-compose up -d`
- [ ] Check TranscoderBridge logs: `docker-compose logs -f transcoder-bridge`
- [ ] Verify RabbitMQ connection established
- [ ] Trigger recording via RecorderScheduler
- [ ] Verify:
  - [ ] Raw segment written to `/data/.../raw/0.ts`
  - [ ] `segment.raw.ready` message published to RabbitMQ
  - [ ] TranscoderBridge consumes message
  - [ ] HTTP POST to transcoder `/enqueue` with full file path
  - [ ] Transcoder calls back to `/completed`
  - [ ] `segment.transcoded.ready` published
  - [ ] S3Uploader consumes message
  - [ ] File uploaded to S3

### Validation Commands
```bash
# Check RabbitMQ queues
docker exec camera-v2-rabbitmq rabbitmqctl list_queues

# Check TranscoderBridge logs
docker-compose logs transcoder-bridge | grep "Processing raw segment"

# Check transcoder has access to recorder files
docker exec camera-v2-transcoder ls -la /data/

# Check S3 uploads
docker-compose logs s3-uploader | grep "Upload successful"
```

---

## 🚨 Critical Notes for Phase 1

### What We're Testing
✅ RabbitMQ message flow
✅ HTTP API communication
✅ Webhook callbacks
✅ Direct file access via volume mounts
✅ Service orchestration

### What We're NOT Testing (Phase 2)
❌ Actual GPU transcoding
❌ Video quality/compression
❌ NVENC/NVDEC performance
❌ GPU utilization

### Success Criteria for Phase 1
- All services start without errors
- Messages flow through complete pipeline
- Callbacks received and processed
- Raw segments uploaded to **Wasabi S3** successfully
- No crashes or connection issues
- Ready to copy to GPU server (will switch to MinIO/production bucket)

---

## 🔄 Rollback Plan

If anything fails, revert these 3 changes:

1. **Recorder**: Change `-c:v copy` back to `-c:v libx264 -crf 34 -preset medium`
2. **Recorder**: Change `segment.raw.ready` back to `segment.ready`
3. **S3Uploader**: Change `segment.transcoded.ready` back to `segment.ready`

Stop new services: `docker-compose stop transcoder transcoder-bridge`

---

## 📝 Implementation Order

1. ✅ Add `--no-gpu` flag to transcoder.c
2. ✅ Create TranscoderBridge service files
3. ✅ Modify Recorder (FFmpeg + messages)
4. ✅ Modify S3Uploader (queue binding)
5. ✅ Update docker-compose.yml
6. ✅ Create docker-compose.override.yml for local isolation
7. ✅ Configure Panel for local testing
8. ✅ Create .env files with credentials
9. ✅ Pre-flight check - all systems verified
10. 🟡 **User Testing** - Ready to start (current step)
11. ⏸️ Move to GPU server (Phase 2)
12. ⏸️ Change transcoder command to remove `--no-gpu` flag

---

---

## 📝 Session Log

### Session 1: 2025-10-23 - Planning & Design
- Created initial implementation plan
- Identified and fixed 10 critical issues
- Refactored to two-phase approach (test server → GPU server)
- **Removed symlink complexity** - using direct volume mounts instead
- Simplified architecture: 4 services instead of 5 (no SymlinkManager)
- **Added `--no-gpu` flag to transcoder.c** - same binary for both phases, no Python mock needed
- **S3 bucket strategy**: Wasabi for Phase 1 testing, MinIO for Phase 2 production

### Session 2: 2025-10-23 - Implementation Complete
- ✅ Implemented all Phase 1 components
- ✅ Created TranscoderBridge service (complete .NET 9.0 microservice)
- ✅ Modified Recorder for raw H.264 pass-through
- ✅ Modified S3Uploader for transcoded segment consumption
- ✅ Created Docker infrastructure (Dockerfile.transcoder, docker-compose updates)
- ✅ Implemented complete production isolation strategy
- ✅ Created docker-compose.override.yml for camera-v2 and camera-v2-panel
- ✅ Configured Panel to connect to local services
- ✅ Created .env files with user's Wasabi credentials
- ✅ Completed comprehensive pre-flight check
- ✅ Verified zero production exposure
- ✅ All documentation updated

**Issues Resolved:**
- Attempted to modify production docker-compose.yml → Fixed with override pattern
- Used production IP 172.17.12.97 → Changed to localhost/host.docker.internal
- Added :9000 port to S3 endpoint → Removed per user feedback
- Panel connecting to production DB → Created override file for local isolation

---

**Last Updated**: 2025-10-23
**Status**: ✅ Phase 1 Complete - Pre-flight Check Passed - Ready for Testing
**Next Action**: User to run `docker-compose up -d` and begin end-to-end testing
