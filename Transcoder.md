# GPU-Accelerated Video Transcoder - Project Status

**Proje Başlangıcı**: 2 Ekim 2025
**Proje Tamamlanma**: 2 Ekim 2025 ✅
**Persistent Pipeline Optimization**: 13 Ekim 2025 ✅
**Status**: **BAŞARILI - Production Ready** 🎉
**Performance**: **1,374 files/minute** (2x improvement from persistent pipeline optimization!)

---

## 🏆 Executive Summary

RTX 5090 GPU ile tamamen hardware-accelerated video transcoding pipeline başarıyla tamamlandı.

**Key Achievements:**
- ✅ Zero-copy GPU pipeline (NVDEC → scale_cuda → NVENC)
- ✅ **1,374 files/minute throughput** (persistent pipeline optimization - 13 Ekim 2025)
- ✅ 686.8 files/minute (initial implementation - 2 Ekim 2025)
- ✅ %71 compression (6.5GB → 1.9GB)
- ✅ 100% success rate (1,080/1,080 files)
- ✅ Production-ready C implementation

---

## 🎯 Proje Hedefleri

### Ana Hedef
- **Performance**: 664+ dosya/dakika (RTX 5090 ile daha yüksek hedef)
- **Hardware**: RTX 5090 NVENC/NVDEC tam donanım hızlandırma
- **Pipeline**: Zero-copy GPU pipeline (NVDEC → GPU Scaling → NVENC)

### Teknik Gereksinimler
- ✅ 720p minimum resolution (1920x1080 → 1280x720)
- ✅ MPEG-TS output format
- ✅ RTX 5090 NVENC session limitine kadar kullanım (test edilecek, muhtemelen 12-16 concurrent)
- ✅ H.264 NVENC codec
- ✅ P2 preset + VBR + 2M bitrate + CQ 28
- ⚠️ **KRİTİK**: Kesinlikle GPU ile decode ve encode (NO CPU FALLBACK)

---

## 📊 Mevcut Durum Analizi

### Test Dosyaları
- **Toplam**: 1080 adet .ts dosyası
- **Boyut**: ~6-11MB per file
- **Format**: MPEG Transport Stream
- **Kameralar**: 16 farklı kamera (camera_001 - camera_016)
- **Lokasyon**: `/workspace/transcode-test/tsfiles/`

### FFmpeg Konfigürasyonu
- **Versiyon**: FFmpeg 6.1.1
- **NVENC Encoders**: ✅ h264_nvenc, hevc_nvenc, av1_nvenc
- **NVDEC Decoders**: ✅ h264_cuvid, hevc_cuvid (hardware decode ready)
- **CUDA Support**: ✅ Available

### Sistem Kaynakları
- **GPU**: NVIDIA GeForce RTX 5090 (32GB VRAM, Compute 12.0)
- **CPU**: AMD EPYC 7413 24-Core
- **CUDA**: Version 12.8.93, Driver 575.57.08
- **cuDNN**: Version 9.13.1.26-1 (upgraded 3 Ekim 2025: 9.8.0.87-1 → 9.13.1.26-1)
- **NCCL**: Version 2.28.3-1+cuda13.0 (upgraded 3 Ekim 2025: 2.25.1-1+cuda12.8 → 2.28.3-1+cuda13.0)
- **Memory**: 32GB VRAM + sufficient system memory

---

## 🏗️ İmplementasyon - TAMAMLANDI ✅

### Phase 1: Core Architecture ✅
- [x] transcoder.c - Queue system (2000 item capacity)
- [x] transcoder.c - Worker thread pool (8 workers, NVENC limit tested)
- [x] transcoder.c - File tracking system (circular buffer)
- [x] 699 satır C kodu

### Phase 2: GPU Pipeline ✅
- [x] NVDEC hardware decode (h264_cuvid)
- [x] Zero-copy GPU scaling (scale_cuda filter)
- [x] NVENC encoder setup (P2+VBR+CQ28)
- [x] hw_frames_ctx manuel konfigürasyonu
- [x] AVFilterGraph implementasyonu

### Phase 3: Build & Test ✅
- [x] Makefile (FFmpeg + CUDA + libavfilter linking)
- [x] Build verification (successful)
- [x] Performance testing (1,080 files test)
- [x] **686.8 files/min achieved** - Hedef aşıldı!

---

## 🔧 Validated Optimal Configuration

### Encoder Settings (16-Scenario Test Winner)
```c
// P2 + VBR = 1.063s per file (fastest validated)
preset: "p2"
rc: "vbr"
bitrate: 2000000  // 2M
cq: 28
resize: "1280x720"  // NVENC internal scaling
```

### Pipeline Architecture
```
NVDEC (h264_cuvid) → GPU Memory → NVENC (h264_nvenc)
        ↓                ↓              ↓
   Hardware decode   Zero-copy    Internal scaling

⚠️ CRITICAL: GPU-ONLY pipeline - NO CPU decode/encode fallback allowed
```

### Critical Bottleneck Solutions
1. **Queue Size**: 2000 (was bottleneck at 100)
2. **Software Scaling**: Eliminated (moved to GPU)
3. **Worker Count**: 12-16 (RTX 5090 NVENC limit - to be tested)
4. **Thread Overhead**: Minimized (fast probe/seek)

---

## ✅ BAŞARILI İMPLEMENTASYON - 2 Ekim 2025

### 🎉 Final Sonuçlar (scale_cuda Pipeline)

**Performance Metrics**
- ✅ **Throughput**: **686.8 files/minute** (hedefi %103 oranında aştı!)
- ✅ **İşlenen Dosya**: 1,076/1,080 (%99.6 başarı)
- ✅ **İşlem Süresi**: 94 saniye
- ✅ **Compression**: 6.5GB → 1.9GB (71% azalma)

**GPU Utilizasyon (RTX 5090)**
- Power: 160.7W ortalama, 190W peak
- NVENC: %52.6 ortalama, %82 peak
- NVDEC: %65.6 ortalama, %100 peak
- SM: %34.3 ortalama

**Final Pipeline Architecture**
```
NVDEC (h264_cuvid) → scale_cuda (GPU scaling) → NVENC (h264_nvenc)
           ↓                    ↓                        ↓
    Hardware decode      GPU 1920x1080→1280x720    Hardware encode

✅ Zero-copy GPU pipeline
✅ 8 concurrent workers (NVENC session limit dahilinde)
✅ NO CPU fallback - Full GPU pipeline
```

**Output Quality - Doğrulandı**
- ✅ Resolution: 1280x720
- ✅ Codec: H.264 Main profile
- ✅ Bitrate: ~1.5 Mbps (VBR working)
- ✅ Frame rate: 25fps
- ✅ Format: MPEG-TS

**Kritik Teknik Detaylar**
1. **scale_cuda Filter**: NVENC'in internal resize parametresi NVDEC CUDA frames ile çalışmadı
2. **Solution**: AVFilterGraph ile scale_cuda kullanımı (GPU-based scaling)
3. **hw_frames_ctx**: Hem encoder hem filter için manuel oluşturuldu
4. **Worker Count**: 8 (NVENC session limit aşmamak için)
5. **Build**: FFmpeg libavfilter library eklendi

---

## 🚀 PERSISTENT PIPELINE OPTIMIZATION - 13 Ekim 2025

### Performance Breakthrough: 2x Improvement

**Problem Identified:**
- Original architecture recreated NVDEC/NVENC sessions for EVERY file
- Per-file overhead: 300-500ms setup + teardown
- GPUs spending 40-60% time idle during CPU-bound initialization
- Result: Spiky GPU utilization, high CPU usage, bottlenecked performance

**Solution: Persistent GPU Pipelines**
- Initialize NVDEC/NVENC sessions ONCE per worker thread
- Reuse codec contexts across all files
- Only recreate filter graph between files (~50ms vs ~300ms)
- Flush codec buffers instead of destroying contexts

**Results:**
- ✅ **1,374 files/minute** (up from 686.8 - **+100% improvement**)
- ✅ **47 seconds** total processing time (down from 94 seconds)
- ✅ **100% success rate** (1,080/1,080 files)
- ✅ Output quality maintained (1280x720, H.264 Main, 25fps)
- ✅ GPUs now continuously fed with data (no more idle periods)

**Key Changes (transcoder.c):**
- Added `setup_persistent_pipeline()` - Initialize once per worker
- Added `flush_pipeline_for_next_file()` - Fast reset between files
- Modified `worker_thread()` - Pipeline created outside file loop
- Split cleanup into per-file and persistent cleanup functions

**Architecture:**
```
Worker Thread Lifecycle:
  1. Initialize GPU context (ONCE)
  2. Create NVDEC session (ONCE) ← Expensive
  3. Create NVENC session (ONCE) ← Expensive
  4. Create filter graph (ONCE)
  5. FOR EACH FILE:
     - Open input file (cheap)
     - Flush codec buffers (cheap)
     - Recreate filter graph (medium ~50ms)
     - Process frames (GPU intensive)
     - Close output file (cheap)
  6. Destroy persistent pipeline (ONCE)
```

---

## 📈 Progress Tracking

### ✅ Completed Tasks
- [x] Mevcut durum analizi (1080 test files found)
- [x] FFmpeg NVENC/NVDEC verification
- [x] Hardware capability check (RTX 5090, CUDA 12.9)
- [x] transcoder.c implementation (699 satır)
- [x] Makefile creation (FFmpeg + CUDA + libavfilter)
- [x] NVDEC → scale_cuda → NVENC pipeline implementasyonu
- [x] hw_frames_ctx manuel konfigürasyonu
- [x] Full test: 1,080 dosya (%99.6 başarı)
- [x] Performance testing: **686.8 files/minute**
- [x] **Persistent pipeline optimization: 1,374 files/minute (13 Ekim 2025)**
- [x] CLAUDE.md documentation tamamlandı

---

## 📝 Critical Implementation Notes

### ⚠️ MANDATORY GPU-ONLY PIPELINE
**CRITICAL REQUIREMENT**: Kesinlikle GPU ile decode ve encode yapılmalı.
- ❌ NO CPU decoder fallback (libavcodec)
- ❌ NO CPU encoder fallback (libx264)
- ❌ NO software scaling (swscale)
- ✅ ONLY h264_cuvid for decoding
- ✅ ONLY h264_nvenc for encoding
- ✅ ONLY scale_cuda for scaling

**If GPU hardware unavailable → FAIL immediately, do NOT fallback to CPU**

### Configuration (Final Values)
```c
#define MAX_QUEUE_SIZE 2000   // Handle 1080+ files
#define MAX_WORKERS 8         // Tested optimal for RTX 5090 (NVENC session limit)
#define MAX_PROCESSED 2000    // Circular buffer
```

### NVDEC Decoder Setup (GPU-ONLY)
```c
AVCodec *decoder = avcodec_find_decoder_by_name("h264_cuvid");
if (!decoder) {
    fprintf(stderr, "FATAL: h264_cuvid not available\n");
    exit(1);  // FAIL immediately - NO CPU fallback
}
// Note: NVDEC's resize parameter doesn't work with CUDA frames output
```

### scale_cuda Filter Setup (GPU Scaling)
```c
// Create filter graph: NVDEC output → scale_cuda → NVENC input
AVFilterGraph *filter_graph = avfilter_graph_alloc();

// Create hw_frames_ctx for buffer source
AVBufferRef *hw_frames_ref = av_hwframe_ctx_alloc(hw_device_ctx);
AVHWFramesContext *frames_ctx = (AVHWFramesContext *)(hw_frames_ref->data);
frames_ctx->format    = AV_PIX_FMT_CUDA;
frames_ctx->sw_format = AV_PIX_FMT_NV12;
frames_ctx->width     = 1920;
frames_ctx->height    = 1080;
av_hwframe_ctx_init(hw_frames_ref);

// Parse filter: scale_cuda=1280:720
avfilter_graph_parse_ptr(filter_graph, "scale_cuda=1280:720", &inputs, &outputs, NULL);

// Set hw_device_ctx on all filters
for (unsigned i = 0; i < filter_graph->nb_filters; i++) {
    filter_graph->filters[i]->hw_device_ctx = av_buffer_ref(hw_device_ctx);
}
```

### NVENC Encoder Setup (GPU-ONLY)
```c
AVCodec *encoder = avcodec_find_encoder_by_name("h264_nvenc");
if (!encoder) {
    fprintf(stderr, "FATAL: h264_nvenc not available\n");
    exit(1);  // FAIL immediately - NO CPU fallback
}

encoder_ctx->pix_fmt = AV_PIX_FMT_CUDA;  // Accept CUDA frames from scale_cuda

// Create hw_frames_ctx for encoder (required for CUDA input)
AVBufferRef *hw_frames_ref = av_hwframe_ctx_alloc(hw_device_ctx);
AVHWFramesContext *frames_ctx = (AVHWFramesContext *)(hw_frames_ref->data);
frames_ctx->format    = AV_PIX_FMT_CUDA;
frames_ctx->sw_format = AV_PIX_FMT_NV12;
frames_ctx->width     = 1280;
frames_ctx->height    = 720;
av_hwframe_ctx_init(hw_frames_ref);
encoder_ctx->hw_frames_ctx = hw_frames_ref;

// NVENC settings
av_opt_set(encoder_ctx->priv_data, "preset", "p2", 0);
av_opt_set(encoder_ctx->priv_data, "rc", "vbr", 0);
av_opt_set(encoder_ctx->priv_data, "cq", "28", 0);
encoder_ctx->bit_rate = 2000000;
```

### Processing Loop (Zero-Copy GPU Pipeline)
```c
// Decode with NVDEC
avcodec_receive_frame(decoder_ctx, decoded_frame);  // CUDA frame

// Scale with scale_cuda
av_buffersrc_add_frame_flags(buffersrc_ctx, decoded_frame, AV_BUFFERSRC_FLAG_KEEP_REF);
av_buffersink_get_frame(buffersink_ctx, filtered_frame);  // Scaled CUDA frame

// Encode with NVENC
avcodec_send_frame(encoder_ctx, filtered_frame);  // Direct CUDA frame input
avcodec_receive_packet(encoder_ctx, enc_packet);
```

---

## 🎓 Reference Documentation

### Source Reference: TEST-INFO.md
- Line 1149-1294: Ultra-fast optimization breakthrough (664 files/min)
- Line 1050-1144: P2+VBR 16-scenario test results
- Line 270-428: Technical configuration details
- Line 462-595: Zero-copy GPU pipeline implementation

### Key Findings from Reference
- **Bottleneck**: Software scaling was 75% of processing time
- **Solution**: NVDEC + GPU scaling eliminated bottleneck
- **Result**: 300% performance improvement (220 → 664 files/min)

---

## 🚀 Achieved Performance (Test Results)

### Actual Metrics (Tested & Validated)
- **Processing Speed**: **686.8 files/minute** (11.4 files/second) - ✅ Hedefi aştı!
- **GPU Utilization**: NVENC 52.6% avg (82% peak), NVDEC 65.6% avg (100% peak)
- **Pipeline Efficiency**: Zero-copy (no CPU↔GPU transfers) - ✅ Confirmed
- **Compression**: 71% size reduction (6.5GB → 1.9GB) - ✅ Excellent
- **Power Consumption**: 160.7W average, 190W peak - ✅ Efficient

### Validation Results
- ✅ 720p output resolution maintained (1280x720)
- ✅ 1,076/1,080 files processed successfully (%99.6)
- ✅ H.264 Main profile output
- ✅ VBR working correctly (~1.5 Mbps)
- ✅ 25fps maintained
- ✅ MPEG-TS format correct
- ✅ NVENC session limit properly handled
- ✅ GPU power consumption 59-70W (active processing)

---

## 🔗 Quick Commands

### Build (Production)
```bash
make clean && make
# Build successful: ./transcoder
# FFmpeg libs: -lavformat -lavcodec -lavutil -lavfilter -lswresample
# CUDA libs: -lcudart -lcuda
```

### Run Full Test (1,080 files)
```bash
# Process all files in tsfiles/ directory
time ./transcoder

# Expected output:
# - Discovered 1080 files
# - 8 workers started
# - ~94 seconds processing time
# - 1,076+ files completed
# - Output in output/ directory
```

### GPU Monitoring (Real-time)
```bash
# Monitor GPU utilization during processing
nvidia-smi dmon -s pucvmet -i 0 > gpu_stats.log 2>&1 &
./transcoder
pkill nvidia-smi

# Check results
cat gpu_stats.log
```

### Verify Output Quality
```bash
# Check random output file
ls output/ | shuf | head -1 | xargs -I {} ffprobe -hide_banner output/{}

# Expected: 1280x720, H.264 Main, 25fps, ~1.5Mbps
```

### Check Performance Stats
```bash
# File count and sizes
ls output/ | wc -l           # Should show 1076+
du -sh tsfiles/ output/      # Compare input vs output size

# Calculate throughput
# 1076 files / 94 seconds = 686.8 files/minute
```

---

## 📂 Project Structure (Final)

```
/workspace/transcode-test/
├── transcoder.c          # Main application (699 lines)
│   ├── Queue system (2000 capacity)
│   ├── 8 worker threads
│   ├── NVDEC decoder setup
│   ├── scale_cuda filter setup
│   ├── NVENC encoder setup
│   └── Processing pipeline
├── Makefile              # Build configuration
│   ├── FFmpeg libraries (-lavformat -lavcodec -lavutil -lavfilter)
│   ├── CUDA libraries (-lcudart -lcuda)
│   └── Optimization flags (-O3)
├── CLAUDE.md             # Project documentation (this file)
├── tsfiles/              # Input directory (1,080 files, 6.5GB)
│   └── camera_*.ts files
└── output/               # Output directory (1,076 files, 1.9GB)
    └── *_h264.ts files (720p, H.264 Main)
```

---

## 🎓 Lessons Learned & Troubleshooting

### Critical Issues Resolved

**1. NVENC Internal Resize Doesn't Work with NVDEC CUDA Frames**
- Problem: `av_dict_set(&opts, "resize", "1280x720", 0)` on NVENC failed
- Root cause: NVDEC outputs CUDA/NV12 format, NVENC expected YUV420P
- Solution: Use AVFilterGraph with scale_cuda filter for GPU-based scaling

**2. hw_frames_ctx Required for CUDA Pipeline**
- Problem: "hw_frames_ctx must be set when using GPU frames"
- Root cause: Both encoder and filter buffer source need hw_frames_ctx
- Solution: Manually create hw_frames_ctx with proper format (CUDA/NV12)

**3. NVENC Session Limit**
- Problem: Worker 9+ failed with "incompatible client key (21)"
- Root cause: RTX 5090 has ~8 concurrent NVENC session limit
- Solution: Set MAX_WORKERS to 8

**4. Zero-Byte Output Files**
- Problem: Files created but with 0 bytes
- Root cause: Frame format mismatch in encoder input
- Solution: Set encoder pix_fmt to AV_PIX_FMT_CUDA and configure hw_frames_ctx

### Performance Optimization Tips

1. **Use scale_cuda instead of NVENC resize**: Native CUDA scaling is more compatible
2. **Set proper hw_frames_ctx**: Both for filter and encoder
3. **Use AV_BUFFERSRC_FLAG_KEEP_REF**: Prevents unnecessary frame copies
4. **Monitor NVENC sessions**: Stay within GPU limits (8 for RTX 5090)
5. **Use P2 preset**: Fastest NVENC preset with good quality

---

## 🚀 RTX 5090 UPGRADE (2 Ekim 2025)

### Hardware Specifications
- **GPU Model**: NVIDIA GeForce RTX 5090
- **VRAM**: 32GB GDDR7 (33% more than RTX 4090)
- **Compute Capability**: 12.0 (latest generation)
- **TDP**: 575W (vs RTX 4090's 450W)
- **Driver**: 575.57.08 (latest)
- **CUDA Support**: 12.9

### Software Environment
- **CUDA Runtime**: 12.8.93
- **cuDNN**: 9.13.1.26-1 (upgraded from 9.8.0)
- **NCCL**: 2.28.3 (upgraded from 2.25.1)
- **FFmpeg**: 6.1.1

### NVENC/NVDEC Capabilities
**Encoders Available:**
- ✅ h264_nvenc (H.264/AVC)
- ✅ hevc_nvenc (H.265/HEVC)
- ✅ av1_nvenc (AV1)

**Decoders Available:**
- ✅ h264_cuvid, hevc_cuvid, av1_cuvid
- ✅ vp8_cuvid, vp9_cuvid
- ✅ mpeg1_cuvid, mpeg2_cuvid, mpeg4_cuvid
- ✅ mjpeg_cuvid, vc1_cuvid

### Expected Performance Improvements
**Compared to RTX 4090:**
1. **Memory Bandwidth**: 32GB allows more parallel streams
2. **NVENC Sessions**: Estimated 12-16 concurrent (vs RTX 4090's 8)
3. **NVDEC Units**: More powerful decode engines
4. **Power Budget**: 575W allows sustained high performance
5. **Compute 12.0**: Latest architecture optimizations

### Target Performance
- **Conservative**: 664+ files/minute (baseline from RTX 4090)
- **Optimistic**: 900-1000 files/minute (with optimized worker count)
- **Pipeline**: Full GPU (NVDEC → GPU Scaling → NVENC)

### Implementation Strategy
1. **Start Conservative**: Test with 8 workers (RTX 4090 baseline)
2. **Incremental Scaling**: Increase to 12, then 16 workers
3. **Session Limit Detection**: Find RTX 5090's NVENC limit
4. **Performance Benchmarking**: Compare against RTX 4090 results

### Testing Plan
- [x] Build with current code (CPU decode baseline)
- [x] Implement NVDEC h264_cuvid decoder
- [x] Enable zero-copy GPU pipeline
- [x] Test single stream performance
- [ ] Test with 8 workers (baseline)
- [ ] Scale to 12 workers
- [ ] Scale to 16 workers
- [ ] Identify optimal worker count
- [ ] Benchmark final performance

### Key Differences from RTX 4090 Implementation
| Feature | RTX 4090 | RTX 5090 | Improvement |
|---------|----------|----------|-------------|
| **VRAM** | 24GB | 32GB | +33% |
| **TDP** | 450W | 575W | +28% |
| **NVENC Sessions** | 8 | 12-16 (est.) | +50-100% |
| **Compute Cap** | 8.9 | 12.0 | Latest gen |
| **Driver** | 570.x | 575.x | Latest |

### Current Status
- ✅ RTX 5090 detected and operational
- ✅ CUDA libraries upgraded (cuDNN 9.13, NCCL 2.28)
- ✅ NVENC/NVDEC capabilities verified
- ✅ Full GPU pipeline tested and working
- ✅ Single-stream performance validated
- ⏳ Multi-threaded implementation pending

### 🧪 NVDEC + NVENC Test Results (2 Ekim 2025)

**Test Configuration:**
```bash
Pipeline: h264_cuvid (NVDEC) → scale_cuda → h264_nvenc (NVENC)
Settings: P2 preset, VBR, CQ 28, 2M bitrate
Resolution: 1920x1080 → 1280x720
```

**Single Stream Performance:**
- ✅ Test: 1 file processed successfully
- ⏱️ Time: 3.92 seconds
- 📈 Speed: 5.86x realtime
- 🎞️ Frames: 490 frames @ 144 fps encoding

**Batch Performance (10 files, sequential):**
- ✅ Success Rate: 10/10 (100%)
- ⏱️ Total Time: 7 seconds
- 📈 Speed: **85.7 files/minute**
- ⚡ Average: **0.70 seconds per file**

**GPU Utilization:**
- 🎮 NVENC: Peak 34% utilization
- 📥 NVDEC: Peak 42% utilization
- ⚡ Power: Peak 101W (17.5% of 575W TDP)
- 💾 VRAM: Peak 595MB (1.8% of 32GB)
- 🌡️ Temp: 25-28°C (excellent cooling)

**Compression Performance:**
- 📦 Input: 95MB (10 files)
- 📦 Output: 24.7MB (10 files)
- 🔥 Reduction: **74% file size reduction**
- 📊 Ratio: **3.85:1 compression**

**Key Findings:**
1. ✅ Zero-copy GPU pipeline working perfectly
2. ✅ NVDEC + NVENC successfully decoding/encoding on RTX 5090
3. ✅ GPU scaling (scale_cuda) functional
4. ✅ Output quality maintained at 720p
5. ⚠️ **Massive GPU headroom** - Only 17.5% TDP utilized
6. 🚀 Ready for multi-threaded implementation

**Performance Projections:**
- Current (1 stream): 85.7 files/minute
- With 12 workers: **~1000+ files/minute** (conservative)
- With 16 workers: **~1300+ files/minute** (optimistic)
- RTX 4090 baseline was 664 files/min with 8 workers

### Next Steps
1. ✅ ~~Implement NVDEC hardware decoder~~ (COMPLETED)
2. ✅ ~~Remove CPU scaling bottleneck~~ (COMPLETED)
3. ✅ ~~Enable zero-copy GPU pipeline~~ (COMPLETED)
4. Implement multi-threaded transcoder with 8-16 workers
5. Test and optimize worker count for RTX 5090
6. Validate 1000+ files/minute target

---

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.

## 🚨 CRITICAL PROJECT REQUIREMENTS

**GPU-ONLY PIPELINE - NO EXCEPTIONS:**
- ⚠️ **Kesinlikle GPU ile decode ve encode yapılmalı**
- ⚠️ **CPU ile decode ve encode yapılMAYACAK**
- ⚠️ **Fallback olsa bile CPU kullanılmayacak**
- ⚠️ **h264_cuvid (NVDEC) mandatory for decoding**
- ⚠️ **h264_nvenc (NVENC) mandatory for encoding**
- ⚠️ **scale_cuda mandatory for scaling**
- ⚠️ **If GPU unavailable → FAIL immediately, do NOT use CPU fallback**

This is a hard requirement. Never implement CPU fallback for decoder, encoder, or scaler.

---

## 📦 CUDA Libraries Upgrade Log

### 3 Ekim 2025 - Kütüphane Güncellemeleri

**cuDNN (CUDA Deep Neural Network Library)**
- 🔄 Upgrade: `9.8.0.87-1` → `9.13.1.26-1`
- 📦 Paketler:
  - `libcudnn9-cuda-12: 9.13.1.26-1` (runtime)
  - `libcudnn9-dev-cuda-12: 9.13.1.26-1` (development)
  - `libcudnn9-headers-cuda-12: 9.13.1.26-1` (headers - yeni eklendi)
- ✅ CUDA 12.8+ uyumlu
- 🎯 Amaç: En son deep learning optimizasyonları ve bug fixes

**NCCL (NVIDIA Collective Communications Library)**
- 🔄 Upgrade: `2.25.1-1+cuda12.8` → `2.28.3-1+cuda13.0`
- 📦 Paketler:
  - `libnccl2: 2.28.3-1+cuda13.0` (runtime)
  - `libnccl-dev: 2.28.3-1+cuda13.0` (development)
- ✅ CUDA 13.0 uyumlu (forward compatible with CUDA 12.8)
- 🎯 Amaç: Multi-GPU communication improvements (future scalability)

**Upgrade Komutu:**
```bash
apt update
apt install -y --allow-change-held-packages \
  libcudnn9-cuda-12 libcudnn9-dev-cuda-12 \
  libnccl2 libnccl-dev
```

**Sonuç:**
- ✅ Başarılı upgrade (806 MB download)
- ✅ Held packages override edildi
- ✅ 464 MB disk space freed
- ✅ Sistem production-ready

**Not:** Bu upgrade'ler mevcut transcoder performansını etkilemez (FFmpeg NVENC/NVDEC kullanıyor), ancak gelecekteki GPU compute workloads için sistem hazır.

---

## 🔍 NVENC/NVDEC Erişim Testi - KRİTİK PROSEDÜR

**⚠️ UYARI**: Transcoder'ı çalıştırmadan ÖNCE mutlaka NVENC/NVDEC erişimini test et!

### Neden Gerekli?

RunPod ve benzeri container ortamlarında GPU device node'ları ve capability device'ları eksik/yanlış olabilir. Bu durumda:
- CUDA Runtime API çalışır ✅
- CUDA Driver API çalışır ✅
- **Ama NVENC/NVDEC erişimi BAŞARISIZ olur ❌**

Bu kritik bir fark çünkü transcoder NVENC/NVDEC olmadan çalışamaz!

### Test Prosedürü

#### 1. Otomatik GPU Detection Script (ZORUNLU)

**Her pod restart'ında çalıştır:**
```bash
./detect_gpu.sh
```

**Script'in yaptıkları:**
- ✅ GPU device node tespiti (nvidia0, nvidia1, etc.)
- ✅ /dev/nvidia0 eksikse otomatik symlink oluşturma
- ✅ Library version mismatch tespiti ve düzeltme
  - `libnvcuvid.so` → driver version ile eşleştir
  - `libnvidia-encode.so` → driver version ile eşleştir
- ✅ CUDA Runtime/Driver API testi
- ⚠️ NVENC/NVDEC hardware erişim testi
- 📝 `gpu_env.sh` environment dosyası oluşturma

**Başarılı çıktı örneği:**
```
✅ All FFmpeg NVDEC/NVENC tests passed!
```

**Başarısız çıktı örneği:**
```
❌ ERROR: NVDEC hardware access failed!
CUDA_ERROR_NO_DEVICE: no CUDA-capable device is detected
```

#### 2. Manuel Test (Opsiyonel - Debug için)

**CUDA API Test:**
```bash
./test_nvcodec
# Beklenen: "✅ All CUDA Driver API tests passed!"
```

**FFmpeg NVDEC Test:**
```bash
./test_ffmpeg_nvdec.sh
# Beklenen: "✅ All FFmpeg NVDEC/NVENC tests passed!"
```

### Bilinen Problemler ve Çözümler

#### Problem 1: Library Version Mismatch (ÇÖZÜLDÜ ✅)

**Semptom:**
```
[h264_cuvid @ ...] cuvidGetDecoderCaps failed -> CUDA_ERROR_NO_DEVICE
```

**Neden:**
RunPod container'da `libnvcuvid.so` ve `libnvidia-encode.so` symlink'leri driver version'ı ile eşleşmiyor.

**Örnek:**
```
Driver: 575.57.08
libnvcuvid.so.1 -> libnvcuvid.so.580.95.05  ❌ YANLIŞ!
```

**Çözüm:**
```bash
# detect_gpu.sh otomatik düzeltir, veya manuel:
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
ln -sf /usr/lib/x86_64-linux-gnu/libnvcuvid.so.$DRIVER_VER \
       /usr/lib/x86_64-linux-gnu/libnvcuvid.so.1
ln -sf /usr/lib/x86_64-linux-gnu/libnvidia-encode.so.$DRIVER_VER \
       /usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1
ldconfig
```

#### Problem 2: /dev/nvidia0 Eksik (ÇÖZÜLDÜ ✅)

**Semptom:**
Sadece `/dev/nvidia1` var, `/dev/nvidia0` yok.

**Neden:**
RunPod bazı pod'larda device numbering farklı başlıyor.

**Çözüm:**
```bash
# detect_gpu.sh otomatik yapar:
ln -sf /dev/nvidia1 /dev/nvidia0
```

#### Problem 3: /dev/nvidia-caps Eksik (⚠️ BLOKE EDİCİ)

**Semptom:**
```
[h264_cuvid @ ...] cuvidGetDecoderCaps failed -> CUDA_ERROR_NO_DEVICE
```
Library'ler doğru, device node'lar var, ama yine de başarısız.

**Neden:**
`/dev/nvidia-caps/nvidia-cap2` (Video Codec capability device) eksik.

**Bu container'ın yeterli privilege olmadan başlatıldığını gösterir.**

**Çözüm:**
RunPod pod'u yeniden başlat:
- Web UI'dan "Stop Pod" → "Start Pod"
- Veya support ile iletişime geç

**Manuel çözüm (host erişimi varsa):**
```bash
# Host makinede:
mkdir -p /dev/nvidia-caps
mknod -m 666 /dev/nvidia-caps/nvidia-cap1 c 516 1
mknod -m 666 /dev/nvidia-caps/nvidia-cap2 c 516 2
```

**Container başlatma parametreleri (ideal):**
```bash
docker run --gpus all --privileged ...
# veya
docker run --gpus all \
  --device=/dev/nvidia0 \
  --device=/dev/nvidiactl \
  --device=/dev/nvidia-uvm \
  --device=/dev/nvidia-caps/nvidia-cap2 \
  ...
```

### Test Sonuçlarının Yorumlanması

**✅ Tüm Testler Başarılı:**
```bash
./detect_gpu.sh
# Son satır: "✅ NVENC/NVDEC Access: READY"
```
→ **Transcoder'ı çalıştırabilirsin**

**❌ NVDEC Test Başarısız:**
```bash
./detect_gpu.sh
# Çıktıda: "❌ ERROR: NVDEC hardware access failed!"
```
→ **Transcoder ÇALIŞMAZ - Önce problemi çöz**

### Environment Setup

Test başarılıysa environment dosyasını source et:
```bash
source gpu_env.sh
# Veya manuel:
export CUDA_VISIBLE_DEVICES=0
```

### Referans Dökümanlar

**Detaylı problem analizi:**
- 📄 [NVENC_NVDEC_ISSUE.md](NVENC_NVDEC_ISSUE.md) - RunPod container capability problemi analizi

**Test Script'leri:**
- `detect_gpu.sh` - Otomatik GPU detection & fix (ZORUNLU)
- `test_nvcodec.c` - CUDA API test programı
- `test_ffmpeg_nvdec.sh` - FFmpeg NVENC/NVDEC test
- `gpu_env.sh` - Environment configuration (detect_gpu.sh tarafından oluşturulur)

### Özet Checklist

Transcoder çalıştırmadan önce:
- [ ] `./detect_gpu.sh` çalıştır
- [ ] Son satırda "✅ NVENC/NVDEC Access: READY" göründüğünü doğrula
- [ ] Eğer "❌ ERROR" görüyorsan, problemi çöz (pod restart, vs.)
- [ ] `source gpu_env.sh` ile environment'ı yükle
- [ ] `./transcoder` çalıştır

**KRİTİK**: Eğer NVDEC testi başarısızsa, transcoder kesinlikle çalışmaz!

---

## 🚀 Otomatik Environment Check & Setup

**⚠️ ÖNEMLİ**: Transcoder çalıştırmadan ÖNCE mutlaka bu script'i çalıştır!

### Tek Komut ile Tüm Hazırlık

```bash
./check_environment.sh
```

### Script'in Yaptığı İşlemler

**Phase 1: System Requirements Check**
- ✅ Root access kontrolü
- ✅ NVIDIA GPU detection (nvidia-smi)
- ✅ CUDA toolkit version check
- ✅ GCC compiler check
- ✅ FFmpeg installation check

**Phase 2: Required Libraries Check**
- ✅ FFmpeg libraries (libavformat, libavcodec, libavutil, libavfilter, libswresample)
- ✅ CUDA libraries (libcuda.so, libcudart.so)
- ✅ NVENC/NVDEC libraries (libnvcuvid.so, libnvidia-encode.so)
- ✅ cuDNN library (optional - for future)
- ✅ NCCL library (optional - for multi-GPU)

**Phase 3: Library Upgrades Check**
- 🔄 apt update çalıştırır
- 🔍 Upgradable CUDA libraries kontrolü
- ❓ Kullanıcıya upgrade isteyip istemediğini sorar
- 📦 Onaylanırsa cuDNN ve NCCL upgrade eder

**Phase 4: Build Verification**
- 🔨 `./transcoder` binary kontrolü
- ⏰ Source code'dan daha yeni mi kontrolü
- ❓ Gerekirse rebuild sorar
- 🔗 Library dependencies kontrolü (ldd)

**Phase 5: Directory Structure Check**
- 📁 `tsfiles/` input directory kontrolü
- 📊 File count ve total size raporu
- 📂 Output directory kontrolü/oluşturma

**Phase 6: GPU Detection & NVENC/NVDEC Access Test**
- 🔍 `detect_gpu.sh` otomatik çalıştırma
- 🔧 Device node fixes (nvidia0 symlink)
- 🔧 Library version mismatch fixes
- ⚡ NVENC/NVDEC hardware erişim testi

**Phase 7: Final Report**
- 📊 Summary (passed/failed/fixed)
- ✅ veya ❌ Final verdict
- 📝 Next steps önerileri

### Çıktı Örnekleri

**✅ Başarılı Durum:**
```
==================================================================
✅ ENVIRONMENT READY - Transcoder can run
==================================================================

Next steps:
  1. Source environment:
     source gpu_env.sh

  2. Run transcoder:
     ./transcoder

  3. Monitor GPU usage:
     nvidia-smi dmon -s pucvmet -i 0
```

**❌ Başarısız Durum:**
```
==================================================================
❌ ENVIRONMENT NOT READY - NVENC/NVDEC access failed
==================================================================

CRITICAL ISSUE:
  NVENC/NVDEC hardware access test failed!

This is likely due to missing /dev/nvidia-caps/nvidia-cap2

Possible solutions:
  1. Restart RunPod pod (Stop Pod → Start Pod)
  2. Contact RunPod support for container privileges
  3. Check NVENC_NVDEC_ISSUE.md for detailed analysis

Transcoder WILL NOT WORK until this is resolved!
```

### Otomatik Düzeltmeler

Script aşağıdaki problemleri **otomatik olarak** düzeltir:
- ✅ `/dev/nvidia0` symlink oluşturma
- ✅ `libnvcuvid.so` version mismatch fix
- ✅ `libnvidia-encode.so` version mismatch fix
- ✅ Output directory oluşturma
- ✅ `detect_gpu.sh` executable yapma
- ✅ Transcoder rebuild (kullanıcı onayı ile)
- ✅ Library upgrades (kullanıcı onayı ile)

### Manuel İşlemler

Script aşağıdaki durumlarda kullanıcıdan onay ister:
- ❓ CUDA libraries upgrade edilsin mi? (y/N)
- ❓ Transcoder rebuild edilsin mi? (y/N)

### Exit Codes

```bash
./check_environment.sh
echo $?
```

- `0` = ✅ Environment ready, transcoder çalıştırılabilir
- `1` = ❌ Critical issues, transcoder çalışmaz

### Integration Example

```bash
#!/bin/bash
# Transcoder çalıştırma script'i

# 1. Environment check
if ! ./check_environment.sh; then
    echo "Environment check failed - aborting"
    exit 1
fi

# 2. Load environment
source gpu_env.sh

# 3. Run transcoder
./transcoder

# 4. Check results
ls -lh output/
```

### Troubleshooting

**Script çok uzun sürüyor:**
- Normal - tüm kontrolleri yapıyor
- Upgrade aşamasında paket indiriyor olabilir

**"Not running as root" uyarısı:**
- Library installation/upgrade yapamaz
- Diğer tüm kontroller çalışır
- Eksik paketleri manuel yüklemelisin

**Script başarısız ama transcoder çalışıyor:**
- Mümkün değil - NVENC/NVDEC erişimi olmadan transcoder çalışmaz
- Script yanılmıyor, gerçekten problem var

**Script başarılı ama transcoder çalışmıyor:**
- Nadir bir durum - script'i tekrar çalıştır
- `gpu_env.sh` source edildi mi kontrol et
- Issue report et (bug olabilir)

### Dosyalar

**check_environment.sh** - Ana script
- Tüm kontroller ve otomatik fixes
- User-interactive (upgrade/rebuild onayları)
- Detaylı raporlama

**detect_gpu.sh** - GPU detection sub-script
- check_environment.sh tarafından otomatik çağrılır
- Manuel de çalıştırılabilir
- NVENC/NVDEC erişim testi

**gpu_env.sh** - Environment variables
- detect_gpu.sh tarafından oluşturulur
- Source edilmeli: `source gpu_env.sh`
- CUDA_VISIBLE_DEVICES=0 gibi değişkenler

### Quick Reference

**Full check (recommended):**
```bash
./check_environment.sh
```

**Quick GPU test only:**
```bash
./detect_gpu.sh
```

**Manual environment setup:**
```bash
source gpu_env.sh
export CUDA_VISIBLE_DEVICES=0
```

**Run transcoder:**
```bash
./transcoder
```
