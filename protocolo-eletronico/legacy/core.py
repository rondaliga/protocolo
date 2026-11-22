"""
Núcleo do sistema: configuração, banco de dados, relógio do servidor,
trilha de auditoria encadeada, validações e verificação de credenciais.

Nada aqui depende do Flask (facilita testes e uso pela CLI manage.py).
"""
import base64
import hashlib
import json
import os
import re
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

from werkzeug.security import check_password_hash

# ----------------------------------------------------------------------
# Configuração (variáveis de ambiente, com padrões seguros)
# ----------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.getenv("PROTOCOLO_DB", BASE_DIR / "instance" / "protocolo.db"))
LOGO_PATH = BASE_DIR / "static" / "logo.png"           # opcional: coloque o logotipo aqui

UNIDADE = os.getenv("UNIDADE", "CECAN - LNRCC")
SESSAO_MINUTOS = int(os.getenv("SESSAO_MINUTOS", "30"))
COOKIE_SEGURO = os.getenv("COOKIE_SEGURO", "0") == "1"  # use 1 quando houver HTTPS
ASSINATURA_OBRIGATORIA = os.getenv("ASSINATURA_OBRIGATORIA", "0") == "1"  # exige desenho no canvas
SEGREGACAO_FUNCOES = os.getenv("SEGREGACAO_FUNCOES", "1") == "1"  # mesma pessoa não assina 2 etapas

MAX_FALHAS = 5          # tentativas erradas de senha/PIN antes do bloqueio
BLOQUEIO_MINUTOS = 5

STATUS_ROTULO = {
    "PENDENTE_ADM": "Pendente ADM",
    "PENDENTE_SETOR": "Pendente Setor Final",
    "CONCLUIDO": "Concluído / Entregue",
}
PERFIS = ("PORTARIA", "ADM", "SETOR", "GESTOR")

# ----------------------------------------------------------------------
# Relógio do servidor (fonte única de data/horário — o cliente nunca informa)
# ----------------------------------------------------------------------
try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo(os.getenv("APP_TZ", "America/Fortaleza"))
except Exception:  # Windows sem tzdata: o Brasil não tem horário de verão desde 2019
    TZ = timezone(timedelta(hours=-3))


def agora() -> datetime:
    return datetime.now(TZ).replace(microsecond=0)


def agora_iso() -> str:
    return agora().isoformat()


def fmt_data(iso: str) -> str:
    return f"{iso[8:10]}/{iso[5:7]}/{iso[0:4]}" if iso else ""


def fmt_hora(iso: str) -> str:
    return iso[11:19] if iso else ""


# ----------------------------------------------------------------------
# Erros de API
# ----------------------------------------------------------------------
class ApiError(Exception):
    def __init__(self, mensagem: str, status: int = 400):
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.status = status


# ----------------------------------------------------------------------
# Banco de dados
# ----------------------------------------------------------------------
def conectar() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    # isolation_level=None: nós controlamos BEGIN/COMMIT explicitamente
    db = sqlite3.connect(DB_PATH, isolation_level=None, timeout=15)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("PRAGMA busy_timeout = 15000")
    return db


def iniciar_banco() -> None:
    db = conectar()
    try:
        db.executescript((BASE_DIR / "schema.sql").read_text(encoding="utf-8"))
    finally:
        db.close()


@contextmanager
def transacao(db: sqlite3.Connection):
    """BEGIN IMMEDIATE ... COMMIT. Se já houver transação aberta, apenas participa dela."""
    if db.in_transaction:
        yield
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        yield
    except BaseException:
        db.execute("ROLLBACK")
        raise
    else:
        db.execute("COMMIT")


# ----------------------------------------------------------------------
# Trilha de auditoria (encadeamento de hash)
# ----------------------------------------------------------------------
GENESIS = "0" * 64


def _hash_auditoria(anterior, quando, uid, acao, pid, detalhes, ip) -> str:
    bruto = f"{anterior}|{quando}|{uid}|{acao}|{pid}|{detalhes}|{ip}"
    return hashlib.sha256(bruto.encode("utf-8")).hexdigest()


def auditar(db, acao, usuario=None, protocolo_id=None, detalhes=None, ip=None) -> None:
    with transacao(db):
        ultimo = db.execute("SELECT hash FROM auditoria ORDER BY id DESC LIMIT 1").fetchone()
        anterior = ultimo["hash"] if ultimo else GENESIS
        quando = agora_iso()
        uid = usuario["id"] if usuario else None
        unome = usuario["nome"] if usuario else None
        det = json.dumps(detalhes or {}, ensure_ascii=False, sort_keys=True)
        h = _hash_auditoria(anterior, quando, uid, acao, protocolo_id, det, ip)
        db.execute(
            "INSERT INTO auditoria (ocorrido_em, usuario_id, usuario_nome, acao, protocolo_id,"
            " detalhes, ip, hash_anterior, hash) VALUES (?,?,?,?,?,?,?,?,?)",
            (quando, uid, unome, acao, protocolo_id, det, ip, anterior, h),
        )


def verificar_cadeia_auditoria(db) -> dict:
    anterior = GENESIS
    total = 0
    for r in db.execute("SELECT * FROM auditoria ORDER BY id"):
        total += 1
        esperado = _hash_auditoria(anterior, r["ocorrido_em"], r["usuario_id"], r["acao"],
                                   r["protocolo_id"], r["detalhes"], r["ip"])
        if r["hash_anterior"] != anterior or r["hash"] != esperado:
            return {"ok": False, "total": total, "primeira_falha_id": r["id"]}
        anterior = r["hash"]
    return {"ok": True, "total": total, "primeira_falha_id": None}


# ----------------------------------------------------------------------
# Validações
# ----------------------------------------------------------------------
_CPF = re.compile(r"(?<!\d)\d{3}\.?\d{3}\.?\d{3}-?\d{2}(?!\d)")


def validar_descricao(texto) -> str:
    """Normaliza espaços e aplica minimização de dados (LGPD): bloqueia CPF."""
    limpo = " ".join(str(texto or "").split())
    if not 5 <= len(limpo) <= 300:
        raise ApiError("A descrição deve ter entre 5 e 300 caracteres.")
    if _CPF.search(limpo):
        raise ApiError("A descrição parece conter um CPF. Informe apenas o necessário para "
                       "identificar o documento (ex.: tipo, número do ofício, órgão de origem).")
    return limpo


def ler_assinatura(valor):
    """Valida o data-URL PNG enviado pelo canvas. Retorna bytes ou None."""
    if not valor:
        return None
    if not isinstance(valor, str) or not valor.startswith("data:image/png;base64,"):
        raise ApiError("Assinatura inválida.")
    try:
        bruto = base64.b64decode(valor.split(",", 1)[1], validate=True)
    except Exception:
        raise ApiError("Assinatura inválida.")
    if len(bruto) > 200_000 or not bruto.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ApiError("Assinatura inválida ou grande demais.")
    return bruto


def selo_integridade(numero, etapa, usuario_id, quando, setor_id, png) -> str:
    h = hashlib.sha256()
    h.update(f"{numero}|{etapa}|{usuario_id}|{quando}|{setor_id}".encode("utf-8"))
    if png:
        h.update(hashlib.sha256(png).digest())
    return h.hexdigest()


# ----------------------------------------------------------------------
# Credenciais com bloqueio por tentativas
# ----------------------------------------------------------------------
def checar_segredo(db, usuario, segredo: str, campo: str, ip=None) -> None:
    """
    Confere senha (campo='senha_hash') ou PIN (campo='pin_hash').
    Senha e PIN compartilham o contador de falhas: 5 erros => bloqueio de 5 min.
    """
    bloqueado = usuario["bloqueado_ate"]
    if bloqueado and datetime.fromisoformat(bloqueado) > agora():
        raise ApiError("Usuário temporariamente bloqueado por tentativas inválidas. "
                       "Aguarde alguns minutos.", 423)

    if segredo and check_password_hash(usuario[campo], segredo):
        if usuario["falhas_consecutivas"] or bloqueado:
            with transacao(db):
                db.execute("UPDATE usuarios SET falhas_consecutivas=0, bloqueado_ate=NULL WHERE id=?",
                           (usuario["id"],))
        return

    with transacao(db):
        falhas = db.execute("SELECT falhas_consecutivas FROM usuarios WHERE id=?",
                            (usuario["id"],)).fetchone()[0] + 1
        if falhas >= MAX_FALHAS:
            ate = (agora() + timedelta(minutes=BLOQUEIO_MINUTOS)).isoformat()
            db.execute("UPDATE usuarios SET falhas_consecutivas=0, bloqueado_ate=? WHERE id=?",
                       (ate, usuario["id"]))
            auditar(db, "USUARIO_BLOQUEADO", usuario, None, {"motivo": campo}, ip)
        else:
            db.execute("UPDATE usuarios SET falhas_consecutivas=? WHERE id=?", (falhas, usuario["id"]))
            auditar(db, "FALHA_AUTENTICACAO", usuario, None, {"campo": campo}, ip)
    raise ApiError("PIN inválido." if campo == "pin_hash" else "Login ou senha inválidos.", 401
                   if campo == "senha_hash" else 403)


def obter_chave_secreta() -> bytes:
    """SECRET_KEY do ambiente, ou arquivo instance/secret.key gerado na 1ª execução."""
    env = os.getenv("SECRET_KEY")
    if env:
        return env.encode("utf-8")
    arquivo = DB_PATH.parent / "secret.key"
    if not arquivo.exists():
        arquivo.parent.mkdir(parents=True, exist_ok=True)
        arquivo.write_bytes(os.urandom(32))
        try:
            os.chmod(arquivo, 0o600)
        except OSError:
            pass
    return arquivo.read_bytes()
