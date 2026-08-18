# syntax=docker/dockerfile:1.7
#
# Runtime PARENT image - packages + hardening scripts, deliberately NOT hardened.
#
# This image is an intermediate build artifact. Do NOT deploy or publish it: it
# still contains apk, busybox, and a shell. Hardening happens in the APP image,
# as the last RUN, so that each app can also delete busybox itself and end up
# with a genuinely shell-free container. See examples/self-contained.Dockerfile.
#
# "Framework-independent" = no .NET runtime here. Only the native libraries a
# self-contained (`--self-contained -r linux-musl-*`) publish links against, so
# the same parent serves .NET 8/9/10, Go, or Rust binaries.
#
# Build:
#   docker build \
#     --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
#     --build-arg REVISION="$(git rev-parse --short HEAD)" \
#     --build-arg VERSION=3.22.0 \
#     -t dotnet-runtime:alpine-3.22 .
#
# For more than one architecture, use buildx - a plain `docker build` produces a
# single-arch image and `FROM` will then fail for every other platform:
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t dotnet-runtime:alpine-3.22 --load .
#
# https://hub.docker.com/_/alpine?tab=tags
ARG BASE_IMAGE_VERSION=3.22
FROM index.docker.io/library/alpine:${BASE_IMAGE_VERSION} AS base

ARG BASE_IMAGE=dotnet-runtime
ARG BASE_IMAGE_VERSION
ARG IMAGE_VENDOR=JN-Solution
ARG BUILD_DATE
ARG REVISION
ARG VERSION
ARG APP_USER=myapp

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.description="Runtime parent image - ${BASE_IMAGE} (NOT hardened; harden in the app image)" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.title="Runtime Parent (${BASE_IMAGE}:${BASE_IMAGE_VERSION})" \
      org.opencontainers.image.vendor="${IMAGE_VENDOR}" \
      org.opencontainers.image.version="${VERSION}"

ENV \
    # Enable detection of running in a container
    DOTNET_RUNNING_IN_CONTAINER=true \
    # Set the invariant mode to false since we're installing icu-libs - required for MSSQL connection
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    \
    # Set the non-root user we'll use
    APP_USER=${APP_USER} \
    # Set the application folder
    APP_DIR=/app \
    \
    # Required for read-only rootFS: https://github.com/dotnet/docs/issues/10217
    # (COMPlus_* is the legacy spelling of the same knob; DOTNET_* is current.)
    DOTNET_EnableDiagnostics=0

COPY scripts /opt/scripts
RUN chmod +x /opt/scripts/*

# Pick up upstream package patches, then install the native deps.
RUN apk update && apk upgrade && \
    apk add --no-cache \
      ca-certificates \
      \
      # .NET Core dependencies
      libgcc \
      krb5-libs \
      \
      # For SYSTEM_GLOBALIZATION_INVARIANT required for MSSQL connection.
      # icu-data-full ships the complete CLDR set; drop it if every consumer
      # sticks to default locales - it is ~30 MB, the biggest size lever here.
      icu-libs \
      icu-data-full \
      libintl \
      libssl3 \
      libstdc++ \
      zlib \
      # Required for Time zone database lookups, when communicate with IIS on VM
      tzdata

# If we need to add a trusted custom CA, do it HERE. update-ca-certificates
# lives in /usr/sbin, which setup_security.sh deletes in the app image.
# COPY ./certs/ca-chain.crt /usr/local/share/ca-certificates/our-ca.crt
# RUN update-ca-certificates 2>/dev/null

# NOTE: setup_app.sh and setup_security.sh are intentionally NOT run here.
# The app image runs them - setup_app.sh needs APP_EXECUTABLE, and
# setup_security.sh must be the very last RUN of the final image.
