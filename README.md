# Ponte Muse <-> Claude pago (servidor MCP)

O Claude pago do Rafael lê o estado atual do Muse (dossiê, calendário,
regras, status) direto da fonte, sem arquivo parado no Drive — e devolve
recados para o Muse sem copiar e colar.

## O que expõe

- Recursos (só leitura): `muse://dossie`, `muse://calendario`,
  `muse://regras`, `muse://status` (+ ferramenta `ler_arquivo`).
- Ferramenta `deixar_recado`: escreve num arquivo de recados que o Muse lê.
- Nada publica, agenda, compra, vende ou apaga.

## Endpoints

- MCP (Streamable HTTP, JSON puro, sem SSE): `/mcp/t/<MCP_TOKEN>/`
- Sincronização (POST, `Authorization: Bearer <SYNC_TOKEN>`): `/sync`
- Saúde: `/health`

## Instalação (VM Ubuntu 24.04, como root)

```bash
git clone https://github.com/ImagoCr/muse-claude-bridge.git /opt/muse-bridge
export MCP_TOKEN='...' SYNC_TOKEN='...' DUCKDNS_SUBDOMAIN='muse-ponte' DUCKDNS_TOKEN='...'
bash /opt/muse-bridge/setup.sh
```

O `setup.sh` instala dependências, cria o serviço systemd `muse-bridge`,
configura o DuckDNS (atualização do IP a cada 5 min) e o Caddy (HTTPS
automático com Let's Encrypt) fazendo reverse proxy para o servidor MCP.

## Sincronização dos arquivos

A VM do Muse envia os 4 arquivos (dossiê, calendário, regras, status)
para `POST /sync` a cada 15 min (cron) e sempre que eles mudam. O servidor
lê os arquivos do disco a cada requisição, então a atualização vale na hora.
