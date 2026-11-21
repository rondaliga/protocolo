#!/usr/bin/env python3
"""
Mini "Supabase" SÓ PARA TESTES: serve o site (dist/) e implementa o mínimo de Auth + PostgREST,
repassando cada chamada ao PostgreSQL real do schema.sql sob o papel `authenticated` — ou seja,
RLS, triggers e RPCs são os de verdade; só o transporte HTTP é simulado.

  python3 mock_supabase.py PORTA BANCO     (o psql precisa conseguir conectar; ver PSQL abaixo)
"""
import json, os, re, shlex, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

PORTA, BANCO = int(sys.argv[1]), sys.argv[2]
DIST = Path(__file__).resolve().parents[2] / "dist"
SENHA_TESTE = "Trocar@123"
PSQL = shlex.split(os.environ.get("PSQL", f"psql -d {BANCO} -tA -v ON_ERROR_STOP=1 -q"))
UUID = re.compile(r"^[0-9a-f-]{36}$")
ARQUIVOS = {}
TIPOS = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".png": "image/png"}


def sql(texto):
    r = subprocess.run(PSQL, input=texto, capture_output=True, text=True)
    if r.returncode != 0:
        m = re.search(r"ERROR:\s+(.*)", r.stderr)
        raise RuntimeError(m.group(1).strip() if m else r.stderr.strip()[:300])
    linhas = [l for l in r.stdout.splitlines() if l.strip()]
    return linhas[-1] if linhas else "null"


def lit(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def como(uid, consulta):
    return sql(f"begin;\nset local role authenticated;\nselect set_config('request.jwt.claim.sub','{uid}',true) \\g /dev/null\n{consulta};\ncommit;\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def responder(self, status, corpo, tipo="application/json"):
        dados = corpo if isinstance(corpo, bytes) else (corpo if isinstance(corpo, str) else json.dumps(corpo)).encode()
        self.send_response(status); self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados))); self.end_headers(); self.wfile.write(dados)

    def uid(self):
        m = re.match(r"Bearer mock\.([0-9a-f-]{36})$", self.headers.get("Authorization", ""))
        return m.group(1) if m else None

    def corpo(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        u = urlparse(self.path)
        if u.path.startswith("/storage/v1/object/authenticated/protocolo-fotos/"):
            uid = self.uid()
            if not uid: return self.responder(401, {"message": "JWT inválido"})
            nome = unquote(u.path[len("/storage/v1/object/authenticated/protocolo-fotos/"):])
            if not re.match(r"^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$", nome): return self.responder(400, {"message": "nome inválido"})
            try:
                ok = como(uid, f"select count(*) from storage.objects where bucket_id='protocolo-fotos' and name='{nome}'")
            except Exception as e:
                return self.responder(400, {"message": str(e)})
            if ok != "1": return self.responder(404, {"message": "not found"})   # RLS: sem acesso = não existe
            return self.responder(200, ARQUIVOS.get(nome, b""), "image/jpeg")
        if u.path.startswith("/rest/v1/"): return self.rest_get(u)
        arq = DIST / (u.path.lstrip("/") or "index.html")
        if arq.is_file() and DIST in arq.resolve().parents:
            return self.responder(200, arq.read_bytes(), TIPOS.get(arq.suffix, "application/octet-stream"))
        self.responder(404, b"nao encontrado", "text/plain")

    def rest_get(self, u):
        uid = self.uid()
        if not uid: return self.responder(401, {"message": "JWT inválido"})
        tabela, q = u.path[len("/rest/v1/"):], parse_qs(u.query)
        try:
            if tabela == "perfis":
                alvo = unquote(q.get("user_id", [""])[0]).removeprefix("eq.")
                assert UUID.match(alvo)
                r = como(uid, f"select coalesce(jsonb_agg(jsonb_build_object('nome',p.nome,'papel',p.papel,'setor_id',p.setor_id,"
                              f"'setores',case when s.id is null then null else jsonb_build_object('nome',s.nome) end)),'[]')::text "
                              f"from public.perfis p left join public.setores s on s.id=p.setor_id where p.user_id='{alvo}'")
            elif tabela == "auditoria":
                r = como(uid, "select coalesce(jsonb_agg(x order by x.id desc),'[]')::text from (select id,ocorrido_em,usuario_nome,acao,protocolo_id,detalhes "
                              "from public.auditoria order by id desc limit 300) x")
            elif tabela == "tramites":
                ids = re.findall(r"\d+", q.get("protocolo_id", [""])[0])
                r = como(uid, "select coalesce(jsonb_agg(jsonb_build_object('protocolo_id',protocolo_id,'etapa',etapa,'assinatura_png',assinatura_png)),'[]')::text "
                              f"from public.tramites where assinatura_png is not null and protocolo_id in ({','.join(ids) or '0'})")
            elif tabela == "setores":
                r = como(uid, "select coalesce(jsonb_agg(jsonb_build_object('id',id,'nome',nome) order by nome),'[]')::text from public.setores where ativo")
            else:
                return self.responder(404, {"message": "tabela fora do mock"})
            self.responder(200, r)
        except Exception as e:
            self.responder(400, {"message": str(e)})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/auth/v1/token":
            c = self.corpo(); gr = parse_qs(u.query).get("grant_type", [""])[0]
            if gr == "password":
                email = str(c.get("email", "")).replace("'", "")
                r = sql(f"select id from auth.users where email = '{email}'")
                if r == "null" or c.get("password") != SENHA_TESTE:
                    return self.responder(400, {"error_code": "invalid_credentials", "msg": "Invalid login credentials"})
                uid = r
            else:
                uid = str(c.get("refresh_token", "")).removeprefix("r.")
                if not UUID.match(uid): return self.responder(400, {"error_code": "invalid_grant"})
            return self.responder(200, {"access_token": f"mock.{uid}", "refresh_token": f"r.{uid}", "expires_in": 3600, "user": {"id": uid}})
        if u.path == "/auth/v1/logout": return self.responder(204, b"")
        if u.path.startswith("/storage/v1/object/protocolo-fotos/"):
            uid = self.uid()
            if not uid: return self.responder(401, {"message": "JWT inválido"})
            nome = unquote(u.path[len("/storage/v1/object/protocolo-fotos/"):])
            n = int(self.headers.get("Content-Length") or 0); dados = self.rfile.read(n)
            if not re.match(r"^[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$", nome) or self.headers.get("Content-Type") != "image/jpeg" or n > 1572864:
                return self.responder(400, {"message": "arquivo recusado"})
            try:
                como(uid, f"insert into storage.objects (bucket_id,name,owner,metadata) values ('protocolo-fotos','{nome}',auth.uid(),'{{\"size\":{n}}}')")
            except Exception as e:
                return self.responder(403, {"message": str(e)})
            ARQUIVOS[nome] = dados
            return self.responder(200, {"Key": "protocolo-fotos/" + nome})
        m = re.match(r"^/rest/v1/rpc/([a-z_]+)$", u.path)
        if m:
            uid = self.uid()
            if not uid: return self.responder(401, {"message": "JWT inválido"})
            fn, args = m.group(1), self.corpo()
            chamada = f"public.{fn}(" + ", ".join(f"{k} := {lit(v)}" for k, v in args.items()) + ")"
            try:
                if fn in ("registrar_acesso", "registrar_exportacao"):
                    como(uid, f"select {chamada}"); return self.responder(204, b"")
                return self.responder(200, como(uid, f"select to_jsonb({chamada})::text"))
            except Exception as e:
                return self.responder(400, {"message": str(e)})
        self.responder(404, {"message": "rota fora do mock"})


print(f"mock em http://127.0.0.1:{PORTA}", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORTA), H).serve_forever()
