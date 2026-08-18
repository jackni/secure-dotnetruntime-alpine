# Framework-DEPENDENT variant: Microsoft ships and patches the .NET runtime;
# this file applies the same hardening on top of their image.
#
# Use this when you want Microsoft to own runtime CVEs. Use the self-contained
# variant (self-contained.Dockerfile) when you want a framework-independent parent and
# an exactly pinned runtime. See README "Which approach should I pick?".
#
# The runtime parent from this repo is used only as a source of the hardening
# scripts - none of its packages end up in the final image.
#
#   docker build -t dotnet-runtime:alpine-3.22 .
#   docker build -f examples/framework-dependent.Dockerfile \
#     --build-arg PROJECT_FILE=App/App.csproj \
#     --build-arg APP_DLL=App.dll \
#     -t my-app:latest .
#
# Multi-arch: swap for `docker buildx build --platform linux/amd64,linux/arm64
# ... --load`. The publish output is portable IL (UseAppHost=false), so the same
# bits run on every architecture and only the runtime image differs.

ARG SCRIPTS_IMAGE=dotnet-runtime:alpine-3.22
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/runtime:10.0-alpine
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0-alpine

# Hardening scripts only - this stage contributes no packages to the final image.
FROM ${SCRIPTS_IMAGE} AS scripts

# ---------------------------------------------------------------------------
# Restore + publish, framework-dependent (no -r, no --self-contained).
# UseAppHost=false: without a RID the SDK would emit a native apphost for the
# BUILD platform, which breaks cross-arch builds. Portable IL avoids that; the
# runtime image supplies the architecture-specific host.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${SDK_IMAGE} AS build
WORKDIR /src
ARG PROJECT_FILE=App/App.csproj
ARG BUILD_CONFIGURATION=Release

COPY ${PROJECT_FILE} ${PROJECT_FILE}
RUN dotnet restore ${PROJECT_FILE}
COPY . .
RUN dotnet publish ${PROJECT_FILE} \
      -c ${BUILD_CONFIGURATION} \
      -o /app \
      --no-restore \
      /p:UseAppHost=false

# ---------------------------------------------------------------------------
# Runtime parent: Microsoft's image plus the bits it deliberately omits.
# mcr .NET Alpine images ship DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true with
# no ICU and no tzdata - that breaks MSSQL connections, culture-aware
# formatting, and TimeZoneInfo lookups. Install them before hardening removes
# apk; this is the last chance to add anything.
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS base
WORKDIR /app

ARG APP_USER=myapp
ENV APP_USER=${APP_USER} \
    APP_DIR=/app \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    DOTNET_EnableDiagnostics=0 \
    TZ=UTC

COPY --from=scripts /opt/scripts /opt/scripts
RUN apk add --no-cache icu-libs icu-data-full tzdata

# ---------------------------------------------------------------------------
# Create the non-root user and lock down /app permissions.
# ---------------------------------------------------------------------------
FROM base AS setup
COPY --from=build /app .

ARG APP_DLL=App.dll
ARG APP_USER_UID=4000
ENV APP_EXECUTABLE=${APP_DLL} \
    APP_USER_UID=${APP_USER_UID}

RUN /bin/sh /opt/scripts/setup_app.sh

# ---------------------------------------------------------------------------
# Final image: harden as the last RUN, then drop to the non-root user.
# ---------------------------------------------------------------------------
FROM base AS final
ARG APP_USER=myapp
ARG APP_USER_UID=4000

COPY --from=setup /etc/passwd /etc/passwd
COPY --from=setup /etc/group /etc/group
COPY --from=setup /etc/shadow /etc/shadow
COPY --from=setup --chown=${APP_USER}:${APP_USER} /app .

USER root
RUN chown ${APP_USER_UID}:${APP_USER_UID} ${APP_DIR} \
  && chmod 0500 ${APP_DIR} \
  && /opt/scripts/setup_security.sh \
  && rm -rf /opt/scripts \
  && rm -f /bin/busybox

USER ${APP_USER_UID}:${APP_USER_UID}

# /usr/bin/dotnet is only a symlink into /usr/share/dotnet, and the hardening
# pass clears /usr/bin. The real host at /usr/share/dotnet/dotnet survives, so
# the entrypoint must name it by absolute path.
# Keep the .dll in sync with APP_DLL - exec form cannot expand variables.
ENTRYPOINT ["/usr/share/dotnet/dotnet", "/app/App.dll"]
