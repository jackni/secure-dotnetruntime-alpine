# Framework-independent production image for a .NET app.
#
# The final stage sits on the runtime PARENT image built from the sibling
# Dockerfile in this folder (native deps only - not a full ASP.NET or .NET
# runtime image). Publish is self-contained for linux-musl so the same pattern
# works for ASP.NET, Worker Service, and console apps.
#
# Hardening runs HERE, not in the parent, as the last RUN of the final stage.
# That is what lets us delete busybox too and end up with no shell at all.
#
# 1. Build the runtime parent image from this folder:
#      docker build -t dotnet-runtime:alpine-3.22 .
#
#    For multi-arch, build BOTH here and below with buildx - the parent must
#    exist for every platform this file targets:
#      docker buildx build --platform linux/amd64,linux/arm64 \
#        -t dotnet-runtime:alpine-3.22 --load .
#
# 2. Build this file with your application repository as the context:
#      docker build -f examples/self-contained.Dockerfile \
#        --build-arg RUNTIME_IMAGE=dotnet-runtime:alpine-3.22 \
#        --build-arg PROJECT_FILE=App/App.csproj \
#        --build-arg APP_EXECUTABLE=App \
#        -t my-app:latest .
#
#    Multi-arch: swap `docker build` for `docker buildx build --platform
#    linux/amd64,linux/arm64 ... --load` (needs the containerd image store;
#    otherwise --push to a registry).
#
# PROJECT_FILE is relative to the Docker build context and is copied under
# /src/. Default layout: <context>/App/App.csproj
# APP_EXECUTABLE must match the self-contained binary name (usually the
# .csproj name without the extension). Also update the final ENTRYPOINT
# path - exec form cannot expand variables, and the final image has no shell.

ARG RUNTIME_IMAGE=dotnet-runtime:alpine-3.22
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0-alpine

# ---------------------------------------------------------------------------
# Runtime parent: locally built Alpine image (see sibling Dockerfile).
# Ships musl-native dependencies, /opt/scripts/{setup_app,setup_security}.sh,
# a shell and apk. Does not include the `dotnet` host, and is NOT yet hardened.
# ---------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS base
WORKDIR /app

# Override to match --build-arg; default aligns with the sibling Dockerfile.
ARG APP_USER=myapp
ENV APP_USER=${APP_USER} \
    APP_DIR=/app

# ---------------------------------------------------------------------------
# Restore + publish (SDK). Alpine SDK matches the musl RID used below.
# ---------------------------------------------------------------------------
# --platform=$BUILDPLATFORM keeps the SDK native to the build host, so a
# cross-arch build compiles at full speed instead of under QEMU. Only the
# published RID follows TARGETARCH - self-contained publish never has to
# execute the target binary.
FROM --platform=$BUILDPLATFORM ${SDK_IMAGE} AS build
WORKDIR /src

ARG PROJECT_FILE=App/App.csproj
ARG BUILD_CONFIGURATION=Release
# Resolved from the build platform so the image works on x64 and arm64 hosts.
ARG TARGETARCH

# Restore first so the NuGet layer is reused when only source changes.
# If this project has ProjectReferences, COPY those .csproj files too
# (or COPY the whole tree before restore).
COPY ${PROJECT_FILE} ${PROJECT_FILE}
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) RID=linux-musl-x64 ;; \
      arm64) RID=linux-musl-arm64 ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    echo "${RID}" > /tmp/rid; \
    dotnet restore ${PROJECT_FILE} -r "${RID}"

COPY . .
# PublishSingleFile is deliberately off: the self-extractor unpacks native libs
# to /tmp/.net on every start, which fights a read-only root filesystem.
RUN set -eu; \
    dotnet publish ${PROJECT_FILE} \
      -c ${BUILD_CONFIGURATION} \
      -o /app \
      -r "$(cat /tmp/rid)" \
      --self-contained true \
      --no-restore \
      /p:PublishSingleFile=false \
      /p:UseAppHost=true

# ---------------------------------------------------------------------------
# Create the non-root user and lock down /app permissions (setup_app.sh).
# ---------------------------------------------------------------------------
FROM base AS setup
COPY --from=build /app .

ARG APP_EXECUTABLE=App
# APP_USER_UID must be declared here too: setup_app.sh creates the account, and
# the final stage's USER must match it. Declaring it in only one stage silently
# creates uid 4000 but runs as something else, and /app at 0500 then denies the
# app its own binary.
ARG APP_USER_UID=4000
ENV APP_EXECUTABLE=${APP_EXECUTABLE} \
    APP_USER_UID=${APP_USER_UID}

RUN /bin/sh /opt/scripts/setup_app.sh

# ---------------------------------------------------------------------------
# Final image: copy the locked-down user database and app, then harden
# (setup_security.sh) and drop to the non-root user. No extra packages.
# ---------------------------------------------------------------------------
FROM base AS final

# ARG does not cross stage boundaries - redeclare before using it here.
ARG APP_USER=myapp
# Numeric uid for USER below: Kubernetes `runAsNonRoot` refuses to start a
# container whose image declares a non-numeric user, because it cannot resolve
# the name to prove it is not root. Keep in sync with APP_USER_UID in
# scripts/setup_app.sh (default 4000).
ARG APP_USER_UID=4000

COPY --from=setup /etc/passwd /etc/passwd
COPY --from=setup /etc/group /etc/group
COPY --from=setup /etc/shadow /etc/shadow

COPY --from=setup --chown=${APP_USER}:${APP_USER} /app .

# Must be the last RUN in the image. setup_security.sh strips the package
# manager, setuid bits, /usr/sbin and /bin/sh; deleting busybox afterwards
# removes the last interpreter, so nothing in here can execute but the app.
# The running shell keeps its own inode alive, so this chain completes.
USER root
# WORKDIR created /app as root:root 0755 before the COPY above, and COPY only
# sets ownership of what it copies - not of the destination directory. Fix the
# directory itself here, while chmod/chown still exist (setup_security.sh
# deletes chown early and chmod last).
RUN chown ${APP_USER_UID}:${APP_USER_UID} ${APP_DIR} \
  && chmod 0500 ${APP_DIR} \
  && /opt/scripts/setup_security.sh \
  && rm -rf /opt/scripts \
  && rm -f /bin/busybox

USER ${APP_USER_UID}:${APP_USER_UID}
# Exec form does not expand variables, and the final image has no shell.
# Keep this path in sync with APP_EXECUTABLE (default binary name: App).
ENTRYPOINT ["/app/App"]

# For ASP.NET apps, set the listen port explicitly (uid is non-root, so use
# >= 1024). No EXPOSE - see README "Why there is no EXPOSE".
# ENV ASPNETCORE_URLS=http://+:8080
