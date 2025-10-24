# CloudCam 24/7 - Codebase Exploration & Analysis Report

**Project**: GPU Transcoder Integration for CloudCam 24/7  
**Analysis Date**: 2025-10-23  
**Status**: COMPLETE - Ready for TranscoderBridge Implementation  
**Scope**: camera-v2 directory (Recorder, S3Uploader, PlaylistManager, Player)

---

## Documentation Files Created

This analysis has generated comprehensive documentation to guide TranscoderBridge implementation:

### 1. **CODEBASE_ANALYSIS.md** (27 KB) - PRIMARY REFERENCE
Complete technical analysis of the codebase including:
- Overall directory structure and service overview
- Existing services (Recorder, S3Uploader, PlaylistManager, Player)
- RabbitMQ message patterns and topology
- Docker-compose configuration details
- FFmpegManager detailed analysis (703-line core component)
- Consumer/Publisher implementation patterns
- Configuration management
- Architectural patterns used
- Critical technical details for TranscoderBridge integration

**Best for**: Understanding existing code patterns and architecture

### 2. **ARCHITECTURE_VISUAL.md** (48 KB) - VISUAL REFERENCE
ASCII diagrams and flowcharts showing:
- System-wide data flow (4 phases: Recording, Upload, Manifest, Playback)
- RabbitMQ message topology (queues, exchanges, bindings)
- Recorder FFmpeg integration and process flow
- S3Uploader dual consumer architecture
- Docker Compose service dependency graph
- File system layout during recording
- Message lifecycle timeline

**Best for**: Understanding data flow and system interactions

### 3. **IMPLEMENTATION_PLAN.md** (16 KB) - PHASE STRATEGY
Two-phase implementation plan with:
- Phase 1: Test server without GPU (current)
- Phase 2: GPU server with NVIDIA RTX
- Step-by-step implementation checklist
- Message modifications needed
- Docker Compose configuration additions
- Transcoder.c modifications for --no-gpu flag
- Testing validation checklist
- Rollback plan

**Best for**: Implementation planning and tracking progress

---

## Existing Documentation

These files provide additional context:

- **SYSTEM_ARCHITECTURE.md** - High-level system design and deployment
- **TRANSCODER_INTEGRATION.md** - Technical transcoder integration details
- **Transcoder.md** - Transcoder source code and API documentation
- **ARCHITECTURE_DIAGRAMS.md** - Additional system diagrams

---

## Quick Navigation by Topic

### Understanding the Overall System
1. Start with: **ARCHITECTURE_VISUAL.md** (System-wide Data Flow section)
2. Then read: **CODEBASE_ANALYSIS.md** (Sections 1-2: Structure & Services)
3. Reference: **SYSTEM_ARCHITECTURE.md** (High-level overview)

### Understanding RabbitMQ Message Patterns
1. Start with: **ARCHITECTURE_VISUAL.md** (RabbitMQ Message Topology section)
2. Then read: **CODEBASE_ANALYSIS.md** (Section 3: RabbitMQ Patterns)
3. Code reference: `/home/nbadmin/camera-project/camera-v2/Recorder/Models/Messages.cs`

### Understanding FFmpeg & Segment Handling
1. Start with: **ARCHITECTURE_VISUAL.md** (Recorder FFmpeg Integration section)
2. Then read: **CODEBASE_ANALYSIS.md** (Section 5: FFmpegManager Details)
3. Code deep-dive: `/home/nbadmin/camera-project/camera-v2/Recorder/Services/FFmpegManager.cs`

### Understanding S3 Upload Architecture
1. Start with: **ARCHITECTURE_VISUAL.md** (S3Uploader Dual Consumer Architecture section)
2. Then read: **CODEBASE_ANALYSIS.md** (Section 6: Consumer Patterns)
3. Code reference: `/home/nbadmin/camera-project/camera-v2/S3Uploader/Services/RabbitMQConsumer.cs`

### Understanding Docker Orchestration
1. Start with: **ARCHITECTURE_VISUAL.md** (Docker Compose Service Dependencies section)
2. Then read: **CODEBASE_ANALYSIS.md** (Section 4: Docker Configuration)
3. File reference: `/home/nbadmin/camera-project/camera-v2/docker-compose.yml`

### Planning TranscoderBridge Implementation
1. Start with: **IMPLEMENTATION_PLAN.md** (Phase 1 overview)
2. Then read: **CODEBASE_ANALYSIS.md** (Section 11: Critical Technical Details)
3. Reference: **ARCHITECTURE_VISUAL.md** (Message Lifecycle Timeline)
4. Review patterns: FFmpegManager, S3Uploader RabbitMQ consumer

---

## Key Findings Summary

### Service Architecture
- **Recorder**: FFmpeg process management with outbox pattern message publishing
- **S3Uploader**: Dual-consumer RabbitMQ architecture for concurrent uploads
- **PlaylistManager**: HLS manifest database with signed URL generation
- **Player**: API and React frontend for video playback

### Message Flow Pattern
```
RecorderScheduler 
  → (recording.requests) 
  → Recorder 
  → (segment.ready) 
  → S3Uploader 
  → (playlist.events) 
  → PlaylistManager
```

### Deployment Architecture
- 10 services in docker-compose.yml
- PostgreSQL for shared/persistent data
- SQLite for Recorder local state
- RabbitMQ for async communication
- Durable queues and message persistence

### Critical Patterns for TranscoderBridge
1. **Outbox Pattern**: Transactional message persistence for reliability
2. **Dual Consumers**: Handle both per-segment and batch operations
3. **Event-Driven**: Loose coupling via message queues
4. **HTTP Callbacks**: Transcoder calls back to bridge when complete
5. **Volume Mounts**: Direct file access between services

---

## Critical Technical Details for Implementation

### File Path Strategy
- Input: `/data/{jobId}/{recordingId}/raw/*.ts` (from Recorder)
- Transcoder reads: `/data` (read-only)
- Transcoder writes: `/workspace/output` (new volume)
- S3Uploader reads: Both locations

### Queue Names (New)
- `segment.raw.ready` - Raw segment ready for transcoding
- `segment.transcoded.ready` - Transcoded segment ready for upload

### Message Types (New)
- `RawSegmentReadyMessage` - From Recorder (via OutboxService)
- `TranscodedSegmentReadyMessage` - From TranscoderBridge

### HTTP API Pattern
- Transcoder: `POST /enqueue` with job details
- Callback: `POST /completed` webhook from transcoder
- Metadata: Pass through message for traceability

---

## Implementation Checklist

### Phase 1: Test Server (No GPU)
- [ ] Create TranscoderBridge service directory structure
- [ ] Implement RabbitMQ consumer for `segment.raw.ready`
- [ ] Implement HTTP client for transcoder API
- [ ] Implement webhook receiver for callbacks
- [ ] Implement RabbitMQ publisher for `segment.transcoded.ready`
- [ ] Add `--no-gpu` flag to transcoder.c
- [ ] Modify Recorder to use output `/raw/` subdirectory
- [ ] Modify S3Uploader to consume from new queues
- [ ] Update docker-compose.yml with TranscoderBridge service
- [ ] Test end-to-end message flow
- [ ] Validate Phase 1 deployment on test server

### Phase 2: GPU Server (Later)
- [ ] Copy working code to GPU server
- [ ] Remove `--no-gpu` flag (enable GPU transcoding)
- [ ] Update S3Uploader bucket to production MinIO
- [ ] Validate GPU transcoding quality/performance
- [ ] Performance tuning and optimization

---

## Code Examples by Pattern

### Outbox Pattern (Publishing)
See: `/home/nbadmin/camera-project/camera-v2/Recorder/Services/OutboxService.cs`
- Transactional message persistence
- Background processor polling
- Retry logic with backoff

### Dual Consumer Pattern (Consuming)
See: `/home/nbadmin/camera-project/camera-v2/S3Uploader/Services/RabbitMQConsumer.cs`
- Consumer 1: Per-item processing
- Consumer 2: Batch processing
- Prefetch management for concurrency

### Event-Driven Pattern (FFmpeg)
See: `/home/nbadmin/camera-project/camera-v2/Recorder/Services/FFmpegManager.cs`
- Fire-and-forget event pattern
- Output parsing and detection
- Stall detection and recovery

### Configuration Management
See: `/home/nbadmin/camera-project/camera-v2/Recorder/Configuration/`
- Options pattern for configuration
- Environment variable overrides
- Per-service configuration

---

## Absolute File References

### Essential Source Files
1. `/home/nbadmin/camera-project/camera-v2/Recorder/Services/FFmpegManager.cs`
2. `/home/nbadmin/camera-project/camera-v2/Recorder/Services/OutboxService.cs`
3. `/home/nbadmin/camera-project/camera-v2/S3Uploader/Services/RabbitMQConsumer.cs`
4. `/home/nbadmin/camera-project/camera-v2/Recorder/Models/Messages.cs`
5. `/home/nbadmin/camera-project/camera-v2/docker-compose.yml`

### Configuration Reference
6. `/home/nbadmin/camera-project/camera-v2/Recorder/appsettings.json`
7. `/home/nbadmin/camera-project/camera-v2/S3Uploader/appsettings.json`
8. `/home/nbadmin/camera-project/camera-v2/Recorder/Configuration/RecorderConfiguration.cs`

### Service Entry Points
9. `/home/nbadmin/camera-project/camera-v2/Recorder/Program.cs`
10. `/home/nbadmin/camera-project/camera-v2/S3Uploader/Program.cs`

---

## Quick Facts

**Technology Stack**:
- .NET 9 for all backend services
- RabbitMQ 3.13 for messaging
- PostgreSQL 16 for persistent data
- SQLite for Recorder local state
- MinIO for S3-compatible storage
- React 18 for frontend

**Key Metrics**:
- Recording duration: 1 hour per session
- Segment duration: 10 seconds each
- Segments per recording: ~360 files
- File size per recording: 1.5-2.5 GB (at CRF 34)
- Concurrent uploads: ~5 parallel

**Queue Topology**:
- 6 direct queues
- 2 fanout exchanges
- 1 fanout-bound queue

**Docker Ports**:
- APIs: 8081-8083
- Frontend: 3001
- RabbitMQ AMQP: 5672
- RabbitMQ UI: 15672
- PostgreSQL: 5433-5435

---

## Getting Started

1. **Read this file first** - Gets you oriented
2. **Study ARCHITECTURE_VISUAL.md** - Understand data flow visually
3. **Deep dive CODEBASE_ANALYSIS.md** - Learn all the details
4. **Review IMPLEMENTATION_PLAN.md** - Understand Phase 1 & 2
5. **Examine source code** - Follow patterns in existing services
6. **Start implementing** - Follow the implementation checklist

---

## Support Files

All documentation files are located in:
- `/home/nbadmin/camera-project/`

All source code is located in:
- `/home/nbadmin/camera-project/camera-v2/`

For environment setup and build information:
- See `.env` file (if exists)
- See individual service Dockerfile files

---

**Document Created**: 2025-10-23  
**Analysis Tool**: Claude Code - Codebase Explorer  
**Status**: Ready for Implementation  
**Contact**: Refer to project README for team contact

---

*This analysis provides everything needed to implement TranscoderBridge while following existing architectural patterns and best practices in the CloudCam 24/7 system.*
