# nginx-proxy-manager + NTLM module

A drop-in image that adds the
[`gabihodoroaga/nginx-ntlm-module`](https://github.com/gabihodoroaga/nginx-ntlm-module)
dynamic module on top of the official
[`jc21/nginx-proxy-manager`](https://hub.docker.com/r/jc21/nginx-proxy-manager)
image — **without modifying a single NPM file**.

This lets you reverse-proxy backends that use **Windows Integrated
Authentication (NTLM)**: IIS, Exchange / OWA, SharePoint, Azure DevOps Server,
and similar.

## Why it is needed

NTLM authenticates the **TCP connection**, not the individual HTTP request: once
the authenticated connection is closed, the identity is gone. Stock nginx may
send each request over a different upstream connection, which results in an
endless 401 loop. The `ntlm` directive pins the authenticated upstream
connection to the client.

## How it works

A two-stage `Dockerfile`:

1. **builder** — runs `nginx -V` *inside the base image itself*, auto-detects the
   OpenResty version (currently `openresty/1.29.2.5` = nginx 1.29.2), downloads
   the matching source and compiles the module with `--with-compat` into a `.so`.
2. **final** — base image + `ngx_http_upstream_ntlm_module.so` +
   `/etc/nginx/modules/ntlm.conf` (the `load_module` line).

NPM's own `nginx.conf` already contains `include /etc/nginx/modules/*.conf;`, so
no NPM file is patched or replaced. Upgrading NPM is just a matter of changing
the `NPM_VERSION` file.

During the build, `nginx -t -c /etc/nginx/ntlm-selftest.conf` is executed — if
the module fails to load or the `ntlm` directive is not recognised, **the build
fails**, so a broken image is never published.

## Quick start

```yaml
# docker-compose.yml
services:
  npm-ntlm:
    image: ghcr.io/halitdogmen/npm-with-ntlm-module:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
```

```bash
docker compose up -d
```

Available tags: `latest`, `<npm-version>` (e.g. `2.15.1`) and
`<npm-version>-ntlm`. All of them point to the same multi-arch manifest
(`linux/amd64` + `linux/arm64`).

Building locally:

```powershell
.\build.ps1                    # Windows
```

```bash
./build.sh                     # Linux / macOS
NPM_VERSION=2.14.0 ./build.sh  # a different NPM version
```

## NTLM configuration (3 steps)

### 1) Define the upstream

Create `data/nginx/custom/http_top.conf` (inside the container:
`/data/nginx/custom/http_top.conf`):

```nginx
upstream ntlm_intranet {
    server 192.168.1.50:80;
    ntlm 100;          # max number of pinned connections (default 100)
    ntlm_timeout 60s;  # idle lifetime of a pinned connection (default 60s)
}
```

Ready-made example: [`examples/http_top.conf`](examples/http_top.conf)

### 2) Restart NPM

```bash
docker compose restart
```

> `http_top.conf` is only read when nginx reloads; saving any host from the UI
> also triggers a reload.

### 3) Proxy Host > Advanced

Open the proxy host and paste this into the **Advanced** tab:

```nginx
location / {
    proxy_pass http://ntlm_intranet$request_uri;

    proxy_http_version 1.1;
    proxy_set_header Connection "";      # keepalive is mandatory for NTLM

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $x_forwarded_proto;

    proxy_buffer_size       16k;         # Windows auth headers are large
    proxy_buffers           8 16k;
    proxy_busy_buffers_size 32k;

    proxy_intercept_errors off;          # 401 responses must reach the client
}
```

Ready-made examples:
[`examples/advanced-config-http.conf`](examples/advanced-config-http.conf),
[`examples/advanced-config-exchange.conf`](examples/advanced-config-exchange.conf)

**Important notes**

- When the Advanced tab contains a `location /` block, NPM skips generating its
  own default location — `proxy_pass` is now yours to control. The form's
  *Forward Hostname/Port* fields are then unused (they are still required, so
  fill them in with the same values).
- Turn **Websockets Support** off: with that option NPM emits
  `proxy_set_header Connection $http_connection;`, which conflicts with the
  `Connection ""` that NTLM requires.
- On the backend, keep **only the NTLM provider** (IIS > Authentication >
  Windows Authentication > Providers: `NTLM` only). Kerberos does not work
  behind a reverse proxy because of the SPN mismatch.
- If you use more than one upstream server, add `ip_hash`: an NTLM session must
  stay on the same server.

## Verification

```bash
# Is the module loaded?
docker exec npm-ntlm nginx -V 2>&1 | head -1
docker exec npm-ntlm cat /usr/share/nginx-ntlm/ntlm-build-info.txt

# Config test (is the ntlm directive recognised?)
docker exec npm-ntlm nginx -t

# The module's own self-test
docker exec npm-ntlm nginx -t -c /etc/nginx/ntlm-selftest.conf
```

If `nginx -t` reports `unknown directive "ntlm"`, the module was not loaded —
check the `.so` with `docker exec npm-ntlm ls -l /usr/lib/nginx/modules/`.

## Moving to a new NPM version

```bash
echo "2.16.0" > NPM_VERSION
git commit -am "chore: jc21/nginx-proxy-manager 2.16.0" && git push
```

On push the pipeline rebuilds against the new base image and publishes
`:2.16.0`, `:2.16.0-ntlm` and `:latest` to GHCR.

In addition, the `check-upstream` workflow checks Docker Hub daily and opens a
**pull request** updating `NPM_VERSION` whenever jc21 releases a new version —
just merge it.

Manual trigger: **Actions > build > Run workflow** (an explicit version can be
supplied).

## Pipeline (GitHub Actions → GHCR)

`.github/workflows/build.yml`

- `linux/amd64` and `linux/arm64` are built in parallel on native runners (no
  QEMU); the digests are merged into a single multi-arch manifest.
- Tags: `<version>`, `<version>-ntlm`, `latest`.
- Buildx GHA cache is used; the merged image is finally smoke-tested with
  `docker run`.
- Triggers: push to `main`, manual dispatch, and a weekly cron (to pick up
  security updates in the base image).

**First-time setup**

1. Push the repository to GitHub.
2. Settings > Actions > General > Workflow permissions →
   *Read and write permissions* (needed by the PR-opening workflow).
3. Because the repository is public, the package can be pulled anonymously
   (verified). If the repository is private the package is private too, and the
   server needs to log in:
   ```bash
   echo $GHCR_PAT | docker login ghcr.io -u halitdogmen --password-stdin
   ```
   Visibility can be changed under GitHub profile > Packages >
   `npm-with-ntlm-module` > Package settings > *Change visibility*.
4. If you do not want the `arm64` build, disable it in the Run workflow dialog
   or remove it from the matrix in `build.yml`.

## Build arguments

| Arg | Default | Description |
|---|---|---|
| `NPM_IMAGE` | `jc21/nginx-proxy-manager` | Base image |
| `NPM_VERSION` | contents of `NPM_VERSION` | Base image tag |
| `NTLM_MODULE_REPO` | `https://github.com/gabihodoroaga/nginx-ntlm-module.git` | Module repository |
| `NTLM_MODULE_REF` | `3da77b0c…` (latest commit) | Commit / branch / tag |

Example — build against the fork that carries the crash fixes:

```bash
docker build \
  --build-arg NTLM_MODULE_REPO=https://github.com/BotoX/nginx-ntlm-module.git \
  --build-arg NTLM_MODULE_REF=master \
  -t npm-ntlm:botox .
```

## Caveats

- The module's author states **"DO NOT USE THIS IN PRODUCTION"** in the upstream
  README; the module has not been updated since 2021 and there are segfault
  reports under load
  ([issue #15](https://github.com/gabihodoroaga/nginx-ntlm-module/issues/15)).
  For critical environments consider the
  [`BotoX`](https://github.com/BotoX/nginx-ntlm-module) fork, which contains
  double-free and connection-pinning fixes.
- Connection pinning keeps upstream connections busy; size `ntlm <number>`
  according to your concurrent user count.
- This repository only builds the image. NPM belongs to jc21, the module to
  gabihodoroaga.

## Tested with

| Item | Result |
|---|---|
| Module build, `openresty/1.29.2.5` (nginx 1.29.2) | amd64 + arm64 |
| `nginx -t` with a real `ntlm` upstream | passes |
| `nginx -T` shows `ntlm 100; ntlm_timeout 60s;` | yes |
| Live traffic through the pinned upstream | 5/5 HTTP 200 |
| Requests carrying `Authorization: NTLM` / `Negotiate` | 200, no worker crash |
| NPM admin UI (port 81) | HTTP 200 |

## Repository layout

```
Dockerfile                             # two-stage build
NPM_VERSION                            # tracked NPM version
scripts/build-ntlm-module.sh           # version detection + module compilation
rootfs/etc/nginx/modules/ntlm.conf     # load_module line
rootfs/etc/nginx/ntlm-selftest.conf    # build-time verification
examples/                              # http_top.conf and Advanced tab snippets
.github/workflows/build.yml            # GHCR pipeline (multi-arch)
.github/workflows/check-upstream.yml   # auto PR for new NPM releases
build.ps1 / build.sh                   # local builds
```
