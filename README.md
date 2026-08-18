# secure-dotnetruntime-alpine

Build **self-contained** app images with no package manager, no shell, and a
non-root read-only app directory.

Two pieces:

| | This repo's `Dockerfile` | Your app's Dockerfile |
| --- | --- | --- |
| Tag | yours, via `-t` | yours, via `-t` |
| Role | **intermediate parent — never deploy it** | the image you ship |
| Contains | native deps + `/opt/scripts` + apk + shell | your app, hardened |
| Hardened? | **no, on purpose** | **yes — as the last `RUN`** |

Hardening runs in the *app* image, not the parent. That ordering is what lets
the final `RUN` delete busybox as well, leaving an image with no interpreter of
any kind. A pre-hardened parent could not do this: `busybox` provides the very
`find`/`rm` that do the removal, so it cannot delete itself, and once a parent
has no shell no child can `RUN` anything.

The parent carries no .NET runtime — only the native libraries a self-contained
binary links against — so the same parent serves .NET 8/9/10, Go, or Rust, and
a framework release never rebuilds it.

Neither file hardcodes an image name. Tag the parent whatever you like, then
point the app build at it with `--build-arg RUNTIME_IMAGE=<your tag>`. The
examples below use `dotnet-runtime:alpine-3.22` because that is
`RUNTIME_IMAGE`'s default in [self-contained.Dockerfile](examples/self-contained.Dockerfile) — nothing
else depends on the name.

---

## Which approach should I pick?

Both apply the same hardening; they differ in **who supplies the .NET runtime**.

| | **A. Self-contained** | **B. Framework-dependent** |
| --- | --- | --- |
| Example | [self-contained.Dockerfile](examples/self-contained.Dockerfile) | [examples/framework-dependent.Dockerfile](examples/framework-dependent.Dockerfile) |
| Parent image | this repo's `Dockerfile` (no runtime) | `mcr…/runtime:10.0-alpine` |
| Runtime ships in | your `/app` | the base image |
| Who patches runtime CVEs | **you**, by republishing | **Microsoft**, you rebuild |
| Parent rebuilt on a .NET release | never | yes |
| One parent for Go/Rust/.NET | **yes** | no |
| Runtime version pinning | exact, immutable | follows the base tag |
| Publish output | per-architecture (musl RID) | portable IL, arch-agnostic |
| Measured size (trivial app) | 205 MB | 198 MB |
| Entrypoint | `["/app/App"]` | `["/usr/share/dotnet/dotnet", "/app/App.dll"]` |

Both produce an image with no package manager, no interpreter, `USER 4000`, and
`/app` at `0500` — verified identically (see [Verified](#verified)).

**The size difference is nearly nothing** (205 vs 198 MB) because B has to add
`icu-data-full` back — Microsoft's Alpine images ship
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true` with no ICU and no tzdata, which
silently breaks MSSQL connections, culture-aware formatting and
`TimeZoneInfo`. Do not pick between these on size.

**Pick A (self-contained) when** you want one hardened parent across several
languages, an exactly pinned runtime that no base refresh can swap, musl
specifically, or a parent that a .NET release never invalidates.

**Pick B (framework-dependent) when** you want Microsoft to own runtime CVEs,
you deploy infrequently enough that patch latency matters more than attack
surface, or your org already tracks the `mcr` images for compliance.

If you cannot rebuild and redeploy quickly, prefer **B**. The reasoning is in
[Be honest about the trade](#be-honest-about-the-trade).

## How to use it

**1. Build the runtime parent** (this repo):

```sh
docker build -t dotnet-runtime:alpine-3.22 .
```

**2. Build your app on top of it**, from your application repository:

```sh
docker build -f examples/self-contained.Dockerfile \
  --build-arg RUNTIME_IMAGE=dotnet-runtime:alpine-3.22 \
  --build-arg PROJECT_FILE=App/App.csproj \
  --build-arg APP_EXECUTABLE=App \
  -t my-app:latest .
```

Copy [self-contained.Dockerfile](examples/self-contained.Dockerfile) (approach A) or
[examples/framework-dependent.Dockerfile](examples/framework-dependent.Dockerfile)
(approach B) into your app repo and edit the final `ENTRYPOINT` to match your binary — exec form cannot expand
variables. That file is built and verified; see [Verified](#verified).

### Multi-architecture builds

Both files are arch-aware: `TARGETARCH` selects `linux-musl-x64` or
`linux-musl-arm64`, and the SDK stage is pinned to `--platform=$BUILDPLATFORM`
so the compiler runs natively on the build host and cross-publishes. Only the
small `setup`/`final` stages run under emulation on a cross build.

**The parent must exist for every platform you target.** A plain
`docker build` produces a single-arch image, and `FROM <parent>` then fails for
the other architecture. Build it with `buildx`:

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  -t dotnet-runtime:alpine-3.22 --load .
```

Then the app the same way:

```sh
docker buildx build --platform linux/amd64,linux/arm64 \
  -f examples/self-contained.Dockerfile \
  --build-arg RUNTIME_IMAGE=dotnet-runtime:alpine-3.22 \
  -t my-app:latest --load .
```

`--load` for a multi-platform image requires the containerd image store
(Docker Desktop: Settings → General → "Use containerd"). Without it, use
`--push` to a registry instead, or build one platform at a time.

Check what you got with `docker image ls --tree`, and run a non-native variant
with `docker run --platform linux/amd64 …` (needs QEMU/binfmt, which Docker
Desktop provides).

Adding an architecture means adding a case to the `TARGETARCH` switch in the
build stage; anything unlisted fails the build loudly rather than silently
producing a wrong RID.

### Build arguments

Parent (`Dockerfile`):

| Arg | Default | Purpose |
| --- | --- | --- |
| `BASE_IMAGE_VERSION` | `3.22` | Alpine tag to build on |
| `APP_USER` | `myapp` | account name the app image will create |
| `BASE_IMAGE`, `IMAGE_VENDOR`, `VERSION`, `REVISION`, `BUILD_DATE` | — | OCI label values only |

App (`examples/self-contained.Dockerfile`):

| Arg | Default | Purpose |
| --- | --- | --- |
| `RUNTIME_IMAGE` | `dotnet-runtime:alpine-3.22` | **the parent tag you built** |
| `SDK_IMAGE` | `mcr.microsoft.com/dotnet/sdk:10.0-alpine` | must be an Alpine SDK (musl RID) |
| `PROJECT_FILE` | `App/App.csproj` | path within the build context |
| `APP_EXECUTABLE` | `App` | self-contained binary name; also update `ENTRYPOINT` |
| `APP_USER` / `APP_USER_UID` | `myapp` / `4000` | non-root account and uid |
| `BUILD_CONFIGURATION` | `Release` | `dotnet publish -c` |
| `TARGETARCH` | set by BuildKit | selects `linux-musl-x64` / `-arm64` |

`ENTRYPOINT` is the one thing a build arg cannot set — exec form does not
expand variables, and there is no shell in the final image to expand them.

### Order of operations in the app image

The three stages matter, and so does their order:

1. **publish** (SDK image) — `dotnet publish --self-contained -r linux-musl-*`
2. **setup** (`FROM parent`) — copy the publish output in, then
   `RUN /opt/scripts/setup_app.sh` to create the non-root user and set
   `/app` to `0500` / payload `0400` / entrypoint `0500`.
3. **final** (`FROM parent`) — copy `/etc/passwd`, `/etc/group`, `/etc/shadow`
   and `/app` across from *setup*, then as the **last `RUN`**:

```dockerfile
RUN /opt/scripts/setup_security.sh \
  && rm -rf /opt/scripts \
  && rm -f /bin/busybox
```

Nothing may `RUN` after that line — there is no interpreter left to run it.
The chain itself completes because the executing shell keeps its own inode
alive after the file is unlinked.

**Ordering rules that bite:**

1. `setup_app.sh` **before** `setup_security.sh` — `adduser`/`addgroup` live in
   `/usr/sbin`, which the security script deletes.
2. Custom CA `COPY` + `update-ca-certificates` belong in the **parent**
   `Dockerfile` — same reason.
3. `ARG` does not cross stage boundaries. Redeclare `ARG APP_USER` in the final
   stage before using `${APP_USER}` in `COPY --chown`.
4. `ENTRYPOINT` must be **exec form** with a literal path. Shell form needs an
   interpreter, and exec form cannot expand variables.

---

## Why not just use the Microsoft runtime image?

Measured on Docker 29.7.2, linux/arm64. Size row: same trivial .NET 10
console app built both ways (`runtime:10.0-alpine` vs self-contained here).

| | `mcr…/runtime:9.0-alpine` | `mcr…/aspnet:9.0-noble-chiseled` | This approach |
| --- | --- | --- | --- |
| Default user | **root** | 1654 | 4000 (numeric) |
| Package manager | **`apk` present** | none | none |
| Shell / interpreter | `/bin/sh` + busybox | none | **none** |
| setuid/setgid files | none |
| **B. framework-dependent** ([examples/framework-dependent.Dockerfile](examples/framework-dependent.Dockerfile)) | builds; runs under the same lockdown; ICU + tzdata OK; `User 4000:4000`; passes the CI script above; 198 MB |
| dotnet host survives hardening | yes — `/usr/bin/dotnet` symlink is removed, `/usr/share/dotnet/dotnet` survives |
| non-default `--build-arg RUNTIME_IMAGE=my-own-parent:test APP_USER=svc APP_USER_UID=5000` | builds; runs as `svc`, `Config.User 5000:5000`, `/app` `dr-x------` uid 5000 |
| `buildx --platform linux/amd64,linux/arm64` on both parent and app | both variants built and run |
| `linux/amd64` variant (cross-built on an arm64 host) | `rid: linux-musl-x64`, ICU + tzdata OK, uid 4000, `/app` `dr-x------`, no setuid, no interpreter reachable |
| `linux/arm64` variant | `rid: linux-musl-arm64`, same results | none | none |
| Accounts in `/etc/passwd` | 18 | few | 3 |
| App dir writable by app | yes | yes | **no** (`0500`) |
| Trivial console app, final image | **141 MB** | ~same | **205 MB** |
| Runtime CVE fix | repull base, redeploy | repull base, redeploy | **rebuild + redeploy the app** |
| Framework coupling | tied to .NET version | tied | independent |
| libc | musl | glibc (Ubuntu) | musl |

### Be honest about the trade

**This is bigger.** Self-contained publishing duplicates the runtime into every
image: 205 MB vs 141 MB for the same trivial .NET 10 console app.

**Patching is a smaller difference than it looks.** `FROM mcr…/runtime:10.0`
resolves to a digest at build time, so when Microsoft patches that tag your
already-built app image is unchanged. **Both approaches need a rebuild and a
redeploy** to pick up a runtime CVE fix. What differs is the cost of that
rebuild: framework-dependent is a base repull plus a DLL copy, while
self-contained is a full publish against an SDK carrying the patched runtime
pack. Both ship in the same .NET release, so availability is not the gap - your
CI cadence is.

The decision rule: **if CI can rebuild and redeploy within your CVE SLA,
self-contained is fine and has the smaller attack surface. If images are built
once and left running for months, a maintained Microsoft base is safer** - not
because self-contained is weaker, but because it is likelier to go stale.

**Scanners still see the .NET runtime — but not the OS libraries.** A common
worry is that self-contained publishing hides the runtime version from
vulnerability scanning. Measured with `docker scout sbom`, it does not: the
runtime shows up as `runtimepack.Microsoft.NETCore.App.Runtime… 10.0.11`.

The real blind spot is elsewhere, and it applies to **both** approaches here:
hardening deletes the apk database, so a scanner can no longer enumerate OS
packages. Measured on the framework-dependent image:

| Image | Components a scanner reports | `.so` files actually present |
| --- | --- | --- |
| `runtime:10.0-alpine`, unhardened | 27 | — |
| Same image, after hardening | **4** | **36** |

Those 36 include `libssl.so.3`, `libcrypto.so.3`, `ld-musl` and `libicuuc.so.78`
— all still there, all still CVE-able, and now invisible. A drop from 27 to 4 is
**not** a 23-package reduction; it is mostly lost visibility. Treat any "0
vulnerabilities" result on a hardened image as unproven.

**Mitigation: scan the stage before hardening**, where the package database
still exists:

```sh
docker build --target setup -t my-app:scan .
docker scout cves my-app:scan     # or trivy / grype
docker build -t my-app:latest .   # ship the hardened one
```

Measured: `--target setup` reports 31 components including `musl`, `icu` and
`openssl`; the shipped image reports 4. Same filesystem, honest inventory.

**Microsoft's chiseled images are strong competition.** Non-root by default, no
shell, no package manager, and Microsoft patches the runtime for you. If you
are .NET-only and glibc/Ubuntu is fine, they are the simpler choice and you
should probably use them.

**Choose this approach when:**

- You want **one parent for several languages/runtimes** (.NET, Go, Rust) and a
  hardening policy you own and can audit — a .NET release never rebuilds it.
- You need **musl/Alpine** specifically; chiseled is Ubuntu/glibc only.
- You want the app **pinned to an exact runtime build**, with no chance a base
  image refresh swaps the runtime underneath it.
- Policy requires **no package manager and no interpreter** in the image, which
  rules out `runtime:*-alpine` (it ships `apk` and a shell).

## What is hardened

`scripts/setup_security.sh`, run as the last `RUN` of the app image, removes the
`apk` package manager and its databases, every setuid/setgid bit, `/usr/sbin`
(incl. `adduser`, `update-ca-certificates`), `su`/`sudo`/`chown`/`ln`/`strings`/
`hexdump`/`od`, all crontabs, init scripts, kernel tunables, `/root`,
`/etc/fstab`, non-app accounts, and login shells.

The app Dockerfile then deletes `/bin/busybox` in the same `RUN`. That is the
step that makes the image genuinely shell-free: `/bin/sh` is only a symlink to
busybox, and every remaining utility (`ls`, `find`, `rm`) is the same binary.
Removing it leaves **no interpreter at all** — verified below, every one of
`/bin/sh`, `/bin/busybox`, `/bin/ls`, `/usr/bin/find`, `/sbin/apk` fails to
exec. Only the app binary can run.

This is why hardening lives in the app image. busybox cannot delete itself
mid-script — `find` and `rm` *are* busybox — so the deletion has to be the very
last thing the image ever does.

**The cost:** you cannot `docker exec` anything, shell-form `HEALTHCHECK` will
not work, and debugging needs an ephemeral sidecar (`kubectl debug`) rather
than a shell in the container. That is the trade for a container with no
interpreter.

---

## Running it

```sh
docker run --rm \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges \
  -p 8080:8080 my-app
```

- **Non-root (uid 4000)** — cannot bind ports below 1024. Use 8080+.
- **`/app` is `0500`** — read-only, owner-only. Nothing writes there.
- **Read-only rootfs** — mount a tmpfs at `/tmp`.
- **ASP.NET Core DataProtection** has no writable key-ring location under this
  layout. Point it at a mounted volume or a shared store, otherwise keys
  regenerate on every start and auth cookies and antiforgery tokens break
  across restarts.
- **Avoid `PublishSingleFile` + `IncludeNativeLibrariesForSelfExtract`** — the
  self-extractor unpacks to `/tmp/.net` on every start, which fights read-only
  rootfs. A plain self-contained publish needs no extraction.

### Why there is no EXPOSE

`EXPOSE` publishes nothing — it writes one metadata field. Mapping is done by
`-p`, compose `ports:`, or a Kubernetes Service, and container-to-container
traffic on a user-defined network works regardless.

Its one runtime behaviour cuts against this project's goal of no hidden exposed
ports: **`docker run -P` auto-publishes every `EXPOSE`d port to `0.0.0.0` on a
random host port.** Measured:

```sh
# image with EXPOSE 8080 + EXPOSE 9999
$ docker run -d -P exp-yes && docker port <id>
8080/tcp -> 0.0.0.0:55000
9999/tcp -> 0.0.0.0:55001

# identical image, no EXPOSE
$ docker run -d -P exp-no && docker port <id>
(nothing published)
```

An ASP.NET app already declares its port authoritatively via `ASPNETCORE_URLS`
or `Kestrel__Endpoints__Http__Url`; `EXPOSE` is a second, non-binding copy that
drifts out of sync. Kubernetes and Compose ignore it entirely. The one exception:
some PaaS build systems infer the routed port from image metadata — add it back
for those images only.

---

## Size

Parent image 81.5 MB (linux/arm64 slice; 105 MB total content for a
amd64+arm64 tag — see `docker image ls --tree`). It is not hardened or flattened - it still carries apk,
busybox and `/opt/scripts`. A trivial self-contained .NET 10 app on top is
205 MB. `icu-data-full` is ~30 MB of the parent — drop it if every consumer sticks to
default locales. It is the single biggest lever.

## Checking an image in CI

Assert the **positive signal first**. A loop that only checks whether
interpreters fail to exec will report a clean image when `docker run` is broken
for an unrelated reason — no QEMU on the runner, a bad `--platform`, a missing
image — which is exactly when you least want a false pass.

```sh
#!/bin/sh
set -eu
IMG=$1; PLATFORM=${2:-linux/amd64}

# 1. positive signal: the app itself must start on this platform
docker run --rm --platform "$PLATFORM" \
  --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  "$IMG" >/dev/null || { echo "FAIL: app does not start"; exit 1; }

# 2. only now is an exec failure evidence of absence
for e in /bin/sh /bin/busybox /bin/ls /usr/bin/find /sbin/apk /usr/bin/wget; do
  if docker run --rm --platform "$PLATFORM" --entrypoint "$e" "$IMG" --help >/dev/null 2>&1; then
    echo "FAIL: $e is reachable"; exit 1
  fi
done

# 3. filesystem facts, read without a shell
id=$(docker create --platform "$PLATFORM" "$IMG")
docker export "$id" | tar -tv > /tmp/fs.txt
docker rm "$id" >/dev/null
grep -qE '^dr-x------.* app/$'        /tmp/fs.txt || { echo "FAIL: /app not 0500"; exit 1; }
grep -qE '^-..s|^-.....s'             /tmp/fs.txt && { echo "FAIL: setuid present"; exit 1; }
echo "OK"
```

Step 2's path list is a denylist, so it can go stale — an Alpine upgrade that
installs a second interpreter elsewhere would pass. Step 3's `docker export`
dump is the authoritative view if you want to assert on the whole filesystem.

## Verified

Built and run on linux/arm64, Docker 29.7.2, using
[self-contained.Dockerfile](examples/self-contained.Dockerfile) against a real `App/App.csproj`
context:

| Check | Result |
| --- | --- |
| `examples/self-contained.Dockerfile` end-to-end build | succeeds |
| App under `--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges` | runs; ICU (`de-DE` → `Januar`), tzdata, uid 4000 OK |
| `/bin/sh`, `/bin/busybox`, `/bin/ls`, `/usr/bin/find`, `/sbin/apk` | **all fail to exec — no interpreter remains** |
| `Config.User` | `4000:4000` (numeric, k8s `runAsNonRoot`-compatible) |
| `/app` | `dr-x------` uid 4000 (0500) |
| `/app/<binary>` | `-r-x------` uid 4000 (0500) |
| `/etc/passwd` | 3 accounts, all `/sbin/nologin` |
| setuid/setgid files | none |
| **B. framework-dependent** ([examples/framework-dependent.Dockerfile](examples/framework-dependent.Dockerfile)) | builds; runs under the same lockdown; ICU + tzdata OK; `User 4000:4000`; passes the CI script above; 198 MB |
| dotnet host survives hardening | yes — `/usr/bin/dotnet` symlink is removed, `/usr/share/dotnet/dotnet` survives |
| non-default `--build-arg RUNTIME_IMAGE=my-own-parent:test APP_USER=svc APP_USER_UID=5000` | builds; runs as `svc`, `Config.User 5000:5000`, `/app` `dr-x------` uid 5000 |
| `buildx --platform linux/amd64,linux/arm64` on both parent and app | both variants built and run |
| `linux/amd64` variant (cross-built on an arm64 host) | `rid: linux-musl-x64`, ICU + tzdata OK, uid 4000, `/app` `dr-x------`, no setuid, no interpreter reachable |
| `linux/arm64` variant | `rid: linux-musl-arm64`, same results |

Filesystem rows were read from the final image with `docker export` (it has no
shell to introspect with):

```sh
id=$(docker create my-app); docker export "$id" | tar -tv | grep ' app/$'
```

[examples/minimal.Dockerfile](examples/minimal.Dockerfile) was built and run
the same way and needs no application source — use it to confirm the pattern
works in your environment.
