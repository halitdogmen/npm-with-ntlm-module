#!/usr/bin/env bash
#
# jc21/nginx-proxy-manager imajının içindeki OpenResty sürümünü tespit eder,
# aynı sürümün kaynak kodunu indirir ve nginx-ntlm-module'ü dinamik modül
# (.so) olarak derler. Sonuç: /out/ngx_http_upstream_ntlm_module.so
#
# Sürüm otomatik tespit edildiği için NPM güncellendiğinde bu dosyaya
# dokunmaya gerek yoktur.
#
set -euo pipefail

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

NTLM_MODULE_REPO="${NTLM_MODULE_REPO:-https://github.com/gabihodoroaga/nginx-ntlm-module.git}"
NTLM_MODULE_REF="${NTLM_MODULE_REF:-master}"

SRC=/usr/src/ntlm-build
OUT=/out
mkdir -p "$SRC" "$OUT"

# ---------------------------------------------------------------------------
# 1. Temel imajdaki nginx / OpenResty sürümünü tespit et
# ---------------------------------------------------------------------------
log "Temel imajdaki nginx sürümü tespit ediliyor"
NGINX_V="$(nginx -V 2>&1 || true)"
echo "$NGINX_V"

OPENRESTY_VERSION="$(printf '%s\n' "$NGINX_V" | sed -n 's|^nginx version: openresty/\([0-9.]\{1,\}\).*|\1|p' | head -n1)"
NGINX_VERSION="$(printf '%s\n' "$NGINX_V"    | sed -n 's|^nginx version: nginx/\([0-9.]\{1,\}\).*|\1|p'     | head -n1)"

if [ -z "$OPENRESTY_VERSION" ] && [ -z "$NGINX_VERSION" ]; then
	echo "HATA: Temel imajdaki nginx sürümü tespit edilemedi." >&2
	exit 1
fi

# Temel imaj --with-compat ile derlenmiş olmalı, yoksa .so yüklenmez.
if ! printf '%s\n' "$NGINX_V" | grep -q -- '--with-compat'; then
	echo "HATA: Temel imajdaki nginx '--with-compat' olmadan derlenmiş." >&2
	echo "      Dinamik modül bu imaja yüklenemez." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Derleme bağımlılıkları (yalnızca builder katmanında, son imaja girmez)
# ---------------------------------------------------------------------------
log "Derleme bağımlılıkları kuruluyor"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git libssl-dev zlib1g-dev perl make patch

# PCRE paketinin adı Debian sürümüne göre değişir (trixie'de libpcre3-dev yok),
# bu yüzden ikisi de denenir, en az biri kurulmalıdır.
for optional in libpcre2-dev libpcre3-dev; do
	apt-get install -y --no-install-recommends "$optional" || true
done
if [ ! -f /usr/include/pcre2.h ] && [ ! -f /usr/include/pcre.h ]; then
	echo "HATA: PCRE geliştirme paketi (libpcre2-dev/libpcre3-dev) kurulamadı." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 3. NTLM modülünün kaynak kodu
# ---------------------------------------------------------------------------
log "NTLM modülü indiriliyor: $NTLM_MODULE_REPO @ $NTLM_MODULE_REF"
git clone --quiet "$NTLM_MODULE_REPO" "$SRC/nginx-ntlm-module"
git -C "$SRC/nginx-ntlm-module" checkout --quiet "$NTLM_MODULE_REF"
MODULE_COMMIT="$(git -C "$SRC/nginx-ntlm-module" rev-parse HEAD)"
git -C "$SRC/nginx-ntlm-module" --no-pager log -1 --format='%H %ci %s'

# ABI uyumu için temel imajla aynı olması gereken bayraklar.
# --with-compat modül imzasını (signature) uyumlu hale getirir.
CONFIGURE_ARGS=(
	--with-compat
	--with-threads
	--with-http_ssl_module
	--with-http_v2_module
	--with-stream
	--with-stream_ssl_module
	--add-dynamic-module="$SRC/nginx-ntlm-module"
)

JOBS="$(nproc)"

# ---------------------------------------------------------------------------
# 4. Kaynak kodu indir + modülü derle
# ---------------------------------------------------------------------------
if [ -n "$OPENRESTY_VERSION" ]; then
	log "OpenResty $OPENRESTY_VERSION kaynak kodu indiriliyor"
	cd "$SRC"
	if curl -fSL --retry 3 -o openresty.tar.gz \
		"https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz"; then
		tar -xzf openresty.tar.gz
		BUILD_DIR="$SRC/openresty-${OPENRESTY_VERSION}"
	else
		log "openresty.org'dan indirilemedi, GitHub etiketi deneniyor"
		curl -fSL --retry 3 -o openresty.tar.gz \
			"https://github.com/openresty/openresty/archive/refs/tags/v${OPENRESTY_VERSION}.tar.gz"
		tar -xzf openresty.tar.gz
		# GitHub arşivi hazır bundle değildir, önce toplanmalı
		( cd "$SRC/openresty-${OPENRESTY_VERSION}" && make )
		BUILD_DIR="$SRC/openresty-${OPENRESTY_VERSION}/openresty-${OPENRESTY_VERSION}"
	fi

	log "OpenResty configure çalıştırılıyor"
	cd "$BUILD_DIR"
	./configure -j"$JOBS" "${CONFIGURE_ARGS[@]}"

	NGX_BUILD_DIR="$(find "$BUILD_DIR/build" -maxdepth 1 -type d -name 'nginx-*' | head -n1)"
	log "Modül derleniyor ($NGX_BUILD_DIR)"
	if ! make -j"$JOBS" -C "$NGX_BUILD_DIR" modules; then
		log "'make modules' başarısız, tam derlemeye geçiliyor"
		cd "$BUILD_DIR"
		make -j"$JOBS"
	fi
	NGINX_CORE_VERSION="$(basename "$NGX_BUILD_DIR" | sed 's|^nginx-||')"
	BASE_DESC="openresty/${OPENRESTY_VERSION} (nginx ${NGINX_CORE_VERSION})"
else
	log "nginx $NGINX_VERSION kaynak kodu indiriliyor"
	cd "$SRC"
	curl -fSL --retry 3 -o nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
	tar -xzf nginx.tar.gz
	cd "nginx-${NGINX_VERSION}"
	./configure "${CONFIGURE_ARGS[@]}"
	make -j"$JOBS" modules
	BASE_DESC="nginx/${NGINX_VERSION}"
fi

# ---------------------------------------------------------------------------
# 5. Sonucu topla
# ---------------------------------------------------------------------------
SO="$(find "$SRC" -name 'ngx_http_upstream_ntlm_module.so' -print -quit)"
if [ -z "$SO" ]; then
	echo "HATA: ngx_http_upstream_ntlm_module.so üretilemedi." >&2
	exit 1
fi

cp "$SO" "$OUT/ngx_http_upstream_ntlm_module.so"
strip --strip-unneeded "$OUT/ngx_http_upstream_ntlm_module.so" || true
chmod 0755 "$OUT/ngx_http_upstream_ntlm_module.so"

cat > "$OUT/ntlm-build-info.txt" <<INFO
nginx-ntlm-module build info
============================
base nginx      : ${BASE_DESC}
module repo     : ${NTLM_MODULE_REPO}
module ref      : ${NTLM_MODULE_REF}
module commit   : ${MODULE_COMMIT}
architecture    : $(uname -m)
INFO

log "Tamamlandı"
ls -l "$OUT"
cat "$OUT/ntlm-build-info.txt"
