Optional mount point for TLS certificates (`MQVPN_TLS_HOST_DIR`, default `./tls`).

Normally leave this empty: the server generates a self-signed certificate in
its data volume. To use a trusted certificate, point `MQVPN_TLS_HOST_DIR` at a
host directory that holds it (for example `/etc/letsencrypt`) and set
`MQVPN_TLS_CERT_FILE` / `MQVPN_TLS_KEY_FILE` to the paths under
`/etc/mqvpn-tls/` inside the container. Never commit private keys here.
