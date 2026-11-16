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
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv git curl caddy cron >/dev/null

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
# Nao falhar o setup se o DuckDNS estiver fora do ar por um instante (o cron tenta de novo em 5 min).
"$BRIDGE_HOME/duckdns-update.sh" || echo "aviso: atualizacao DuckDNS falhou agora; o cron tenta de novo em 5 min"
( crontab -l 2>/dev/null | grep -v duckdns-update.sh; echo "*/5 * * * * $BRIDGE_HOME/duckdns-update.sh" ) | crontab -

echo "== firewall da VM (libera 80/443) =="
# A imagem Ubuntu da Oracle vem com iptables rejeitando tudo, menos SSH (22).
# Libera 80/443 agora e garante que sobrevivem a reboot (servico oneshot).
for PORT in 80 443; do
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
done
cat > /etc/systemd/system/bridge-firewall.service <<'EOF'
[Unit]
Description=Libera 80/443 no iptables (ponte Muse-Claude)
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for p in 80 443; do iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $p -j ACCEPT; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable bridge-firewall.service

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
# Aguarda a ponte responder (o Python demora alguns segundos para subir em 1 OCPU).
# Nunca falhar o script aqui: os servicos ja foram iniciados acima.
for i in 1 2 3 4 5 6; do
  sleep 5
  if curl -fsS "http://127.0.0.1:8765/health" >/dev/null 2>&1; then
    echo "ponte respondendo (tentativa $i)"
    break
  fi
done
systemctl is-active muse-bridge.service || true
systemctl is-active caddy || true
echo
echo "Ponte instalada. URL do MCP: https://${DOMAIN}/mcp/t/<MCP_TOKEN>/"
