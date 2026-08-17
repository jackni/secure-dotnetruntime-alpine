# https://hub.docker.com/_/alpine?tab=tags
ARG BASE_IMAGE_VERSION=3.22
FROM index.docker.io/library/alpine:${BASE_IMAGE_VERSION} as base
ARG BASE_IMAGE=dotnet-runtime
ARG BASE_IMAGE_VERSION
ARG IMAGE_VENDOR=JN-Solution
ARG BUILD_DATE
ARG REVISION
ARG VERSION
ARG APP_USER=myapp

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.description="Base image - ${BASE_IMAGE}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.title="Base Image (${BASE_IMAGE}:${BASE_IMAGE_VERSION})" \
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
    COMPlus_EnableDiagnostics=0

COPY scripts /opt/scripts

RUN chmod +x /opt/scripts/*

RUN apk add --no-cache \
      ca-certificates \
      \
      # .NET Core dependencies
      libgcc \
      krb5-libs \
      \
      # For SYSTEM_GLOBALIZATION_INVARIANT required for MSSQL connection
      icu-libs \
      libintl \
      libssl3 \
      libstdc++ \
      zlib \
      # Required for Time zone database lookups, when communicate with IIS on VM
      tzdata
      

# patch package. this will make sure that we can pick up, upstream package patch
 RUN apk update && \
      apk upgrade

# if we need to add Trusted custom CA for ourselves, use script below
# COPY ./certs/ca-chain.crt /usr/local/share/ca-certificates/our-ca.crt
# RUN update-ca-certificates 2>/dev/null
