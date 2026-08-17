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

# Ensure we only use apk repositories over HTTPS (although APK contains an embedded signature)
echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/main" > /etc/apk/repositories \
  && echo "https://alpine.global.ssl.fastly.net/alpine/v$(cut -d . -f 1,2 < /etc/alpine-release)/community" >> /etc/apk/repositories

# Update base system
apk update
apk add --no-cache ca-certificates

# Remove existing crontabs, if any.
rm -rf /var/spool/cron \
  && rm -rf /etc/crontabs \
  && rm -rf /etc/periodic

# Remove all but a handful of admin commands.
find /sbin /usr/sbin \
  ! -type d \
    -a ! -name apk \
    -a ! -name ln \
  -delete

# Remove world-writeable permissions except for /tmp/
find / \
  -xdev \
  -type d \
  -a ! -path "${APP_DIR}" \
  -a -perm +0002 \
  -exec chmod o-w {} + \
  && find / \
        -xdev \
        -type f \
        -a ! -path "${APP_DIR}" \
        -a -perm +0002 \
      -exec chmod o-w {} + \
  && chmod 777 /tmp/ \
  && chown "${APP_USER}":root /tmp/

# Remove unnecessary accounts
# excluding the app user, the nobody user and root
sed -i -r "/^(${APP_USER}|root|nobody)/!d" /etc/group \
  && sed -i -r "/^(${APP_USER}|root|nobody)/!d" /etc/passwd

# Remove interactive login shell for everyone
sed -i -r 's#^(.*):[^:]*$#\1:/sbin/nologin#' /etc/passwd

# Disable login password for everyone
for username in $(cut -d ':' -f1 </etc/passwd | tr '\n' ' '); \
  do passwd -l "${username}" 2>/dev/null; done \
|| true

# Remove apk configs
find /bin /etc /lib /sbin /usr \
    -xdev \
    -type f \
    -regex '.*apk.*' \
    ! -name apk \
  -exec rm -rf {} +

# Remove temp shadow,passwd,group
find /bin /etc /lib /sbin /usr \
    -xdev \
    -type f \
    -regex '.*-$' \
  -exec rm -f {} +

# Ensure system dirs are owned by root and not writable by anybody else.
find /bin /etc /lib /sbin /usr \
    -xdev \
    -type d \
  -exec chown root:root {} + \
  -exec chmod 0755 {} +

# Remove suid & sgid files
find /bin /etc /lib /sbin /usr \
    -xdev \
    -type f \
    -a \( \
        -perm +4000 \
        -o -perm +2000 \
    \) \
  -delete

# Remove dangerous commands
find /bin /etc /lib /sbin /usr \
    -xdev \( \
        -name hexdump -o \
        -name chgrp -o \
        -name chown -o \
        -name ln -o \
        -name od -o \
        -name strings -o \
        -name su \
        -name sudo \
    \) \
  -delete

# Remove all but a handful of admin commands.
find /sbin /usr/sbin \
    ! -type d \
    -a ! -name nologin \
    -a ! -name dotnet \
  -delete

# Remove init scripts since we do not use them.
rm -rf /etc/init.d /lib/rc /etc/conf.d /etc/inittab /etc/runlevels /etc/rc.conf /etc/logrotate.d

# Remove kernel tunables
rm -rf /etc/sysctl* /etc/modprobe.d /etc/modules /etc/mdev.conf /etc/acpi

# Remove root home dir
rm -rf /root

# Remove fstab
rm -f /etc/fstab

# Remove all but a handful of executable commands
find /bin /usr/bin \
    ! -type d \
    -a ! -name busybox \
    -a ! -name cd \
    -a ! -name chmod \
    -a ! -name dir \
    -a ! -name find \
    -a ! -name ls \
    -a ! -name rm \
    -a ! -name sh \
    -a ! -name test \
    -a ! -name xargs \
  -delete

# Remove any symlinks that we broke during the previous steps
find /bin /etc /lib /sbin /usr \
    -xdev \
    -type l \
    -exec test ! -e {} \; \
  -delete


# Phase 3 - production hardening
# Remove the apk package manager binaries
find /bin /etc /lib /sbin /usr /var \
    -type f \
    -iname '*apk*' \
    -xdev \
  -delete

# Remove all related folders for apk package manager
find /bin /etc /lib /sbin /usr /var \
    -type d \
    -iname '*apk*' \
    -xdev \
  -exec rm -rf '{}' +

find /bin /etc /lib /sbin /usr \
    -xdev \
    -type l \
    -exec test ! -e {} \; \
  -delete


# Remove chmod and the shell
/usr/bin/find /bin /etc /lib /sbin /usr \
    -xdev \( \
      -name chmod \
      -name sh \
    \) \
  -delete
