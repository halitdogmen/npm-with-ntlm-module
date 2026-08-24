# syntax=docker/dockerfile:1

# =============================================================================
# jc21/nginx-proxy-manager + NTLM upstream modülü
# =============================================================================
# Resmi jc21/nginx-proxy-manager imajı hiç değiştirilmez; üzerine yalnızca
# ngx_http_upstream_ntlm_module.so ve onu yükleyen bir conf dosyası eklenir.
# Böylece yeni bir NPM sürümü çıktığında sadece NPM_VERSION değiştirilip
# yeniden derlenir.
# =============================================================================

ARG NPM_IMAGE=jc21/nginx-proxy-manager
ARG NPM_VERSION=2.15.1

# -----------------------------------------------------------------------------
# 1. Aşama: modülü temel imajın OpenResty sürümüne karşı derle
# -----------------------------------------------------------------------------
FROM ${NPM_IMAGE}:${NPM_VERSION} AS builder

# Modül kaynağı istenirse başka bir fork/commit ile değiştirilebilir
ARG NTLM_MODULE_REPO=https://github.com/gabihodoroaga/nginx-ntlm-module.git
ARG NTLM_MODULE_REF=3da77b0cb30e517dfee01d7e7f7d649144d24051

COPY --chmod=0755 scripts/build-ntlm-module.sh /tmp/build-ntlm-module.sh
RUN bash /tmp/build-ntlm-module.sh

# -----------------------------------------------------------------------------
# 2. Aşama: son imaj (temel imaj + .so + load_module)
# -----------------------------------------------------------------------------
FROM ${NPM_IMAGE}:${NPM_VERSION}

ARG NPM_VERSION
ARG NTLM_MODULE_REPO
ARG NTLM_MODULE_REF

COPY --from=builder /out/ngx_http_upstream_ntlm_module.so /usr/lib/nginx/modules/ngx_http_upstream_ntlm_module.so
COPY --from=builder /out/ntlm-build-info.txt              /usr/share/nginx-ntlm/ntlm-build-info.txt

# /etc/nginx/modules/*.conf NPM'in kendi nginx.conf'u tarafından zaten
# include edilir; NPM dosyalarına dokunmadan modülü yüklemenin doğru yolu budur.
COPY rootfs/ /

# Modül gerçekten yükleniyor mu ve "ntlm" direktifi kabul ediliyor mu?
# Hata olursa imaj derlemesi burada durur.
RUN set -eux; \
	mkdir -p /var/log/nginx; \
	nginx -t -c /etc/nginx/ntlm-selftest.conf; \
	cat /usr/share/nginx-ntlm/ntlm-build-info.txt

LABEL org.opencontainers.image.title="nginx-proxy-manager-ntlm" \
	org.opencontainers.image.description="jc21/nginx-proxy-manager ${NPM_VERSION} + ngx_http_upstream_ntlm_module" \
	org.opencontainers.image.base.name="jc21/nginx-proxy-manager:${NPM_VERSION}" \
	org.opencontainers.image.licenses="MIT" \
	io.nginxproxymanager.version="${NPM_VERSION}" \
	io.ntlm.module.repo="${NTLM_MODULE_REPO}" \
	io.ntlm.module.ref="${NTLM_MODULE_REF}"
