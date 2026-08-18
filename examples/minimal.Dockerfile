# Smallest end-to-end proof of the pattern. Needs no application source - it
# generates a throwaway console app - so you can confirm the runtime parent and
# the hardening work in your environment before porting a real service.
#
#   docker build -t dotnet-runtime:alpine-3.22 .
#   docker build -f examples/minimal.Dockerfile -t base-smoke examples/
#   docker run --rm \
#     --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
#     --cap-drop ALL --security-opt no-new-privileges \
#     base-smoke
#
# Expected output:
#   rid: linux-musl-<arch>
#   icu: Januar               <- proves icu-libs + icu-data-full
#   tz:  America/New_York     <- proves tzdata
#
# Then confirm nothing can execute but the app:
#   docker run --rm --entrypoint /bin/sh      base-smoke   # must fail
#   docker run --rm --entrypoint /bin/busybox base-smoke   # must fail

ARG RUNTIME_IMAGE=dotnet-runtime:alpine-3.22
ARG SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:9.0-alpine

FROM ${RUNTIME_IMAGE} AS base
WORKDIR /app
ARG APP_USER=myapp
ENV APP_USER=${APP_USER} \
    APP_DIR=/app

# --platform=$BUILDPLATFORM keeps the SDK native to the build host, so a
# cross-arch build compiles at full speed instead of under QEMU. Only the
# published RID follows TARGETARCH - self-contained publish never has to
# execute the target binary.
FROM --platform=$BUILDPLATFORM ${SDK_IMAGE} AS build
ARG TARGETARCH
WORKDIR /src
RUN dotnet new console -o app --no-restore
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) RID=linux-musl-x64 ;; \
      arm64) RID=linux-musl-arm64 ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    printf '%s\n' \
      'using System.Globalization;' \
      'Console.WriteLine($"rid: {System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier}");' \
      'Console.WriteLine($"icu: {new CultureInfo("de-DE").DateTimeFormat.MonthNames[0]}");' \
      'Console.WriteLine($"tz:  {TimeZoneInfo.FindSystemTimeZoneById("America/New_York").Id}");' \
      > app/Program.cs; \
    dotnet publish app/app.csproj -c Release -o /app \
      --self-contained true -r "${RID}" \
      /p:PublishSingleFile=false /p:UseAppHost=true /p:InvariantGlobalization=false

# Create the non-root user and lock down /app permissions.
FROM base AS setup
COPY --from=build /app .
ARG APP_EXECUTABLE=app
# APP_USER_UID must be declared here too: setup_app.sh creates the account, and
# the final stage's USER must match it. Declaring it in only one stage silently
# creates uid 4000 but runs as something else, and /app at 0500 then denies the
# app its own binary.
ARG APP_USER_UID=4000
ENV APP_EXECUTABLE=${APP_EXECUTABLE} \
    APP_USER_UID=${APP_USER_UID}
RUN /bin/sh /opt/scripts/setup_app.sh

# Final: bring the user database and app across, then harden as the last RUN.
FROM base AS final
ARG APP_USER=myapp
ARG APP_USER_UID=4000

COPY --from=setup /etc/passwd /etc/passwd
COPY --from=setup /etc/group /etc/group
COPY --from=setup /etc/shadow /etc/shadow
COPY --from=setup --chown=${APP_USER}:${APP_USER} /app .

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
ENTRYPOINT ["/app/app"]
