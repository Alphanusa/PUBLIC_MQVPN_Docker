# mqvpn Server untuk Docker Compose & Dokploy

Deployment **production-ready** untuk server [mqvpn](https://github.com/mp0rta/mqvpn)
(Multipath QUIC VPN, MASQUE CONNECT-IP / RFC 9484) di VPS Ubuntu, agar ponsel
Android dapat **menggabungkan Wi-Fi dan 4G/5G sekaligus** (bandwidth aggregation
+ failover) dan keluar ke internet lewat IP VPS.

```
 Android (app mqvpn)                                 VPS (Docker, network_mode: host)
 ┌──────────────────┐   Path A: Wi-Fi  ── UDP ──┐   ┌──────────────────────────────────────┐
 │ TUN  10.70.0.x   │                           ├──▶│ mqvpn server (uid mqvpn)  UDP :443   │
 │ Multipath QUIC   │   Path B: 4G/5G  ── UDP ──┘   │   └─ TUN mqvpn0 10.70.0.1            │
 └──────────────────┘                               │ iptables: MQVPN-FWD / MQVPN-NAT      │
                                                    │   10.70.0.0/24 ─MASQUERADE─▶ eth0 ──▶ Internet
                                                    └──────────────────────────────────────┘
```

- Versi mqvpn di-*pin* (default **v0.19.2**, rilis terbaru saat ini) dan diverifikasi
  dengan SHA-256 (rilis resmi) atau hash commit (build dari source).
- `linux/amd64` dan `linux/arm64`.
- Tanpa systemd, tanpa image pihak ketiga: base image `ubuntu:24.04` (di-pin digest)
  + binary resmi dari GitHub Releases.
- Kredensial dibuat sekali, disimpan di volume, tidak pernah ditampilkan di log.
- Firewall memakai chain khusus yang idempotent dan dibersihkan saat container berhenti.

---

## Daftar isi

1. [Isi repositori](#isi-repositori)
2. [Cara kerja (hasil studi upstream)](#cara-kerja-hasil-studi-upstream)
3. [Prasyarat](#prasyarat)
4. [Deploy dengan Dokploy](#deploy-dengan-dokploy)
5. [Deploy tanpa Dokploy (Docker Compose CLI)](#deploy-tanpa-dokploy-docker-compose-cli)
6. [Konflik port UDP 443 dengan Traefik Dokploy](#konflik-port-udp-443-dengan-traefik-dokploy)
7. [Membuka port di firewall VPS](#membuka-port-di-firewall-vps)
8. [Konfigurasi (.env)](#konfigurasi-env)
9. [Konfigurasi aplikasi Android](#konfigurasi-aplikasi-android)
10. [Memverifikasi Wi-Fi + data seluler dipakai bersamaan](#memverifikasi-wi-fi--data-seluler-dipakai-bersamaan)
11. [Sertifikat TLS](#sertifikat-tls)
12. [Keamanan](#keamanan)
13. [Operasional sehari-hari](#operasional-sehari-hari)
14. [Upgrade dan rollback](#upgrade-dan-rollback)
15. [Troubleshooting](#troubleshooting)
16. [Pengujian](#pengujian)
17. [Lisensi](#lisensi)

---

## Isi repositori

| File | Fungsi |
|---|---|
| `compose.yaml` | Service Docker Compose (kompatibel Dokploy): host network, `/dev/net/tun`, capability minimal, healthcheck, volume persisten. |
| `Dockerfile` | Multi-stage. `release` (default): unduh tarball rilis resmi per arsitektur + verifikasi SHA-256. `source`: build tag yang di-pin dari source (BoringSSL → xquic → mqvpn) persis seperti workflow rilis upstream. |
| `.env.example` | Semua konfigurasi beserta default dan penjelasannya. |
| `scripts/entrypoint.sh` | Pengganti systemd unit + `mqvpn-server-setup` + `mqvpn-server-nat.sh` upstream: validasi env, kredensial, render config, firewall, menjalankan & mengawasi mqvpn, cleanup. |
| `scripts/firewall.sh` | `mqvpn-firewall setup\|teardown\|check\|status` — NAT/forwarding di chain khusus. |
| `scripts/healthcheck.sh` | `mqvpn-healthcheck` — health check yang benar-benar menguji layanan. |
| `scripts/info.sh` | `mqvpn-info [--show-key]` — data koneksi untuk Android. |
| `scripts/paths.sh` | `mqvpn-paths [--watch N] [--json]` — status setiap path (Wi-Fi/seluler) per klien. |
| `scripts/common.sh` | Fungsi bersama. |
| `tests/e2e-multipath.sh` | Uji end-to-end otomatis (klien Linux dua jalur, throughput, failover, persistensi, cleanup). |
| `tls/` | Titik mount opsional untuk sertifikat (kosong secara default). |

---

## Cara kerja (hasil studi upstream)

Hal-hal berikut diverifikasi dari source code upstream tag `v0.19.2`
(`src/main.c`, `src/config.c`, `src/platform/linux/*`, `scripts/mqvpn-server-*.sh`,
`systemd/mqvpn-server.service.in`, aplikasi `android/`), bukan diasumsikan:

| Aspek | Implementasi upstream | Di container ini |
|---|---|---|
| Menjalankan server | `mqvpn --config /etc/mqvpn/server.conf` (systemd `Type=simple`). Mode server disimpulkan dari `[Interface] Listen`. | `mqvpn --config /run/mqvpn/server.conf`, dijalankan oleh entrypoint (tanpa systemd). |
| Format config | INI (`[Interface] [TLS] [Auth] [Multipath] [Hybrid] [Reorder] [Control]`) atau JSON. Tidak ada komentar inline. | INI dirender dari `.env` setiap start, divalidasi dengan parser upstream (`mqvpn-nat-config`). |
| Auth key | `mqvpn --genkey` = 32 byte acak, base64. `[Auth] Key` (global) dan `User = nama:key`. | Dibuat sekali di volume (`/etc/mqvpn/auth.key`, `users/<nama>.key`), mode 0600. |
| TLS | Installer membuat self-signed EC P-256; klien perlu `--insecure` / "Trust self-signed certificate". Untuk sertifikat tepercaya pakai *full chain*. | Sama (validitas 10 tahun), atau sertifikat sendiri via env. |
| TUN | Server membuat TUN `mqvpn0` sendiri (ioctl `TUNSETIFF`, butuh `CAP_NET_ADMIN`), alamat `.1` dari subnet. Jika gagal membuat TUN, server **tetap berjalan tanpa TUN** (hanya log error). | `/dev/net/tun` + `NET_ADMIN`; entrypoint memeriksa TUN benar-benar ada, jika tidak → restart. |
| NAT | `mqvpn-server-nat.sh` (ExecStartPre/ExecStopPost): `ip_forward=1`, `MASQUERADE` ke interface default (`ip route get`), `FORWARD` ACCEPT; IPv6 forwarding + NAT66. | `mqvpn-firewall` dengan pendekatan sama tetapi di chain khusus, idempotent, dan menghormati backend iptables host. |
| sysctl | Server menulis `net.ipv4.conf.mqvpn0.accept_local=1` (agar ICMP error / PMTU sampai). | `/proc/sys` read-only di container → host `/proc/sys/net` di-mount ke `/host/proc/sys/net`, entrypoint yang menulis. |
| Port | Default `0.0.0.0:443/udp`. Socket tunggal IPv4 *atau* IPv6. | `MQVPN_PORT` (default 443), `MQVPN_LISTEN_ADDR`. |
| Control API | TCP JSON tanpa autentikasi, opsional (`[Control] Listen`). `mqvpn --status` memakainya. | Aktif di `127.0.0.1:19090` (loopback host saja) untuk healthcheck, watchdog, `mqvpn-paths`. |
| Hybrid / Reorder | Opsi sisi server; aktif hanya bagi klien yang juga mengaktifkannya. Installer upstream menyalakan keduanya + `AllowClientScheduler`. | Default sama (`MQVPN_HYBRID=true`, `MQVPN_REORDER=true`). |
| Android | Field: *Server address* (`host[:port]`, default port 443), *Access key*, *Trust self-signed certificate*; memakai Wi-Fi dan Cellular via `requestNetwork` + `bindSocket`. | Didokumentasikan di bawah. |

Installer resmi (`install.sh`/paket deb) **tidak** dipakai: ia bergantung pada
systemd, debconf, dan menulis ke `/etc` host.

Binary rilis hanya membutuhkan `libevent-2.1-7`, `libstdc++`, dan glibc ≥ 2.34
(xquic dan BoringSSL di-link statis), sehingga runtime image cukup kecil.

---

## Prasyarat

- VPS Linux (Ubuntu 22.04/24.04 direkomendasikan) dengan **IPv4 publik**, amd64 atau arm64.
- Docker Engine ≥ 24 (BuildKit, default sejak Docker 23) dan Docker Compose v2.
  Dokploy sudah memasang keduanya.
- Modul kernel `tun` (ada di hampir semua VPS; cek `ls -l /dev/net/tun`).
- Port **UDP** yang bisa dibuka dari internet (lihat [konflik port](#konflik-port-udp-443-dengan-traefik-dokploy)).
- VPS berbasis OpenVZ/LXC lama sering tidak menyediakan TUN — gunakan KVM.

---

## Deploy dengan Dokploy

1. **Buat service.** Dokploy → *Projects* → pilih/buat project → *Create Service* →
   **Compose** (tipe *Docker Compose*, bukan *Stack*).
2. **Sumber.** Pilih *Git*/*GitHub* dan arahkan ke repositori ini (branch Anda),
   *Compose Path* = `./compose.yaml`.
   (Alternatif *Raw*: tempel `compose.yaml` tidak cukup, karena image dibangun dari
   `Dockerfile` + `scripts/` — gunakan sumber Git.)
3. **Environment.** Tab *Environment* → tempel isi `.env.example` lalu ubah seperlunya.
   Minimal di server Dokploy:
   ```dotenv
   MQVPN_PORT=8443          # UDP 443 dipakai Traefik Dokploy (HTTP/3), lihat bagian konflik port
   MQVPN_PUBLIC_HOST=203.0.113.10   # IP publik / nama DNS VPS (opsional, untuk ringkasan)
   ```
   Dokploy menulis nilai ini ke file `.env` di samping `compose.yaml` dan
   meng-interpolasikannya ke `compose.yaml`.
4. **Jangan** menambahkan *Domain* ke service ini dan biarkan **Isolated Deployment = OFF**.
   Keduanya menambahkan `networks:` ke service, yang tidak bisa digabung dengan
   `network_mode: host`. Traefik tidak dibutuhkan (Traefik tidak bisa mem-proxy VPN UDP/QUIC ini;
   server menerima UDP langsung di IP host).
5. Biarkan opsi *Pull images* nonaktif (image dibangun lokal; `pull_policy: build`).
6. Klik **Deploy**. Build pertama ±1–2 menit (`MQVPN_BUILD_METHOD=release`).
7. Buka port UDP di firewall VPS/cloud ([lihat di bawah](#membuka-port-di-firewall-vps)).
8. Lihat tab *Logs*. Jika sukses:
   ```
   [entrypoint] INFO: mqvpn 0.19.2 server is up
   [entrypoint] INFO:   Android 'Server address' : 203.0.113.10:8443  (UDP 8443 must be open ...)
   [entrypoint] INFO:   Android 'Access key'     : not logged; run 'mqvpn-info --show-key' in the container terminal
   [entrypoint] INFO:   TLS                      : self-signed -> turn ON 'Trust self-signed certificate' in the app
   ```
   Status container akan menjadi **healthy**.
9. Ambil access key: tab *Terminal* service (atau SSH ke VPS) lalu jalankan
   ```bash
   mqvpn-info --show-key
   ```
   Dari SSH: `docker exec -it $(docker ps -qf name=mqvpn) mqvpn-info --show-key`.

**Redeploy** tidak memerlukan langkah manual apa pun: config dirender ulang dari
*Environment*, sedangkan auth key, sertifikat, dan prefix IPv6 tetap tersimpan di
volume bernama `<appName>_mqvpn-data` (nama project = `appName` Dokploy, sehingga
volume yang sama dipakai di setiap redeploy). Klien tidak perlu dikonfigurasi ulang.

> Menghapus service beserta volumenya di Dokploy akan menghapus key dan sertifikat.
> Semua klien lalu membutuhkan key baru. Lihat [backup](#backup-dan-restore).

---

## Deploy tanpa Dokploy (Docker Compose CLI)

```bash
git clone <repo-ini> mqvpn-docker
```
```bash
cd mqvpn-docker
```
```bash
cp .env.example .env
```
```bash
nano .env
```
```bash
docker compose up -d --build
```
```bash
docker compose logs -f
```
```bash
docker compose exec mqvpn mqvpn-info --show-key
```

Validasi file tanpa menjalankan: `docker compose config`.

---

## Konflik port UDP 443 dengan Traefik Dokploy

Traefik milik Dokploy mem-*publish* **UDP 443** (HTTP/3) di host (`dokploy-traefik`,
`TRAEFIK_HTTP3_PORT`). Karena mqvpn juga memakai UDP, keduanya tidak bisa berbagi
port tersebut. Entrypoint mendeteksinya dan berhenti dengan pesan jelas:

```
ERROR: UDP port 443 is already in use on this host (0.0.0.0:443 ). On Dokploy hosts Traefik publishes UDP 443 for HTTP/3: set MQVPN_PORT ...
```
atau, bila userland-proxy Docker dimatikan:
```
ERROR: a Docker container publishes UDP port 443 (DNAT rule in the nat table) and would capture the VPN traffic. ...
```

Pilihan:

1. **Direkomendasikan:** pakai port lain, mis. `MQVPN_PORT=8443` (atau 4433, 10443).
   Di Android tulis `IP:8443`. Port 443/UDP hanya penting jika jaringan klien memblokir
   port lain; sebagian besar jaringan seluler/Wi-Fi tidak.
2. Bebaskan UDP 443 dari Traefik (HTTP/3 situs Dokploy dipindah/dimatikan). Dokploy membaca
   `TRAEFIK_HTTP3_PORT` dari environment service Dokploy saat membuat ulang Traefik; ubah
   ke port lain lalu *Reload/Recreate Traefik* dari menu *Web Server*. Ini mengubah
   infrastruktur Dokploy — lakukan hanya bila Anda paham konsekuensinya (tidak diuji di sini).
3. Server tanpa Dokploy/Traefik: default 443 langsung bekerja.

Port **TCP** 443 (HTTPS Traefik) tidak bentrok; mqvpn hanya memakai UDP.

---

## Membuka port di firewall VPS

mqvpn memakai **UDP** pada `MQVPN_PORT`. Container memakai jaringan host, jadi
**aturan INPUT host berlaku** (berbeda dengan port yang di-publish Docker).

- **Firewall cloud provider** (Security Group AWS/GCP/Azure, Hetzner Cloud Firewall,
  DigitalOcean Cloud Firewall, Vultr, dsb.): tambahkan *inbound* `UDP <MQVPN_PORT>` dari `0.0.0.0/0`
  (dan `::/0` bila memakai IPv6).
- **UFW** (Ubuntu):
  ```bash
  sudo ufw allow 8443/udp comment 'mqvpn'
  ```
  Ganti `8443` dengan `MQVPN_PORT`. Atau set `MQVPN_FIREWALL_OPEN_PORT=true`: container
  menambahkan satu aturan ACCEPT untuk port itu di chain `MQVPN-IN-<tun>` dan
  menghapusnya saat berhenti (firewall cloud tetap perlu dibuka manual).
- Jangan menutup SSH Anda sendiri: container tidak pernah mengubah policy atau aturan lain.

Forwarding: UFW (`DEFAULT_FORWARD_POLICY="DROP"`) dan Docker (policy `FORWARD DROP`)
tidak perlu diubah — chain `MQVPN-FWD-<tun>` yang dipasang di posisi pertama `FORWARD`
hanya meloloskan trafik dari/ke TUN mqvpn.

### Aturan firewall yang dipasang

```
-A FORWARD -j MQVPN-FWD-mqvpn0                     # satu-satunya perubahan di chain bawaan
-A MQVPN-FWD-mqvpn0 -d 10.70.0.0/24 -o mqvpn0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A MQVPN-FWD-mqvpn0 -s 10.70.0.0/24 -d 10.70.0.0/24 -i mqvpn0 -o mqvpn0 -j ACCEPT
-A MQVPN-FWD-mqvpn0 -d 10.0.0.0/8 -i mqvpn0 -j DROP       # ... dan rentang privat lain
-A MQVPN-FWD-mqvpn0 -s 10.70.0.0/24 -i mqvpn0 -j ACCEPT
-A MQVPN-FWD-mqvpn0 -i mqvpn0 -j DROP
-A MQVPN-FWD-mqvpn0 -o mqvpn0 -j DROP
-t nat -A POSTROUTING -j MQVPN-NAT-mqvpn0
-t nat -A MQVPN-NAT-mqvpn0 -s 10.70.0.0/24 -o eth0 -j MASQUERADE
```
Lihat aturan aktif: `mqvpn-firewall status`.

- **Idempotent:** setiap start, chain di-flush lalu diisi ulang dan jump dijamin tepat satu.
- **Self-healing:** watchdog (tiap 30 dtk) memasang ulang bila aturan hilang
  (mis. `ufw reload`, `firewall-cmd --reload`, `iptables -F`) dan memperbarui NAT bila
  interface default berubah.
- **Cleanup:** saat container berhenti (`docker stop`, redeploy, `compose down`), semua chain
  `MQVPN-*-<tun>` dihapus dan sysctl yang diubah container dikembalikan.
- **Backend iptables** host (nf_tables atau legacy) dideteksi otomatis
  (`MQVPN_IPTABLES_BACKEND=auto`), karena aturan harus berada di backend yang sama dengan
  policy `FORWARD DROP` milik Docker/UFW.
- Jika container dibunuh paksa (SIGKILL/OOM/host crash), aturan lama dibersihkan pada start
  berikutnya. Untuk menghapusnya tanpa menjalankan server:
  `docker compose run --rm mqvpn mqvpn-firewall teardown`.

---

## Konfigurasi (.env)

Semua variabel opsional. Perubahan berlaku pada deploy/restart berikutnya; kredensial
tidak dibuat ulang.

| Variabel | Default | Keterangan |
|---|---|---|
| `MQVPN_VERSION` | `0.19.2` | Versi mqvpn (build arg). |
| `MQVPN_SHA256_AMD64` / `MQVPN_SHA256_ARM64` | hash v0.19.2 | SHA-256 tarball rilis, dari `SHA256SUMS` rilis. Build gagal bila tidak cocok. |
| `MQVPN_BUILD_METHOD` | `release` | `release` (binary resmi) atau `source` (compile tag). |
| `MQVPN_GIT_COMMIT` | commit `v0.19.2` | Diverifikasi saat `source`. |
| `MQVPN_PORT` | `443` | Port UDP VPN. |
| `MQVPN_LISTEN_ADDR` | `0.0.0.0` | Alamat bind (`::` untuk IPv6 saja; upstream memakai satu socket per family). |
| `MQVPN_PUBLIC_HOST` | auto | IP/DNS publik untuk ringkasan & CN/SAN sertifikat self-signed baru. |
| `MQVPN_SUBNET` | `10.70.0.0/24` | Pool IPv4 klien (/16–/30). Dicek tidak tumpang-tindih dengan jaringan host. |
| `MQVPN_SUBNET6` | `auto` | `auto` (aktif jika host punya IPv6 internet; ULA /112 acak dibuat sekali), `off`, atau prefix /96–/126. |
| `MQVPN_TUN_NAME` | `mqvpn0` | Nama TUN (≤15 karakter). Ubah hanya untuk >1 instance per host. |
| `MQVPN_MTU` | auto | MTU TUN 1280–9000 (auto ≈ 1382). |
| `MQVPN_MAX_CLIENTS` | `64` | Batas klien bersamaan. |
| `MQVPN_LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error`. |
| `MQVPN_AUTH_KEY` | kosong | Kosong = dibuat otomatis & disimpan di volume (disarankan). Isi hanya untuk memakai key lama. |
| `MQVPN_GLOBAL_KEY` | `true` | `false` = hanya key per pengguna yang diterima. |
| `MQVPN_USERS` | kosong | Nama perangkat, mis. `hp-andi,laptop`; key per nama dibuat sekali. Menghapus nama = mencabut akses. |
| `MQVPN_TLS_HOST_DIR` | `./tls` | Direktori host yang di-mount read-only ke `/etc/mqvpn-tls`. |
| `MQVPN_TLS_CERT_FILE` / `MQVPN_TLS_KEY_FILE` | kosong | Path *di dalam container* ke full chain & private key. Kosong = self-signed. |
| `MQVPN_SCHEDULER` | `wlb` | `wlb`, `minrtt`, `wlb_udp_pin`, `backup_fec`. |
| `MQVPN_ALLOW_CLIENT_SCHEDULER` | `true` | Klien boleh memilih scheduler unduhannya sendiri. |
| `MQVPN_CC` | `bbr2` | `bbr2`, `bbr`, `cubic`. |
| `MQVPN_REINJECTION` | `off` | `off`, `deadline`, `idle` (duplikasi spekulatif server→klien). |
| `MQVPN_HYBRID` | `true` | Tawarkan *hybrid TCP lane* (satu koneksi TCP bisa memakai semua path). |
| `MQVPN_REORDER` | `true` | Tawarkan reorder buffer untuk datagram. |
| `MQVPN_CONTROL_PORT` | `19090` | Control API di `127.0.0.1` host. `0` = nonaktif (healthcheck tanpa uji event loop, `mqvpn-paths` tidak tersedia). |
| `MQVPN_NAT_INTERFACE` | `auto` | Interface keluar untuk MASQUERADE: `auto` (rute default), `any`, atau nama interface. |
| `MQVPN_BLOCK_PRIVATE_NETWORKS` | `true` | Blokir akses klien ke RFC1918, CGNAT, link-local (metadata cloud), container Docker internal. |
| `MQVPN_FIREWALL_OPEN_PORT` | `false` | Tambah ACCEPT UDP port di INPUT (berguna dengan UFW). |
| `MQVPN_IPTABLES_BACKEND` | `auto` | `auto`, `nft`, `legacy`. |
| `MQVPN_SKIP_SUBNET_CHECK` | `false` | Lewati cek tumpang-tindih subnet. |

### Opsi lanjutan upstream

Opsi yang tidak punya variabel (mis. `[Hybrid] TcpMaxFlows`, `[ReorderRule]`,
`[Advanced]`, `[Hybrid] EgressAllow`) bisa ditulis di
`/etc/mqvpn/server.extra.conf` (di dalam volume); isinya ditambahkan ke akhir
config dan divalidasi parser upstream saat start:

```bash
docker compose exec mqvpn sh -c 'printf "[Hybrid]\nTcpMaxFlows = 512\n" > /etc/mqvpn/server.extra.conf'
```
```bash
docker compose restart mqvpn
```
`Listen`, `Subnet`, `Subnet6`, `TunName`, dan `[Control]` harus diatur lewat `.env`
(entrypoint menolak bila diubah di file ini, karena firewall bergantung padanya).
Referensi kunci: <https://docs.mqvpn.org/guide/configuration>.

---

## Konfigurasi aplikasi Android

1. **Pasang aplikasi resmi** *mqvpn* (`org.mqvpn.app`, Android 8.0+) dari
   [Google Play](https://play.google.com/store/apps/details?id=org.mqvpn.app),
   [F-Droid](https://f-droid.org/packages/org.mqvpn.app/), atau APK di
   [GitHub Releases](https://github.com/mp0rta/mqvpn/releases). Status upstream: eksperimental.
2. Ambil data koneksi di server: `mqvpn-info --show-key`.
3. Buka aplikasi → **Get Started** → layar *Connect to your server*:

   | Field | Isi |
   |---|---|
   | **Server address** | `IP_VPS:PORT`, mis. `203.0.113.10:8443`. Tanpa `:port` aplikasi memakai 443. IPv6: `[2001:db8::1]:8443`. Dengan sertifikat tepercaya isi nama DNS-nya, mis. `vpn.example.com:8443`. |
   | **Access key** | Key dari `mqvpn-info --show-key` (global, atau key per pengguna dari `MQVPN_USERS`). Salin persis, termasuk `=` di akhir. |
   | **Trust self-signed certificate** | **ON** jika server memakai sertifikat self-signed (default). **OFF** jika memakai sertifikat tepercaya (Let's Encrypt). |

4. Layar *Your connections*: set **Wi‑Fi = Use** dan **Cellular = Use**.
5. Tekan **Connect** dan izinkan permintaan VPN Android.
6. Opsional di **Settings → Advanced**:
   - **Carry TCP over its own lane** (hybrid TCP lane): agar *satu* unduhan/stream TCP
     memakai Wi-Fi + seluler sekaligus. Server sudah menawarkannya (`MQVPN_HYBRID=true`).
   - **Smooth out packet order** (reorder buffer): untuk trafik UDP/QUIC (video, game)
     pada jalur dengan latensi berbeda (`MQVPN_REORDER=true`).
   - **How traffic is split**: pilihan scheduler klien (butuh `MQVPN_ALLOW_CLIENT_SCHEDULER=true`).
   - **Kill switch**: aktifkan bila VPS **tidak** punya IPv6 (log server menulis
     `IPv6 disabled`). Tanpa IPv6 di tunnel, Android mengirim trafik IPv6 langsung lewat
     Wi-Fi/seluler (tidak di-bonding). Dengan kill switch, IPv6 ditahan sehingga aplikasi
     memakai IPv4 melalui VPN.
   - *TLS server name*: hanya perlu bila *Server address* berupa IP tetapi sertifikat
     tepercaya dibuat untuk nama DNS.

Trafik Android keluar ke internet melalui VPS: DNS default aplikasi (`8.8.8.8`,
`1.1.1.1`) dan semua trafik IPv4 (dan IPv6 bila aktif) di-NAT oleh server
(`MQVPN-NAT-<tun>`). Cek di browser ponsel: buka situs "what is my IP" → harus
menampilkan IP VPS.

---

## Memverifikasi Wi-Fi + data seluler dipakai bersamaan

**Di ponsel**

- Layar **Home** menampilkan kartu Wi‑Fi dan Cellular masing-masing dengan laju unduhnya,
  serta teks *"Using X of Y connections"*: Y = path yang aktif, X = path yang sedang
  mengunduh > 1 Mbit/s. Saat speed test/unduhan besar, **"Using 2 of 2 connections"**
  berarti Wi-Fi dan seluler benar-benar dipakai bersamaan.
- Layar **Paths**/**Stats** menunjukkan throughput, latensi, dan loss per path.
  Ikon aktivitas data seluler Android juga bergerak walau Wi-Fi tersambung.

**Di server** (paling objektif, dari control API server):

```bash
docker compose exec mqvpn mqvpn-paths --watch 2
```
Contoh keluaran nyata dari uji di repositori ini (klien dengan dua jalur yang masing-masing
dibatasi 20 Mbit/s, sedang mengunduh):
```
client (global)  endpoint 172.30.102.2:60116  connected 24s  scheduler wlb
  total: 106.8 MiB down, 925.2 KiB up, 2 path(s), 2 active
  path state                 srtt    down total  up total    down now        up now          lost
  0    active                81ms    54.3 MiB    454.7 KiB   19.35 Mbit/s    0.19 Mbit/s     0
  1    active                6ms     52.5 MiB    470.5 KiB   15.26 Mbit/s    0.11 Mbit/s     0
```
- Dua baris path dengan state `active` = ponsel terhubung lewat dua jaringan.
- Kolom `down now` kedua path > 0 saat mengunduh = keduanya dipakai bersamaan.
- *down* = server → ponsel, *up* = ponsel → server.

**Uji failover:** saat mengunduh, matikan Wi-Fi di ponsel. Unduhan berlanjut lewat
seluler; `mqvpn-paths` menunjukkan satu path tidak lagi aktif. Nyalakan kembali →
path kembali `active`.

**Uji agregasi:** bandingkan speed test dengan hanya satu jaringan (*Paths* → set satu
ke *Off*) vs keduanya. Untuk satu koneksi TCP (mis. satu unduhan), aktifkan *Carry TCP
over its own lane*; tanpa itu agregasi paling terlihat pada banyak koneksi paralel.

---

## Sertifikat TLS

**Self-signed (default).** Dibuat sekali (EC P-256, 10 tahun) di
`/etc/mqvpn/tls/` dalam volume. Di Android aktifkan *Trust self-signed certificate*.
Catatan keamanan: dengan opsi itu klien tidak memverifikasi identitas server, sehingga
penyerang aktif di jaringan klien secara teori dapat melakukan MITM dan mencuri access
key. Untuk produksi gunakan sertifikat tepercaya.

**Sertifikat tepercaya (mis. Let's Encrypt).** Port 80 umumnya dipakai Traefik, jadi
gunakan *DNS-01 challenge* certbot di host (atau salin sertifikat dari tempat lain), lalu:

```dotenv
MQVPN_PUBLIC_HOST=vpn.example.com
MQVPN_TLS_HOST_DIR=/etc/letsencrypt
MQVPN_TLS_CERT_FILE=/etc/mqvpn-tls/live/vpn.example.com/fullchain.pem
MQVPN_TLS_KEY_FILE=/etc/mqvpn-tls/live/vpn.example.com/privkey.pem
```

- Wajib *full chain* (`fullchain.pem`): klien tidak mengambil intermediate yang hilang.
- Seluruh `/etc/letsencrypt` di-mount (symlink `live/` → `archive/` tetap valid).
- Entrypoint memvalidasi pasangan cert/key dan memperingatkan bila kedaluwarsa < 14 hari.
- mqvpn hanya membaca sertifikat saat start: restart container setelah perpanjangan,
  mis. hook certbot `--deploy-hook 'docker restart <nama-container>'`.
- Di Android: *Server address* `vpn.example.com:PORT`, *Trust self-signed* **OFF**.
- Untuk membuat ulang self-signed (mis. setelah ganti `MQVPN_PUBLIC_HOST`): hapus
  `/etc/mqvpn/tls/server.crt` dan `server.key` di volume lalu restart.

---

## Keamanan

- **Least privilege.** `cap_drop: ALL` + hanya `NET_ADMIN, NET_RAW, NET_BIND_SERVICE,
  SETUID, SETGID, CHOWN, KILL` untuk entrypoint. Proses `mqvpn` sendiri berjalan sebagai
  user `mqvpn` (bukan root) dengan **hanya** `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`
  (ambient capability, `no_new_privs`). Root filesystem read-only, `/run` dan `/tmp` tmpfs,
  `no-new-privileges`. Tidak `privileged`.
- **Rahasia.** Auth key dibuat dengan `mqvpn --genkey` (32 byte dari `/dev/urandom`),
  file 0600 di volume, config ber-key di tmpfs 0640 (root:mqvpn). Key tidak pernah ditulis
  ke log, `state.env`, maupun environment container (kecuali Anda sendiri mengisi
  `MQVPN_AUTH_KEY`). `mqvpn-info` menyamarkan key kecuali dengan `--show-key`.
- **Isolasi jaringan.** Klien VPN hanya boleh ke internet: rentang privat, CGNAT,
  link-local (termasuk metadata cloud `169.254.169.254`), multicast, dan container Docker
  internal diblokir (`MQVPN_BLOCK_PRIVATE_NETWORKS=true`), selaras dengan daftar
  default-deny hybrid lane upstream. Koneksi masuk tak diminta ke klien ditolak.
- **Control API** tidak berautentikasi (desain upstream), hanya di `127.0.0.1` host.
  Proses lain di host (atau container ber-`network_mode: host`) dapat mengaksesnya.
  Setel `MQVPN_CONTROL_PORT=0` bila itu tidak dapat diterima.
- **Mount `/proc/sys/net`** memberi akses tulis sysctl jaringan host; menulisnya tetap
  memerlukan `CAP_NET_ADMIN`, yang memang dimiliki container. Bisa dihapus dari
  `compose.yaml` jika `net.ipv4.ip_forward=1` (Docker sudah menyetelnya) dan Anda menerima
  peringatan `accept_local` (ICMP/PMTU untuk trafik yang diteruskan akan dibuang).
- **Supply chain.** Base image di-pin digest; binary mqvpn diverifikasi SHA-256
  (`ADD --checksum`) atau hash commit Git. Rilis upstream juga punya attestation:
  `gh attestation verify mqvpn_<VER>_<ARCH>.tar.gz --owner mp0rta`.
- **Per-user key** (`MQVPN_USERS`) memungkinkan pencabutan akses satu perangkat tanpa
  mengganti key semua perangkat.

---

## Operasional sehari-hari

| Perintah (di dalam container) | Fungsi |
|---|---|
| `mqvpn-info` / `mqvpn-info --show-key` | Data koneksi Android/CLI. |
| `mqvpn-paths [--watch 2]` | Klien terhubung dan status setiap path. |
| `mqvpn --status --control-port 19090` | Status bawaan upstream. |
| `mqvpn-healthcheck` | Jalankan health check manual. |
| `mqvpn-firewall status` | Aturan iptables aktif. |

Dari host: `docker compose exec mqvpn <perintah>` (CLI) atau tab *Terminal* (Dokploy).

**Health check** (`docker ps` → `healthy`) lolos hanya jika: proses mqvpn berjalan,
TUN ada dan UP, ada socket UDP di port VPN, control API menjawab (`get_stats` +
`get_status`, membuktikan event loop yang juga melayani socket VPN responsif), dan aturan
NAT/forwarding terpasang.

**Watchdog** entrypoint (tiap 30 dtk): memasang ulang aturan firewall yang hilang,
memperbarui NAT bila interface default berubah, dan me-restart container bila TUN hilang
atau control API tidak menjawab 3× berturut-turut (Docker Compose biasa tidak
me-restart container yang *unhealthy*, jadi watchdog yang melakukannya). Crash mqvpn →
container keluar non-zero → `restart: unless-stopped` menjalankannya lagi.

**Rotasi key global:** hapus `/etc/mqvpn/auth.key` lalu restart → key baru (semua klien
yang memakai key global perlu diperbarui). **Cabut satu perangkat:** hapus namanya dari
`MQVPN_USERS` dan redeploy (opsional hapus `/etc/mqvpn/users/<nama>.key`).

### Backup dan restore

Isi volume kecil (key, sertifikat, prefix IPv6):
```bash
docker run --rm -v <project>_mqvpn-data:/data -v "$PWD":/backup ubuntu:24.04 tar czf /backup/mqvpn-data.tgz -C /data .
```
```bash
docker run --rm -v <project>_mqvpn-data:/data -v "$PWD":/backup ubuntu:24.04 tar xzf /backup/mqvpn-data.tgz -C /data
```
Simpan backup di tempat aman (berisi private key dan auth key).

---

## Upgrade dan rollback

1. Lihat rilis baru di <https://github.com/mp0rta/mqvpn/releases> dan baca catatan rilisnya.
2. Ambil hash dari file `SHA256SUMS` rilis tersebut:
   ```bash
   curl -fsSL https://github.com/mp0rta/mqvpn/releases/download/v0.20.0/SHA256SUMS | grep -E '_(amd64|arm64)\.tar\.gz$'
   ```
   (ganti `0.20.0` dengan versi baru).
3. Ubah di *Environment* Dokploy / `.env`:
   ```dotenv
   MQVPN_VERSION=0.20.0
   MQVPN_SHA256_AMD64=<hash mqvpn_0.20.0_amd64.tar.gz>
   MQVPN_SHA256_ARM64=<hash mqvpn_0.20.0_arm64.tar.gz>
   # hanya untuk MQVPN_BUILD_METHOD=source:
   MQVPN_GIT_COMMIT=<hash commit tag v0.20.0>   # git ls-remote https://github.com/mp0rta/mqvpn refs/tags/v0.20.0
   ```
4. **Deploy** (Dokploy) atau `docker compose up -d --build`. Build gagal bila hash tidak
   cocok atau versi binary tidak sesuai `MQVPN_VERSION`. Key, sertifikat, dan subnet tetap.
5. Periksa log (`server is up`), `healthy`, dan koneksi Android.
6. **Rollback:** kembalikan tiga variabel ke nilai sebelumnya lalu deploy ulang.

Catatan upgrade: baca perubahan opsi config di catatan rilis; entrypoint memakai format
INI yang stabil (`[Interface]/[TLS]/[Auth]/...`). Base image Ubuntu diperbarui dengan
mengganti digest `BASE_IMAGE` di `Dockerfile` (`docker buildx imagetools inspect ubuntu:24.04`).

---

## Troubleshooting

| Gejala | Penyebab & solusi |
|---|---|
| Log: `UDP port 443 is already in use` / `publishes UDP port 443` | Traefik Dokploy (HTTP/3) atau layanan lain memakai port itu. Set `MQVPN_PORT=8443` (lihat [konflik port](#konflik-port-udp-443-dengan-traefik-dokploy)). |
| Android tidak bisa connect (timeout) | Port UDP belum dibuka di firewall cloud / UFW; *Server address* salah port; IP publik berbeda (VPS di balik NAT 1:1 → pakai IP publik). Uji dari luar: `nc -vzu IP PORT` tidak andal untuk UDP — cek counter: `iptables -L MQVPN-IN-mqvpn0 -v` (dengan `MQVPN_FIREWALL_OPEN_PORT=true`) atau `tcpdump -ni any udp port PORT`. |
| Connect gagal, log klien soal sertifikat | Server self-signed tetapi *Trust self-signed certificate* OFF, atau sertifikat tepercaya tidak cocok dengan nama di *Server address* (isi *TLS server name*). |
| Connect lalu langsung putus / "auth" | Access key salah (salin ulang dengan `mqvpn-info --show-key`), atau nama pengguna dihapus dari `MQVPN_USERS`. |
| Terhubung tetapi tidak ada internet | `mqvpn-firewall status` (aturan ada?); `cat /proc/sys/net/ipv4/ip_forward` = 1; `MQVPN_NAT_INTERFACE` benar (`auto` mengikuti rute default; host multi-uplink → `any`). Host dengan **firewalld** (backend nftables) memiliki chain forward sendiri yang menolak trafik: izinkan zona/interface `mqvpn0` (`firewall-cmd --zone=trusted --add-interface=mqvpn0 --permanent`) dan masquerade. |
| Situs tertentu "hang" (MTU/PMTU) | Pastikan mount `/proc/sys/net` ada (log: `set net.ipv4.conf.mqvpn0.accept_local=1`). Coba `MQVPN_MTU=1280`. |
| Peringatan `cannot set accept_local` dari mqvpn | Normal di container; entrypoint yang menyetelnya sesaat kemudian (lihat baris `INFO: set ... accept_local=1`). |
| Hanya satu path aktif | Di aplikasi: *Paths* → Cellular = *Use*; data seluler aktif; hemat data/baterai yang membatasi data latar belakang dinonaktifkan untuk mqvpn. Beberapa ROM butuh *Developer options → Mobile data always active* = ON. Kuota/APN seluler habis juga membuat path seluler gagal. |
| Satu unduhan tidak lebih cepat | Aktifkan *Carry TCP over its own lane* (hybrid) di aplikasi. Agregasi juga dibatasi oleh jalur terlambat; lihat `mqvpn-paths --watch 2`. |
| IPv6 bocor/tidak lewat VPN | `IPv6 disabled (...)` di log: VPS tanpa IPv6 → aktifkan *Kill switch* di Android, atau beri VPS IPv6. |
| `MQVPN_SUBNET ... overlaps` | Subnet bentrok dengan jaringan host (mis. private network Hetzner 10.0.0.0/16, bridge Docker). Pilih rentang lain, mis. `10.71.0.0/24`. |
| `/dev/net/tun is missing` | Host tanpa modul tun: `sudo modprobe tun` (permanen: `echo tun | sudo tee /etc/modules-load.d/tun.conf`). VPS OpenVZ/LXC mungkin tidak mendukung TUN. |
| `network interface mqvpn0 already exists` | Instance lain (container lain atau paket deb `mqvpn-server` via systemd) masih berjalan. Hentikan atau set `MQVPN_TUN_NAME` + `MQVPN_PORT` berbeda. |
| Aturan iptables tidak berefek (host legacy) | Host memakai `iptables-legacy` tetapi deteksi salah → set `MQVPN_IPTABLES_BACKEND=legacy` (atau `nft`). |
| Container *unhealthy* | `docker inspect --format '{{json .State.Health}}' <container>` menampilkan alasannya (satu baris, tanpa rahasia). |
| Dokploy: error "network_mode ... networks" | Matikan *Isolated Deployment* dan hapus domain dari service ini. |
| `Error setting rlimit` saat start | Hapus `ulimits` yang Anda tambahkan; entrypoint sudah menaikkan batas file terbuka ke hard limit. |

Log detail: `MQVPN_LOG_LEVEL=debug`.

---

## Pengujian

Yang **dijalankan** saat membuat repositori ini (Docker 29.10, Compose v5.7, kernel 6.18, amd64):

- `docker compose config` — valid.
- Build image `release` (amd64) lewat `docker compose build`; build stage `source`
  (amd64, compile penuh tag v0.19.2 termasuk submodule, linkage sama dengan binary
  rilis); build image `release` untuk **linux/arm64** via QEMU, lalu `mqvpn --version`,
  `--genkey`, dan parser config dijalankan di image arm64.
- `tests/e2e-multipath.sh` — **ALL TESTS PASSED**: server di container (host network,
  non-root, read-only), klien Linux mqvpn di container dengan dua interface pada dua
  bridge yang masing-masing dibatasi 20 Mbit/s:
  - tunnel + NAT ke host "internet": OK
  - satu path, 6 unduhan paralel: ~18 Mbit/s → dua path: 30–36 Mbit/s pada beberapa
    putaran (kedua path aktif dan masing-masing membawa trafik)
  - satu unduhan TCP dengan hybrid lane: ~37 Mbit/s vs ~18 Mbit/s satu path
  - failover (satu interface dimatikan saat mengunduh): unduhan selesai
  - akses ke jaringan privat diblokir
  - key & sertifikat sama setelah container dibuat ulang; key tidak muncul di log
  - semua chain `MQVPN-*` terhapus setelah stop
- Uji manual: konflik UDP 443 (simulasi Traefik `-p 443:443/udp`) terdeteksi; watchdog
  memasang ulang jump yang dihapus; crash mqvpn → restart otomatis; stop bersih (< 1 dtk,
  exit 0); `ip_forward` 0→1 lalu dikembalikan; validasi env/subnet/IPv6/sertifikat;
  key per pengguna; key salah ditolak; sertifikat kustom (layout Let's Encrypt); backend
  `iptables-legacy` paksa; `MQVPN_FIREWALL_OPEN_PORT`; `server.extra.conf`.
- `shellcheck` untuk semua skrip.

Yang **tidak bisa** diuji di lingkungan ini:

- Perangkat **Android** nyata (aplikasi resmi) — konfigurasi didokumentasikan dari source
  aplikasi upstream; pengujian memakai klien Linux resmi dengan protokol yang sama.
- **Dokploy** sungguhan (tidak tersedia); kompatibilitas diverifikasi dari source Dokploy
  (perintah `docker compose -p <app> up -d --build`, file `.env`, *Isolated Deployment*,
  Traefik UDP 443).
- **IPv6** (kernel sandbox tanpa IPv6): jalur `MQVPN_SUBNET6=auto` hanya teruji pada cabang
  "IPv6 tidak tersedia"; NAT66/forwarding IPv6 belum teruji end-to-end.
- Server **arm64** penuh: di bawah emulasi QEMU user-mode, `iptables-nft` gagal (netlink
  tidak diemulasikan), jadi hanya binary yang teruji; perlu dicoba di hardware ARM nyata.
- Host dengan UFW/firewalld aktif dan host yang benar-benar memakai backend iptables-legacy.
- Jaringan seluler/Wi-Fi nyata (latensi/loss nyata); shaping hanya laju (tbf), tanpa netem.

Menjalankan uji sendiri (host Linux dengan Docker, sebagai root):
```bash
tests/e2e-multipath.sh
```

---

## Lisensi

mqvpn © mp0rta dan kontributor, Apache-2.0; nama dan logo "mqvpn" tunduk pada
[TRADEMARK.md](https://github.com/mp0rta/mqvpn/blob/main/TRADEMARK.md) upstream.
Image menyertakan LICENSE, NOTICE, dan lisensi pihak ketiga (xquic, BoringSSL, lwIP) di
`/usr/local/share/doc/mqvpn/`. Repositori ini hanya berisi berkas deployment dan tidak
berafiliasi dengan proyek upstream.
