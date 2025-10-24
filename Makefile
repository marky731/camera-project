# GPU-Accelerated Video Transcoder Makefile - Dual RTX 5090 Edition
# FFmpeg + CUDA + NVENC/NVDEC support

CC = gcc
NVCC = /usr/local/cuda/bin/nvcc

# Target executable
TARGET = transcoder

# Source files
SOURCES = transcoder.c

# FFmpeg flags (direct linking, no pkg-config needed)
FFMPEG_CFLAGS = -I/usr/include/x86_64-linux-gnu
FFMPEG_LIBS = -lavformat -lavcodec -lavutil -lavfilter -lswresample

# CUDA flags
CUDA_CFLAGS = -I/usr/local/cuda/include
CUDA_LIBS = -L/usr/local/cuda/lib64 -lcudart -lcuda

# Compiler flags
CFLAGS = -O3 -Wall -pthread $(FFMPEG_CFLAGS) $(CUDA_CFLAGS)
LDFLAGS = $(FFMPEG_LIBS) $(CUDA_LIBS) -pthread -lm -lmicrohttpd -lcurl -lcjson

# Build rules
all: $(TARGET)

$(TARGET): $(SOURCES)
	@echo "Building GPU-accelerated transcoder (Dual RTX 5090)..."
	$(CC) $(CFLAGS) -o $(TARGET) $(SOURCES) $(LDFLAGS)
	@echo "Build complete: ./$(TARGET)"

clean:
	@echo "Cleaning build artifacts..."
	rm -f $(TARGET) test_nvcodec
	@echo "Clean complete"

test: $(TARGET)
	@echo "Starting transcoder test (dual GPU)..."
	@echo "Clearing output directory..."
	@rm -f output/*.ts
	@export CUDA_VISIBLE_DEVICES=0,1 && time ./$(TARGET)

monitor:
	@echo "Dual GPU monitoring (Ctrl+C to stop)..."
	nvidia-smi dmon -s pucvmet -i 0,1

monitor-single:
	@echo "Single GPU monitoring - GPU 0 (Ctrl+C to stop)..."
	nvidia-smi dmon -s pucvmet -i 0

benchmark: $(TARGET)
	@echo "Running performance benchmark (dual GPU)..."
	@rm -f output/*.ts
	@export CUDA_VISIBLE_DEVICES=0,1 && time ./$(TARGET)

env-check:
	@echo "Running environment check..."
	@./check_environment.sh

help:
	@echo "GPU-Accelerated Transcoder Build System - Dual RTX 5090"
	@echo ""
	@echo "Targets:"
	@echo "  all           - Build transcoder (default)"
	@echo "  clean         - Remove build artifacts"
	@echo "  test          - Build and run transcoder with dual GPUs"
	@echo "  monitor       - Monitor dual GPU utilization"
	@echo "  monitor-single- Monitor single GPU (GPU 0)"
	@echo "  benchmark     - Run with time measurement"
	@echo "  env-check     - Check environment requirements"
	@echo "  help          - Show this help message"

.PHONY: all clean test monitor monitor-single benchmark env-check help
