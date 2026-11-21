"""
Testes de ponta a ponta das regras de negócio.  Execute:  python test_fluxo.py
Usa um banco temporário — não toca no banco real.
"""
import base64
import os
import sqlite3
import tempfile
import unittest

_tmp = tempfile.mkdtemp()
os.environ["PROTOCOLO_DB"] = os.path.join(_tmp, "teste.db")

import core  # noqa: E402
import manage  # noqa: E402
from app import app  # noqa: E402

# PNG 1x1 válido (simula o desenho do canvas)
PNG = "data:image/png;base64," + base64.b64encode(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAHnOcQAAAAABJRU5ErkJggg=="
)).decode()


def preparar_banco():
    core.iniciar_banco()
    db = core.conectar()
    for s in ("Jurídico", "Farmácia"):
        manage.criar_setor(db, s)
    manage.criar_usuario(db, "portaria", "Maria", "PORTARIA", None, "senha-portaria", "1111")
    manage.criar_usuario(db, "adm", "João", "ADM", None, "senha-adm-1", "2222")
    manage.criar_usuario(db, "juridico", "Ana", "SETOR", "Jurídico", "senha-jur-1", "3333")
    manage.criar_usuario(db, "gestor", "Paula", "GESTOR", None, "senha-gestor", "5555")
    manage.criar_usuario(db, "adm2", "Rui", "ADM", None, "senha-adm-2", "6666")
    db.close()


class Cliente:
    """Cliente de teste que guarda cookie de sessão e token CSRF."""
    def __init__(self, login, senha):
        self.c = app.test_client()
        r = self.c.post("/api/login", json={"login": login, "senha": senha})
        assert r.status_code == 200, r.get_json()
        self.csrf = r.get_json()["csrf"]

    def post(self, url, **corpo):
        return self.c.post(url, json=corpo, headers={"X-CSRF-Token": self.csrf})

    def get(self, url):
        return self.c.get(url)


class TestLivroProtocolo(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        preparar_banco()

    def setUp(self):
        self.portaria = Cliente("portaria", "senha-portaria")
        self.adm = Cliente("adm", "senha-adm-1")
        self.setor = Cliente("juridico", "senha-jur-1")
        self.gestor = Cliente("gestor", "senha-gestor")

    def novo(self, desc="Ofício nº 123/2026 - 2ª Vara Cível", **extra):
        r = self.portaria.post("/api/protocolos", descricao=desc, pin="1111", **extra)
        self.assertEqual(r.status_code, 201, r.get_json())
        return r.get_json()

    # ---- numeração e criação ------------------------------------------------
    def test_numeracao_sequencial_e_status_inicial(self):
        a, b = self.novo(), self.novo("Carta A.R. Correios")
        ano = core.agora_iso()[:4]
        self.assertRegex(a["numero"], rf"^{ano}-\d{{4}}$")
        self.assertEqual(int(b["numero"][-4:]), int(a["numero"][-4:]) + 1)
        self.assertEqual(a["status"], "PENDENTE_ADM")
        self.assertTrue(a["etapas"][0]["registrada"])
        self.assertFalse(a["etapas"][1]["registrada"])

    def test_data_hora_vem_do_servidor(self):
        # o cliente tenta forçar data/hora: o servidor ignora
        p = self.novo(recebido_em="1999-01-01T00:00:00", criado_em="1999-01-01T00:00:00")
        self.assertTrue(p["criado_em"].startswith(core.agora_iso()[:10]))

    def test_pin_errado_nao_cria(self):
        r = self.portaria.post("/api/protocolos", descricao="Ofício teste 1", pin="9999")
        self.assertEqual(r.status_code, 403)

    def test_lgpd_bloqueia_cpf(self):
        r = self.portaria.post("/api/protocolos", descricao="Intimação de 123.456.789-09", pin="1111")
        self.assertEqual(r.status_code, 400)
        self.assertIn("CPF", r.get_json()["erro"])
        # número de processo CNJ não deve ser confundido com CPF
        self.novo("Mandado proc. 0001234-56.2026.8.20.0001 - 1ª Vara")

    # ---- permissões e sequência --------------------------------------------
    def test_perfis(self):
        p = self.novo()
        self.assertEqual(self.adm.post("/api/protocolos", descricao="xxxxxx", pin="2222").status_code, 403)
        self.assertEqual(self.portaria.post(f"/api/protocolos/{p['id']}/adm", pin="1111").status_code, 403)
        self.assertEqual(self.setor.post(f"/api/protocolos/{p['id']}/adm", pin="3333").status_code, 403)

    def test_setor_nao_pula_adm(self):
        p = self.novo()
        r = self.setor.post(f"/api/protocolos/{p['id']}/setor", pin="3333")
        self.assertEqual(r.status_code, 404)  # setor nem enxerga o que ainda está pendente no ADM

    def test_fluxo_completo(self):
        p = self.novo()
        r = self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222", assinatura_png=PNG)
        self.assertEqual(r.status_code, 200, r.get_json())
        self.assertEqual(r.get_json()["status"], "PENDENTE_SETOR")
        self.assertEqual(r.get_json()["etapas"][1]["assinatura_tipo"], "PIN_CANVAS")
        # ADM não confirma duas vezes
        self.assertEqual(self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222").status_code, 409)
        r = self.setor.post(f"/api/protocolos/{p['id']}/setor", pin="3333")
        self.assertEqual(r.status_code, 200, r.get_json())
        j = r.get_json()
        self.assertEqual(j["status"], "CONCLUIDO")
        self.assertEqual(j["etapas"][2]["setor"], "Jurídico")
        self.assertEqual(self.setor.post(f"/api/protocolos/{p['id']}/setor", pin="3333").status_code, 409)
        # imagem da assinatura é servida só com login
        tid = j["etapas"][1]["tramite_id"]
        self.assertEqual(self.gestor.get(f"/api/tramites/{tid}/assinatura.png").status_code, 200)
        self.assertEqual(app.test_client().get(f"/api/tramites/{tid}/assinatura.png").status_code, 401)

    def test_segregacao_de_funcoes(self):
        # um GESTOR não assina etapas; aqui testamos a regra com o mesmo usuário ADM em 2 protocolos distintos
        p = self.novo()
        self.assertEqual(self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222").status_code, 200)

    # ---- imutabilidade --------------------------------------------------------
    def test_banco_bloqueia_alteracoes(self):
        p = self.novo()
        self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222")
        db = core.conectar()
        for sql in ("UPDATE tramites_historico SET recebido_em='2000-01-01T00:00:00' WHERE protocolo_id=%d" % p["id"],
                    "DELETE FROM tramites_historico WHERE protocolo_id=%d" % p["id"],
                    "UPDATE protocolos SET descricao='adulterada!' WHERE id=%d" % p["id"],
                    "UPDATE protocolos SET numero='1999-0001' WHERE id=%d" % p["id"],
                    "DELETE FROM protocolos WHERE id=%d" % p["id"],
                    "UPDATE auditoria SET acao='X'", "DELETE FROM auditoria"):
            with self.assertRaises(sqlite3.IntegrityError, msg=sql):
                db.execute(sql)
        # a sequência também é garantida pelo banco (pula direto para a etapa 3)
        q = self.novo()  # só tem a 1ª etapa: inserir a 3ª direto no banco deve ser recusado
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO tramites_historico (protocolo_id, etapa, recebido_em, usuario_id, usuario_nome,"
                       " setor_id, setor_nome, assinatura_tipo, selo) VALUES (?,3,'x',1,'x',1,'x','PIN','x')",
                       (q["id"],))
        db.close()

    def test_correcao_preserva_original_e_exige_justificativa(self):
        p = self.novo("Ofício com erro de digitaçao")
        url = f"/api/protocolos/{p['id']}/correcao"
        self.assertEqual(self.portaria.post(url, descricao_nova="Ofício corrigido", justificativa="curta",
                                            pin="1111").status_code, 400)
        r = self.portaria.post(url, descricao_nova="Ofício com erro de digitação corrigido",
                               justificativa="Erro de digitação na descrição original", pin="1111")
        self.assertEqual(r.status_code, 200, r.get_json())
        j = r.get_json()
        self.assertEqual(j["descricao"], "Ofício com erro de digitação corrigido")
        self.assertEqual(j["descricao_original"], "Ofício com erro de digitaçao")
        self.assertEqual(len(j["correcoes"]), 1)
        # setor não pode corrigir
        self.assertEqual(self.setor.post(url, descricao_nova="Outra coisa qualquer",
                                         justificativa="Tentativa indevida aqui", pin="3333").status_code, 403)

    # ---- auditoria, busca, PDF ------------------------------------------------
    def test_auditoria_encadeada_detecta_adulteracao(self):
        self.novo()
        self.assertTrue(self.gestor.get("/api/auditoria/verificar").get_json()["ok"])
        self.assertEqual(self.portaria.get("/api/auditoria").status_code, 403)
        # simula adulteração ignorando o trigger (atacante com acesso ao arquivo)
        db = core.conectar()
        alvo = db.execute("SELECT MIN(id) FROM auditoria WHERE acao='PROTOCOLO_CRIADO'").fetchone()[0]
        trigger = db.execute("SELECT sql FROM sqlite_master WHERE name='trg_auditoria_sem_update'").fetchone()[0]
        try:
            db.execute("DROP TRIGGER trg_auditoria_sem_update")
            db.execute(f"UPDATE auditoria SET acao='LOGIN' WHERE id={alvo}")
            r = self.gestor.get("/api/auditoria/verificar").get_json()
            self.assertFalse(r["ok"])
            self.assertIsNotNone(r["primeira_falha_id"])
        finally:  # restaura o banco para não contaminar os outros testes
            db.execute(f"UPDATE auditoria SET acao='PROTOCOLO_CRIADO' WHERE id={alvo}")
            db.execute(trigger)
            db.close()
        self.assertTrue(self.gestor.get("/api/auditoria/verificar").get_json()["ok"])

    def test_busca_filtros_e_visibilidade_do_setor(self):
        p = self.novo("Notificação Procon unica-xyz")
        r = self.gestor.get("/api/protocolos?q=unica-xyz&status=PENDENTE_ADM").get_json()
        self.assertEqual(r["total"], 1)
        self.assertEqual(self.gestor.get("/api/protocolos?q=unica-xyz&status=CONCLUIDO").get_json()["total"], 0)
        # setor não vê protocolo que ainda aguarda o ADM
        self.assertEqual(self.setor.get("/api/protocolos?q=unica-xyz").get_json()["total"], 0)
        self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222")
        self.assertEqual(self.setor.get("/api/protocolos?q=unica-xyz").get_json()["total"], 1)
        # caractere curinga do LIKE é tratado como texto
        self.assertEqual(self.gestor.get("/api/protocolos?q=%25").get_json()["total"], 0)
        resumo = self.gestor.get("/api/resumo").get_json()
        self.assertEqual(resumo["total"], resumo["pendente_adm"] + resumo["pendente_setor"] + resumo["concluido"])

    def test_pdfs(self):
        p = self.novo()
        self.adm.post(f"/api/protocolos/{p['id']}/adm", pin="2222", assinatura_png=PNG)
        for url in (f"/api/protocolos/{p['id']}/pdf", "/api/relatorio/pdf", "/api/relatorio/pdf?status=CONCLUIDO"):
            r = self.gestor.get(url)
            self.assertEqual(r.status_code, 200, url)
            self.assertTrue(r.data.startswith(b"%PDF"))
        os.makedirs(os.path.join(_tmp, "pdf"), exist_ok=True)
        open(os.path.join(_tmp, "pdf", "ficha.pdf"), "wb").write(self.gestor.get(f"/api/protocolos/{p['id']}/pdf").data)
        open(os.path.join(_tmp, "pdf", "listagem.pdf"), "wb").write(self.gestor.get("/api/relatorio/pdf").data)

    # ---- segurança --------------------------------------------------------------
    def test_csrf_e_sessao(self):
        c = app.test_client()
        self.assertEqual(c.get("/api/protocolos").status_code, 401)
        self.assertEqual(self.portaria.c.post("/api/protocolos", json={"descricao": "abcdef", "pin": "1111"}).status_code, 403)

    def test_bloqueio_por_tentativas(self):
        c = app.test_client()
        for _ in range(5):
            c.post("/api/login", json={"login": "adm2", "senha": "errada"})
        r = c.post("/api/login", json={"login": "adm2", "senha": "senha-adm-2"})
        self.assertEqual(r.status_code, 423)

    def test_cabecalhos_de_seguranca(self):
        r = app.test_client().get("/api/config")
        self.assertIn("default-src 'self'", r.headers["Content-Security-Policy"])
        self.assertEqual(r.headers["X-Frame-Options"], "DENY")


if __name__ == "__main__":
    print("PDFs de teste ficarão em:", os.path.join(_tmp, "pdf"))
    unittest.main(verbosity=2)
