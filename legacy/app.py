"""
Livro de Protocolo Eletrônico — API e servidor web (Flask).

Fluxo obrigatório:  Portaria (cria) -> ADM (2º aceite) -> Setor final (3º aceite)
Data/horário sempre do relógio do servidor. Etapas registradas são imutáveis.
"""
import io
import re
import secrets
import sqlite3
from datetime import timedelta
from functools import wraps

from flask import Flask, Response, g, jsonify, request, send_file, send_from_directory, session
from werkzeug.security import check_password_hash, generate_password_hash

import core
import pdf_export
from core import ApiError

app = Flask(__name__, static_folder="static", static_url_path="/static")
app.config.update(
    SECRET_KEY=core.obter_chave_secreta(),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=core.COOKIE_SEGURO,
    PERMANENT_SESSION_LIFETIME=timedelta(minutes=core.SESSAO_MINUTOS),  # expira por inatividade
    MAX_CONTENT_LENGTH=400 * 1024,
    JSON_AS_ASCII=False,
)

_HASH_FALSO = generate_password_hash("senha-falsa")  # equaliza o tempo quando o login não existe


# ======================================================================
# Infraestrutura: conexão, erros, segurança HTTP, autenticação
# ======================================================================
def get_db():
    if "db" not in g:
        g.db = core.conectar()
    return g.db


@app.teardown_appcontext
def _fechar_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


@app.errorhandler(ApiError)
def _erro_api(e):
    return jsonify(erro=e.mensagem), e.status


@app.errorhandler(sqlite3.IntegrityError)
def _erro_integridade(e):
    # Triggers/constraints do banco são a última linha de defesa das regras de negócio.
    return jsonify(erro="Operação rejeitada pelas regras de integridade do livro de protocolo."), 409


@app.errorhandler(413)
def _erro_413(_e):
    return jsonify(erro="Requisição grande demais."), 413


@app.after_request
def _cabecalhos(resp):
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
        "frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-store"
    return resp


@app.before_request
def _verificar_csrf():
    if request.method in ("POST", "PUT", "PATCH", "DELETE") and request.path.startswith("/api/") \
            and request.path != "/api/login":
        enviado = request.headers.get("X-CSRF-Token", "")
        esperado = session.get("csrf", "")
        if not esperado or not secrets.compare_digest(enviado.encode(), esperado.encode()):
            raise ApiError("Sessão inválida ou expirada. Atualize a página e entre novamente.", 403)


def usuario_atual():
    uid = session.get("uid")
    if not uid:
        return None
    if "usuario" not in g:
        g.usuario = get_db().execute(
            "SELECT u.*, s.nome AS setor_nome FROM usuarios u "
            "LEFT JOIN setores s ON s.id = u.setor_id WHERE u.id = ? AND u.ativo = 1", (uid,)
        ).fetchone()
    return g.usuario


def exigir(*perfis):
    """Decorator: exige login e (opcionalmente) um dos perfis informados."""
    def deco(fn):
        @wraps(fn)
        def interno(*a, **kw):
            u = usuario_atual()
            if not u:
                raise ApiError("Faça login para continuar.", 401)
            if perfis and u["perfil"] not in perfis:
                raise ApiError("Seu perfil não tem permissão para esta operação.", 403)
            return fn(*a, **kw)
        return interno
    return deco


def dados_json() -> dict:
    d = request.get_json(silent=True)
    if not isinstance(d, dict):
        raise ApiError("Corpo da requisição inválido.")
    return d


def audit(acao, protocolo_id=None, detalhes=None, usuario=None):
    core.auditar(get_db(), acao, usuario or usuario_atual(), protocolo_id, detalhes, request.remote_addr)


def dict_usuario(u):
    return {"id": u["id"], "nome": u["nome"], "login": u["login"], "perfil": u["perfil"],
            "setor_id": u["setor_id"], "setor_nome": u["setor_nome"]}


# ======================================================================
# Consultas de protocolos
# ======================================================================
def _sql_base(com_png=False):
    extras = ""
    if com_png:
        extras = ", t1.assinatura_png AS e1_png, t2.assinatura_png AS e2_png, t3.assinatura_png AS e3_png"
    return f"""
    SELECT p.id, p.numero, p.status, p.criado_em,
           COALESCE((SELECT c.descricao_nova FROM correcoes_descricao c
                      WHERE c.protocolo_id = p.id ORDER BY c.id DESC LIMIT 1), p.descricao) AS descricao,
           (SELECT COUNT(*) FROM correcoes_descricao c WHERE c.protocolo_id = p.id) AS n_correcoes,
           t1.recebido_em AS e1_em, t1.usuario_nome AS e1_usuario, t1.assinatura_tipo AS e1_tipo,
           t2.recebido_em AS e2_em, t2.usuario_nome AS e2_usuario, t2.assinatura_tipo AS e2_tipo,
           t3.recebido_em AS e3_em, t3.usuario_nome AS e3_usuario, t3.assinatura_tipo AS e3_tipo,
           t3.setor_nome AS e3_setor, t3.setor_id AS e3_setor_id
           {extras}
      FROM protocolos p
      LEFT JOIN tramites_historico t1 ON t1.protocolo_id = p.id AND t1.etapa = 1
      LEFT JOIN tramites_historico t2 ON t2.protocolo_id = p.id AND t2.etapa = 2
      LEFT JOIN tramites_historico t3 ON t3.protocolo_id = p.id AND t3.etapa = 3
    """


def _restricao_visibilidade(u):
    """Minimização (LGPD): usuário de SETOR só vê o que aguarda recebimento ou foi recebido no seu setor."""
    if u["perfil"] == "SETOR":
        return "(status = 'PENDENTE_SETOR' OR e3_setor_id = ?)", [u["setor_id"]]
    return None, []


_DATA_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _filtros(u):
    """Monta WHERE/params a partir da query string + restrição de visibilidade."""
    where, params, descr = [], [], []
    q = request.args.get("q", "").strip()[:100]
    if q:
        like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        where.append("(numero LIKE ? ESCAPE '\\' OR descricao LIKE ? ESCAPE '\\')")
        params += [like, like]
        descr.append(f"busca “{q}”")
    status = request.args.get("status", "")
    if status in core.STATUS_ROTULO:
        where.append("status = ?")
        params.append(status)
        descr.append(f"status: {core.STATUS_ROTULO[status]}")
    di, df = request.args.get("data_ini", ""), request.args.get("data_fim", "")
    if _DATA_RE.match(di):
        where.append("substr(criado_em, 1, 10) >= ?")
        params.append(di)
        descr.append(f"a partir de {core.fmt_data(di + 'T')}")
    if _DATA_RE.match(df):
        where.append("substr(criado_em, 1, 10) <= ?")
        params.append(df)
        descr.append(f"até {core.fmt_data(df + 'T')}")
    r, rp = _restricao_visibilidade(u)
    if r:
        where.append(r)
        params += rp
    return where, params, descr


def _consultar(db, where, params, limite, deslocamento=0, com_png=False):
    cte = f"WITH base AS ({_sql_base(com_png)})"
    cond = (" WHERE " + " AND ".join(where)) if where else ""
    total = db.execute(f"{cte} SELECT COUNT(*) FROM base{cond}", params).fetchone()[0]
    linhas = db.execute(f"{cte} SELECT * FROM base{cond} ORDER BY id DESC LIMIT ? OFFSET ?",
                        params + [limite, deslocamento]).fetchall()
    return total, linhas


def carregar_protocolo(db, pid, u):
    """Ficha completa de um protocolo (ou None se não existe / sem visibilidade)."""
    where, params = ["id = ?"], [pid]
    r, rp = _restricao_visibilidade(u)
    if r:
        where.append(r)
        params += rp
    base = db.execute(f"WITH base AS ({_sql_base()}) SELECT * FROM base WHERE " + " AND ".join(where),
                      params).fetchone()
    if not base:
        return None
    orig = db.execute("SELECT descricao FROM protocolos WHERE id = ?", (pid,)).fetchone()[0]
    tramites = {t["etapa"]: t for t in db.execute(
        "SELECT id, etapa, recebido_em, usuario_nome, setor_nome, assinatura_tipo, selo, "
        "(assinatura_png IS NOT NULL) AS tem_png FROM tramites_historico WHERE protocolo_id = ?", (pid,))}
    nomes = {1: "1ª Etapa — Portaria", 2: "2ª Etapa — ADM", 3: "3ª Etapa — Super/Setor"}
    etapas = []
    for n in (1, 2, 3):
        t = tramites.get(n)
        etapas.append({
            "etapa": n, "nome": nomes[n], "registrada": t is not None,
            "tramite_id": t["id"] if t else None,
            "recebido_em": t["recebido_em"] if t else None,
            "usuario": t["usuario_nome"] if t else None,
            "setor": t["setor_nome"] if t else None,
            "assinatura_tipo": t["assinatura_tipo"] if t else None,
            "tem_png": bool(t["tem_png"]) if t else False,
            "selo": t["selo"] if t else None,
        })
    correcoes = [dict(c) for c in db.execute(
        "SELECT descricao_anterior, descricao_nova, justificativa, usuario_nome, corrigido_em "
        "FROM correcoes_descricao WHERE protocolo_id = ? ORDER BY id", (pid,))]
    return {"id": base["id"], "numero": base["numero"], "status": base["status"],
            "status_rotulo": core.STATUS_ROTULO[base["status"]], "criado_em": base["criado_em"],
            "descricao": base["descricao"], "descricao_original": orig,
            "n_correcoes": base["n_correcoes"], "etapas": etapas, "correcoes": correcoes}


def _inserir_tramite(db, pid, numero, etapa, u, setor_id, setor_nome, png, quando):
    selo = core.selo_integridade(numero, etapa, u["id"], quando, setor_id, png)
    db.execute(
        "INSERT INTO tramites_historico (protocolo_id, etapa, recebido_em, usuario_id, usuario_nome,"
        " setor_id, setor_nome, assinatura_tipo, assinatura_png, selo, ip) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (pid, etapa, quando, u["id"], u["nome"], setor_id, setor_nome,
         "PIN_CANVAS" if png else "PIN", png, selo, request.remote_addr))


def _exigir_pin_e_assinatura(u, d):
    """Aceite formal: PIN do próprio usuário logado + (opcional/obrigatório) desenho no canvas."""
    core.checar_segredo(get_db(), u, str(d.get("pin", "")), "pin_hash", request.remote_addr)
    png = core.ler_assinatura(d.get("assinatura_png"))
    if core.ASSINATURA_OBRIGATORIA and not png:
        raise ApiError("A assinatura no quadro é obrigatória.")
    return png


# ======================================================================
# Páginas e configuração pública
# ======================================================================
@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/config")
def config_publica():
    return jsonify(unidade=core.UNIDADE, logo=core.LOGO_PATH.exists(),
                   assinatura_obrigatoria=core.ASSINATURA_OBRIGATORIA)


# ======================================================================
# Autenticação
# ======================================================================
@app.post("/api/login")
def login():
    d = dados_json()
    db = get_db()
    login_ = str(d.get("login", "")).strip()[:60]
    senha = str(d.get("senha", ""))
    u = db.execute("SELECT u.*, s.nome AS setor_nome FROM usuarios u LEFT JOIN setores s ON s.id=u.setor_id "
                   "WHERE u.login = ? AND u.ativo = 1", (login_,)).fetchone()
    if not u:
        check_password_hash(_HASH_FALSO, senha)
        audit("FALHA_LOGIN", detalhes={"login": login_})
        raise ApiError("Login ou senha inválidos.", 401)
    core.checar_segredo(db, u, senha, "senha_hash", request.remote_addr)
    session.clear()
    session.permanent = True
    session["uid"] = u["id"]
    session["csrf"] = secrets.token_urlsafe(32)
    audit("LOGIN", usuario=u)
    return jsonify(usuario=dict_usuario(u), csrf=session["csrf"])


@app.post("/api/logout")
@exigir()
def logout():
    audit("LOGOUT")
    session.clear()
    return jsonify(ok=True)


@app.get("/api/me")
@exigir()
def me():
    return jsonify(usuario=dict_usuario(usuario_atual()), csrf=session["csrf"])


@app.get("/api/setores")
@exigir()
def listar_setores():
    rows = get_db().execute("SELECT id, nome FROM setores WHERE ativo = 1 ORDER BY nome").fetchall()
    return jsonify([dict(r) for r in rows])


# ======================================================================
# Dashboard e listagem
# ======================================================================
@app.get("/api/resumo")
@exigir()
def resumo():
    db, u = get_db(), usuario_atual()
    r, rp = _restricao_visibilidade(u)
    cond = f" WHERE {r}" if r else ""
    por_status = {s: 0 for s in core.STATUS_ROTULO}
    for linha in db.execute(f"WITH base AS ({_sql_base()}) SELECT status, COUNT(*) n FROM base{cond} "
                            "GROUP BY status", rp):
        por_status[linha["status"]] = linha["n"]
    hoje = core.agora_iso()[:10]
    c2 = (f" AND {r}" if r else "")
    registrados_hoje = db.execute(
        f"WITH base AS ({_sql_base()}) SELECT COUNT(*) FROM base WHERE substr(criado_em,1,10) = ?{c2}",
        [hoje] + rp).fetchone()[0]
    return jsonify(total=sum(por_status.values()), hoje=registrados_hoje, **{
        "pendente_adm": por_status["PENDENTE_ADM"],
        "pendente_setor": por_status["PENDENTE_SETOR"],
        "concluido": por_status["CONCLUIDO"]})


@app.get("/api/protocolos")
@exigir()
def listar_protocolos():
    db, u = get_db(), usuario_atual()
    where, params, _ = _filtros(u)
    try:
        pagina = max(1, int(request.args.get("pagina", 1)))
        por_pagina = min(100, max(1, int(request.args.get("por_pagina", 25))))
    except ValueError:
        raise ApiError("Parâmetros de paginação inválidos.")
    total, linhas = _consultar(db, where, params, por_pagina, (pagina - 1) * por_pagina)
    return jsonify(total=total, pagina=pagina, por_pagina=por_pagina,
                   itens=[{k: l[k] for k in l.keys() if k != "e3_setor_id"} for l in linhas])


@app.get("/api/protocolos/<int:pid>")
@exigir()
def detalhe_protocolo(pid):
    p = carregar_protocolo(get_db(), pid, usuario_atual())
    if not p:
        raise ApiError("Protocolo não encontrado.", 404)
    return jsonify(p)


@app.get("/api/tramites/<int:tid>/assinatura.png")
@exigir()
def imagem_assinatura(tid):
    db, u = get_db(), usuario_atual()
    t = db.execute("SELECT protocolo_id, assinatura_png FROM tramites_historico WHERE id = ?", (tid,)).fetchone()
    if not t or not t["assinatura_png"] or not carregar_protocolo(db, t["protocolo_id"], u):
        raise ApiError("Assinatura não encontrada.", 404)
    return Response(t["assinatura_png"], mimetype="image/png")


# ======================================================================
# Fluxo: 1ª etapa (Portaria) — cria o protocolo
# ======================================================================
@app.post("/api/protocolos")
@exigir("PORTARIA")
def criar_protocolo():
    db, u, d = get_db(), usuario_atual(), dados_json()
    descricao = core.validar_descricao(d.get("descricao"))
    png = _exigir_pin_e_assinatura(u, d)
    with core.transacao(db):
        quando = core.agora_iso()
        ano = int(quando[:4])
        linha = db.execute("SELECT ultimo FROM sequencias WHERE ano = ?", (ano,)).fetchone()
        n = (linha["ultimo"] if linha else 0) + 1
        db.execute("INSERT INTO sequencias (ano, ultimo) VALUES (?, ?) "
                   "ON CONFLICT(ano) DO UPDATE SET ultimo = excluded.ultimo", (ano, n))
        numero = f"{ano}-{n:04d}"
        pid = db.execute("INSERT INTO protocolos (numero, descricao, status, criado_em, criado_por) "
                         "VALUES (?,?,?,?,?)", (numero, descricao, "PENDENTE_ADM", quando, u["id"])).lastrowid
        _inserir_tramite(db, pid, numero, 1, u, None, None, png, quando)
        audit("PROTOCOLO_CRIADO", pid, {"numero": numero, "descricao": descricao})
    return jsonify(carregar_protocolo(db, pid, u)), 201


# ======================================================================
# Fluxo: 2ª etapa (ADM) e 3ª etapa (Setor)
# ======================================================================
def _confirmar_etapa(pid, etapa):
    db, u, d = get_db(), usuario_atual(), dados_json()
    png = _exigir_pin_e_assinatura(u, d)
    esperado = {2: "PENDENTE_ADM", 3: "PENDENTE_SETOR"}[etapa]
    with core.transacao(db):
        p = db.execute("SELECT id, numero, status FROM protocolos WHERE id = ?", (pid,)).fetchone()
        if not p:
            raise ApiError("Protocolo não encontrado.", 404)
        if p["status"] != esperado:
            if p["status"] == "CONCLUIDO":
                raise ApiError("Este protocolo já foi concluído.", 409)
            if etapa == 3:
                # Ainda aguarda o ADM: o setor não enxerga este protocolo (mesma regra de visibilidade
                # da listagem), então não revelamos que ele existe. A sequência continua garantida.
                raise ApiError("Protocolo não encontrado.", 404)
            raise ApiError("O recebimento do ADM já foi registrado para este protocolo.", 409)
        if core.SEGREGACAO_FUNCOES and db.execute(
                "SELECT 1 FROM tramites_historico WHERE protocolo_id = ? AND usuario_id = ?",
                (pid, u["id"])).fetchone():
            raise ApiError("Segregação de funções: você já assinou outra etapa deste protocolo.", 403)
        quando = core.agora_iso()
        # 3ª etapa: o setor final é o do usuário logado (perfil SETOR sempre tem setor_id)
        setor_id, setor_nome = (u["setor_id"], u["setor_nome"]) if etapa == 3 else (None, None)
        _inserir_tramite(db, pid, p["numero"], etapa, u, setor_id, setor_nome, png, quando)
        audit("RECEBIMENTO_ADM" if etapa == 2 else "RECEBIMENTO_SETOR", pid,
              {"numero": p["numero"], "setor": setor_nome, "assinatura": "PIN_CANVAS" if png else "PIN"})
    return jsonify(carregar_protocolo(db, pid, u))


@app.post("/api/protocolos/<int:pid>/adm")
@exigir("ADM")
def confirmar_adm(pid):
    return _confirmar_etapa(pid, 2)


@app.post("/api/protocolos/<int:pid>/setor")
@exigir("SETOR")
def confirmar_setor(pid):
    return _confirmar_etapa(pid, 3)


# ======================================================================
# Correção de descrição (preserva a original; exige justificativa + PIN)
# ======================================================================
@app.post("/api/protocolos/<int:pid>/correcao")
@exigir("PORTARIA", "ADM", "GESTOR")
def corrigir_descricao(pid):
    db, u, d = get_db(), usuario_atual(), dados_json()
    nova = core.validar_descricao(d.get("descricao_nova"))
    justificativa = " ".join(str(d.get("justificativa", "")).split())
    if not 10 <= len(justificativa) <= 500:
        raise ApiError("Informe uma justificativa de 10 a 500 caracteres.")
    core.checar_segredo(db, u, str(d.get("pin", "")), "pin_hash", request.remote_addr)
    with core.transacao(db):
        if not db.execute("SELECT 1 FROM protocolos WHERE id = ?", (pid,)).fetchone():
            raise ApiError("Protocolo não encontrado.", 404)
        atual = db.execute(
            "SELECT COALESCE((SELECT descricao_nova FROM correcoes_descricao WHERE protocolo_id = p.id "
            "ORDER BY id DESC LIMIT 1), p.descricao) FROM protocolos p WHERE p.id = ?", (pid,)).fetchone()[0]
        if nova == atual:
            raise ApiError("A nova descrição é igual à atual.")
        quando = core.agora_iso()
        db.execute("INSERT INTO correcoes_descricao (protocolo_id, descricao_anterior, descricao_nova,"
                   " justificativa, usuario_id, usuario_nome, corrigido_em) VALUES (?,?,?,?,?,?,?)",
                   (pid, atual, nova, justificativa, u["id"], u["nome"], quando))
        audit("DESCRICAO_CORRIGIDA", pid, {"anterior": atual, "nova": nova, "justificativa": justificativa})
    return jsonify(carregar_protocolo(db, pid, u))


# ======================================================================
# Exportação PDF (ficha individual e listagem espelhando o livro físico)
# ======================================================================
def _enviar_pdf(conteudo: bytes, nome: str):
    return send_file(io.BytesIO(conteudo), mimetype="application/pdf", download_name=nome,
                     as_attachment=request.args.get("baixar") == "1")


@app.get("/api/protocolos/<int:pid>/pdf")
@exigir()
def pdf_ficha(pid):
    db, u = get_db(), usuario_atual()
    p = carregar_protocolo(db, pid, u)
    if not p:
        raise ApiError("Protocolo não encontrado.", 404)
    pngs = {r["etapa"]: r["assinatura_png"] for r in db.execute(
        "SELECT etapa, assinatura_png FROM tramites_historico WHERE protocolo_id = ?", (pid,))}
    audit("EXPORTACAO_FICHA", pid, {"numero": p["numero"]})
    conteudo = pdf_export.ficha_pdf(p, pngs, core.UNIDADE, core.LOGO_PATH, u["nome"], core.agora_iso())
    return _enviar_pdf(conteudo, f"protocolo-{p['numero']}.pdf")


@app.get("/api/relatorio/pdf")
@exigir()
def pdf_listagem():
    db, u = get_db(), usuario_atual()
    where, params, descr = _filtros(u)
    total, linhas = _consultar(db, where, params, 2000, 0, com_png=True)
    audit("EXPORTACAO_LISTAGEM", None, {"filtros": descr, "registros": total})
    conteudo = pdf_export.listagem_pdf([dict(l) for l in linhas], total, descr, core.UNIDADE,
                                       core.LOGO_PATH, u["nome"], core.agora_iso())
    return _enviar_pdf(conteudo, f"livro-de-protocolo-{core.agora_iso()[:10]}.pdf")


# ======================================================================
# Auditoria (GESTOR)
# ======================================================================
@app.get("/api/auditoria")
@exigir("GESTOR")
def listar_auditoria():
    try:
        limite = min(500, max(1, int(request.args.get("limite", 200))))
    except ValueError:
        raise ApiError("Parâmetro inválido.")
    rows = get_db().execute(
        "SELECT a.id, a.ocorrido_em, a.usuario_nome, a.acao, a.protocolo_id, p.numero AS protocolo,"
        " a.detalhes, a.ip FROM auditoria a LEFT JOIN protocolos p ON p.id = a.protocolo_id "
        "ORDER BY a.id DESC LIMIT ?", (limite,)).fetchall()
    return jsonify([dict(r) for r in rows])


@app.get("/api/auditoria/verificar")
@exigir("GESTOR")
def verificar_auditoria():
    return jsonify(core.verificar_cadeia_auditoria(get_db()))


if __name__ == "__main__":
    import os
    core.iniciar_banco()
    # Servidor de desenvolvimento. Em produção use waitress/gunicorn atrás de HTTPS (veja o README).
    app.run(host=os.getenv("HOST", "127.0.0.1"), port=int(os.getenv("PORT", "5000")), debug=False)
