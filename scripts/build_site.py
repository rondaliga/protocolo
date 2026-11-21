#!/usr/bin/env python3
"""
Monta o site estático em dist/ para o GitHub Pages.

  - copia web/ -> dist/ (sem config.js / config.example.js);
  - gera dist/config.js a partir de variáveis de ambiente;
  - troca __SUPABASE_ORIGIN__ na CSP do index.html pelo domínio do seu projeto Supabase;
  - RECUSA o build se a chave informada for uma chave secreta (service_role / sb_secret_...).

Variáveis: SUPABASE_URL, SUPABASE_ANON_KEY (obrigatórias); UNIDADE, TIMEZONE, IDLE_MINUTES,
ASSINATURA_OBRIGATORIA (opcionais).
"""
import base64
import json
import os
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse

RAIZ = Path(__file__).resolve().parent.parent
ORIGEM, DESTINO = RAIZ / "web", RAIZ / "dist"


def falhar(msg: str):
    print(f"ERRO: {msg}", file=sys.stderr)
    sys.exit(1)


def chave_e_secreta(chave: str) -> bool:
    if chave.startswith("sb_secret_"):
        return True
    partes = chave.split(".")
    if len(partes) == 3:                                   # JWT legado: confere o papel no payload
        try:
            payload = partes[1] + "=" * (-len(partes[1]) % 4)
            return json.loads(base64.urlsafe_b64decode(payload)).get("role") == "service_role"
        except Exception:
            return False
    return False


def main():
    url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    chave = os.environ.get("SUPABASE_ANON_KEY", "").strip()
    if not url or not chave:
        falhar("defina SUPABASE_URL e SUPABASE_ANON_KEY (veja o README, passo de publicação).")
    p = urlparse(url)
    local = p.hostname in ("localhost", "127.0.0.1")
    if not (p.scheme == "https" or (p.scheme == "http" and local)) or not p.hostname or p.path not in ("", "/"):
        falhar("SUPABASE_URL deve ser o endereço https://xxxx.supabase.co do projeto (sem caminho).")
    if chave_e_secreta(chave):
        falhar("a chave informada é SECRETA (service_role). Use somente a chave pública anon/publishable.")

    if DESTINO.exists():
        shutil.rmtree(DESTINO)
    shutil.copytree(ORIGEM, DESTINO, ignore=shutil.ignore_patterns("config.js", "config.example.js", "README.md"))

    cfg = {
        "SUPABASE_URL": url,
        "SUPABASE_ANON_KEY": chave,
        "UNIDADE": os.environ.get("UNIDADE", "CECAN - LNRCC"),
        "TIMEZONE": os.environ.get("TIMEZONE", "America/Fortaleza"),
        "IDLE_MINUTES": int(os.environ.get("IDLE_MINUTES", "30")),
        "ASSINATURA_OBRIGATORIA": os.environ.get("ASSINATURA_OBRIGATORIA", "false").lower() == "true",
    }
    (DESTINO / "config.js").write_text("window.APP_CONFIG = " + json.dumps(cfg, ensure_ascii=False, indent=2) + ";\n",
                                       encoding="utf-8")

    indice = DESTINO / "index.html"
    html = indice.read_text(encoding="utf-8")
    if "__SUPABASE_ORIGIN__" not in html:
        falhar("placeholder __SUPABASE_ORIGIN__ não encontrado no index.html.")
    indice.write_text(html.replace("__SUPABASE_ORIGIN__", f"{p.scheme}://{p.netloc}"), encoding="utf-8")
    (DESTINO / ".nojekyll").write_text("")
    print(f"Site gerado em {DESTINO} (Supabase: {p.scheme}://{p.netloc}).")


if __name__ == "__main__":
    main()
