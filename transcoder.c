/*
 * GPU-Accelerated Video Transcoder - RTX 5090 Edition
 * Target: 1000+ files/minute with RTX 5090 NVENC/NVDEC
 *
 * Architecture:
 *   NVDEC (h264_cuvid) → scale_cuda (GPU scaling) → NVENC (h264_nvenc)
 *   Zero-copy GPU-only pipeline, 16 concurrent workers
 *   NO CPU fallback - GPU mandatory
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_cuda.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <cuda_runtime.h>
#include <microhttpd.h>
#include <cjson/cJSON.h>
#include <curl/curl.h>
#include <signal.h>
#include <time.h>

// Configuration based on validated optimal settings
#define MAX_WORKERS 14          // 2x RTX 5090: 7 workers per GPU
#define MAX_QUEUE_SIZE 2000     // Handle 1080+ files without starvation
#define MAX_PROCESSED 2000      // Circular buffer for processed files
#define INPUT_DIR "/workspace/transcode-test-5090/tsfiles"
#define OUTPUT_DIR "/workspace/transcode-test-5090/output"
#define API_PORT 8080           // HTTP API port

// Job information including callback details
typedef struct {
    char filename[512];
    char callback_url[512];
    char metadata_json[2048];
} TranscodeJob;

// Queue system for task distribution
typedef struct {
    TranscodeJob jobs[MAX_QUEUE_SIZE];
    int front;
    int rear;
    int count;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} TaskQueue;

// Processed files tracking (circular buffer)
typedef struct {
    char files[MAX_PROCESSED][256];
    int count;
    pthread_mutex_t mutex;
} ProcessedFiles;

// Transcode context per worker
typedef struct {
    int worker_id;
    int gpu_id;  // GPU device ID (0 or 1)
    AVFormatContext *input_ctx;
    AVFormatContext *output_ctx;
    AVCodecContext *decoder_ctx;
    AVCodecContext *encoder_ctx;
    AVBufferRef *hw_device_ctx;
    AVFilterGraph *filter_graph;
    AVFilterContext *buffersrc_ctx;
    AVFilterContext *buffersink_ctx;
    cudaStream_t cuda_stream;
    int video_stream_idx;
} TranscodeContext;

// Global state
TaskQueue task_queue;
ProcessedFiles processed_files;
volatile int processing_active = 1;
volatile int files_processed = 0;
volatile int files_failed = 0;
time_t start_time;
static int no_gpu_mode = 0;  // Phase 1 test mode: no actual transcoding

// Statistics
pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;

// API server
struct MHD_Daemon *api_daemon = NULL;

// ============================================================================
// Queue Management
// ============================================================================

void queue_init(TaskQueue *q) {
    q->front = 0;
    q->rear = 0;
    q->count = 0;
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->not_empty, NULL);
    pthread_cond_init(&q->not_full, NULL);
}

void queue_push(TaskQueue *q, const TranscodeJob *job) {
    pthread_mutex_lock(&q->mutex);

    while (q->count >= MAX_QUEUE_SIZE) {
        pthread_cond_wait(&q->not_full, &q->mutex);
    }

    q->jobs[q->rear] = *job;
    q->rear = (q->rear + 1) % MAX_QUEUE_SIZE;
    q->count++;

    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mutex);
}

int queue_pop(TaskQueue *q, TranscodeJob *job) {
    pthread_mutex_lock(&q->mutex);

    while (q->count == 0 && processing_active) {
        pthread_cond_wait(&q->not_empty, &q->mutex);
    }

    if (q->count == 0) {
        pthread_mutex_unlock(&q->mutex);
        return 0;
    }

    *job = q->jobs[q->front];
    q->front = (q->front + 1) % MAX_QUEUE_SIZE;
    q->count--;

    pthread_cond_signal(&q->not_full);
    pthread_mutex_unlock(&q->mutex);
    return 1;
}

// ============================================================================
// Processed Files Tracking (Circular Buffer)
// ============================================================================

void processed_init(ProcessedFiles *pf) {
    pf->count = 0;
    pthread_mutex_init(&pf->mutex, NULL);
}

int is_file_processed(ProcessedFiles *pf, const char *filename) {
    pthread_mutex_lock(&pf->mutex);

    // Check if output file exists
    char output_path[512];
    char base_name[256];
    strncpy(base_name, filename, sizeof(base_name) - 1);
    base_name[sizeof(base_name) - 1] = '\0';

    char *ext = strstr(base_name, ".ts");
    if (ext) *ext = '\0';

    snprintf(output_path, sizeof(output_path), "%s/%s_h264.ts", OUTPUT_DIR, base_name);

    struct stat st;
    if (stat(output_path, &st) == 0) {
        pthread_mutex_unlock(&pf->mutex);
        return 1;
    }

    // Check in-memory circular buffer
    int start = (pf->count >= MAX_PROCESSED) ? (pf->count % MAX_PROCESSED) : 0;
    int items = (pf->count >= MAX_PROCESSED) ? MAX_PROCESSED : pf->count;

    for (int i = 0; i < items; i++) {
        int idx = (start + i) % MAX_PROCESSED;
        if (strcmp(pf->files[idx], filename) == 0) {
            pthread_mutex_unlock(&pf->mutex);
            return 1;
        }
    }

    pthread_mutex_unlock(&pf->mutex);
    return 0;
}

void mark_file_processed(ProcessedFiles *pf, const char *filename) {
    pthread_mutex_lock(&pf->mutex);

    int index = pf->count % MAX_PROCESSED;
    strncpy(pf->files[index], filename, 255);
    pf->files[index][255] = '\0';
    pf->count++;

    pthread_mutex_unlock(&pf->mutex);
}

// ============================================================================
// CUDA Hardware Context Setup
// ============================================================================

int init_hw_device_ctx(TranscodeContext *ctx) {
    // Create CUDA device string: "0" or "1"
    char device_str[8];
    snprintf(device_str, sizeof(device_str), "%d", ctx->gpu_id);

    int ret = av_hwdevice_ctx_create(&ctx->hw_device_ctx, AV_HWDEVICE_TYPE_CUDA,
                                     device_str, NULL, 0);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d GPU %d] Failed to create CUDA device context\n",
                ctx->worker_id, ctx->gpu_id);
        return ret;
    }

    fprintf(stderr, "[Worker %d] Using GPU %d\n", ctx->worker_id, ctx->gpu_id);

    // Create CUDA stream for async operations
    cudaError_t cuda_ret = cudaStreamCreate(&ctx->cuda_stream);
    if (cuda_ret != cudaSuccess) {
        fprintf(stderr, "[Worker %d] CUDA stream creation failed: %s\n",
                ctx->worker_id, cudaGetErrorString(cuda_ret));
        return -1;
    }

    fprintf(stderr, "[Worker %d] CUDA device context and stream created\n", ctx->worker_id);
    return 0;
}

// ============================================================================
// NVDEC Decoder Setup (h264_cuvid) - PERSISTENT VERSION
// ============================================================================

// Persistent decoder: initialized once with standard camera parameters
// All camera files are 1920x1080 H.264, so we can hardcode parameters
int init_decoder_persistent(TranscodeContext *ctx) {
    // GPU-ONLY: Use h264_cuvid (NVDEC) - NO CPU FALLBACK
    const AVCodec *decoder = avcodec_find_decoder_by_name("h264_cuvid");
    if (!decoder) {
        fprintf(stderr, "[Worker %d] FATAL: h264_cuvid (NVDEC) not available - GPU-only pipeline required\n", ctx->worker_id);
        exit(1);  // FAIL immediately - NO CPU fallback
    }

    ctx->decoder_ctx = avcodec_alloc_context3(decoder);
    if (!ctx->decoder_ctx) {
        fprintf(stderr, "[Worker %d] Failed to allocate decoder context\n", ctx->worker_id);
        return -1;
    }

    // Standard camera parameters (all files are identical format)
    ctx->decoder_ctx->codec_type = AVMEDIA_TYPE_VIDEO;
    ctx->decoder_ctx->codec_id = AV_CODEC_ID_H264;
    ctx->decoder_ctx->width = 1920;
    ctx->decoder_ctx->height = 1080;
    ctx->decoder_ctx->pix_fmt = AV_PIX_FMT_CUDA;
    ctx->decoder_ctx->time_base = (AVRational){1, 25};

    // Set hardware device context for NVDEC
    ctx->decoder_ctx->hw_device_ctx = av_buffer_ref(ctx->hw_device_ctx);

    // NVDEC options for fast decode
    AVDictionary *opts = NULL;
    char gpu_str[8];
    snprintf(gpu_str, sizeof(gpu_str), "%d", ctx->gpu_id);
    av_dict_set(&opts, "gpu", gpu_str, 0);

    if (avcodec_open2(ctx->decoder_ctx, decoder, &opts) < 0) {
        fprintf(stderr, "[Worker %d] Failed to open NVDEC decoder\n", ctx->worker_id);
        av_dict_free(&opts);
        return -1;
    }

    av_dict_free(&opts);
    fprintf(stderr, "[Worker %d] NVDEC decoder initialized (persistent, h264_cuvid)\n", ctx->worker_id);
    return 0;
}

// ============================================================================
// NVENC Encoder Setup (h264_nvenc with P2+VBR+CQ28)
// ============================================================================

int init_encoder(TranscodeContext *ctx) {
    // GPU-ONLY: Use h264_nvenc (NVENC) - NO CPU FALLBACK
    const AVCodec *encoder = avcodec_find_encoder_by_name("h264_nvenc");
    if (!encoder) {
        fprintf(stderr, "[Worker %d] FATAL: h264_nvenc (NVENC) not available - GPU-only pipeline required\n", ctx->worker_id);
        exit(1);  // FAIL immediately - NO CPU fallback
    }

    ctx->encoder_ctx = avcodec_alloc_context3(encoder);
    if (!ctx->encoder_ctx) {
        fprintf(stderr, "[Worker %d] Failed to allocate encoder context\n", ctx->worker_id);
        return -1;
    }

    // Encoder settings for 720p output with CUDA frames from scale_cuda filter
    ctx->encoder_ctx->width = 1280;
    ctx->encoder_ctx->height = 720;
    ctx->encoder_ctx->time_base = (AVRational){1, 25};
    ctx->encoder_ctx->framerate = (AVRational){25, 1};
    ctx->encoder_ctx->sample_aspect_ratio = (AVRational){1, 1};
    ctx->encoder_ctx->pix_fmt = AV_PIX_FMT_CUDA;  // Accept CUDA frames from scale_cuda
    ctx->encoder_ctx->bit_rate = 1500000;  // 1.5M bitrate (reduced for smaller output)

    // Create hw_frames_ctx for encoder (required when using CUDA frames)
    AVBufferRef *hw_frames_ref = av_hwframe_ctx_alloc(ctx->hw_device_ctx);
    AVHWFramesContext *frames_ctx = (AVHWFramesContext *)(hw_frames_ref->data);
    frames_ctx->format    = AV_PIX_FMT_CUDA;
    frames_ctx->sw_format = AV_PIX_FMT_NV12;
    frames_ctx->width     = 1280;
    frames_ctx->height    = 720;

    int ret = av_hwframe_ctx_init(hw_frames_ref);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to init encoder hw_frames_ctx\n", ctx->worker_id);
        av_buffer_unref(&hw_frames_ref);
        return -1;
    }

    ctx->encoder_ctx->hw_frames_ctx = hw_frames_ref;

    // NVENC optimal settings (P2 + VBR + CQ30 - optimized for smaller output)
    av_opt_set(ctx->encoder_ctx->priv_data, "preset", "p2", 0);
    av_opt_set(ctx->encoder_ctx->priv_data, "rc", "vbr", 0);
    av_opt_set(ctx->encoder_ctx->priv_data, "cq", "30", 0);  // Increased for smaller file size
    av_opt_set(ctx->encoder_ctx->priv_data, "profile", "main", 0);
    av_opt_set(ctx->encoder_ctx->priv_data, "level", "auto", 0);

    // Set GPU ID dynamically based on worker assignment
    char gpu_str_enc[8];
    snprintf(gpu_str_enc, sizeof(gpu_str_enc), "%d", ctx->gpu_id);
    av_opt_set(ctx->encoder_ctx->priv_data, "gpu", gpu_str_enc, 0);

    AVDictionary *opts = NULL;
    ret = avcodec_open2(ctx->encoder_ctx, encoder, &opts);
    av_dict_free(&opts);

    if (ret < 0) {
        fprintf(stderr, "[Worker %d] FATAL: Failed to open h264_nvenc encoder\n", ctx->worker_id);
        return -1;
    }

    fprintf(stderr, "[Worker %d] NVENC encoder initialized (h264_nvenc)\n", ctx->worker_id);
    return 0;
}

// Initialize scale_cuda filter for GPU-based scaling - PERSISTENT VERSION
// Uses hard-coded parameters since all camera files are identical format
int init_filter_persistent(TranscodeContext *ctx) {
    char args[512];
    int ret;

    const AVFilter *buffersrc = avfilter_get_by_name("buffer");
    const AVFilter *buffersink = avfilter_get_by_name("buffersink");
    AVFilterInOut *outputs = avfilter_inout_alloc();
    AVFilterInOut *inputs = avfilter_inout_alloc();

    ctx->filter_graph = avfilter_graph_alloc();
    if (!outputs || !inputs || !ctx->filter_graph) {
        fprintf(stderr, "[Worker %d] Failed to allocate filter graph\n", ctx->worker_id);
        return -1;
    }

    // Create buffer source (NVDEC output) - standard camera parameters
    snprintf(args, sizeof(args),
             "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
             1920, 1080,
             AV_PIX_FMT_CUDA,
             1, 25,
             1, 1);

    fprintf(stderr, "[Worker %d] Creating buffer source with args: %s\n", ctx->worker_id, args);
    ret = avfilter_graph_create_filter(&ctx->buffersrc_ctx, buffersrc, "in",
                                       args, NULL, ctx->filter_graph);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to create buffer source\n", ctx->worker_id);
        return -1;
    }

    // Create hw_frames_ctx for buffer source
    fprintf(stderr, "[Worker %d] Creating hw_frames_ctx for buffer source\n", ctx->worker_id);
    AVBufferRef *hw_frames_ref = av_hwframe_ctx_alloc(ctx->hw_device_ctx);
    if (!hw_frames_ref) {
        fprintf(stderr, "[Worker %d] Failed to allocate hw_frames_ctx\n", ctx->worker_id);
        return -1;
    }

    AVHWFramesContext *frames_ctx = (AVHWFramesContext *)(hw_frames_ref->data);
    frames_ctx->format    = AV_PIX_FMT_CUDA;
    frames_ctx->sw_format = AV_PIX_FMT_NV12;
    frames_ctx->width     = ctx->decoder_ctx->width;
    frames_ctx->height    = ctx->decoder_ctx->height;

    ret = av_hwframe_ctx_init(hw_frames_ref);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to initialize hw_frames_ctx\n", ctx->worker_id);
        av_buffer_unref(&hw_frames_ref);
        return -1;
    }

    AVBufferSrcParameters *par = av_buffersrc_parameters_alloc();
    par->hw_frames_ctx = hw_frames_ref;
    av_buffersrc_parameters_set(ctx->buffersrc_ctx, par);
    av_free(par);

    // Create buffer sink (NVENC input)
    ret = avfilter_graph_create_filter(&ctx->buffersink_ctx, buffersink, "out",
                                       NULL, NULL, ctx->filter_graph);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to create buffer sink\n", ctx->worker_id);
        return -1;
    }

    // Configure outputs (from buffer source)
    outputs->name = av_strdup("in");
    outputs->filter_ctx = ctx->buffersrc_ctx;
    outputs->pad_idx = 0;
    outputs->next = NULL;

    // Configure inputs (to buffer sink)
    inputs->name = av_strdup("out");
    inputs->filter_ctx = ctx->buffersink_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    // scale_cuda filter: resize 1920x1080 -> 1280:720 on GPU
    const char *filter_descr = "scale_cuda=1280:720";

    fprintf(stderr, "[Worker %d] Parsing filter graph: %s\n", ctx->worker_id, filter_descr);
    ret = avfilter_graph_parse_ptr(ctx->filter_graph, filter_descr,
                                   &inputs, &outputs, NULL);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to parse filter graph\n", ctx->worker_id);
        return -1;
    }

    // Set hardware device context on filter graph
    fprintf(stderr, "[Worker %d] Setting hw_device_ctx on %d filters\n", ctx->worker_id, ctx->filter_graph->nb_filters);
    for (unsigned i = 0; i < ctx->filter_graph->nb_filters; i++) {
        ctx->filter_graph->filters[i]->hw_device_ctx = av_buffer_ref(ctx->hw_device_ctx);
    }

    fprintf(stderr, "[Worker %d] Configuring filter graph...\n", ctx->worker_id);
    ret = avfilter_graph_config(ctx->filter_graph, NULL);
    if (ret < 0) {
        fprintf(stderr, "[Worker %d] Failed to configure filter graph\n", ctx->worker_id);
        return -1;
    }

    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);

    fprintf(stderr, "[Worker %d] scale_cuda filter initialized (persistent, 1920x1080 -> 1280x720 on GPU)\n", ctx->worker_id);
    return 0;
}

// ============================================================================
// Persistent Pipeline Setup and Management
// ============================================================================

// Initialize the persistent GPU pipeline once per worker
// This avoids expensive per-file recreation of NVENC/NVDEC sessions
int setup_persistent_pipeline(TranscodeContext *ctx) {
    fprintf(stderr, "[Worker %d] Setting up persistent GPU pipeline...\n", ctx->worker_id);

    // Initialize decoder (NVDEC session - expensive to create)
    if (init_decoder_persistent(ctx) < 0) {
        fprintf(stderr, "[Worker %d] Failed to initialize persistent decoder\n", ctx->worker_id);
        return -1;
    }

    // Initialize encoder (NVENC session - expensive to create)
    if (init_encoder(ctx) < 0) {
        fprintf(stderr, "[Worker %d] Failed to initialize persistent encoder\n", ctx->worker_id);
        return -1;
    }

    // Initialize filter (scale_cuda graph - expensive to configure)
    if (init_filter_persistent(ctx) < 0) {
        fprintf(stderr, "[Worker %d] Failed to initialize persistent filter\n", ctx->worker_id);
        return -1;
    }

    fprintf(stderr, "[Worker %d] ✓ Persistent pipeline ready (NVDEC→scale_cuda→NVENC)\n", ctx->worker_id);
    return 0;
}

// Flush pipeline state between files
// This is MUCH faster than recreating contexts (~10ms vs ~300ms)
void flush_pipeline_for_next_file(TranscodeContext *ctx) {
    // Flush decoder and encoder buffers
    avcodec_flush_buffers(ctx->decoder_ctx);
    avcodec_flush_buffers(ctx->encoder_ctx);

    // Filter graph must be recreated as it enters EOF state
    // This is still much cheaper than recreating decoder/encoder (~50ms vs ~300ms)
    if (ctx->filter_graph) {
        avfilter_graph_free(&ctx->filter_graph);
        ctx->filter_graph = NULL;
        ctx->buffersrc_ctx = NULL;
        ctx->buffersink_ctx = NULL;
    }

    // Reinitialize filter for next file
    init_filter_persistent(ctx);
}

// ============================================================================
// File Processing Pipeline
// ============================================================================

int process_file(TranscodeContext *ctx, const char *input_filename) {
    char input_path[512];
    char output_path[512];
    char base_name[256];

    snprintf(input_path, sizeof(input_path), "%s/%s", INPUT_DIR, input_filename);

    strncpy(base_name, input_filename, sizeof(base_name) - 1);
    base_name[sizeof(base_name) - 1] = '\0';
    char *ext = strstr(base_name, ".ts");
    if (ext) *ext = '\0';

    snprintf(output_path, sizeof(output_path), "%s/%s_h264.ts", OUTPUT_DIR, base_name);

    fprintf(stderr, "[Worker %d] Processing: %s\n", ctx->worker_id, input_filename);

    // Open input file with fast probing
    AVDictionary *format_opts = NULL;
    av_dict_set(&format_opts, "probesize", "1024", 0);
    av_dict_set(&format_opts, "analyzeduration", "0", 0);
    av_dict_set(&format_opts, "fflags", "+fastseek", 0);

    if (avformat_open_input(&ctx->input_ctx, input_path, NULL, &format_opts) < 0) {
        fprintf(stderr, "[Worker %d] Failed to open input: %s\n", ctx->worker_id, input_path);
        av_dict_free(&format_opts);
        return -1;
    }
    av_dict_free(&format_opts);

    if (avformat_find_stream_info(ctx->input_ctx, NULL) < 0) {
        fprintf(stderr, "[Worker %d] Failed to find stream info\n", ctx->worker_id);
        return -1;
    }

    // Find video stream
    ctx->video_stream_idx = -1;
    for (unsigned int i = 0; i < ctx->input_ctx->nb_streams; i++) {
        if (ctx->input_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            ctx->video_stream_idx = i;
            break;
        }
    }

    if (ctx->video_stream_idx == -1) {
        fprintf(stderr, "[Worker %d] No video stream found\n", ctx->worker_id);
        return -1;
    }

    AVStream *in_stream = ctx->input_ctx->streams[ctx->video_stream_idx];

    // Flush pipeline state from previous file (if any)
    // This is MUCH faster than recreating contexts (~10ms vs ~300ms)
    flush_pipeline_for_next_file(ctx);

    // Create output context
    avformat_alloc_output_context2(&ctx->output_ctx, NULL, "mpegts", output_path);
    if (!ctx->output_ctx) {
        fprintf(stderr, "[Worker %d] Failed to create output context\n", ctx->worker_id);
        return -1;
    }

    AVStream *out_stream = avformat_new_stream(ctx->output_ctx, NULL);
    if (!out_stream) {
        fprintf(stderr, "[Worker %d] Failed to create output stream\n", ctx->worker_id);
        return -1;
    }

    if (avcodec_parameters_from_context(out_stream->codecpar, ctx->encoder_ctx) < 0) {
        fprintf(stderr, "[Worker %d] Failed to copy encoder parameters\n", ctx->worker_id);
        return -1;
    }

    out_stream->time_base = ctx->encoder_ctx->time_base;

    if (!(ctx->output_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&ctx->output_ctx->pb, output_path, AVIO_FLAG_WRITE) < 0) {
            fprintf(stderr, "[Worker %d] Failed to open output file: %s\n", ctx->worker_id, output_path);
            return -1;
        }
    }

    if (avformat_write_header(ctx->output_ctx, NULL) < 0) {
        fprintf(stderr, "[Worker %d] Failed to write header\n", ctx->worker_id);
        return -1;
    }

    // Zero-copy GPU pipeline: NVDEC → scale_cuda → NVENC
    AVPacket *packet = av_packet_alloc();
    AVFrame *decoded_frame = av_frame_alloc();
    AVFrame *filtered_frame = av_frame_alloc();

    int frame_count = 0;

    while (av_read_frame(ctx->input_ctx, packet) >= 0) {
        if (packet->stream_index == ctx->video_stream_idx) {
            if (avcodec_send_packet(ctx->decoder_ctx, packet) == 0) {
                while (avcodec_receive_frame(ctx->decoder_ctx, decoded_frame) == 0) {
                    // Send CUDA frame to scale_cuda filter
                    if (av_buffersrc_add_frame_flags(ctx->buffersrc_ctx, decoded_frame,
                                                     AV_BUFFERSRC_FLAG_KEEP_REF) < 0) {
                        fprintf(stderr, "[Worker %d] Error feeding filter\n", ctx->worker_id);
                        av_frame_unref(decoded_frame);
                        continue;
                    }

                    // Get scaled CUDA frame from filter
                    while (av_buffersink_get_frame(ctx->buffersink_ctx, filtered_frame) >= 0) {
                        filtered_frame->pts = frame_count++;

                        // Send scaled CUDA frame to NVENC encoder
                        if (avcodec_send_frame(ctx->encoder_ctx, filtered_frame) == 0) {
                            AVPacket *enc_packet = av_packet_alloc();
                            while (avcodec_receive_packet(ctx->encoder_ctx, enc_packet) == 0) {
                                enc_packet->stream_index = 0;
                                av_packet_rescale_ts(enc_packet, ctx->encoder_ctx->time_base,
                                                    out_stream->time_base);
                                av_interleaved_write_frame(ctx->output_ctx, enc_packet);
                                av_packet_unref(enc_packet);
                            }
                            av_packet_free(&enc_packet);
                        }
                        av_frame_unref(filtered_frame);
                    }
                    av_frame_unref(decoded_frame);
                }
            }
        }
        av_packet_unref(packet);
    }

    // Flush decoder
    avcodec_send_packet(ctx->decoder_ctx, NULL);
    while (avcodec_receive_frame(ctx->decoder_ctx, decoded_frame) == 0) {
        av_buffersrc_add_frame_flags(ctx->buffersrc_ctx, decoded_frame, AV_BUFFERSRC_FLAG_KEEP_REF);

        while (av_buffersink_get_frame(ctx->buffersink_ctx, filtered_frame) >= 0) {
            filtered_frame->pts = frame_count++;
            avcodec_send_frame(ctx->encoder_ctx, filtered_frame);

            AVPacket *enc_packet = av_packet_alloc();
            while (avcodec_receive_packet(ctx->encoder_ctx, enc_packet) == 0) {
                enc_packet->stream_index = 0;
                av_packet_rescale_ts(enc_packet, ctx->encoder_ctx->time_base, out_stream->time_base);
                av_interleaved_write_frame(ctx->output_ctx, enc_packet);
                av_packet_unref(enc_packet);
            }
            av_packet_free(&enc_packet);
            av_frame_unref(filtered_frame);
        }
        av_frame_unref(decoded_frame);
    }

    // Flush filter
    av_buffersrc_add_frame_flags(ctx->buffersrc_ctx, NULL, 0);
    while (av_buffersink_get_frame(ctx->buffersink_ctx, filtered_frame) >= 0) {
        filtered_frame->pts = frame_count++;
        avcodec_send_frame(ctx->encoder_ctx, filtered_frame);

        AVPacket *enc_packet = av_packet_alloc();
        while (avcodec_receive_packet(ctx->encoder_ctx, enc_packet) == 0) {
            enc_packet->stream_index = 0;
            av_packet_rescale_ts(enc_packet, ctx->encoder_ctx->time_base, out_stream->time_base);
            av_interleaved_write_frame(ctx->output_ctx, enc_packet);
            av_packet_unref(enc_packet);
        }
        av_packet_free(&enc_packet);
        av_frame_unref(filtered_frame);
    }

    // Flush encoder
    avcodec_send_frame(ctx->encoder_ctx, NULL);
    AVPacket *enc_packet = av_packet_alloc();
    while (avcodec_receive_packet(ctx->encoder_ctx, enc_packet) == 0) {
        enc_packet->stream_index = 0;
        av_packet_rescale_ts(enc_packet, ctx->encoder_ctx->time_base, out_stream->time_base);
        av_interleaved_write_frame(ctx->output_ctx, enc_packet);
        av_packet_unref(enc_packet);
    }
    av_packet_free(&enc_packet);

    av_write_trailer(ctx->output_ctx);

    av_frame_free(&filtered_frame);
    av_frame_free(&decoded_frame);
    av_packet_free(&packet);

    fprintf(stderr, "[Worker %d] ✓ Completed: %s (%d frames)\n",
            ctx->worker_id, input_filename, frame_count);

    return 0;
}

// ============================================================================
// HTTP Callback Notification
// ============================================================================

// Callback for curl to discard response data
static size_t discard_response_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    return size * nmemb;  // Discard response
}

// Send completion notification to callback URL
int send_completion_callback(const char *callback_url, const char *input_file,
                             const char *output_file, int frame_count,
                             int processing_time_ms, const char *metadata_json,
                             const char *status) {
    if (!callback_url || strlen(callback_url) == 0) {
        return 0;  // No callback URL provided, skip
    }

    CURL *curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "[Callback] Failed to initialize curl\n");
        return -1;
    }

    // Build JSON payload
    cJSON *json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "status", status);
    cJSON_AddStringToObject(json, "inputFile", input_file);
    cJSON_AddStringToObject(json, "outputFile", output_file);
    cJSON_AddNumberToObject(json, "frameCount", frame_count);
    cJSON_AddNumberToObject(json, "processingTimeMs", processing_time_ms);

    // Add metadata if provided
    if (metadata_json && strlen(metadata_json) > 0) {
        cJSON *metadata = cJSON_Parse(metadata_json);
        if (metadata) {
            cJSON_AddItemToObject(json, "metadata", metadata);
        }
    }

    char *json_str = cJSON_PrintUnformatted(json);

    // Configure curl
    curl_easy_setopt(curl, CURLOPT_URL, callback_url);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_str);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, discard_response_callback);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);

    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    // Perform request
    CURLcode res = curl_easy_perform(curl);

    if (res != CURLE_OK) {
        fprintf(stderr, "[Callback] Failed to send callback: %s\n", curl_easy_strerror(res));
    } else {
        fprintf(stderr, "[Callback] ✓ Sent to %s\n", callback_url);
    }

    // Cleanup
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    free(json_str);
    cJSON_Delete(json);

    return (res == CURLE_OK) ? 0 : -1;
}

// ============================================================================
// Worker Thread
// ============================================================================

// Cleanup per-file resources (input/output contexts only)
// Called after each file - keeps persistent pipeline alive
void cleanup_file_contexts(TranscodeContext *ctx) {
    if (ctx->input_ctx) {
        avformat_close_input(&ctx->input_ctx);
        ctx->input_ctx = NULL;
    }
    if (ctx->output_ctx) {
        if (!(ctx->output_ctx->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&ctx->output_ctx->pb);
        }
        avformat_free_context(ctx->output_ctx);
        ctx->output_ctx = NULL;
    }
}

// Cleanup persistent pipeline resources
// Called once at worker thread exit
void cleanup_persistent_pipeline(TranscodeContext *ctx) {
    if (ctx->decoder_ctx) {
        avcodec_free_context(&ctx->decoder_ctx);
        ctx->decoder_ctx = NULL;
    }
    if (ctx->encoder_ctx) {
        avcodec_free_context(&ctx->encoder_ctx);
        ctx->encoder_ctx = NULL;
    }
    if (ctx->filter_graph) {
        avfilter_graph_free(&ctx->filter_graph);
        ctx->filter_graph = NULL;
    }
}

void *worker_thread(void *arg) {
    int worker_id = *(int*)arg;
    free(arg);

    fprintf(stderr, "[Worker %d] Started\n", worker_id);

    TranscodeContext ctx = {0};
    ctx.worker_id = worker_id;
    ctx.gpu_id = worker_id / 7;  // Workers 0-6 → GPU 0, Workers 7-13 → GPU 1 (7 per GPU)

    // In no-GPU mode, skip hardware initialization
    if (!no_gpu_mode) {
        // Initialize CUDA hardware context
        if (init_hw_device_ctx(&ctx) < 0) {
            fprintf(stderr, "[Worker %d] Failed to initialize hardware context\n", worker_id);
            return NULL;
        }

        // Initialize persistent GPU pipeline (ONCE per worker, not per file!)
        // This is the key optimization: avoid expensive NVENC/NVDEC session recreation
        if (setup_persistent_pipeline(&ctx) < 0) {
            fprintf(stderr, "[Worker %d] Failed to setup persistent pipeline\n", worker_id);
            return NULL;
        }
    }

    TranscodeJob job;

    while (1) {
        if (!queue_pop(&task_queue, &job)) {
            break;
        }

        int result = 0;
        struct timespec start, end;
        clock_gettime(CLOCK_MONOTONIC, &start);

        if (no_gpu_mode) {
            // Phase 1: No-GPU mode - just echo back input path
            fprintf(stderr, "[Worker %d] ⚠️  NO-GPU mode: %s (would transcode if GPU available)\n",
                    worker_id, job.filename);

            clock_gettime(CLOCK_MONOTONIC, &end);
            int processing_ms = (end.tv_sec - start.tv_sec) * 1000 +
                               (end.tv_nsec - start.tv_nsec) / 1000000;

            // Send callback with input path as output (Phase 1 behavior)
            send_completion_callback(job.callback_url, job.filename, job.filename,
                                    0, processing_ms, job.metadata_json, "completed");

            fprintf(stderr, "[Worker %d] ✓ Acknowledgment sent - S3Uploader will upload raw segment\n",
                    worker_id);
            result = 0;
        } else {
            // Phase 2: Normal GPU transcoding
            result = process_file(&ctx, job.filename);

            clock_gettime(CLOCK_MONOTONIC, &end);
            int processing_ms = (end.tv_sec - start.tv_sec) * 1000 +
                               (end.tv_nsec - start.tv_nsec) / 1000000;

            // In Phase 2, send callback with transcoded output path
            if (result == 0) {
                char output_path[512];
                char base_name[256];
                strncpy(base_name, job.filename, sizeof(base_name) - 1);
                char *ext = strstr(base_name, ".ts");
                if (ext) *ext = '\0';
                snprintf(output_path, sizeof(output_path), "%s_h264.ts", base_name);

                send_completion_callback(job.callback_url, job.filename, output_path,
                                        0, processing_ms, job.metadata_json, "completed");
            } else {
                send_completion_callback(job.callback_url, job.filename, "",
                                        0, processing_ms, job.metadata_json, "failed");
            }
        }

        if (result == 0) {
            mark_file_processed(&processed_files, job.filename);
            pthread_mutex_lock(&stats_mutex);
            files_processed++;
            pthread_mutex_unlock(&stats_mutex);
        } else {
            pthread_mutex_lock(&stats_mutex);
            files_failed++;
            pthread_mutex_unlock(&stats_mutex);
        }

        // Cleanup only per-file resources (NOT the persistent pipeline!)
        if (!no_gpu_mode) {
            cleanup_file_contexts(&ctx);
        }
    }

    // Final cleanup - destroy persistent pipeline
    if (!no_gpu_mode) {
        cleanup_persistent_pipeline(&ctx);

        if (ctx.cuda_stream) {
            cudaStreamSynchronize(ctx.cuda_stream);
            cudaStreamDestroy(ctx.cuda_stream);
        }
        if (ctx.hw_device_ctx) {
            av_buffer_unref(&ctx.hw_device_ctx);
        }
    }

    fprintf(stderr, "[Worker %d] Finished\n", worker_id);
    return NULL;
}

// ============================================================================
// File Scanner Thread
// ============================================================================

void *scanner_thread(void *arg) {
    fprintf(stderr, "[Scanner] Starting file discovery...\n");

    DIR *dir = opendir(INPUT_DIR);
    if (!dir) {
        fprintf(stderr, "[Scanner] Failed to open directory: %s\n", INPUT_DIR);
        return NULL;
    }

    struct dirent *entry;
    int discovered = 0;

    while ((entry = readdir(dir)) != NULL) {
        if (strstr(entry->d_name, ".ts") && !strstr(entry->d_name, "_h264.ts")) {
            if (!is_file_processed(&processed_files, entry->d_name)) {
                TranscodeJob job = {0};
                strncpy(job.filename, entry->d_name, sizeof(job.filename) - 1);
                // No callback URL in batch mode
                queue_push(&task_queue, &job);
                discovered++;
            }
        }
    }

    closedir(dir);

    fprintf(stderr, "[Scanner] Discovered %d files for processing\n", discovered);
    return NULL;
}

// ============================================================================
// Signal Handling & API Server
// ============================================================================

void signal_handler(int sig) {
    fprintf(stderr, "\n[Signal] Received signal %d (%s), shutting down gracefully...\n",
            sig, sig == SIGINT ? "SIGINT" : "SIGTERM");

    processing_active = 0;

    // Wake up all threads
    pthread_cond_broadcast(&task_queue.not_empty);

    // Stop API server
    if (api_daemon) {
        MHD_stop_daemon(api_daemon);
        api_daemon = NULL;
    }
}

// Helper: Send HTTP response
static enum MHD_Result send_response(struct MHD_Connection *connection,
                                     int status_code,
                                     const char *response_text) {
    struct MHD_Response *response = MHD_create_response_from_buffer(
        strlen(response_text),
        (void*)response_text,
        MHD_RESPMEM_MUST_COPY
    );

    MHD_add_response_header(response, "Content-Type", "application/json");
    MHD_add_response_header(response, "Access-Control-Allow-Origin", "*");

    enum MHD_Result ret = MHD_queue_response(connection, status_code, response);
    MHD_destroy_response(response);

    return ret;
}

// API Endpoint: POST /enqueue - Add file to transcoding queue
static enum MHD_Result handle_enqueue(struct MHD_Connection *connection,
                                      const char *upload_data,
                                      size_t upload_data_size) {
    if (upload_data_size == 0) {
        return send_response(connection, 400, "{\"error\":\"Empty request body\"}");
    }

    // Parse JSON
    cJSON *json = cJSON_Parse(upload_data);
    if (!json) {
        return send_response(connection, 400, "{\"error\":\"Invalid JSON\"}");
    }

    // Get inputPath (full path to file)
    cJSON *input_path_item = cJSON_GetObjectItem(json, "inputPath");
    if (!input_path_item || !cJSON_IsString(input_path_item)) {
        cJSON_Delete(json);
        return send_response(connection, 400, "{\"error\":\"Missing 'inputPath' field\"}");
    }

    const char *input_path = input_path_item->valuestring;

    // Validate path exists
    if (access(input_path, F_OK) != 0) {
        cJSON_Delete(json);

        cJSON *error_response = cJSON_CreateObject();
        cJSON_AddStringToObject(error_response, "error", "File not found");
        cJSON_AddStringToObject(error_response, "inputPath", input_path);
        char *error_str = cJSON_Print(error_response);
        enum MHD_Result ret = send_response(connection, 404, error_str);
        free(error_str);
        cJSON_Delete(error_response);

        return ret;
    }

    // Get callback URL (optional)
    const char *callback_url = "";
    cJSON *callback_item = cJSON_GetObjectItem(json, "callbackUrl");
    if (callback_item && cJSON_IsString(callback_item)) {
        callback_url = callback_item->valuestring;
    }

    // Get metadata (optional)
    char metadata_json[2048] = {0};
    cJSON *metadata_item = cJSON_GetObjectItem(json, "metadata");
    if (metadata_item) {
        char *metadata_str = cJSON_PrintUnformatted(metadata_item);
        if (metadata_str) {
            strncpy(metadata_json, metadata_str, sizeof(metadata_json) - 1);
            free(metadata_str);
        }
    }

    // Check queue capacity
    pthread_mutex_lock(&task_queue.mutex);
    int queue_depth = task_queue.count;
    int queue_capacity = MAX_QUEUE_SIZE;
    pthread_mutex_unlock(&task_queue.mutex);

    if (queue_depth >= (queue_capacity * 0.95)) {
        cJSON_Delete(json);

        cJSON *full_response = cJSON_CreateObject();
        cJSON_AddStringToObject(full_response, "error", "Queue almost full");
        cJSON_AddNumberToObject(full_response, "queue_depth", queue_depth);
        cJSON_AddNumberToObject(full_response, "queue_capacity", queue_capacity);
        cJSON_AddStringToObject(full_response, "retry_after", "60");
        char *full_str = cJSON_Print(full_response);
        enum MHD_Result ret = send_response(connection, 503, full_str);
        free(full_str);
        cJSON_Delete(full_response);

        return ret;
    }

    // Create job
    TranscodeJob job = {0};
    strncpy(job.filename, input_path, sizeof(job.filename) - 1);
    strncpy(job.callback_url, callback_url, sizeof(job.callback_url) - 1);
    strncpy(job.metadata_json, metadata_json, sizeof(job.metadata_json) - 1);

    // Add to queue
    queue_push(&task_queue, &job);

    fprintf(stderr, "[API] Enqueued: %s (queue depth: %d)\n", input_path, queue_depth + 1);

    // Success response
    cJSON *success_response = cJSON_CreateObject();
    cJSON_AddStringToObject(success_response, "status", "queued");
    cJSON_AddStringToObject(success_response, "inputPath", input_path);
    cJSON_AddNumberToObject(success_response, "queue_depth", queue_depth + 1);
    char *success_str = cJSON_Print(success_response);

    enum MHD_Result ret = send_response(connection, 200, success_str);

    free(success_str);
    cJSON_Delete(success_response);
    cJSON_Delete(json);

    return ret;
}

// API Endpoint: GET /health - Health check
static enum MHD_Result handle_health(struct MHD_Connection *connection) {
    cJSON *health = cJSON_CreateObject();

    pthread_mutex_lock(&stats_mutex);
    cJSON_AddStringToObject(health, "status", "healthy");
    cJSON_AddNumberToObject(health, "processed", files_processed);
    cJSON_AddNumberToObject(health, "failed", files_failed);
    cJSON_AddNumberToObject(health, "queue_depth", task_queue.count);
    cJSON_AddNumberToObject(health, "workers", MAX_WORKERS);
    cJSON_AddNumberToObject(health, "uptime_seconds", (int)(time(NULL) - start_time));
    pthread_mutex_unlock(&stats_mutex);

    char *health_str = cJSON_Print(health);
    enum MHD_Result ret = send_response(connection, 200, health_str);

    free(health_str);
    cJSON_Delete(health);

    return ret;
}

// API Endpoint: GET /metrics - Prometheus metrics
static enum MHD_Result handle_metrics(struct MHD_Connection *connection) {
    char metrics[4096];

    pthread_mutex_lock(&stats_mutex);
    snprintf(metrics, sizeof(metrics),
        "# HELP transcoder_processed_total Total files processed\n"
        "# TYPE transcoder_processed_total counter\n"
        "transcoder_processed_total %d\n"
        "\n"
        "# HELP transcoder_failed_total Total files failed\n"
        "# TYPE transcoder_failed_total counter\n"
        "transcoder_failed_total %d\n"
        "\n"
        "# HELP transcoder_queue_depth Current queue depth\n"
        "# TYPE transcoder_queue_depth gauge\n"
        "transcoder_queue_depth %d\n"
        "\n"
        "# HELP transcoder_workers Total worker threads\n"
        "# TYPE transcoder_workers gauge\n"
        "transcoder_workers %d\n"
        "\n"
        "# HELP transcoder_uptime_seconds Uptime in seconds\n"
        "# TYPE transcoder_uptime_seconds counter\n"
        "transcoder_uptime_seconds %d\n",
        files_processed, files_failed, task_queue.count, MAX_WORKERS,
        (int)(time(NULL) - start_time)
    );
    pthread_mutex_unlock(&stats_mutex);

    struct MHD_Response *response = MHD_create_response_from_buffer(
        strlen(metrics), (void*)metrics, MHD_RESPMEM_MUST_COPY
    );
    MHD_add_response_header(response, "Content-Type", "text/plain; version=0.0.4");

    enum MHD_Result ret = MHD_queue_response(connection, 200, response);
    MHD_destroy_response(response);

    return ret;
}

// HTTP request router
struct connection_info {
    char *upload_data_buffer;
    size_t upload_data_size;
};

static enum MHD_Result http_handler(void *cls,
                                    struct MHD_Connection *connection,
                                    const char *url,
                                    const char *method,
                                    const char *version,
                                    const char *upload_data,
                                    size_t *upload_data_size,
                                    void **con_cls) {
    // First call - setup
    if (*con_cls == NULL) {
        struct connection_info *con_info = malloc(sizeof(struct connection_info));
        con_info->upload_data_buffer = NULL;
        con_info->upload_data_size = 0;
        *con_cls = con_info;
        return MHD_YES;
    }

    struct connection_info *con_info = *con_cls;

    // Accumulate POST data
    if (*upload_data_size != 0) {
        con_info->upload_data_buffer = realloc(con_info->upload_data_buffer,
                                               con_info->upload_data_size + *upload_data_size + 1);
        memcpy(con_info->upload_data_buffer + con_info->upload_data_size,
               upload_data, *upload_data_size);
        con_info->upload_data_size += *upload_data_size;
        con_info->upload_data_buffer[con_info->upload_data_size] = '\0';
        *upload_data_size = 0;
        return MHD_YES;
    }

    // Route handling
    enum MHD_Result result;

    if (strcmp(url, "/enqueue") == 0 && strcmp(method, "POST") == 0) {
        result = handle_enqueue(connection, con_info->upload_data_buffer,
                               con_info->upload_data_size);
    }
    else if (strcmp(url, "/health") == 0 && strcmp(method, "GET") == 0) {
        result = handle_health(connection);
    }
    else if (strcmp(url, "/metrics") == 0 && strcmp(method, "GET") == 0) {
        result = handle_metrics(connection);
    }
    else {
        result = send_response(connection, 404,
            "{\"error\":\"Not found\",\"available_endpoints\":[\"/enqueue (POST)\",\"/health (GET)\",\"/metrics (GET)\"]}");
    }

    // Cleanup
    if (con_info->upload_data_buffer) {
        free(con_info->upload_data_buffer);
    }
    free(con_info);
    *con_cls = NULL;

    return result;
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, char **argv) {
    // Check for no-GPU mode (Phase 1 testing)
    int arg_start = 1;
    if (argc > 1 && strcmp(argv[1], "--no-gpu") == 0) {
        no_gpu_mode = 1;
        arg_start = 2;
        fprintf(stderr, "=======================================================\n");
        fprintf(stderr, "⚠️  NO-GPU TEST MODE (Phase 1)\n");
        fprintf(stderr, "File copy instead of transcoding - testing only!\n");
        fprintf(stderr, "=======================================================\n\n");
    } else {
        fprintf(stderr, "=======================================================\n");
        fprintf(stderr, "GPU-Accelerated Transcoder - Daemon Mode\n");
        fprintf(stderr, "Target: 1000+ files/minute\n");
        fprintf(stderr, "Pipeline: NVDEC → NVENC (GPU-ONLY, NO CPU FALLBACK)\n");
        fprintf(stderr, "=======================================================\n\n");
    }

    // Record start time
    start_time = time(NULL);

    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Create output directory
    mkdir(OUTPUT_DIR, 0755);

    // Initialize systems
    queue_init(&task_queue);
    processed_init(&processed_files);

    // Check if running in batch mode or daemon mode
    int daemon_mode = 1;
    if (argc > arg_start && strcmp(argv[arg_start], "--batch") == 0) {
        daemon_mode = 0;
    }

    if (daemon_mode) {
        // ============================================================================
        // DAEMON MODE: API-based continuous queue feeding
        // ============================================================================

        fprintf(stderr, "[Main] Starting API server on port %d...\n", API_PORT);

        // Start API server
        api_daemon = MHD_start_daemon(
            MHD_USE_THREAD_PER_CONNECTION,
            API_PORT,
            NULL, NULL,
            &http_handler, NULL,
            MHD_OPTION_END
        );

        if (api_daemon == NULL) {
            fprintf(stderr, "[ERROR] Failed to start API server on port %d\n", API_PORT);
            fprintf(stderr, "[ERROR] Port may be in use. Check with: netstat -tuln | grep %d\n", API_PORT);
            return 1;
        }

        fprintf(stderr, "[Main] ✓ API server listening on http://0.0.0.0:%d\n", API_PORT);
        fprintf(stderr, "[Main]   Endpoints:\n");
        fprintf(stderr, "[Main]     POST /enqueue  - Add file to queue\n");
        fprintf(stderr, "[Main]     GET  /health   - Health check\n");
        fprintf(stderr, "[Main]     GET  /metrics  - Prometheus metrics\n\n");

        fprintf(stderr, "[Main] Starting %d worker threads...\n", MAX_WORKERS);

        // Start workers
        pthread_t workers[MAX_WORKERS];
        for (int i = 0; i < MAX_WORKERS; i++) {
            int *worker_id = malloc(sizeof(int));
            *worker_id = i;
            pthread_create(&workers[i], NULL, worker_thread, worker_id);
            usleep(50000);  // 50ms delay between thread creation for stability
        }

        fprintf(stderr, "[Main] ✓ All %d workers ready and waiting for jobs\n\n", MAX_WORKERS);
        fprintf(stderr, "[Main] Daemon running. Press Ctrl+C to stop.\n");
        fprintf(stderr, "[Main] Example: curl -X POST http://localhost:%d/enqueue -H 'Content-Type: application/json' -d '{\"filename\":\"camera_001.ts\"}'\n\n", API_PORT);

        // Stats loop - print stats every 5 seconds
        int last_processed = 0;
        int last_failed = 0;
        time_t last_stats_time = time(NULL);

        while (processing_active) {
            sleep(5);

            time_t now = time(NULL);
            int elapsed = (int)(now - last_stats_time);

            pthread_mutex_lock(&stats_mutex);
            int current_processed = files_processed;
            int current_failed = files_failed;
            int queue_depth = task_queue.count;
            pthread_mutex_unlock(&stats_mutex);

            int processed_delta = current_processed - last_processed;
            int failed_delta = current_failed - last_failed;
            double rate = elapsed > 0 ? (processed_delta / (double)elapsed) : 0.0;

            fprintf(stderr, "\r[Stats] Processed: %d (+%d) | Failed: %d (+%d) | Queue: %d | Rate: %.1f files/sec | Uptime: %ds",
                    current_processed, processed_delta,
                    current_failed, failed_delta,
                    queue_depth,
                    rate,
                    (int)(now - start_time));
            fflush(stderr);

            last_processed = current_processed;
            last_failed = current_failed;
            last_stats_time = now;
        }

        // Graceful shutdown
        fprintf(stderr, "\n\n[Main] Shutting down gracefully...\n");
        fprintf(stderr, "[Main] Stopping API server...\n");

        if (api_daemon) {
            MHD_stop_daemon(api_daemon);
            api_daemon = NULL;
        }

        fprintf(stderr, "[Main] Waiting for workers to finish current jobs...\n");

        // Wait for workers to exit
        for (int i = 0; i < MAX_WORKERS; i++) {
            pthread_join(workers[i], NULL);
        }

        fprintf(stderr, "\n===========================================\n");
        fprintf(stderr, "Daemon Shutdown Complete\n");
        fprintf(stderr, "Files Processed: %d\n", files_processed);
        fprintf(stderr, "Files Failed: %d\n", files_failed);
        fprintf(stderr, "Uptime: %d seconds\n", (int)(time(NULL) - start_time));
        fprintf(stderr, "===========================================\n");

    } else {
        // ============================================================================
        // BATCH MODE: File system scanning (legacy mode)
        // ============================================================================

        fprintf(stderr, "[Main] Running in BATCH mode (scanning %s)\n\n", INPUT_DIR);

        // Start scanner
        pthread_t scanner;
        pthread_create(&scanner, NULL, scanner_thread, NULL);
        pthread_join(scanner, NULL);

        fprintf(stderr, "\n[Main] Starting %d worker threads...\n\n", MAX_WORKERS);

        // Start workers
        pthread_t workers[MAX_WORKERS];
        for (int i = 0; i < MAX_WORKERS; i++) {
            int *worker_id = malloc(sizeof(int));
            *worker_id = i;
            pthread_create(&workers[i], NULL, worker_thread, worker_id);
            usleep(50000);
        }

        // Wait for queue to be empty (all files processed)
        while (1) {
            pthread_mutex_lock(&task_queue.mutex);
            int count = task_queue.count;
            pthread_mutex_unlock(&task_queue.mutex);
            if (count == 0) break;
            sleep(1);
        }

        // Signal workers that no more files are coming
        pthread_mutex_lock(&task_queue.mutex);
        processing_active = 0;
        pthread_cond_broadcast(&task_queue.not_empty);
        pthread_mutex_unlock(&task_queue.mutex);

        fprintf(stderr, "\n[Main] All files processed, waiting for workers to finish...\n");

        // Wait for workers to exit
        for (int i = 0; i < MAX_WORKERS; i++) {
            pthread_join(workers[i], NULL);
        }

        fprintf(stderr, "\n===========================================\n");
        fprintf(stderr, "Batch Processing Complete\n");
        fprintf(stderr, "Files Processed: %d\n", files_processed);
        fprintf(stderr, "Files Failed: %d\n", files_failed);
        fprintf(stderr, "===========================================\n");
    }

    return 0;
}
