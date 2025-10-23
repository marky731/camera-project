# GPU Transcoder Integration - Implementation Plan

**Project**: CloudCam 24/7 GPU Transcoder Integration
**Created**: 2025-10-23
**Status**: 🔴 Not Started
**Progress**: 0% (0/11 phases complete)
**Current Phase**: Phase 1 - TranscoderBridge Service Creation
**Last Updated**: 2025-10-23 12:07 UTC

---

## 📊 Quick Status Dashboard

| Phase | Component | Status | Progress | Blockers |
|-------|-----------|--------|----------|----------|
| 1 | TranscoderBridge Service | 🔴 Not Started | 0/15 | None |
| 2 | Recorder Modifications | 🔴 Not Started | 0/5 | None |
| 3 | transcoder.c Extensions | 🔴 Not Started | 0/6 | None |
| 4 | S3Uploader Modifications | 🔴 Not Started | 0/4 | None |
| 5 | RabbitMQ Queue Setup | 🔴 Not Started | 0/3 | None |
| 6 | Docker Compose Integration | 🔴 Not Started | 0/5 | None |
| 7 | Dockerfile Creation | 🔴 Not Started | 0/3 | None |
| 8 | Storage Directory Setup | 🔴 Not Started | 0/2 | None |
| 9 | Configuration Updates | 🔴 Not Started | 0/3 | None |
| 10 | Testing & Validation | 🔴 Not Started | 0/8 | None |
| 11 | Documentation & Cleanup | 🔴 Not Started | 0/4 | None |

**Legend**: 🔴 Not Started | 🟡 In Progress | 🟢 Complete | 🔵 Blocked | ⚠️ Issue

---

## 🎯 Project Overview

### Goal
Integrate the GPU-accelerated transcoder ([transcoder.c](transcoder.c)) into the CloudCam 24/7 recording pipeline to offload CPU-intensive encoding to RTX 5090 GPU.

### Architecture Change
```
BEFORE: Camera → Recorder (CPU libx264) → S3 → Player
AFTER:  Camera → Recorder (copy codec) → TranscoderBridge → GPU Transcoder → S3 → Player
```

### Key Benefits
- ✅ 71% storage reduction (6.5GB → 1.9GB)
- ✅ 1,374 files/minute transcoding capacity
- ✅ Offload CPU encoding to dedicated GPU
- ✅ Maintain recording reliability (decouple concerns)

### References
- Architecture: [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md)
- Integration Design: [TRANSCODER_INTEGRATION.md](TRANSCODER_INTEGRATION.md)
- Transcoder Details: [Transcoder.md](Transcoder.md)
- Transcoder Code: [transcoder.c](transcoder.c)

---

## 📋 Implementation Phases

---

### **Phase 1: Create TranscoderBridge Service** 🔴 Not Started

**Objective**: Build new .NET 9 microservice to bridge RabbitMQ ↔ GPU Transcoder HTTP API

**Status**: 0/15 tasks complete

#### Tasks

##### 1.1 Project Setup
- [ ] Create directory `camera-v2/TranscoderBridge/`
- [ ] Create `TranscoderBridge.csproj` with .NET 9 SDK
- [ ] Add NuGet packages:
  - [ ] `RabbitMQ.Client` (>= 6.8.0)
  - [ ] `Microsoft.Extensions.Hosting` (>= 9.0.0)
  - [ ] `System.Text.Json` (>= 9.0.0)

**File**: [camera-v2/TranscoderBridge/TranscoderBridge.csproj](camera-v2/TranscoderBridge/TranscoderBridge.csproj)
```xml
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="RabbitMQ.Client" Version="6.8.1" />
    <PackageReference Include="Microsoft.Extensions.Hosting" Version="9.0.0" />
  </ItemGroup>
</Project>
```

##### 1.2 Configuration
- [ ] Create `appsettings.json` with Transcoder API URL, RabbitMQ settings, storage paths

**File**: [camera-v2/TranscoderBridge/appsettings.json](camera-v2/TranscoderBridge/appsettings.json)
```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "Transcoder": {
    "ApiUrl": "http://transcoder:8080",
    "ApiTimeoutSeconds": 30
  },
  "RabbitMQ": {
    "Host": "rabbitmq",
    "Port": 5672,
    "Username": "dev",
    "Password": "${RABBITMQ_PASSWORD}",
    "VirtualHost": "cloudcam",
    "InputQueue": "segment.raw.ready",
    "OutputQueue": "segment.transcoded.ready",
    "PrefetchCount": 5
  },
  "TranscoderBridge": {
    "DataPath": "/data",
    "InputPath": "/data/transcoder-input",
    "OutputPath": "/data/transcoder-output",
    "WebhookPort": 8081,
    "CleanupRawAfterTranscode": true,
    "CleanupSymlinksAfterCallback": true
  }
}
```

##### 1.3 Message Models
- [ ] Create `Models/RawSegmentReadyMessage.cs`
- [ ] Create `Models/TranscodedSegmentReadyMessage.cs`
- [ ] Create `Models/TranscodeJobRequest.cs`
- [ ] Create `Models/TranscodeCompletionCallback.cs`

**File**: [camera-v2/TranscoderBridge/Models/RawSegmentReadyMessage.cs](camera-v2/TranscoderBridge/Models/RawSegmentReadyMessage.cs)
```csharp
namespace TranscoderBridge.Models;

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

**File**: [camera-v2/TranscoderBridge/Models/TranscodedSegmentReadyMessage.cs](camera-v2/TranscoderBridge/Models/TranscodedSegmentReadyMessage.cs)
```csharp
namespace TranscoderBridge.Models;

public class TranscodedSegmentReadyMessage
{
    public Guid RecordingJobId { get; set; }
    public Guid RecordingId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string FilePath { get; set; } = string.Empty;
    public long FileSize { get; set; }
    public DateTime SegmentStart { get; set; }
    public DateTime SegmentEnd { get; set; }
    public int SegmentDuration { get; set; }
    public string Resolution { get; set; } = "1280x720";
    public double CompressionRatio { get; set; }
    public int FrameCount { get; set; }
    public long ProcessingTimeMs { get; set; }
}
```

**File**: [camera-v2/TranscoderBridge/Models/TranscodeJobRequest.cs](camera-v2/TranscoderBridge/Models/TranscodeJobRequest.cs)
```csharp
namespace TranscoderBridge.Models;

public class TranscodeJobRequest
{
    public string Filename { get; set; } = string.Empty;
    public string CallbackUrl { get; set; } = string.Empty;
    public Dictionary<string, object> Metadata { get; set; } = new();
}
```

**File**: [camera-v2/TranscoderBridge/Models/TranscodeCompletionCallback.cs](camera-v2/TranscoderBridge/Models/TranscodeCompletionCallback.cs)
```csharp
namespace TranscoderBridge.Models;

public class TranscodeCompletionCallback
{
    public string InputFile { get; set; } = string.Empty;
    public string OutputFile { get; set; } = string.Empty;
    public int FrameCount { get; set; }
    public string Status { get; set; } = string.Empty;
    public long ProcessingTimeMs { get; set; }
    public Dictionary<string, object> Metadata { get; set; } = new();
}
```

##### 1.4 Core Services
- [ ] Create `Services/TranscoderApiClient.cs` - HTTP client for transcoder.c API
- [ ] Create `Services/RabbitMQConsumer.cs` - Consume segment.raw.ready
- [ ] Create `Services/RabbitMQPublisher.cs` - Publish segment.transcoded.ready
- [ ] Create `Services/SymlinkManager.cs` - Symlink creation/cleanup
- [ ] Create `Services/TranscoderBridgeService.cs` - Main orchestrator

**File**: [camera-v2/TranscoderBridge/Services/TranscoderApiClient.cs](camera-v2/TranscoderBridge/Services/TranscoderApiClient.cs)
```csharp
namespace TranscoderBridge.Services;

public class TranscoderApiClient
{
    private readonly HttpClient _httpClient;
    private readonly ILogger<TranscoderApiClient> _logger;
    private readonly string _apiUrl;

    public TranscoderApiClient(IConfiguration config, ILogger<TranscoderApiClient> logger)
    {
        _apiUrl = config["Transcoder:ApiUrl"] ?? "http://transcoder:8080";
        var timeout = config.GetValue<int>("Transcoder:ApiTimeoutSeconds", 30);

        _httpClient = new HttpClient
        {
            BaseAddress = new Uri(_apiUrl),
            Timeout = TimeSpan.FromSeconds(timeout)
        };
        _logger = logger;
    }

    public async Task<bool> EnqueueTranscodeJobAsync(TranscodeJobRequest request, CancellationToken ct)
    {
        try
        {
            var response = await _httpClient.PostAsJsonAsync("/enqueue", request, ct);
            response.EnsureSuccessStatusCode();
            _logger.LogInformation("Enqueued transcode job: {Filename}", request.Filename);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to enqueue transcode job: {Filename}", request.Filename);
            return false;
        }
    }
}
```

##### 1.5 Webhook Controller
- [ ] Create `Controllers/WebhookController.cs` - POST /completed endpoint

**File**: [camera-v2/TranscoderBridge/Controllers/WebhookController.cs](camera-v2/TranscoderBridge/Controllers/WebhookController.cs)
```csharp
using Microsoft.AspNetCore.Mvc;
using TranscoderBridge.Models;
using TranscoderBridge.Services;

namespace TranscoderBridge.Controllers;

[ApiController]
[Route("")]
public class WebhookController : ControllerBase
{
    private readonly ILogger<WebhookController> _logger;
    private readonly RabbitMQPublisher _publisher;
    private readonly SymlinkManager _symlinkManager;
    private readonly IConfiguration _config;

    public WebhookController(
        ILogger<WebhookController> logger,
        RabbitMQPublisher publisher,
        SymlinkManager symlinkManager,
        IConfiguration config)
    {
        _logger = logger;
        _publisher = publisher;
        _symlinkManager = symlinkManager;
        _config = config;
    }

    [HttpPost("completed")]
    public async Task<IActionResult> TranscodeCompleted([FromBody] TranscodeCompletionCallback callback)
    {
        try
        {
            _logger.LogInformation("Received transcode completion: {OutputFile}", callback.OutputFile);

            // Extract metadata passed through from original message
            var metadata = callback.Metadata;
            var recordingJobId = Guid.Parse(metadata["recordingJobId"].ToString()!);
            var recordingId = Guid.Parse(metadata["recordingId"].ToString()!);
            var segmentStart = DateTime.Parse(metadata["segmentStart"].ToString()!);
            var segmentDuration = int.Parse(metadata["segmentDuration"].ToString()!);

            // Calculate compression ratio
            var outputPath = Path.Combine(_config["TranscoderBridge:OutputPath"]!, callback.OutputFile);
            var outputSize = new FileInfo(outputPath).Length;
            var inputFile = metadata["fileName"].ToString()!;
            var inputPath = Path.Combine(_config["TranscoderBridge:DataPath"]!,
                recordingJobId.ToString(), recordingId.ToString(), "raw", inputFile);
            var inputSize = new FileInfo(inputPath).Length;
            var compressionRatio = (double)outputSize / inputSize;

            // Publish transcoded segment ready message
            var message = new TranscodedSegmentReadyMessage
            {
                RecordingJobId = recordingJobId,
                RecordingId = recordingId,
                FileName = callback.OutputFile,
                FilePath = outputPath,
                FileSize = outputSize,
                SegmentStart = segmentStart,
                SegmentEnd = segmentStart.AddSeconds(segmentDuration),
                SegmentDuration = segmentDuration,
                Resolution = "1280x720",
                CompressionRatio = compressionRatio,
                FrameCount = callback.FrameCount,
                ProcessingTimeMs = callback.ProcessingTimeMs
            };

            await _publisher.PublishTranscodedSegmentReadyAsync(message);

            // Cleanup symlink if configured
            if (_config.GetValue<bool>("TranscoderBridge:CleanupSymlinksAfterCallback"))
            {
                var symlinkPath = Path.Combine(_config["TranscoderBridge:InputPath"]!, callback.InputFile);
                _symlinkManager.RemoveSymlink(symlinkPath);
            }

            // Cleanup raw file if configured
            if (_config.GetValue<bool>("TranscoderBridge:CleanupRawAfterTranscode"))
            {
                if (File.Exists(inputPath))
                {
                    File.Delete(inputPath);
                    _logger.LogInformation("Cleaned up raw segment: {InputPath}", inputPath);
                }
            }

            return Ok(new { status = "acknowledged" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error processing transcode completion callback");
            return StatusCode(500, new { error = ex.Message });
        }
    }

    [HttpGet("health")]
    public IActionResult Health()
    {
        return Ok(new { status = "healthy", timestamp = DateTime.UtcNow });
    }
}
```

##### 1.6 Program.cs Setup
- [ ] Create `Program.cs` with service registration and host configuration

**File**: [camera-v2/TranscoderBridge/Program.cs](camera-v2/TranscoderBridge/Program.cs)
```csharp
using TranscoderBridge.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services
builder.Services.AddControllers();
builder.Services.AddSingleton<TranscoderApiClient>();
builder.Services.AddSingleton<RabbitMQPublisher>();
builder.Services.AddSingleton<SymlinkManager>();
builder.Services.AddHostedService<TranscoderBridgeService>();

var app = builder.Build();

app.MapControllers();

var port = builder.Configuration.GetValue<int>("TranscoderBridge:WebhookPort", 8081);
app.Run($"http://0.0.0.0:{port}");
```

##### 1.7 Dockerfile
- [ ] Create `Dockerfile` for containerization

**File**: [camera-v2/TranscoderBridge/Dockerfile](camera-v2/TranscoderBridge/Dockerfile)
```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY TranscoderBridge.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/aspnet:9.0
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "TranscoderBridge.dll"]
```

#### Validation Checklist
- [ ] Project builds without errors: `dotnet build`
- [ ] All models have correct properties matching message schemas
- [ ] HTTP client correctly configured with timeout
- [ ] Webhook controller returns proper HTTP status codes
- [ ] Configuration paths are injectable via environment variables

---

### **Phase 2: Modify Recorder Service** 🔴 Not Started

**Objective**: Change Recorder to use copy codec and publish to new queue

**Status**: 0/5 tasks complete

#### Tasks

##### 2.1 FFmpeg Command Update
- [ ] Modify `camera-v2/Recorder/Services/FFmpegManager.cs` BuildFFmpegCommand method
- [ ] Remove libx264 encoding parameters (line ~150)
- [ ] Add `-c:v copy` codec parameter
- [ ] Remove scale filter and quality settings

**File**: [camera-v2/Recorder/Services/FFmpegManager.cs](camera-v2/Recorder/Services/FFmpegManager.cs)
**Location**: Line ~150 in `BuildFFmpegCommand()` method

**BEFORE:**
```csharp
command.Append($"-vf scale={width}:{height} ");
command.Append("-c:v libx264 -crf 34 -preset medium ");
```

**AFTER:**
```csharp
command.Append("-c:v copy ");
```

##### 2.2 Storage Path Update
- [ ] Modify output directory to include `/raw` subdirectory
- [ ] Update segment path detection in monitoring logic

**File**: [camera-v2/Recorder/Services/FFmpegManager.cs](camera-v2/Recorder/Services/FFmpegManager.cs)
**Location**: Line ~80 in `StartRecordingAsync()` method

**BEFORE:**
```csharp
var outputDir = Path.Combine(dataPath, recordingJobId, recordingId);
```

**AFTER:**
```csharp
var outputDir = Path.Combine(dataPath, recordingJobId, recordingId, "raw");
Directory.CreateDirectory(outputDir); // Ensure raw subdirectory exists
```

##### 2.3 New Message Type
- [ ] Add `RawSegmentReadyMessage` class to `camera-v2/Recorder/Models/Messages.cs`

**File**: [camera-v2/Recorder/Models/Messages.cs](camera-v2/Recorder/Models/Messages.cs)
**Location**: Add at end of file

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

##### 2.4 Message Publishing Update
- [ ] Modify `camera-v2/Recorder/Services/RecordingService.cs` to publish `RawSegmentReadyMessage`
- [ ] Change queue name from `segment.ready` to `segment.raw.ready`

**File**: [camera-v2/Recorder/Services/RecordingService.cs](camera-v2/Recorder/Services/RecordingService.cs)
**Location**: Find `PublishSegmentReadyMessage` method

**ADD NEW METHOD:**
```csharp
private async Task PublishRawSegmentReadyMessage(Segment segment)
{
    var message = new RawSegmentReadyMessage
    {
        RecordingJobId = segment.RecordingJobId,
        RecordingId = segment.RecordingId,
        FileName = segment.FileName,
        FilePath = segment.FilePath,
        FileSize = segment.FileSize,
        SegmentStart = segment.SegmentStart,
        SegmentEnd = segment.SegmentEnd,
        SegmentDuration = segment.SegmentDuration
    };

    await _outboxService.AddOutboxMessageAsync(
        "segment.raw.ready",
        "segment.raw.ready",
        JsonSerializer.Serialize(message)
    );
}
```

**REPLACE CALLS:** Find all calls to `PublishSegmentReadyMessage` and replace with `PublishRawSegmentReadyMessage`

##### 2.5 Configuration
- [ ] Add configuration flag to enable/disable raw capture mode

**File**: [camera-v2/Recorder/appsettings.json](camera-v2/Recorder/appsettings.json)

```json
{
  "Recorder": {
    "DataPath": "/data",
    "FFmpegPath": "ffmpeg",
    "RecordingDurationSeconds": 3620,
    "SegmentMonitorIntervalMs": 5000,
    "OutboxProcessIntervalMs": 10000,
    "RtspTransport": "tcp",
    "RtspTimeoutSeconds": 10,
    "UseRawCapture": true,
    "RawSegmentQueue": "segment.raw.ready"
  }
}
```

#### Validation Checklist
- [ ] FFmpeg command verified: `ffmpeg ... -c:v copy ...` (no libx264)
- [ ] Output directory includes `/raw` subdirectory
- [ ] RawSegmentReadyMessage has all required fields
- [ ] Queue name changed to `segment.raw.ready`
- [ ] Build successful: `dotnet build camera-v2/Recorder/`

---

### **Phase 3: Extend transcoder.c** 🔴 Not Started

**Objective**: Add HTTP callback support with libcurl for completion notifications

**Status**: 0/6 tasks complete

#### Tasks

##### 3.1 Add libcurl Dependency
- [ ] Update Makefile to link libcurl

**File**: [Makefile](Makefile)
**Location**: `LIBS` variable line

**BEFORE:**
```makefile
LIBS = -lavformat -lavcodec -lavutil -lavfilter -lswresample \
       -lcudart -lcuda -lmicrohttpd -lpthread
```

**AFTER:**
```makefile
LIBS = -lavformat -lavcodec -lavutil -lavfilter -lswresample \
       -lcudart -lcuda -lmicrohttpd -lpthread -lcurl
```

##### 3.2 Add libcurl Headers
- [ ] Add `#include <curl/curl.h>` to transcoder.c

**File**: [transcoder.c](transcoder.c)
**Location**: After line ~10 (with other includes)

```c
#include <curl/curl.h>
```

##### 3.3 Extend Job Structure
- [ ] Add callback_url and metadata_json fields to TranscodeJob struct

**File**: [transcoder.c](transcoder.c)
**Location**: Find `typedef struct` for TranscodeJob (around line 50-60)

**BEFORE:**
```c
typedef struct {
    char filename[512];
    // ... other fields
} TranscodeJob;
```

**AFTER:**
```c
typedef struct {
    char filename[512];
    char callback_url[512];      // NEW: HTTP callback endpoint
    char metadata_json[2048];    // NEW: JSON metadata passthrough
    // ... other fields
} TranscodeJob;
```

##### 3.4 Implement notify_completion Function
- [ ] Add new function to POST completion notification via libcurl

**File**: [transcoder.c](transcoder.c)
**Location**: Add before worker_thread function (around line 400)

```c
// HTTP callback notification for transcode completion
static void notify_completion(const char* callback_url,
                              const char* input_file,
                              const char* output_file,
                              int frame_count,
                              long processing_time_ms,
                              const char* metadata_json,
                              const char* status) {
    if (!callback_url || strlen(callback_url) == 0) {
        return; // No callback configured
    }

    CURL *curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "Failed to initialize libcurl\n");
        return;
    }

    // Build JSON payload
    char payload[4096];
    snprintf(payload, sizeof(payload),
        "{\"inputFile\":\"%s\",\"outputFile\":\"%s\",\"frameCount\":%d,"
        "\"status\":\"%s\",\"processingTimeMs\":%ld,\"metadata\":%s}",
        input_file, output_file, frame_count, status, processing_time_ms,
        metadata_json && strlen(metadata_json) > 0 ? metadata_json : "{}");

    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, callback_url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);

    CURLcode res = curl_easy_perform(curl);
    if (res != CURLE_OK) {
        fprintf(stderr, "Callback failed: %s\n", curl_easy_strerror(res));
    } else {
        printf("✅ Callback sent to %s\n", callback_url);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
}
```

##### 3.5 Update /enqueue Endpoint
- [ ] Parse callbackUrl and metadata from JSON request body
- [ ] Store in TranscodeJob structure

**File**: [transcoder.c](transcoder.c)
**Location**: Find `handle_enqueue` function (around line 600)

**MODIFY** JSON parsing to extract new fields:
```c
// After parsing "filename" field, add:

// Parse callback URL (optional)
const char *callback_key = "\"callbackUrl\":\"";
const char *callback_start = strstr(request_body, callback_key);
if (callback_start) {
    callback_start += strlen(callback_key);
    const char *callback_end = strchr(callback_start, '"');
    if (callback_end) {
        size_t len = callback_end - callback_start;
        if (len < sizeof(job->callback_url)) {
            strncpy(job->callback_url, callback_start, len);
            job->callback_url[len] = '\0';
        }
    }
}

// Parse metadata (optional JSON object)
const char *metadata_key = "\"metadata\":";
const char *metadata_start = strstr(request_body, metadata_key);
if (metadata_start) {
    metadata_start += strlen(metadata_key);
    // Find matching closing brace for JSON object
    int brace_count = 0;
    const char *p = metadata_start;
    const char *metadata_end = NULL;

    while (*p) {
        if (*p == '{') brace_count++;
        else if (*p == '}') {
            brace_count--;
            if (brace_count == 0) {
                metadata_end = p + 1;
                break;
            }
        }
        p++;
    }

    if (metadata_end) {
        size_t len = metadata_end - metadata_start;
        if (len < sizeof(job->metadata_json)) {
            strncpy(job->metadata_json, metadata_start, len);
            job->metadata_json[len] = '\0';
        }
    }
}
```

##### 3.6 Call notify_completion After Transcoding
- [ ] Add callback invocation in worker_thread after successful transcode

**File**: [transcoder.c](transcoder.c)
**Location**: In `worker_thread` function, after successful transcoding (around line 500)

**ADD** after writing output file and before cleanup:
```c
// Record processing time
long processing_time_ms = /* calculate from start_time to end_time */;

// Notify completion via callback
notify_completion(
    job->callback_url,
    job->filename,
    output_filename,
    frame_count,
    processing_time_ms,
    job->metadata_json,
    "completed"
);
```

#### Validation Checklist
- [ ] Makefile includes `-lcurl` in LIBS
- [ ] Code compiles: `make clean && make`
- [ ] TranscodeJob struct has new fields
- [ ] notify_completion function compiles without errors
- [ ] JSON parsing extracts callbackUrl and metadata correctly
- [ ] Test callback with `curl -X POST http://localhost:8080/enqueue -d '{"filename":"test.ts","callbackUrl":"http://localhost:8081/completed","metadata":{}}'`

---

### **Phase 4: Update S3Uploader Service** 🔴 Not Started

**Objective**: Change S3Uploader to consume transcoded segments instead of raw

**Status**: 0/4 tasks complete

#### Tasks

##### 4.1 Update Queue Binding
- [ ] Change queue binding from `segment.ready` to `segment.transcoded.ready`

**File**: [camera-v2/S3Uploader/Services/RabbitMQConsumer.cs](camera-v2/S3Uploader/Services/RabbitMQConsumer.cs)
**Location**: Queue declaration/binding section

**BEFORE:**
```csharp
channel.QueueBind("segment.upload.queue", "segment.ready", "");
```

**AFTER:**
```csharp
channel.QueueBind("segment.upload.queue", "segment.transcoded.ready", "");
```

##### 4.2 Update Message Type
- [ ] Change deserialization to TranscodedSegmentReadyMessage

**File**: [camera-v2/S3Uploader/Services/RabbitMQConsumer.cs](camera-v2/S3Uploader/Services/RabbitMQConsumer.cs)
**Location**: Message handler method

**BEFORE:**
```csharp
var message = JsonSerializer.Deserialize<SegmentReadyMessage>(body);
```

**AFTER:**
```csharp
var message = JsonSerializer.Deserialize<TranscodedSegmentReadyMessage>(body);
```

##### 4.3 Add New Message Model
- [ ] Add TranscodedSegmentReadyMessage class to Models

**File**: [camera-v2/S3Uploader/Models/Messages.cs](camera-v2/S3Uploader/Models/Messages.cs)

```csharp
public class TranscodedSegmentReadyMessage
{
    public Guid RecordingJobId { get; set; }
    public Guid RecordingId { get; set; }
    public string FileName { get; set; } = string.Empty;
    public string FilePath { get; set; } = string.Empty;
    public long FileSize { get; set; }
    public DateTime SegmentStart { get; set; }
    public DateTime SegmentEnd { get; set; }
    public int SegmentDuration { get; set; }
    public string Resolution { get; set; } = "1280x720";
    public double CompressionRatio { get; set; }
    public int FrameCount { get; set; }
    public long ProcessingTimeMs { get; set; }
}
```

##### 4.4 Update File Path Logic
- [ ] Change source path to read from transcoder-output directory

**File**: [camera-v2/S3Uploader/Services/RabbitMQConsumer.cs](camera-v2/S3Uploader/Services/RabbitMQConsumer.cs)
**Location**: Upload handler method

**BEFORE:**
```csharp
var sourcePath = Path.Combine(dataPath, message.RecordingJobId.ToString(),
    message.RecordingId.ToString(), message.FileName);
```

**AFTER:**
```csharp
// FilePath already contains full path from TranscoderBridge
var sourcePath = message.FilePath;
```

#### Validation Checklist
- [ ] Queue name updated to `segment.transcoded.ready`
- [ ] Message model has all transcoded metadata fields
- [ ] File path correctly points to transcoder-output directory
- [ ] Build successful: `dotnet build camera-v2/S3Uploader/`

---

### **Phase 5: RabbitMQ Queue Setup** 🔴 Not Started

**Objective**: Declare new queues for raw and transcoded segments

**Status**: 0/3 tasks complete

#### Tasks

##### 5.1 Declare segment.raw.ready Queue
- [ ] Add queue declaration in TranscoderBridge startup

**File**: [camera-v2/TranscoderBridge/Services/RabbitMQConsumer.cs](camera-v2/TranscoderBridge/Services/RabbitMQConsumer.cs)
**Location**: Connection initialization

```csharp
channel.QueueDeclare(
    queue: "segment.raw.ready",
    durable: true,
    exclusive: false,
    autoDelete: false,
    arguments: null
);
```

##### 5.2 Declare segment.transcoded.ready Queue
- [ ] Add queue declaration in TranscoderBridge startup

```csharp
channel.QueueDeclare(
    queue: "segment.transcoded.ready",
    durable: true,
    exclusive: false,
    autoDelete: false,
    arguments: null
);
```

##### 5.3 Configure Queue Properties
- [ ] Set prefetch count for fair work distribution
- [ ] Enable publisher confirms for reliability

```csharp
channel.BasicQos(prefetchSize: 0, prefetchCount: 5, global: false);
channel.ConfirmSelect(); // Enable publisher confirms
```

#### Validation Checklist
- [ ] Both queues created successfully on RabbitMQ startup
- [ ] Queues are durable (survive broker restart)
- [ ] Prefetch count configured correctly
- [ ] Verify in RabbitMQ Management UI (http://localhost:15672)

---

### **Phase 6: Docker Compose Integration** 🔴 Not Started

**Objective**: Add transcoder and transcoder-bridge services to docker-compose.yml

**Status**: 0/5 tasks complete

#### Tasks

##### 6.1 Add Transcoder Service
- [ ] Add GPU transcoder service definition

**File**: [camera-v2/docker-compose.yml](camera-v2/docker-compose.yml)
**Location**: Add after existing services

```yaml
  transcoder:
    build:
      context: ..
      dockerfile: Dockerfile.transcoder
    container_name: camera-v2-transcoder
    volumes:
      - transcoder_input:/workspace/tsfiles:ro
      - transcoder_output:/workspace/output
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu, video]
    ports:
      - "8080:8080"
    restart: unless-stopped
    networks:
      - default
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

##### 6.2 Add TranscoderBridge Service
- [ ] Add .NET bridge service definition

```yaml
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
      TranscoderBridge__InputPath: "/data/transcoder-input"
      TranscoderBridge__OutputPath: "/data/transcoder-output"
      TranscoderBridge__WebhookPort: "8081"
    volumes:
      - recorder_data:/data:ro
      - transcoder_input:/data/transcoder-input
      - transcoder_output:/data/transcoder-output
    ports:
      - "8085:8081"
    restart: unless-stopped
    networks:
      - default
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8081/health"]
      interval: 30s
      timeout: 10s
      retries: 3
```

##### 6.3 Add Volume Definitions
- [ ] Define named volumes for transcoder storage

```yaml
volumes:
  recording_jobs_public_db_data:
  recorder_scheduler_db_data:
  playlist_manager_db_data:
  rabbitmq_data:
  recorder_data:
  transcoder_input:    # NEW
  transcoder_output:   # NEW
```

##### 6.4 Update Recorder Volume Mount
- [ ] Ensure recorder_data volume is mounted read-only to bridge

**Already handled in service definition above with `:ro` flag**

##### 6.5 Add Network Configuration
- [ ] Ensure all services on same network for DNS resolution

```yaml
networks:
  default:
    name: camera-v2-network
```

#### Validation Checklist
- [ ] docker-compose.yml syntax valid: `docker-compose config`
- [ ] GPU capabilities correctly specified
- [ ] Volume mounts correct (ro for read-only sources)
- [ ] Environment variables properly templated
- [ ] Health checks configured for new services
- [ ] Service dependencies correct (depends_on)

---

### **Phase 7: Create Dockerfile for transcoder.c** 🔴 Not Started

**Objective**: Containerize the C-based GPU transcoder

**Status**: 0/3 tasks complete

#### Tasks

##### 7.1 Create Dockerfile.transcoder
- [ ] Create Dockerfile in project root

**File**: [Dockerfile.transcoder](Dockerfile.transcoder)

```dockerfile
FROM nvidia/cuda:12.8.0-devel-ubuntu24.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libavformat-dev \
    libavcodec-dev \
    libavutil-dev \
    libavfilter-dev \
    libswresample-dev \
    libmicrohttpd-dev \
    libcurl4-openssl-dev \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /app

# Copy source and build
COPY transcoder.c Makefile ./
RUN make clean && make

# Create workspace directories
WORKDIR /workspace
RUN mkdir -p tsfiles output

# Expose HTTP API port
EXPOSE 8080

# Run transcoder daemon
CMD ["/app/transcoder"]
```

##### 7.2 Test Build
- [ ] Build Docker image locally

```bash
docker build -f Dockerfile.transcoder -t camera-v2-transcoder:test .
```

##### 7.3 Test GPU Access
- [ ] Verify GPU accessible in container

```bash
docker run --rm --gpus all camera-v2-transcoder:test nvidia-smi
```

#### Validation Checklist
- [ ] Docker image builds successfully
- [ ] nvidia-smi works inside container
- [ ] transcoder binary exists at /app/transcoder
- [ ] Workspace directories created (/workspace/tsfiles, /workspace/output)
- [ ] HTTP port 8080 exposed

---

### **Phase 8: Storage Directory Initialization** 🔴 Not Started

**Objective**: Create required directories on host system

**Status**: 0/2 tasks complete

#### Tasks

##### 8.1 Create Host Directories
- [ ] Create transcoder input/output directories on host

```bash
sudo mkdir -p /data/transcoder-input
sudo mkdir -p /data/transcoder-output
sudo chown -R 1000:1000 /data/transcoder-input /data/transcoder-output
sudo chmod 755 /data/transcoder-input /data/transcoder-output
```

##### 8.2 Verify Permissions
- [ ] Test write access from Docker user context

```bash
# Test as Docker user (typically UID 1000)
docker run --rm -v /data/transcoder-output:/test alpine touch /test/test.txt
docker run --rm -v /data/transcoder-output:/test alpine rm /test/test.txt
```

#### Validation Checklist
- [ ] Directories exist on host filesystem
- [ ] Correct ownership (1000:1000 or appropriate user)
- [ ] Write permissions verified
- [ ] No permission denied errors

---

### **Phase 9: Configuration Updates** 🔴 Not Started

**Objective**: Update service configurations for transcoding pipeline

**Status**: 0/3 tasks complete

#### Tasks

##### 9.1 Update Recorder Configuration
- [ ] Enable raw capture mode in appsettings.json

**File**: [camera-v2/Recorder/appsettings.json](camera-v2/Recorder/appsettings.json)

```json
{
  "Recorder": {
    "DataPath": "/data",
    "FFmpegPath": "ffmpeg",
    "RecordingDurationSeconds": 3620,
    "SegmentMonitorIntervalMs": 5000,
    "OutboxProcessIntervalMs": 10000,
    "RtspTransport": "tcp",
    "RtspTimeoutSeconds": 10,
    "UseRawCapture": true,
    "RawSegmentQueue": "segment.raw.ready"
  }
}
```

##### 9.2 Verify RabbitMQ Configuration
- [ ] Check RabbitMQ environment variables in docker-compose.yml

```yaml
environment:
  RABBITMQ_DEFAULT_USER: dev
  RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
  RABBITMQ_DEFAULT_VHOST: cloudcam
```

##### 9.3 Update Environment Variables
- [ ] Add RABBITMQ_PASSWORD to .env file if missing

**File**: [camera-v2/.env](camera-v2/.env)

```bash
RABBITMQ_PASSWORD=your_secure_password_here
POSTGRES_PASSWORD=your_postgres_password_here
```

#### Validation Checklist
- [ ] All configuration files have correct paths
- [ ] Environment variables properly set
- [ ] No hardcoded credentials
- [ ] Configuration values match between services

---

### **Phase 10: Testing & Validation** 🔴 Not Started

**Objective**: Comprehensive end-to-end testing of integrated pipeline

**Status**: 0/8 tasks complete

#### Tasks

##### 10.1 Unit Test - TranscoderBridge
- [ ] Test TranscoderApiClient HTTP requests
- [ ] Test WebhookController callback handling
- [ ] Test SymlinkManager symlink creation/deletion
- [ ] Test RabbitMQ consumer message parsing

```bash
cd camera-v2/TranscoderBridge
dotnet test
```

##### 10.2 Integration Test - Recorder to TranscoderBridge
- [ ] Start Recorder and TranscoderBridge services
- [ ] Trigger recording via RecorderScheduler
- [ ] Verify raw segments written to /data/.../raw/
- [ ] Verify RawSegmentReadyMessage published to segment.raw.ready
- [ ] Verify TranscoderBridge consumes message
- [ ] Verify symlinks created in /data/transcoder-input/

##### 10.3 Integration Test - TranscoderBridge to Transcoder
- [ ] Verify HTTP POST to transcoder:8080/enqueue
- [ ] Check transcoder job queue with `curl http://localhost:8080/queue`
- [ ] Monitor transcoder processing logs
- [ ] Verify output files created in /data/transcoder-output/

##### 10.4 Integration Test - Transcoder to TranscoderBridge Callback
- [ ] Verify HTTP POST callback to transcoder-bridge:8081/completed
- [ ] Check TranscoderBridge logs for callback receipt
- [ ] Verify TranscodedSegmentReadyMessage published
- [ ] Verify symlink cleanup if enabled

##### 10.5 Integration Test - TranscoderBridge to S3Uploader
- [ ] Verify S3Uploader consumes from segment.transcoded.ready
- [ ] Verify transcoded segment uploaded to MinIO/S3
- [ ] Check S3 bucket for uploaded files
- [ ] Verify compression ratio metrics logged

##### 10.6 End-to-End Test - Single Camera 10 Minutes
- [ ] Configure 1 test camera with 10-minute recording
- [ ] Monitor full pipeline: Recorder → Bridge → Transcoder → S3
- [ ] Verify all segments processed (no gaps)
- [ ] Check playback quality via Player
- [ ] Measure end-to-end latency (capture → S3)

##### 10.7 Load Test - 2-5 Cameras 1-2 Hours
- [ ] Configure 2-5 test cameras
- [ ] Run recording for 1-2 hours
- [ ] Monitor GPU utilization: `nvidia-smi dmon`
- [ ] Monitor queue depths in RabbitMQ Management UI
- [ ] Check for any failed messages or dead letters
- [ ] Verify storage reduction (~71%)
- [ ] Verify no segment loss (100% completion)

##### 10.8 Quality Validation
- [ ] Compare original vs transcoded segment quality
- [ ] Verify resolution: 1280x720
- [ ] Verify codec: H.264 Main profile
- [ ] Verify frame rate maintained (25fps)
- [ ] Verify audio preserved (if present)
- [ ] Manual playback test via Player frontend

#### Validation Checklist
- [ ] All unit tests pass
- [ ] Integration tests successful
- [ ] End-to-end test completes without errors
- [ ] Load test shows stable performance
- [ ] Quality meets acceptance criteria
- [ ] GPU utilization 40-60% (efficient)
- [ ] No memory leaks observed
- [ ] No disk space exhaustion

---

### **Phase 11: Documentation & Cleanup** 🔴 Not Started

**Objective**: Update documentation and finalize implementation

**Status**: 0/4 tasks complete

#### Tasks

##### 11.1 Update SYSTEM_ARCHITECTURE.md
- [ ] Add TranscoderBridge service documentation
- [ ] Update message flow diagrams
- [ ] Document new queues and messages
- [ ] Update deployment architecture section

**File**: [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md)

##### 11.2 Update Service Analysis Documents
- [ ] Create TranscoderBridge/SERVICE_ANALYSIS.md
- [ ] Update Recorder/SERVICE_ANALYSIS.md with raw capture mode
- [ ] Update S3Uploader/SERVICE_ANALYSIS.md with transcoded queue

##### 11.3 Update TRANSCODER_INTEGRATION.md
- [ ] Mark implementation status as COMPLETE
- [ ] Add deployment notes
- [ ] Document configuration parameters
- [ ] Add troubleshooting section

**File**: [TRANSCODER_INTEGRATION.md](TRANSCODER_INTEGRATION.md)

##### 11.4 Create Operations Runbook
- [ ] Document startup procedures
- [ ] Document monitoring commands
- [ ] Document rollback procedures
- [ ] Document common issues and solutions

**File**: [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md) (new file)

#### Validation Checklist
- [ ] All documentation updated
- [ ] Architecture diagrams reflect new services
- [ ] Runbook tested by following steps
- [ ] Code comments added for complex logic

---

## 🚨 Rollback Procedures

### Emergency Rollback (If Integration Fails)

**Quick Rollback Steps**:
1. Stop new services:
   ```bash
   docker-compose stop transcoder transcoder-bridge
   ```

2. Revert Recorder to CPU encoding:
   - File: `camera-v2/Recorder/Services/FFmpegManager.cs`
   - Change: `-c:v copy` → `-c:v libx264 -crf 34 -preset medium`
   - Rebuild: `docker-compose build recorder`

3. Revert Recorder message queue:
   - File: `camera-v2/Recorder/Services/RecordingService.cs`
   - Change: `segment.raw.ready` → `segment.ready`
   - Rebuild: `docker-compose build recorder`

4. Revert S3Uploader queue binding:
   - File: `camera-v2/S3Uploader/Services/RabbitMQConsumer.cs`
   - Change: `segment.transcoded.ready` → `segment.ready`
   - Rebuild: `docker-compose build s3-uploader`

5. Restart affected services:
   ```bash
   docker-compose up -d recorder s3-uploader
   ```

**System returns to original CPU-based encoding pipeline.**

---

## 📝 Session Notes

### Session 1: 2025-10-23 12:07 UTC
- **Work Done**:
  - System analysis completed
  - Implementation plan created
  - IMPLEMENTATION_PLAN.md document created
- **Next Steps**: Begin Phase 1 - TranscoderBridge service creation
- **Blockers**: None
- **Notes**: All prerequisites understood, ready to start implementation

---

## 🔗 Quick Reference Links

### Documentation
- [SYSTEM_ARCHITECTURE.md](SYSTEM_ARCHITECTURE.md) - Overall system architecture
- [TRANSCODER_INTEGRATION.md](TRANSCODER_INTEGRATION.md) - Integration design document
- [Transcoder.md](Transcoder.md) - GPU transcoder technical details
- [transcoder.c](transcoder.c) - Transcoder C implementation

### Service Directories
- [camera-v2/Recorder](camera-v2/Recorder/) - Recording service
- [camera-v2/RecorderScheduler](camera-v2/RecorderScheduler/) - Job scheduler
- [camera-v2/S3Uploader](camera-v2/S3Uploader/) - S3 upload service
- [camera-v2/PlaylistManager](camera-v2/PlaylistManager/) - Playlist manager
- [camera-v2/Player](camera-v2/Player/) - Player frontend/API

### Configuration Files
- [camera-v2/docker-compose.yml](camera-v2/docker-compose.yml) - Service orchestration
- [camera-v2/Recorder/appsettings.json](camera-v2/Recorder/appsettings.json) - Recorder config
- [camera-v2/S3Uploader/appsettings.json](camera-v2/S3Uploader/appsettings.json) - S3 config

### Key Commands
```bash
# Build all services
docker-compose build

# Start specific service
docker-compose up -d transcoder-bridge

# View logs
docker-compose logs -f transcoder-bridge

# Check GPU utilization
nvidia-smi dmon -s pucvmet

# RabbitMQ Management
http://localhost:15672 (dev/password)

# Check queue depths
docker exec camera-v2-rabbitmq rabbitmqctl list_queues
```

---

## 📊 Progress Tracking

**Overall Progress**: 0% (0/11 phases complete)

**Phase Status**:
- ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/11 phases

**Estimated Completion**: 13-19 hours total effort

**Target Deployment Date**: TBD

---

## ✅ Success Criteria Checklist

- [ ] 2-5 cameras recording simultaneously for 1-2 hours
- [ ] All segments transcoded and uploaded to S3
- [ ] Playback quality matches specification (720p H.264 Main)
- [ ] GPU utilization 40-60% (efficient use)
- [ ] No segment loss (100% completion rate)
- [ ] Storage reduction ~70% achieved
- [ ] End-to-end latency <60 seconds (segment→S3)
- [ ] System stable with no memory leaks
- [ ] Rollback procedures tested and documented

---

**Last Updated**: 2025-10-23 12:07 UTC
**Document Version**: 1.0
**Maintained By**: Claude Code AI Assistant
