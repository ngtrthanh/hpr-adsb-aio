#!/bin/bash
set -e

# Ensure the shared Docker network exists before any container starts
docker network create hpr-net 2>/dev/null || true

# Create multi-arch builder if not already present
docker buildx create --name hpr-fused-builder --use --platform linux/amd64,linux/arm64,linux/arm/v7 2>/dev/null || true
docker buildx inspect --bootstrap

# Build for both ARM targets and push to registry
docker buildx build --platform linux/arm/v7,linux/arm64 \
    -t ghcr.io/ngtrthanh/hpr-adsb-aio:latest --push .
