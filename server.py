#!/usr/bin/env python3
"""Ponte Muse <-> Claude pago — servidor MCP.

Expoe os arquivos vivos do Muse para o Claude pago ler (dossie,
calendario, regras, status) e uma ferramenta para ele deixar recados.
Somente leitura + recado. Nada publica, agenda, compra, vende ou apaga.

Transporte: Streamable HTTP, respostas em JSON puro (sem SSE),
sem estado (stateless). Autenticacao: token no caminho da URL:
/mcp/t/<MCP_TOKEN>.

Sincronizacao: os arquivos vivem em DATA_DIR e sao atualizados pelo
endpoint POST /sync (header Authorization: Bearer <SYNC_TOKEN>),
chamado pela VM do Muse. O servidor le os arquivos do disco a cada
requisicao, entao a atualizacao vale na hora.

Configuracao (arquivos em /opt/muse-bridge ou variaveis de ambiente):
  .token       token do MCP (caminho /mcp/t/<token>)
  .token-sync  token do /sync
  DATA_DIR     diretorio dos arquivos (padrao /opt/muse-bridge/data)
"""
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.types import Resource, TextContent, Tool
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Mount, Route
from contextlib import asynccontextmanager
import uvicorn

BASE = Path(os.environ.get("MUSE_BRIDGE_HOME", "/opt/muse-bridge"))
DATA_DIR = Path(os.environ.get("MUSE_BRIDGE_DATA", str(BASE / "data")))
PORT = int(os.environ.get("MUSE_BRIDGE_PORT", "8765"))

MCP_TOKEN = (BASE / ".token").read_text(encoding="utf-8").strip()
SYNC_TOKEN = (BASE / ".token-sync").read_text(encoding="utf-8").strip()
assert len(MCP_TOKEN) >= 20 and len(SYNC_TOKEN) >= 20, "tokens invalidos"

FILES = {
    "dossie": DATA_DIR / "dossie.md",
    "calendario": DATA_DIR / "calendario.md",
    "regras": DATA_DIR / "regras.md",
    "status": DATA_DIR / "status.md",
}
ALLOWED_SYNC = set(FILES)
BLOCKED = re.compile(r"(\.env|credentials|secret|\.pem$|\.key$|id_rsa|\.token|vault|/\.ssh/)", re.I)
MAX_CHARS = 200_000
INBOX = BASE / "inbox" / "recados.md"


def read_text(path: Path) -> str:
    data = path.read_text(encoding="utf-8", errors="replace")
    if len(data) > MAX_CHARS:
        data = data[:MAX_CHARS] + f"\n\n[... cortado em {MAX_CHARS} caracteres ...]"
    return data


server = Server("muse-bridge")

RESOURCES = {
    "muse://dossie": (FILES["dossie"], "Dossiê do Claude (versão atual, viva)"),
    "muse://calendario": (FILES["calendario"], "Calendário editorial — Capela Diária (atual)"),
    "muse://regras": (FILES["regras"], "Regras fixas do @ceuemimagens"),
    "muse://status": (FILES["status"], "Status atual do projeto (feito / em andamento / planejado / depende de aprovação)"),
}


@server.list_resources()
async def list_resources():
    return [
        Resource(uri=uri, name=name, mimeType="text/markdown", description=name)
        for uri, (_, name) in RESOURCES.items()
    ]


@server.read_resource()
async def read_resource(uri):
    uri = str(uri)
    if uri not in RESOURCES:
        raise ValueError(f"recurso desconhecido: {uri}")
    path, _ = RESOURCES[uri]
    if not path.exists():
        raise ValueError(f"arquivo do recurso nao existe: {path}")
    return read_text(path)


@server.list_tools()
async def list_tools():
    return [
        Tool(
            name="ler_arquivo",
            description="Le um arquivo de texto do diretorio de dados da ponte (somente leitura). Nomes permitidos: dossie, calendario, regras, status.",
            inputSchema={
                "type": "object",
                "properties": {
                    "caminho": {"type": "string", "description": "Um de: dossie, calendario, regras, status."}
                },
                "required": ["caminho"],
            },
        ),
        Tool(
            name="deixar_recado",
            description="Deixa um recado para o Muse. Use para devolver pareceres, correcoes e avisos. O recado fica registrado com data e hora.",
            inputSchema={
                "type": "object",
                "properties": {
                    "mensagem": {"type": "string", "description": "O recado para o Muse (max. 5000 caracteres)."},
                    "assunto": {"type": "string", "description": "Assunto curto do recado (opcional)."},
                },
                "required": ["mensagem"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name, arguments):
    args = arguments or {}
    if name == "ler_arquivo":
        caminho = str(args.get("caminho", "")).strip()
        if caminho not in FILES:
            raise ValueError("caminho permitido: dossie, calendario, regras, status.")
        path = FILES[caminho]
        if not path.exists():
            raise ValueError(f"arquivo nao existe: {caminho}")
        return [TextContent(type="text", text=read_text(path))]

    if name == "deixar_recado":
        mensagem = str(args.get("mensagem", "")).strip()
        assunto = str(args.get("assunto", "")).strip() or "recado do Claude"
        if not mensagem:
            raise ValueError("informe 'mensagem'.")
        if len(mensagem) > 5000:
            mensagem = mensagem[:5000] + "\n[... cortado ...]"
        INBOX.parent.mkdir(parents=True, exist_ok=True)
        agora = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        with INBOX.open("a", encoding="utf-8") as f:
            f.write(f"\n## {agora} — {assunto}\n\n{mensagem}\n")
        return [TextContent(type="text", text=f"Recado registrado para o Muse ({agora}).")]

    raise ValueError(f"ferramenta desconhecida: {name}")


session_manager = StreamableHTTPSessionManager(
    app=server,
    event_store=None,
    json_response=True,  # JSON puro, sem SSE
    stateless=True,
)


async def handle_mcp(scope, receive, send):
    await session_manager.handle_request(scope, receive, send)


async def handle_sync(request: Request):
    auth = request.headers.get("authorization", "")
    if auth != f"Bearer {SYNC_TOKEN}":
        return JSONResponse({"ok": False, "erro": "nao autorizado"}, status_code=401)
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False, "erro": "JSON invalido"}, status_code=400)
    files = body.get("files") or {}
    if not isinstance(files, dict):
        return JSONResponse({"ok": False, "erro": "'files' precisa ser um objeto"}, status_code=400)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    updated = []
    for name, content in files.items():
        if name not in ALLOWED_SYNC or not isinstance(content, str):
            continue
        if BLOCKED.search(name):
            continue
        FILES[name].write_text(content, encoding="utf-8")
        updated.append(name)
    return JSONResponse({"ok": True, "updated": updated})


async def handle_health(request: Request):
    return JSONResponse({"ok": True, "service": "muse-bridge"})


@asynccontextmanager
async def lifespan(app):
    async with session_manager.run():
        print("muse-bridge pronto", flush=True)
        yield


app = Starlette(
    lifespan=lifespan,
    routes=[
        Mount(f"/mcp/t/{MCP_TOKEN}", app=handle_mcp),
        Route("/sync", endpoint=handle_sync, methods=["POST"]),
        Route("/health", endpoint=handle_health, methods=["GET"]),
    ],
)


if __name__ == "__main__":
    print(f"muse-bridge na porta {PORT}", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
