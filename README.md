# nginx-proxy-manager + NTLM modülü

Resmi [`jc21/nginx-proxy-manager`](https://hub.docker.com/r/jc21/nginx-proxy-manager)
imajının **hiçbir dosyasını değiştirmeden** üzerine
[`gabihodoroaga/nginx-ntlm-module`](https://github.com/gabihodoroaga/nginx-ntlm-module)
dinamik modülünü ekleyen bir imaj.

Böylece IIS / Exchange / SharePoint / Azure DevOps Server gibi **Windows
Integrated Authentication (NTLM)** kullanan backend'ler NPM arkasından
proxy'lenebilir.

## Neden gerekli?

NTLM, HTTP isteği değil **TCP bağlantısı** üzerinde doğrulama yapar: doğrulanan
bağlantı kapanırsa kimlik de düşer. Standart nginx her isteği farklı bir upstream
bağlantısına yollayabildiği için sonsuz 401 döngüsü oluşur. `ntlm` direktifi,
doğrulanmış upstream bağlantısını istemciye sabitler (pin).

## Nasıl çalışır?

İki aşamalı bir `Dockerfile`:

1. **builder** — temel imajın *kendi içinden* `nginx -V` çalıştırılır, OpenResty
   sürümü otomatik tespit edilir (şu an `openresty/1.29.2.5` = nginx 1.29.2),
   aynı sürümün kaynak kodu indirilir ve modül `--with-compat` ile `.so` olarak
   derlenir.
2. **final** — temel imaj + `ngx_http_upstream_ntlm_module.so` +
   `/etc/nginx/modules/ntlm.conf` (`load_module` satırı).

NPM'in kendi `nginx.conf` dosyası zaten `include /etc/nginx/modules/*.conf;`
satırını içerdiği için NPM'in hiçbir dosyasına dokunulmaz. Sürüm yükseltmek
`NPM_VERSION` dosyasını değiştirmekten ibarettir.

İmaj derlenirken `nginx -t -c /etc/nginx/ntlm-selftest.conf` çalıştırılır; modül
yüklenmiyorsa veya `ntlm` direktifi tanınmıyorsa **build başarısız olur**, yani
bozuk imaj yayınlanmaz.

## Hızlı başlangıç

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

Yerel derleme:

```powershell
.\build.ps1                    # Windows
```

```bash
./build.sh                     # Linux / macOS
NPM_VERSION=2.14.0 ./build.sh  # başka bir NPM sürümü
```

## NTLM yapılandırması (3 adım)

### 1) Upstream tanımla

`data/nginx/custom/http_top.conf` dosyasını oluşturun (konteyner içindeki yolu
`/data/nginx/custom/http_top.conf`):

```nginx
upstream ntlm_intranet {
    server 192.168.1.50:80;
    ntlm 100;          # pinlenecek azami bağlantı sayısı (varsayılan 100)
    ntlm_timeout 60s;  # boştaki pinli bağlantının ömrü (varsayılan 60s)
}
```

Hazır örnek: [`examples/http_top.conf`](examples/http_top.conf)

### 2) NPM'i yeniden başlat

```bash
docker compose restart
```

> `http_top.conf` yalnızca nginx yeniden yüklendiğinde okunur; arayüzden bir
> host kaydetmek de reload tetikler.

### 3) Proxy Host > Advanced

İlgili Proxy Host'u açıp **Advanced** sekmesine yapıştırın:

```nginx
location / {
    proxy_pass http://ntlm_intranet$request_uri;

    proxy_http_version 1.1;
    proxy_set_header Connection "";      # NTLM için keepalive şart

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $x_forwarded_proto;

    proxy_buffer_size       16k;         # Windows auth başlıkları büyüktür
    proxy_buffers           8 16k;
    proxy_busy_buffers_size 32k;

    proxy_intercept_errors off;          # 401 yanıtları istemciye aynen gitmeli
}
```

Hazır örnekler:
[`examples/advanced-config-http.conf`](examples/advanced-config-http.conf),
[`examples/advanced-config-exchange.conf`](examples/advanced-config-exchange.conf)

**Önemli notlar**

- Advanced alanında `location /` bulunduğunda NPM kendi varsayılan location
  bloğunu üretmez; `proxy_pass` artık sizin kontrolünüzdedir. Formdaki
  *Forward Hostname/Port* alanları bu durumda kullanılmaz (yine de doldurulmalı).
- **Websockets Support** seçeneğini kapatın: NPM bu seçenekle
  `proxy_set_header Connection $http_connection;` ekler ve bu, NTLM için gereken
  `Connection ""` ayarıyla çakışır.
- Backend'de **Kerberos (Negotiate) yerine yalnızca NTLM** sağlayıcısını bırakın
  (IIS > Authentication > Windows Authentication > Providers: sadece `NTLM`).
  Kerberos, reverse proxy arkasında SPN uyuşmazlığı nedeniyle çalışmaz.
- Birden çok upstream sunucu kullanacaksanız `ip_hash` ekleyin; NTLM oturumu aynı
  sunucuda kalmalıdır.

## Doğrulama

```bash
# Modül yüklü mü?
docker exec npm-ntlm nginx -V 2>&1 | head -1
docker exec npm-ntlm cat /usr/share/nginx-ntlm/ntlm-build-info.txt

# Yapılandırma testi (ntlm direktifi tanınıyor mu?)
docker exec npm-ntlm nginx -t

# Modülün kendi kendine testi
docker exec npm-ntlm nginx -t -c /etc/nginx/ntlm-selftest.conf
```

`nginx -t` çıktısında `unknown directive "ntlm"` görüyorsanız modül
yüklenmemiştir; `docker exec npm-ntlm ls -l /usr/lib/nginx/modules/` ile `.so`
dosyasını kontrol edin.

## Yeni NPM sürümüne geçiş

```bash
echo "2.16.0" > NPM_VERSION
git commit -am "chore: jc21/nginx-proxy-manager 2.16.0" && git push
```

Push edildiğinde pipeline yeni sürümü derleyip GHCR'a `:2.16.0`, `:2.16.0-ntlm`
ve `:latest` etiketleriyle yükler.

Ayrıca `check-upstream` workflow'u her gün Docker Hub'ı kontrol eder; yeni bir
NPM sürümü çıktığında `NPM_VERSION` dosyasını güncelleyen bir **Pull Request**
açar, merge etmeniz yeterlidir.

Elle tetiklemek için: **Actions > build > Run workflow** (isteğe bağlı sürüm
numarası girilebilir).

## Pipeline (GitHub Actions → GHCR)

`.github/workflows/build.yml`

- `linux/amd64` + `linux/arm64` native runner'larda paralel derlenir (QEMU yok),
  digest'ler tek bir multi-arch manifest'te birleştirilir.
- Etiketler: `<sürüm>`, `<sürüm>-ntlm`, `latest`.
- Buildx GHA cache kullanılır; sonda imaj `docker run` ile duman testinden geçer.
- Tetikleyiciler: `main`'e push, elle çalıştırma, haftalık cron (temel imajın
  güvenlik güncellemelerini almak için).

**İlk kurulum**

1. Repo'yu GitHub'a push edin.
2. Settings > Actions > General > Workflow permissions →
   *Read and write permissions* (PR açan workflow için gerekli).
3. İlk build sonrası paket **private** olur. Herkese açık olsun isterseniz:
   GitHub profili > Packages > `npm-with-ntlm-module` > Package settings >
   *Change visibility → Public*. Private bırakırsanız sunucuda giriş gerekir:
   ```bash
   echo $GHCR_PAT | docker login ghcr.io -u halitdogmen --password-stdin
   ```
4. `arm64` derlemesi istemiyorsanız Run workflow ekranından kapatabilir veya
   `build.yml` içindeki matristen çıkarabilirsiniz.

## Build arg'ları

| Arg | Varsayılan | Açıklama |
|---|---|---|
| `NPM_IMAGE` | `jc21/nginx-proxy-manager` | Temel imaj |
| `NPM_VERSION` | `NPM_VERSION` dosyası | Temel imaj etiketi |
| `NTLM_MODULE_REPO` | `https://github.com/gabihodoroaga/nginx-ntlm-module.git` | Modül deposu |
| `NTLM_MODULE_REF` | `3da77b0c…` (son commit) | Commit / branch / tag |

Örnek — çökme (segfault) düzeltmeleri içeren fork ile derleme:

```bash
docker build \
  --build-arg NTLM_MODULE_REPO=https://github.com/BotoX/nginx-ntlm-module.git \
  --build-arg NTLM_MODULE_REF=master \
  -t npm-ntlm:botox .
```

## Uyarılar

- Modülün yazarı README'sinde **"DO NOT USE THIS IN PRODUCTION"** notunu düşüyor;
  modül 2021'den beri güncellenmiyor ve yoğun trafikte segfault raporları var
  ([issue #15](https://github.com/gabihodoroaga/nginx-ntlm-module/issues/15)).
  Kritik ortamlarda double-free ve pinleme düzeltmeleri içeren
  [`BotoX`](https://github.com/BotoX/nginx-ntlm-module) fork'unu değerlendirin.
- NTLM bağlantı pinlemesi upstream bağlantılarını meşgul tutar; `ntlm <sayı>`
  değerini eşzamanlı kullanıcı sayısına göre ayarlayın.
- Bu depo yalnızca imajı üretir; NPM jc21'e, modül gabihodoroaga'ya aittir.

## Dosya yapısı

```
Dockerfile                             # 2 aşamalı build
NPM_VERSION                            # takip edilen NPM sürümü
scripts/build-ntlm-module.sh           # sürüm tespiti + modül derleme
rootfs/etc/nginx/modules/ntlm.conf     # load_module satırı
rootfs/etc/nginx/ntlm-selftest.conf    # build sırasında doğrulama
examples/                              # http_top.conf ve Advanced örnekleri
.github/workflows/build.yml            # GHCR pipeline (multi-arch)
.github/workflows/check-upstream.yml   # yeni NPM sürümü için otomatik PR
build.ps1 / build.sh                   # yerel derleme
```
