#!/bin/sh -x

# exit immediately when a command fails
set -e
# exit if a single command fails in a pipeline
set -o pipefail
# exit if any variable is not set
set -u

# set the application directory if it's not set
[ -z "${APP_DIR:-}" ] \
  && APP_DIR="/app"

# set the non-root user if it's not set
[ -z "${APP_USER:-}" ] \
  && APP_USER="app_user"

# set the non-root group if it's not set
[ -z "${APP_USER_GROUP:-}" ] \
  && APP_USER_GROUP="${APP_USER}"

# set the non-root user id if it's not set
[ -z "${APP_USER_UID:-}" ] \
  && APP_USER_UID="4000"

# set the non-root group id if it's not set
[ -z "${APP_USER_GID:-}" ] \
  && APP_USER_GID="${APP_USER_UID}"

# setup running folder
# Ensure the application directory exists
mkdir -p "${APP_DIR}"

# Add a non-root user and group and transfer ownership of the app directory
addgroup -g "${APP_USER_GID:-4000}" "${APP_USER_GROUP}" \
  && adduser \
        --disabled-password \
        --gecos "" \
        --home "${APP_DIR}" \
        --ingroup "${APP_USER}" \
        --no-create-home \
        --uid "${APP_USER_UID}" \
        "${APP_USER}" \
    && chown -R "${APP_USER}" "${APP_DIR}" \
    && chmod 500 "${APP_DIR}"

# set rx to all subdirectories
find "${APP_DIR}" -type d -exec chmod 500 {} +

# Define the executable binary (aka entrypoint) for the application
if [ -z "${APP_EXECUTABLE:-}" ]; then
  echo "APP_EXECUTABLE is not set";
  exit 0; # exception
fi

# Set r to all files excluding the executable binary
find "${APP_DIR}" ! -name "${APP_EXECUTABLE}" -type f -exec chmod 400 {} +
find "${APP_DIR}"   -name "${APP_EXECUTABLE}" -type f -exec chmod 500 {} +