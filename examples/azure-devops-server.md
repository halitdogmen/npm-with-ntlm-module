# Azure DevOps Server (on-prem) behind NPM with NTLM

Tested layout: public `https://devops.example.com/tfs` → backend
`http://10.0.0.20:8080/tfs` (the default on-prem virtual directory).
Keeping the same `/tfs` path prefix on both sides avoids link rewriting.

## 1. Backend prerequisites (Azure DevOps Server / IIS)

- IIS > site `Azure DevOps Server` (and the `tfs` application) > Authentication >
  **Windows Authentication** enabled → Providers: **`NTLM` only**
  (remove `Negotiate`; Kerberos cannot work behind a reverse proxy because the
  SPN of the public host does not match).
- Azure DevOps Server Administration Console > Application Tier >
  **Public URL** → `https://devops.example.com/tfs`.
  Without this, redirects and generated links point at the internal host name.
- Make sure the app tier is reachable from the NPM host on port 8080/443.

## 2. `/data/nginx/custom/http_top.conf`

```nginx
# Azure DevOps Server upstream, connection-pinned for NTLM
upstream azdo_backend {
    server 10.0.0.20:8080;
    ntlm 200;          # raise for more concurrent users
    ntlm_timeout 120s;
}

# Keep NTLM keepalive ("" ) for normal requests, but still allow the
# WebSocket/SignalR upgrade the web UI uses for live updates.
map $http_upgrade $azdo_connection {
    default "";
    websocket "upgrade";
}

# NTLM type-3 tokens are large for users in many AD groups;
# the nginx default (4 8k) causes HTTP 400 "request header too large".
large_client_header_buffers 8 32k;
```

## 3. Proxy Host settings in the NPM UI

| Field | Value |
|---|---|
| Domain Names | `devops.example.com` |
| Scheme / Forward Hostname / Port | `http` / `10.0.0.20` / `8080` (unused, but required) |
| Cache Assets | **off** (authenticated content must not be cached) |
| Block Common Exploits | **off** (its rules break some Azure DevOps URLs) |
| Websockets Support | **off** (handled by the `map` above instead) |
| SSL | certificate + Force SSL + HTTP/2 as you like |

## 4. Advanced tab

```nginx
location / {
    proxy_pass http://azdo_backend$request_uri;

    proxy_http_version 1.1;
    proxy_set_header Connection $azdo_connection;   # "" or "upgrade"
    proxy_set_header Upgrade    $http_upgrade;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $x_forwarded_proto;

    # Windows auth + Azure DevOps send large headers
    proxy_buffer_size       32k;
    proxy_buffers           8 32k;
    proxy_busy_buffers_size 64k;

    # git push / artifact upload / file download
    client_max_body_size    0;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;

    # long-running calls (builds, artifact streaming, SignalR polling)
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # 401 challenges must reach the client untouched
    proxy_intercept_errors off;
}
```

If the backend uses HTTPS (`server 10.0.0.20:443;` in the upstream), change the
scheme and add:

```nginx
    proxy_pass https://azdo_backend$request_uri;
    proxy_ssl_verify        off;    # self-signed backend certificate
    proxy_ssl_server_name   on;
    proxy_ssl_session_reuse off;    # keeps NTLM pinning predictable
```

## 5. Apply and verify

```bash
docker compose restart
docker exec npm-ntlm nginx -t

# NTLM handshake: expect 401 -> 401 -> 200
curl -v --ntlm -u 'DOMAIN\user:password' \
     https://devops.example.com/tfs/_apis/connectionData
```

A successful response is JSON containing `authenticatedUser`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Endless 401 / credential prompt loop | Connection is not pinned: check `ntlm` in the upstream, `proxy_http_version 1.1` and `Connection ""` |
| `400 Request Header Or Cookie Too Large` | Raise `large_client_header_buffers` and `proxy_buffer_size` |
| Works in browser, fails for `git push` | `client_max_body_size 0;` and `proxy_request_buffering off;` |
| Redirects to the internal host name | Public URL not set in the Administration Console |
| `502` right after login | Backend offers `Negotiate`; leave only the `NTLM` provider |
| Live updates / build console stuck | The `map $http_upgrade` block is missing from `http_top.conf` |
