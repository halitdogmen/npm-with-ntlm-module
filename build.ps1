# Yerel derleme (Windows / Docker Desktop)
#   .\build.ps1                 -> NPM_VERSION dosyasındaki sürümle derler
#   .\build.ps1 -NpmVersion 2.15.1
param(
    [string]$NpmVersion = (Get-Content -Path "$PSScriptRoot\NPM_VERSION" -Raw).Trim(),
    [string]$Tag        = "npm-ntlm",
    [string]$NtlmRepo   = "https://github.com/gabihodoroaga/nginx-ntlm-module.git",
    [string]$NtlmRef    = "3da77b0cb30e517dfee01d7e7f7d649144d24051"
)

Write-Host "jc21/nginx-proxy-manager:$NpmVersion uzerine NTLM modulu derleniyor..." -ForegroundColor Cyan

docker build `
    --progress plain `
    --build-arg "NPM_VERSION=$NpmVersion" `
    --build-arg "NTLM_MODULE_REPO=$NtlmRepo" `
    --build-arg "NTLM_MODULE_REF=$NtlmRef" `
    -t "${Tag}:$NpmVersion" `
    -t "${Tag}:latest" `
    $PSScriptRoot

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "`nDogrulama:" -ForegroundColor Cyan
docker run --rm --entrypoint sh "${Tag}:$NpmVersion" -c "nginx -t -c /etc/nginx/ntlm-selftest.conf; cat /usr/share/nginx-ntlm/ntlm-build-info.txt"
