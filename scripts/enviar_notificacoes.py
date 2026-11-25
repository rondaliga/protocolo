#!/usr/bin/env python3
"""
Rotina de avisos por e-mail do Livro de Protocolo (executada pelo GitHub Actions a cada ~15 min).

1. pede ao banco que verifique prazos e tempos máximos (SLA) e enfileire os avisos novos;
2. lê a fila de e-mails pendentes e envia por SMTP;
3. marca cada item como enviado ou com erro (até 5 tentativas).

Usa apenas a chave pública (anon) + um SEGREDO próprio da integração, que só permite
verificar SLA e ler/marcar a fila. Nunca usa a chave service_role.
Os e-mails não contêm a descrição do documento (LGPD).

Variáveis: SUPABASE_URL, SUPABASE_ANON_KEY, INTEGRACAO_SEGREDO, SMTP_HOST, SMTP_PORT (587),
           SMTP_USER, SMTP_PASS, SMTP_FROM  (SMTP_SSL=true para porta 465)
"""
import json, os, smtplib, ssl, sys, urllib.error, urllib.request
from email.message import EmailMessage


def env(nome, obrig=True, padrao=""):
    v = os.environ.get(nome, padrao).strip()
    if obrig and not v:
        print(f"ERRO: variável {nome} não configurada.", file=sys.stderr); sys.exit(1)
    return v


BASE = env("SUPABASE_URL").rstrip("/"); ANON = env("SUPABASE_ANON_KEY"); SEGREDO = env("INTEGRACAO_SEGREDO")
HOST = env("SMTP_HOST"); PORTA = int(env("SMTP_PORT", False, "587")); USUARIO = env("SMTP_USER"); SENHA = env("SMTP_PASS")
REMETENTE = env("SMTP_FROM", False, USUARIO); SSL = env("SMTP_SSL", False, "false").lower() == "true"


def rpc(nome, args):
    req = urllib.request.Request(f"{BASE}/rest/v1/rpc/{nome}", data=json.dumps(args).encode(), method="POST",
                                 headers={"apikey": ANON, "Authorization": f"Bearer {ANON}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            corpo = r.read().decode()
            return json.loads(corpo) if corpo else None
    except urllib.error.HTTPError as e:
        print(f"ERRO na chamada {nome}: HTTP {e.code} {e.read().decode()[:200]}", file=sys.stderr); sys.exit(1)


def main():
    novos = rpc("integracao_verificar", {"p_segredo": SEGREDO})
    print(f"Avisos novos gerados: {novos.get('avisos_novos')}")
    fila = rpc("integracao_fila", {"p_segredo": SEGREDO, "p_limite": 30}) or []
    print(f"E-mails na fila: {len(fila)}")
    if not fila:
        return
    ctx = ssl.create_default_context()
    srv = smtplib.SMTP_SSL(HOST, PORTA, context=ctx, timeout=30) if SSL else smtplib.SMTP(HOST, PORTA, timeout=30)
    with srv:
        if not SSL:
            srv.starttls(context=ctx)
        srv.login(USUARIO, SENHA)
        falhas = 0
        for item in fila:
            msg = EmailMessage()
            msg["From"] = REMETENTE; msg["To"] = REMETENTE            # destinatários reais em cópia oculta
            msg["Bcc"] = ", ".join(item["destinatarios"]); msg["Subject"] = item["assunto"]
            msg.set_content(item["corpo"])
            if item.get("corpo_html"):
                msg.add_alternative(item["corpo_html"], subtype="html")
            try:
                srv.send_message(msg, from_addr=REMETENTE, to_addrs=item["destinatarios"] + [REMETENTE])
                rpc("integracao_marcar", {"p_segredo": SEGREDO, "p_id": item["id"], "p_ok": True})
                print(f"  enviado #{item['id']}")
            except Exception as e:                                    # noqa: BLE001
                falhas += 1
                rpc("integracao_marcar", {"p_segredo": SEGREDO, "p_id": item["id"], "p_ok": False, "p_erro": str(e)[:200]})
                print(f"  falhou #{item['id']}: {type(e).__name__}", file=sys.stderr)
    if falhas:
        sys.exit(1)


main()
