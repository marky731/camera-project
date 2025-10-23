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
| 1 | TranscoderBridge Service | 🔴 Not Started | Critical | |
| 2 | Recorder Modifications | 🔴 Not Started | Critical | |
| 3 | S3Uploader Modifications | 🔴 Not Started | Critical | |
| 4 | Docker Compose Setup | 🔴 Not Started | Critical | |
| 5 | Mock Transcoder API | 🔴 Not Started | For Testing | |
| 6 | End-to-End Validation | 🔴 Not Started | Final Check | |

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
    "segmentStart": "...",
    "segmentDuration": 10
  }
}
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

**Add volume mount in docker-compose.yml**:
```yaml
s3-uploader:
  volumes:
    - recorder_data:/data:ro  # Existing
    - transcoder_output:/workspace/output:ro  # NEW - read transcoded files
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

**⚠️ Phase 1 Note**: This Dockerfile requires GPU hardware (CUDA base image). For Phase 1 testing on test server **without GPU**, use the Python mock transcoder instead (see Step 5 below). This Dockerfile will be used in Phase 2 on the GPU server.

---

## 🔧 Step 5: Mock Transcoder for Testing (Phase 1)

Since we don't have GPU on test server, create a simple mock that:

1. Listens on port 8080
2. Accepts POST `/enqueue` with full file path
3. Immediately calls back to webhook with success
4. Doesn't actually transcode (just copies file or creates dummy output)

**Quick Python Mock** (optional for testing):
```python
from flask import Flask, request
import requests
import shutil
import os

app = Flask(__name__)

@app.route('/enqueue', methods=['POST'])
def enqueue():
    data = request.json
    callback_url = data['callbackUrl']
    input_path = data['inputPath']  # Full path from message

    # Create dummy output file (just copy)
    output_filename = os.path.basename(input_path).replace('.ts', '_h264.ts')
    output_path = f'/workspace/output/{output_filename}'
    shutil.copy(input_path, output_path)

    # Immediately callback
    requests.post(callback_url, json={
        'inputFile': os.path.basename(input_path),
        'outputFile': output_filename,
        'frameCount': 250,
        'status': 'completed',
        'processingTimeMs': 10,
        'metadata': data['metadata']
    })
    return {'status': 'queued'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
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
- No crashes or connection issues
- Ready to copy to GPU server

---

## 🔄 Rollback Plan

If anything fails, revert these 3 changes:

1. **Recorder**: Change `-c:v copy` back to `-c:v libx264 -crf 34 -preset medium`
2. **Recorder**: Change `segment.raw.ready` back to `segment.ready`
3. **S3Uploader**: Change `segment.transcoded.ready` back to `segment.ready`

Stop new services: `docker-compose stop transcoder transcoder-bridge`

---

## 📝 Implementation Order

1. ✅ Create TranscoderBridge service files
2. ✅ Modify Recorder (FFmpeg + messages)
3. ✅ Modify S3Uploader (queue binding)
4. ✅ Update docker-compose.yml
5. ✅ Create Dockerfile.transcoder
6. ✅ Build and test locally
7. ✅ Validate end-to-end flow
8. ⏸️ Move to GPU server (Phase 2)

---

---

## 📝 Session Log

### Session 1: 2025-10-23 - Planning & Design
- Created initial implementation plan
- Identified and fixed 10 critical issues
- Refactored to two-phase approach (test server → GPU server)
- **Removed symlink complexity** - using direct volume mounts instead
- Simplified architecture: 4 services instead of 5 (no SymlinkManager)

### Session 2: [Date] - [Work Done]
- Status updates go here
- Track progress with emoji indicators in table above

---

**Last Updated**: 2025-10-23
**Status**: Ready for Phase 1 Implementation
**Next Action**: Create TranscoderBridge service directory structure
