#!/usr/bin/env bash
# Yerel derleme (Linux / macOS)
set -euo pipefail
cd "$(dirname "$0")"

NPM_VERSION="${NPM_VERSION:-$(tr -d ' \n\r' < NPM_VERSION)}"
TAG="${TAG:-npm-ntlm}"
NTLM_MODULE_REPO="${NTLM_MODULE_REPO:-https://github.com/gabihodoroaga/nginx-ntlm-module.git}"
NTLM_MODULE_REF="${NTLM_MODULE_REF:-3da77b0cb30e517dfee01d7e7f7d649144d24051}"

echo "jc21/nginx-proxy-manager:${NPM_VERSION} üzerine NTLM modülü derleniyor..."

docker build \
	--progress plain \
	--build-arg "NPM_VERSION=${NPM_VERSION}" \
	--build-arg "NTLM_MODULE_REPO=${NTLM_MODULE_REPO}" \
	--build-arg "NTLM_MODULE_REF=${NTLM_MODULE_REF}" \
	-t "${TAG}:${NPM_VERSION}" \
	-t "${TAG}:latest" \
	.

echo
echo "Doğrulama:"
docker run --rm --entrypoint sh "${TAG}:${NPM_VERSION}" \
	-c 'nginx -t -c /etc/nginx/ntlm-selftest.conf; cat /usr/share/nginx-ntlm/ntlm-build-info.txt'
