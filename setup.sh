#!/usr/bin/env bash
# Instalacao da ponte Muse <-> Claude numa VM Ubuntu 24.04 (Oracle Free Tier).
# Rodar como root, com as variaveis de ambiente:
#   MCP_TOKEN, SYNC_TOKEN, DUCKDNS_SUBDOMAIN, DUCKDNS_TOKEN
# O repo precisa estar clonado em /opt/muse-bridge (este script roda de la).
set -euo pipefail

: "${MCP_TOKEN:?informe MCP_TOKEN}"
: "${SYNC_TOKEN:?informe SYNC_TOKEN}"
: "${DUCKDNS_SUBDOMAIN:?informe DUCKDNS_SUBDOMAIN}"
: "${DUCKDNS_TOKEN:?informe DUCKDNS_TOKEN}"

BRIDGE_HOME=/opt/muse-bridge
cd "$BRIDGE_HOME"

echo "== pacotes =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv git curl caddy >/dev/null

echo "== tokens e diretorios =="
printf '%s' "$MCP_TOKEN" > "$BRIDGE_HOME/.token"
printf '%s' "$SYNC_TOKEN" > "$BRIDGE_HOME/.token-sync"
chmod 0600 "$BRIDGE_HOME/.token" "$BRIDGE_HOME/.token-sync"
mkdir -p "$BRIDGE_HOME/data" "$BRIDGE_HOME/inbox"
printf 'DUCKDNS_SUBDOMAIN=%s\nDUCKDNS_TOKEN=%s\n' "$DUCKDNS_SUBDOMAIN" "$DUCKDNS_TOKEN" > "$BRIDGE_HOME/duckdns.conf"
chmod 0600 "$BRIDGE_HOME/duckdns.conf"

echo "== venv e dependencias =="
python3 -m venv "$BRIDGE_HOME/venv"
"$BRIDGE_HOME/venv/bin/pip" install -q -r "$BRIDGE_HOME/requirements.txt"

echo "== servico systemd =="
cp "$BRIDGE_HOME/muse-bridge.service" /etc/systemd/system/muse-bridge.service
systemctl daemon-reload
systemctl enable muse-bridge.service
systemctl restart muse-bridge.service

echo "== DuckDNS (atualiza o IP a cada 5 min) =="
cat > "$BRIDGE_HOME/duckdns-update.sh" <<'EOF'
#!/usr/bin/env bash
set -a; . /opt/muse-bridge/duckdns.conf; set +a
curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=" >/dev/null
EOF
chmod +x "$BRIDGE_HOME/duckdns-update.sh"
"$BRIDGE_HOME/duckdns-update.sh"
( crontab -l 2>/dev/null | grep -v duckdns-update.sh; echo "*/5 * * * * $BRIDGE_HOME/duckdns-update.sh" ) | crontab -

echo "== Caddy (HTTPS automatico) =="
DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"
cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
	reverse_proxy 127.0.0.1:8765
}
EOF
systemctl enable caddy
systemctl restart caddy

echo "== status =="
sleep 2
systemctl is-active muse-bridge.service
systemctl is-active caddy
curl -fsS "http://127.0.0.1:8765/health" || true
echo
echo "Ponte instalada. URL do MCP: https://${DOMAIN}/mcp/t/<MCP_TOKEN>/"
