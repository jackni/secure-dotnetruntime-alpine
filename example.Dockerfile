# Framework-independent production image for a .NET app.
#
# The final stage sits on the hardened Alpine runtime base built from the
# sibling Dockerfile in this folder (native deps only — not a full ASP.NET
# or .NET runtime image). Publish is self-contained for linux-musl so the
# same pattern works for ASP.NET, Worker Service, and console apps.
#
# 1. Build the secure base image from this folder:
#      docker build -t dotnet-runtime:alpine-3.22 .
#
# 2. Build this file with your application repository as the context:
#      docker build -f example.Dockerfile \
#        --build-arg RUNTIME_IMAGE=dotnet-runtime:alpine-3.22 \
#        --build-arg PROJECT_FILE=App/App.csproj \
#        --build-arg APP_EXECUTABLE=App \
#        -t my-app:latest .
#
# PROJECT_FILE is relative to the Docker build context and is copied under
# /src/. Default layout: <context>/App/App.csproj
# APP_EXECUTABLE must match the self-contained binary name (usually the
# .csproj name without the extension). Also update the final ENTRYPOINT
# path — exec form cannot expand variables, and the hardened image has no shell.

ARG RUNTIME_IMAGE=dotnet-runtime:alpine-3.22
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0-alpine

# ---------------------------------------------------------------------------
# Runtime base: locally built secure Alpine image (see sibling Dockerfile).
# Ships musl-native dependencies, /opt/scripts/{setup_app,setup_security}.sh,
# and a non-root APP_USER name. Does not include the `dotnet` host.
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
FROM ${SDK_IMAGE} AS build
WORKDIR /src

ARG PROJECT_FILE=App/App.csproj
ARG BUILD_CONFIGURATION=Release
ARG RUNTIME_IDENTIFIER=linux-musl-x64

# Restore first so the NuGet layer is reused when only source changes.
# If this project has ProjectReferences, COPY those .csproj files too
# (or COPY the whole tree before restore).
COPY ${PROJECT_FILE} ${PROJECT_FILE}
RUN dotnet restore ${PROJECT_FILE}

COPY . .
RUN dotnet publish ${PROJECT_FILE} \
      -c ${BUILD_CONFIGURATION} \
      -o /app \
      -r ${RUNTIME_IDENTIFIER} \
      --self-contained true \
      --no-restore

# ---------------------------------------------------------------------------
# Create the non-root user and lock down /app permissions (setup_app.sh).
# ---------------------------------------------------------------------------
FROM base AS setup
COPY --from=build /app .

ARG APP_EXECUTABLE=App
ENV APP_EXECUTABLE=${APP_EXECUTABLE}

RUN /bin/sh /opt/scripts/setup_app.sh

# ---------------------------------------------------------------------------
# Final image: copy the locked-down user database and app, then harden
# (setup_security.sh) and drop to the non-root user. No extra packages.
# ---------------------------------------------------------------------------
FROM base AS final

COPY --from=setup /etc/passwd /etc/passwd
COPY --from=setup /etc/group /etc/group
COPY --from=setup /etc/shadow /etc/shadow

COPY --from=setup --chown=${APP_USER}:${APP_USER} /app .

USER root
RUN /opt/scripts/setup_security.sh \
  && rm -rf /opt/scripts \
  && rm -f /bin/busybox

USER ${APP_USER}
# Exec form does not expand variables, and the final image has no shell.
# Keep this path in sync with APP_EXECUTABLE (default binary name: App).
ENTRYPOINT ["/app/App"]

# Web apps only — the hardened image has no extra packages or implied ports.
# Uncomment if you are packaging an ASP.NET app:
# ENV ASPNETCORE_URLS=http://+:8080
# EXPOSE 8080
