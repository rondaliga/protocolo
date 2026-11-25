#!/usr/bin/env python3
"""
Teste E2E no navegador (Playwright): site real (dist/) + mock_supabase.py + PostgreSQL real.
Pré-requisitos: dist/ gerado com SUPABASE_URL=http://127.0.0.1:5057 ; banco preparado (preparar_db.sh).
Uso: python3 run_e2e.py [pasta_de_saida]
"""
import os, shlex, subprocess, sys, time
from pathlib import Path
from playwright.sync_api import expect, sync_playwright

AQUI = Path(__file__).resolve().parent
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/e2e-out"); OUT.mkdir(parents=True, exist_ok=True)
PORTA = 5057
URL = f"http://127.0.0.1:{PORTA}/"
SENHA = "Trocar@123"
problemas = []
from PIL import Image, ImageDraw
FOTO = OUT / "envelope.jpg"
_im = Image.new("RGB", (2400, 1600), (240, 235, 220)); ImageDraw.Draw(_im).rectangle((300, 300, 2100, 1300), outline=(30, 60, 90), width=20)
_im.save(FOTO, "JPEG", quality=95)

srv = subprocess.Popen([sys.executable, str(AQUI / "mock_supabase.py"), str(PORTA), "protocolo_e2e"],
                       env=dict(os.environ), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1.5)


def psql(q):
    return subprocess.run(["psql", "-d", "protocolo_e2e", "-tA", "-c", q], capture_output=True, text=True).stdout.strip()


def login(page, usuario, senha=SENHA, email=None):
    page.goto(URL)
    page.locator("#form-login").wait_for(state="visible")
    page.fill("input[name=email]", email or f"{usuario}@teste.local")
    page.fill("input[name=senha]", senha)
    page.click("#form-login button[type=submit]")
    page.locator("#view-app").wait_for(state="visible")
    page.locator("#tbody, #vazio").first.wait_for(state="attached")
    page.wait_for_timeout(500)


def assinar(page, form):
    """modo 'Desenhar': escolhe o quadro e rabisca"""
    page.click(f"{form} .modo[data-modo=desenhada]")
    sel = f"{form} canvas.quadro"
    b = page.locator(sel).bounding_box()
    page.mouse.move(b["x"] + 30, b["y"] + 100); page.mouse.down()
    for i in range(1, 12): page.mouse.move(b["x"] + 30 + i * 20, b["y"] + 100 - (i % 3) * 25)
    page.mouse.up()


def abrir_item_conta(page, seletor):
    page.click("#btn-conta"); page.locator("#menu-conta").wait_for(state="visible"); page.click(seletor)


def sair(page):
    page.click("#btn-sair"); page.locator("#view-login").wait_for(state="visible")


def pdf_da_impressao(page, nome, paisagem):
    page.emulate_media(media="print")
    page.pdf(path=str(OUT / nome), prefer_css_page_size=True, print_background=True)
    page.emulate_media(media="screen")


def esperar_toast(page, trecho):
    try:
        page.locator("#toast:not([hidden])", has_text=trecho).wait_for(timeout=8000)
    except Exception:
        print(f"FALHA: esperava toast com «{trecho}»; toast atual: {page.inner_text('#toast')!r}; hidden={page.get_attribute('#toast', 'hidden')!r}")
        raise
    print("toast:", page.inner_text("#toast"))


try:
    with sync_playwright() as p:
        CAM = ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]
        try: b = p.chromium.launch(args=CAM)
        except Exception: b = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"] + CAM)
        ctx = b.new_context(viewport={"width": 1366, "height": 820}, permissions=["camera"])
        page = ctx.new_page()
        page.add_init_script("window.print = () => { window.__imprimiu = (window.__imprimiu || 0) + 1; };")
        page.on("console", lambda m: problemas.append(f"console[{m.type}]: {m.text}") if m.type == "error" and "status of 4" not in m.text else None)
        page.on("pageerror", lambda e: problemas.append(f"pageerror: {e}"))

        # login inválido
        page.goto(URL); page.fill("input[name=email]", "portaria@teste.local"); page.fill("input[name=senha]", "errada")
        page.click("#form-login button[type=submit]"); page.locator("#login-erro").wait_for(state="visible")
        print("login inválido:", page.inner_text("#login-erro")); assert "inválidos" in page.inner_text("#login-erro")

        # 1) PORTARIA
        login(page, "portaria")
        assert page.locator("#btn-novo").is_visible() and page.locator("#btn-aba-auditoria").is_hidden()
        page.screenshot(path=str(OUT / "1_dashboard_portaria.png"))
        page.click("#btn-novo")
        assert "Evitar registrar informações pessoais ou sigilosas" in page.inner_text("#form-novo .aviso")
        page.fill("textarea[name=descricao]", "Intimação de 123.456.789-09"); page.fill("#form-novo input[name=pin]", "1111")
        page.click("#form-novo .modo[data-modo=digitada]")
        page.click("#form-novo button[type=submit]"); page.locator("#form-novo .erro").wait_for(state="visible")
        print("CPF:", page.inner_text("#form-novo .erro")); assert "CPF" in page.inner_text("#form-novo .erro")
        page.fill("textarea[name=descricao]", "Ofício nº 123/2026 - 2ª Vara Cível <b>teste-xss</b>")
        # judicial exige foto
        page.select_option("#form-novo select[name=tipo]", "judicial")
        assert page.locator("#lbl-urgente").is_visible()
        page.fill("#form-novo input[name=pin]", "1111"); page.click("#form-novo button[type=submit]")
        page.locator("#form-novo .erro").wait_for(state="visible"); print("sem foto:", page.inner_text("#form-novo .erro"))
        assert "foto" in page.inner_text("#form-novo .erro")
        page.set_input_files("#inp-foto", str(FOTO)); page.locator("#foto-previa").wait_for(state="visible")
        page.check("#form-novo input[name=urgente]")
        page.fill("#form-novo input[name=pin]", "9999"); page.click("#form-novo button[type=submit]")
        page.wait_for_timeout(600); print("PIN errado:", page.inner_text("#form-novo .erro")); assert "PIN" in page.inner_text("#form-novo .erro")
        assinar(page, "#form-novo"); page.fill("#form-novo input[name=pin]", "1111")
        page.screenshot(path=str(OUT / "2_modal_novo.png"))
        page.click("#form-novo button[type=submit]"); esperar_toast(page, "registrado")
        page.wait_for_timeout(500)
        assert "<b>" not in page.inner_html("#tbody").replace("&lt;b&gt;", ""), "XSS: HTML não escapado"
        assert "teste-xss" in page.inner_text("#tbody")
        assert "JUDICIAL" in page.inner_text("#tbody") and "URGENTE" in page.inner_text("#tbody")
        page.screenshot(path=str(OUT / "2b_lista_portaria.png"))
        # segundo registro (para filtros) — correspondência comum
        page.click("#btn-novo"); page.fill("textarea[name=descricao]", "Carta A.R. Correios"); page.click("#form-novo .modo[data-modo=digitada]"); page.fill("#form-novo input[name=pin]", "1111")
        page.click("#form-novo button[type=submit]"); page.wait_for_timeout(700)
        sair(page)

        # 2) ADM
        login(page, "adm")
        assert page.locator("#btn-novo").is_hidden()
        assert page.inner_text("#sino-n") == "2", page.inner_text("#sino-n")        # sino: 2 chegadas aguardando o ADM
        page.click("#btn-sino"); assert "2026-0001" in page.inner_text("#lista-sino")
        page.screenshot(path=str(OUT / "2c_sino_adm.png")); page.click("#btn-sino")
        page.click("#tbody tr:has-text('2026-0001')"); page.locator("#dlg-detalhe[open]").wait_for()
        page.locator("#det-fotos img.foto-det").wait_for(timeout=8000)              # foto carregada do bucket privado
        page.screenshot(path=str(OUT / "2d_detalhe_judicial.png"))
        page.click("[data-acao=adm]")
        page.locator("#sel-destino option", has_text="Jurídico").wait_for(state="attached")
        page.select_option("#sel-destino", label="Jurídico")
        page.fill("#form-confirmar input[name=pin]", "0000"); page.click("#form-confirmar button[type=submit]")
        page.locator("#form-confirmar .erro").wait_for(state="visible"); print("PIN errado ADM:", page.inner_text("#form-confirmar .erro"))
        page.click("#form-confirmar .modo[data-modo=digitada]")
        assert page.input_value("#form-confirmar .assin-texto") == "João (Administração)"          # nome já vem preenchido
        page.click("#form-confirmar .estilo[data-estilo=elegante]")
        assert page.get_attribute("#form-confirmar .estilo[data-estilo=elegante]", "aria-checked") == "true"
        page.fill("#form-confirmar .assin-texto", "João Pereira"); page.fill("#form-confirmar input[name=pin]", "2222")
        page.screenshot(path=str(OUT / "3_confirmar_adm.png"))
        page.click("#form-confirmar button[type=submit]"); esperar_toast(page, "ADM registrado")
        page.wait_for_timeout(700)
        page.screenshot(path=str(OUT / "4_detalhe_apos_adm.png"))
        assert "Aguardando setor de destino" in page.inner_text("#detalhe-corpo")
        assert "Assinatura digitada" in page.inner_text("#detalhe-corpo") and "Assinatura desenhada" in page.inner_text("#detalhe-corpo")
        page.click("#detalhe-corpo [data-fechar]")
        # ajuste de prazo (ADM) na correspondência ainda pendente
        page.click("#tbody tr:has-text('2026-0002')"); page.click("[data-acao=prazo]")
        page.fill("#form-prazo input[name=data]", (__import__("datetime").date.today() + __import__("datetime").timedelta(days=30)).isoformat())
        page.fill("#form-prazo textarea[name=justificativa]", "Prazo de 10 dias informado no ofício"); page.fill("#form-prazo input[name=pin]", "2222")
        page.click("#form-prazo button[type=submit]"); esperar_toast(page, "Prazo ajustado"); page.wait_for_timeout(700)
        assert "histórico de alterações" in page.inner_text("#detalhe-corpo").lower()
        page.screenshot(path=str(OUT / "4b_prazo.png"))
        page.click("#detalhe-corpo [data-fechar]"); sair(page)

        # 3) SETOR (Farmácia não vê; Jurídico confirma)
        login(page, "farmacia")
        page.wait_for_timeout(300); n_far = page.locator("#tbody tr[data-id]").count(); print("farmácia vê:", n_far); assert n_far == 0, "setor errado não pode ver"
        assert page.inner_text("#sino-n") == "0" or page.locator("#sino-n").is_hidden()
        sair(page)
        login(page, "juridico")
        assert page.inner_text("#sino-n") == "1"
        page.click("#tbody tr[data-id]:first-child"); page.click("[data-acao=setor]")
        assert "Jurídico" in page.inner_text("#conf-setor-info")
        page.click("#form-confirmar .modo[data-modo=digitada]"); page.fill("#form-confirmar input[name=pin]", "3333"); page.click("#form-confirmar button[type=submit]")
        esperar_toast(page, "concluída"); page.wait_for_timeout(700)
        assert "Concluído / Entregue" in page.inner_text("#detalhe-corpo")
        # ficha para impressão (A4 retrato)
        page.click("[data-acao=imprimir]"); page.wait_for_timeout(700)
        assert page.evaluate("window.__imprimiu") == 1
        pdf_da_impressao(page, "ficha.pdf", False)
        page.click("#detalhe-corpo [data-fechar]"); sair(page)

        # 4) GESTOR
        login(page, "gestor")
        page.screenshot(path=str(OUT / "5_dashboard_gestor.png"))
        cards = [page.inner_text(s) for s in ("#k-total", "#k-adm", "#k-setor", "#k-ok")]; print("KPIs:", cards)
        assert cards == ["2", "1", "0", "1"], cards
        assert page.inner_text("#k-venc") == "0"
        page.select_option("select[name=ordem]", "prazo"); page.wait_for_timeout(500)
        assert page.locator("#tbody tr[data-id]").count() == 2
        page.select_option("select[name=ordem]", "recentes")
        page.click(".k-ok"); page.wait_for_timeout(600)
        assert page.locator("#tbody tr[data-id]").count() == 1 and page.inner_text("#contagem").startswith("1 ")
        page.click("#btn-limpar"); page.wait_for_timeout(500)
        page.fill("#form-filtros input[name=q]", "carta")                  # busca instantânea (debounce)
        expect(page.locator("#tbody tr[data-id]")).to_have_count(1, timeout=6000)
        page.fill("#form-filtros input[name=q]", "%")                      # curinga tratado como texto
        expect(page.locator("#tbody tr[data-id]")).to_have_count(0, timeout=6000)
        page.click("#btn-limpar"); page.wait_for_timeout(500)
        # correção de descrição
        page.click("#tbody tr:has-text('Carta A.R.')"); page.click("[data-acao=corrigir]")
        page.fill("#form-correcao textarea[name=descricao_nova]", "Carta A.R. Correios - Vara Federal")
        page.fill("#form-correcao textarea[name=justificativa]", "Complemento do órgão de origem"); page.fill("#form-correcao input[name=pin]", "5555")
        page.click("#form-correcao button[type=submit]"); esperar_toast(page, "Correção"); page.wait_for_timeout(700)
        assert "Descrição original: Carta A.R. Correios" in page.inner_text("#detalhe-corpo")
        page.click("#detalhe-corpo [data-fechar]")
        # livro para impressão (A4 paisagem)
        page.click("#btn-imprimir-livro"); page.wait_for_timeout(1200)
        assert page.evaluate("window.__imprimiu") == 1
        assert page.locator("#print-root.livro table.p-tab tbody tr").count() == 2
        assert page.locator("#print-root.livro table.p-tab thead tr").count() == 2 and page.locator("#print-root.livro thead th[colspan=\"2\"]").count() == 3
        pdf_da_impressao(page, "livro.pdf", True)
        # alterar PIN
        abrir_item_conta(page, "#btn-pin"); page.fill("#form-pin input[name=atual]", "5555"); page.fill("#form-pin input[name=novo]", "5556")
        page.click("#form-pin button[type=submit]"); esperar_toast(page, "PIN alterado"); page.wait_for_timeout(300)
        # auditoria
        page.click("#btn-aba-auditoria"); page.click("#btn-verificar"); page.locator("#resultado-verificacao:not(:empty)").wait_for()
        print("auditoria:", page.inner_text("#resultado-verificacao")); assert "íntegra" in page.inner_text("#resultado-verificacao")
        txt = page.inner_text("#tbody-audit")
        assert "Livro impresso" in txt and "Ficha impressa" in txt and "Entrou no sistema" in txt and "Descrição corrigida" in txt
        assert "{" not in txt and "IMPRESSAO_" not in txt, "a trilha não deve mostrar JSON/códigos crus"
        assert "2026-0001" in page.inner_text("#tbody-audit tr:has-text('Ficha impressa')"), "ficha impressa deve citar o nº"
        page.screenshot(path=str(OUT / "6_auditoria.png"))
        # filtros da trilha
        page.select_option("#form-aud select[name=categoria]", "correcao"); page.wait_for_timeout(700)
        assert page.locator("#tbody-audit tr").count() == 1 and "Descrição corrigida" in page.inner_text("#tbody-audit")
        page.select_option("#form-aud select[name=categoria]", ""); page.fill("#form-aud input[name=q]", "2026-0002"); page.wait_for_timeout(900)
        assert page.locator("#tbody-audit tr").count() >= 3, page.inner_text("#aud-contagem")
        page.fill("#form-aud input[name=q]", ""); page.wait_for_timeout(700)
        page.click("#tbody-audit button[data-prot]"); page.locator("#dlg-detalhe[open]").wait_for()           # nº do protocolo abre a ficha
        page.click("#detalhe-corpo [data-fechar]")
        with page.expect_download() as dl: page.click("#aud-csv")
        csv = Path(dl.value.path()).read_text(encoding="utf-8-sig"); assert "Protocolo registrado" in csv and "Data;Hora;Tipo" in csv.replace('"', "")
        with page.expect_download() as dx: page.click("#aud-xlsx")
        xp = Path(dx.value.path()); import shutil; shutil.copy(xp, Path(sys.argv[1]) / "trilha.xlsx")
        assert dx.value.suggested_filename.endswith(".xlsx")
        txt_trilha = page.inner_text("#tbody-audit"); assert "Descrição:" in txt_trilha or "Sem filtros" in txt_trilha or "Protocolo" in txt_trilha
        page.click("#aud-imprimir"); page.wait_for_timeout(1200)
        assert page.locator("#print-root.livro table.p-tab tbody tr").count() >= 5
        assert page.locator("#print-root.livro table.p-tab thead tr").count() == 1 and page.locator("#print-root .p-rodape").count() == 0
        pdf_da_impressao(page, "trilha.pdf", True)
        page.evaluate("document.getElementById('print-root').innerHTML=''")

        # ---------- GESTOR com acesso total: registra, recebe como ADM e como setor ----------
        page.click("[data-aba=protocolos]"); assert page.locator("#btn-novo").is_visible()
        page.click("#btn-novo"); page.fill("textarea[name=descricao]", "Ofício interno da Gestão nº 7")
        page.click("#form-novo .modo[data-modo=digitada]"); page.click("#form-novo .estilo[data-estilo=rubrica]"); page.fill("#form-novo input[name=pin]", "5556")
        page.click("#form-novo button[type=submit]"); esperar_toast(page, "registrado"); page.wait_for_timeout(600)
        page.click("#tbody tr:has-text('Gestão nº 7')"); page.click("[data-acao=adm]")
        page.locator("#sel-destino option", has_text="Farmácia").wait_for(state="attached")
        page.select_option("#sel-destino", label="Farmácia"); page.click("#form-confirmar .modo[data-modo=digitada]"); page.fill("#form-confirmar input[name=pin]", "5556")
        page.click("#form-confirmar button[type=submit]"); esperar_toast(page, "ADM registrado"); page.wait_for_timeout(600)
        page.click("[data-acao=setor]"); assert "em nome do setor de destino: Farmácia" in page.inner_text("#conf-setor-info")
        page.click("#form-confirmar .modo[data-modo=pin]")                                          # só PIN (assinatura visual opcional)
        page.fill("#form-confirmar input[name=pin]", "5556"); page.click("#form-confirmar button[type=submit]")
        esperar_toast(page, "concluída"); page.wait_for_timeout(600)
        assert "Concluído / Entregue" in page.inner_text("#detalhe-corpo")
        page.screenshot(path=str(OUT / "6b_gestor_total.png"))
        page.click("#detalhe-corpo [data-fechar]")

        # ---------- PAINEL DE CONTROLE ----------
        page.click("#btn-aba-painel"); page.locator("#tbody-usr tr").first.wait_for()
        assert page.locator("#tbody-usr tr").count() == 5, page.locator("#tbody-usr tr").count()
        page.screenshot(path=str(OUT / "8_painel_usuarios.png"))
        page.click("#usr-novo"); assert len(page.input_value("#form-usuario input[name=senha]")) == 12      # senha provisória gerada
        page.fill("#form-usuario input[name=email]", "novo.adm@teste.local"); page.fill("#form-usuario input[name=nome]", "Rita Nova (ADM)")
        page.select_option("#form-usuario select[name=papel]", "adm")
        senha_prov = page.input_value("#form-usuario input[name=senha]"); pin_prov = page.input_value("#form-usuario input[name=pin_novo]")
        page.fill("#form-usuario input[name=pin]", "0000"); page.click("#form-usuario button[type=submit]")
        page.wait_for_timeout(600); assert "PIN" in page.inner_text("#form-usuario .erro")                   # PIN do gestor errado
        page.fill("#form-usuario input[name=pin]", "5556"); page.click("#form-usuario button[type=submit]")
        page.locator("#dlg-credencial[open]").wait_for(); cred = page.inner_text("#cred-dados")
        assert senha_prov in cred and pin_prov in cred and "novo.adm@teste.local" in cred, cred
        expect(page.locator("#cred-email-msg")).to_contain_text("novo.adm@teste.local", timeout=8000)
        corpo_bv = psql("select corpo from public.fila_email where evento='BOAS_VINDAS' and destinatarios=array['novo.adm@teste.local'] order by id desc limit 1")
        assert senha_prov in corpo_bv and pin_prov in corpo_bv and "Prezado(a)" in corpo_bv and "PRIMEIRO ACESSO" in corpo_bv, corpo_bv
        page.screenshot(path=str(OUT / "8b_credenciais.png")); page.click("#dlg-credencial [data-fechar]"); page.wait_for_timeout(300)
        assert page.locator("#tbody-usr tr").count() == 6
        assert "Primeiro acesso pendente" in page.inner_text("#tbody-usr tr:has-text('Rita Nova')")
        page.select_option("#usr-filtro-papel", "adm"); assert page.locator("#tbody-usr tr").count() == 2; page.select_option("#usr-filtro-papel", "")
        # setor, regras e feriado
        page.click("[data-sub=cadastros]"); page.click("#set-novo"); page.fill("#form-setor input[name=nome]", "Superintendência Teste")
        page.click("#form-setor button[type=submit]"); esperar_toast(page, "Setor salvo"); page.wait_for_timeout(400)
        assert "Superintendência Teste" in page.inner_text("#tbody-set")
        page.click("[data-sub=sistema]"); page.locator("#form-param input[name=sessao_inatividade_min]").wait_for()
        page.click("[data-sub=cadastros]"); page.fill("#form-feriado input[name=data]", "2027-02-09"); page.fill("#form-feriado input[name=descricao]", "Carnaval")
        page.click("#form-feriado button[type=submit]"); esperar_toast(page, "Feriado cadastrado"); page.wait_for_timeout(400)
        assert "Carnaval" in page.inner_text("#tbody-fer"); page.click("#tbody-fer button"); page.wait_for_timeout(500)
        page.click("[data-sub=sistema]"); page.click("[data-ir=sis-uso]"); page.locator("#sistema-kpis .kpi").first.wait_for(); assert "usuários ativos" in page.inner_text("#sistema-kpis").lower()
        page.screenshot(path=str(OUT / "8c_painel_sistema.png"))
        sair(page)

        # ---------- PRIMEIRO ACESSO do usuário criado ----------
        login(page, None, senha=senha_prov, email="novo.adm@teste.local")
        page.locator("#dlg-conta[open]").wait_for()
        assert page.locator("#conta-cancelar").is_hidden() and page.locator("#conta-bloco-pin").is_visible()
        page.keyboard.press("Escape"); page.wait_for_timeout(200); assert page.locator("#dlg-conta[open]").count() == 1, "Esc não pode pular o primeiro acesso"
        page.fill("#form-conta input[name=senha]", "Nova-Senha-2026"); page.fill("#form-conta input[name=senha2]", "Outra-Senha-2026")
        page.fill("#form-conta input[name=pin_atual]", pin_prov); page.fill("#form-conta input[name=pin_novo]", "2580"); page.fill("#form-conta input[name=pin_novo2]", "2580")
        page.click("#form-conta button[type=submit]"); assert "não conferem" in page.inner_text("#form-conta .erro")
        page.fill("#form-conta input[name=senha2]", "Nova-Senha-2026"); page.fill("#form-conta input[name=pin_atual]", "999999")
        page.click("#form-conta button[type=submit]"); page.wait_for_timeout(700)
        assert "PIN" in page.inner_text("#form-conta .erro") and page.locator("#conta-bloco-senha").is_hidden()   # senha já trocada; falta só o PIN
        page.fill("#form-conta input[name=pin_atual]", pin_prov); page.fill("#form-conta input[name=pin_novo]", "2580"); page.fill("#form-conta input[name=pin_novo2]", "2580")
        page.click("#form-conta button[type=submit]"); esperar_toast(page, "Credenciais definidas")
        page.screenshot(path=str(OUT / "9_primeiro_acesso_ok.png"))
        assert page.locator("#btn-aba-painel").is_hidden() and page.locator("#btn-aba-auditoria").is_hidden()     # ADM não vê o painel
        sair(page)
        page.goto(URL); page.fill("input[name=email]", "novo.adm@teste.local"); page.fill("input[name=senha]", senha_prov)
        page.click("#form-login button[type=submit]"); page.locator("#login-erro").wait_for(state="visible")      # senha provisória não vale mais
        login(page, None, senha="Nova-Senha-2026", email="novo.adm@teste.local")
        assert page.locator("#dlg-conta[open]").count() == 0
        sair(page)

        # gestor desativa e a pessoa não entra mais
        login(page, "gestor"); page.click("#btn-aba-painel"); page.locator("#tbody-usr tr").first.wait_for()
        page.click("#tbody-usr tr:has-text('Rita Nova') [data-uacao=ativo]"); page.fill("#form-ativo input[name=pin]", "5556")
        page.click("#form-ativo button[type=submit]"); esperar_toast(page, "desativado"); page.wait_for_timeout(500)
        assert page.locator("#tbody-usr tr:has-text('Rita Nova')").count() == 0                              # filtro "somente ativos"
        assert page.locator("#tbody-usr tr:has-text('Paula') [data-uacao=ativo]").count() == 0, "gestor não se desativa"
        sair(page)
        page.goto(URL); page.fill("input[name=email]", "novo.adm@teste.local"); page.fill("input[name=senha]", "Nova-Senha-2026")
        page.click("#form-login button[type=submit]"); page.locator("#login-erro").wait_for(state="visible")
        login(page, "gestor")

        # =================== v4: ordem das assinaturas, câmera, detalhe, exclusões, parâmetros, logo ===================
        import datetime as _dt, subprocess as _sp
        def psql(q): return _sp.run(["psql", "-d", "protocolo_e2e", "-tA", "-c", q], capture_output=True, text=True).stdout.strip()
        page.click("[data-aba=protocolos]"); page.click("#btn-novo")
        modos = page.locator("#form-novo .modos .modo").all_inner_texts()
        assert "Desenhar" in modos[0] and "Digitar" in modos[1] and "PIN" in modos[2], modos                  # ordem: Desenhar, Digitar, PIN
        assert page.get_attribute("#form-novo .modo[data-modo=desenhada]", "aria-pressed") == "true"
        assert page.locator("#form-novo canvas.quadro").is_visible() and page.locator("#form-novo .assin-texto").is_hidden()
        # captura da foto: webcam (computador), remover e galeria
        assert page.locator("#btn-foto-camera").is_visible() and page.locator("#btn-foto-arquivo").is_visible()
        assert page.get_attribute("#inp-foto-camera", "capture") == "environment"
        page.click("#btn-foto-camera"); page.locator("#dlg-camera[open]").wait_for()
        expect(page.locator("#btn-capturar")).to_be_enabled(timeout=8000)
        page.screenshot(path=str(OUT / "11_camera.png"))
        page.click("#btn-capturar"); page.locator("#foto-previa").wait_for(state="visible", timeout=8000)
        assert page.locator("#btn-foto-remover").is_visible() and page.locator("#dlg-camera[open]").count() == 0
        page.click("#btn-foto-remover"); assert page.locator("#foto-previa").is_hidden()
        page.set_input_files("#inp-foto", str(FOTO)); page.locator("#foto-previa").wait_for(state="visible")
        page.screenshot(path=str(OUT / "2e_modal_novo_foto.png"))
        page.click("#form-novo [data-fechar]")

        # detalhe reorganizado + exclusão de protocolo
        page.click("#tbody tr:has-text('Gestão nº 7')"); page.locator("#dlg-detalhe[open]").wait_for()
        d = page.inner_text("#detalhe-corpo").lower()
        for t in ("documento", "tramitação", "registrado por", "registrado em", "selo de integridade", "excluir protocolo"): assert t in d, t
        assert page.locator(".et-ass-caixa").count() == 3 and page.locator("li.feito").count() == 3
        page.screenshot(path=str(OUT / "10_detalhe_novo.png"))
        page.click("[data-acao=excluir]"); page.locator("#dlg-excluir[open]").wait_for()
        page.fill("#form-excluir textarea[name=justificativa]", "Registro de teste feito em duplicidade"); page.fill("#form-excluir input[name=pin]", "0000")
        page.check("#form-excluir input[name=ciente]"); page.click("#form-excluir button[type=submit]")
        page.wait_for_timeout(600); assert "PIN" in page.inner_text("#form-excluir .erro")
        page.fill("#form-excluir input[name=pin]", "5556"); page.screenshot(path=str(OUT / "12_excluir.png"))
        page.click("#form-excluir button[type=submit]"); esperar_toast(page, "excluído"); page.wait_for_timeout(600)
        assert page.locator("#tbody tr:has-text('Gestão nº 7')").count() == 0
        n_fotos = int(psql("select count(*) from storage.objects")); assert n_fotos >= 1, n_fotos
        page.click("#tbody tr:has-text('2026-0001')"); page.locator("#det-fotos img.foto-det").wait_for(timeout=8000)    # protocolo com foto
        page.click("[data-acao=excluir]"); page.fill("#form-excluir textarea[name=justificativa]", "Documento recebido por engano na unidade")
        page.fill("#form-excluir input[name=pin]", "5556"); page.check("#form-excluir input[name=ciente]"); page.check("#form-excluir input[name=trilha]")
        page.click("#form-excluir button[type=submit]"); esperar_toast(page, "excluído"); page.wait_for_timeout(800)
        assert int(psql("select count(*) from storage.objects")) == n_fotos - 1, "a foto deve sair do armazenamento"
        assert psql("select count(*) from public.protocolos where numero='2026-0001'") == "0"

        # Prazos e regras: formatos de hora, um único botão Salvar
        page.click("#btn-aba-painel"); page.click("[data-sub=sistema]"); page.locator("#form-param input[name=sessao_inatividade_min]").wait_for()
        assert page.locator("#form-param button[type=submit]").count() == 1 and page.locator("#form-param button:has-text('Salvar')").count() == 1
        expect(page.locator("#param-corpo input[name=sessao_inatividade_min]")).to_have_value("6h", timeout=6000)
        assert page.locator("#param-salvar").is_disabled(), page.inner_text("#param-estado")
        page.screenshot(path=str(OUT / "14_parametros.png"), full_page=True)
        page.fill("#form-param input[name=sessao_inatividade_min]", "xx"); assert page.locator("#param-salvar").is_disabled() and "inválido" in page.inner_text("#p-sessao_inatividade_min")
        page.fill("#form-param input[name=sessao_inatividade_min]", "1h30"); assert "90 min" in page.inner_text("#p-sessao_inatividade_min") and page.locator("#param-salvar").is_enabled()
        page.fill("#form-param input[name=expediente_inicio]", "07:30"); page.fill("#form-param input[name=prazo_judicial_dias]", "6")
        page.click("#param-salvar"); esperar_toast(page, "Alterações salvas"); page.wait_for_timeout(500)
        assert page.input_value("#form-param input[name=sessao_inatividade_min]") == "1h30" and page.input_value("#form-param input[name=expediente_inicio]") == "07:30"
        assert psql("select valor from public.parametros where chave='sessao_inatividade_min'") == "1:30"
        page.fill("#form-param input[name=expediente_fim]", "07:00"); assert page.locator("#p-exped").is_visible() and page.locator("#param-salvar").is_disabled()
        page.click("#param-descartar"); page.wait_for_timeout(500); assert page.input_value("#form-param input[name=expediente_fim]") == "17:00"
        page.fill("#form-param input[name=sessao_inatividade_min]", "6h"); page.fill("#form-param input[name=expediente_inicio]", "08:00")
        page.fill("#form-param input[name=prazo_judicial_dias]", "5"); page.click("#param-salvar"); esperar_toast(page, "Alterações salvas")
        page.wait_for_timeout(800)          # o formulário é recarregado após salvar
        # tempo de inatividade ajustável (padrão 6 h)
        assert page.input_value("#form-param input[name=sessao_inatividade_min]") == "6h", page.input_value("#form-param input[name=sessao_inatividade_min]")
        for ruim in ("2d", "25h", "1min", "abc", ""):
            page.fill("#form-param input[name=sessao_inatividade_min]", ruim)
            assert page.locator("#param-salvar").is_disabled(), f"'{ruim}' deveria impedir o salvamento"
        page.fill("#form-param input[name=sessao_inatividade_min]", "8h30")
        page.wait_for_timeout(300)
        assert "510 min" in page.inner_text("#p-sessao_inatividade_min") and page.locator("#param-salvar").is_enabled(), (page.inner_text("#p-sessao_inatividade_min"), page.input_value("#form-param input[name=sessao_inatividade_min]"), page.locator("#form-param .invalido").evaluate_all("e=>e.map(x=>x.name+\"=\"+x.value)"))
        page.click("#param-salvar"); esperar_toast(page, "Alterações salvas"); page.wait_for_timeout(500)
        assert psql("select valor from public.parametros where chave='sessao_inatividade_min'") == "8:30"
        assert page.input_value("#form-param input[name=sessao_inatividade_min]") == "8h30"
        page.fill("#form-param input[name=sessao_inatividade_min]", "6h"); page.click("#param-salvar"); esperar_toast(page, "Alterações salvas"); page.wait_for_timeout(400)
        assert psql("select valor from public.parametros where chave='sessao_inatividade_min'") == "6:00"

        # Logo em todo o sistema
        page.click("[data-sub=sistema]"); page.locator("#form-logo").wait_for()
        LOGO = OUT / "logo-teste.png"; _l = Image.new("RGBA", (900, 300), (0, 0, 0, 0)); _d = ImageDraw.Draw(_l)
        _d.rounded_rectangle((10, 10, 890, 290), 60, fill=(31, 78, 110, 255)); _d.ellipse((60, 60, 240, 240), fill=(224, 88, 75, 255)); _l.save(LOGO)
        page.set_input_files("#logo-arquivo", str(LOGO)); page.locator("#logo-previa").wait_for(state="visible"); expect(page.locator("#logo-salvar")).to_be_enabled()
        page.fill("#logo-pin", "0000"); page.click("#logo-salvar"); page.wait_for_timeout(600); assert "PIN" in page.inner_text("#form-logo .erro")
        page.fill("#logo-pin", "5556"); page.click("#logo-salvar"); esperar_toast(page, "Logotipo atualizado")
        assert page.locator(".topo img.logo").is_visible() and page.get_attribute(".topo img.logo", "src").startswith("data:image/")
        assert page.evaluate("document.querySelector('link[rel=icon]').href").startswith("data:image/")
        page.screenshot(path=str(OUT / "13_logo.png"))
        page.click("[data-aba=protocolos]"); page.click("#tbody tr[data-id]:first-child"); page.click("[data-acao=imprimir]"); page.wait_for_timeout(700)
        assert page.locator("#print-root .p-cab img[src^='data:image/']").count() == 1, "a ficha impressa deve usar o logo"
        pdf_da_impressao(page, "ficha_logo.pdf", False); page.evaluate("document.getElementById('print-root').innerHTML=''")
        page.click("#detalhe-corpo [data-fechar]")
        page.click("#btn-imprimir-livro"); page.wait_for_timeout(1200)
        assert page.locator("#print-root .p-cab img[src^='data:image/']").count() == 1, "o livro impresso deve usar o logo"
        page.evaluate("document.getElementById('print-root').innerHTML=''")
        sair(page); page.goto(URL); page.locator("#view-login img.logo").wait_for(state="visible", timeout=6000)     # logo já na tela de login
        page.screenshot(path=str(OUT / "13b_login_logo.png"))
        login(page, "gestor", senha=SENHA); page.click("#btn-aba-painel"); page.click("[data-sub=sistema]")
        page.fill("#logo-pin", "5556"); page.click("#logo-restaurar"); esperar_toast(page, "Logotipo padrão"); page.wait_for_timeout(300)
        assert page.locator(".topo img.logo").is_hidden() and page.locator(".topo .cruz").is_visible()

        # excluir registros da trilha
        page.click("#btn-aba-auditoria"); page.locator("#tbody-audit tr").first.wait_for()
        page.click("#aud-excluir"); page.locator("#dlg-limpar-trilha[open]").wait_for()
        hoje = _dt.date.today(); ini, fim = (hoje - _dt.timedelta(days=1)).isoformat(), (hoje + _dt.timedelta(days=1)).isoformat()
        page.fill("#form-limpar-trilha input[name=data_ini]", ini); page.fill("#form-limpar-trilha input[name=data_fim]", fim)
        page.fill("#form-limpar-trilha textarea[name=justificativa]", "Descarte dos registros de teste"); page.fill("#form-limpar-trilha input[name=pin]", "0000")
        page.check("#form-limpar-trilha input[name=ciente]"); page.screenshot(path=str(OUT / "12b_limpar_trilha.png"))
        page.click("#form-limpar-trilha button[type=submit]"); page.wait_for_timeout(600); assert "PIN" in page.inner_text("#form-limpar-trilha .erro")
        page.fill("#form-limpar-trilha input[name=pin]", "5556"); page.click("#form-limpar-trilha button[type=submit]"); esperar_toast(page, "da trilha")
        page.wait_for_timeout(700)
        assert page.locator("#tbody-audit tr").count() == 1 and "Registros da trilha excluídos" in page.inner_text("#tbody-audit"), page.inner_text("#tbody-audit")
        page.click("#btn-verificar"); page.locator("#resultado-verificacao:not(:empty)").wait_for(); assert "íntegra" in page.inner_text("#resultado-verificacao")
        page.screenshot(path=str(OUT / "6c_trilha_apos_exclusao.png"))
        sair(page)

        # celular: "Tirar foto" abre a câmera do aparelho
        cel = b.new_context(viewport={"width": 390, "height": 800}, is_mobile=True, has_touch=True, permissions=["camera"])
        pc = cel.new_page(); pc.on("pageerror", lambda e: problemas.append(f"pageerror(cel): {e}"))
        login(pc, "gestor"); pc.click("#btn-novo")
        # nova captura: a câmera abre dentro do sistema (não troca de aplicativo, evita o erro de Android)
        pc.click("#btn-foto-camera"); pc.locator("#dlg-camera[open]").wait_for(); expect(pc.locator("#btn-capturar")).to_be_enabled(timeout=8000)
        assert pc.locator("#btn-cam-trocar").is_visible()
        pc.screenshot(path=str(OUT / "15a_celular_camera.png"))
        pc.click("#btn-capturar"); pc.locator("#foto-previa").wait_for(state="visible", timeout=8000)
        assert pc.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")
        pc.screenshot(path=str(OUT / "15_celular_foto.png"))
        # plano B: sem câmera no navegador, abre a câmera do aparelho (campo de arquivo)
        pc.click("#btn-foto-remover")
        pc.evaluate("Object.defineProperty(navigator, 'mediaDevices', { value: undefined, configurable: true })")
        with pc.expect_file_chooser() as fc: pc.click("#btn-foto-camera")
        fc.value.set_files(str(FOTO)); pc.locator("#foto-previa").wait_for(state="visible", timeout=8000)
        assert pc.get_attribute("#inp-foto-camera", "capture") == "environment"
        cel.close()
        login(page, "gestor")

        # ---- rascunho automático do novo protocolo
        import json as _json
        page.click("[data-aba=protocolos]"); page.click("#btn-novo")
        page.select_option("#form-novo select[name=tipo]", "judicial"); page.check("#form-novo input[name=urgente]")
        page.fill("#form-novo textarea[name=descricao]", "Ofício de teste do rascunho 77/2026")
        page.set_input_files("#inp-foto", str(FOTO)); page.locator("#foto-previa").wait_for(state="visible"); page.wait_for_timeout(1200)
        bruto = page.evaluate("Object.entries(sessionStorage).filter(([k]) => k.startsWith('protocolo.rascunho.')).map(([k, v]) => v)")
        assert len(bruto) == 1, bruto
        rasc = _json.loads(bruto[0]); assert rasc["descricao"].startswith("Ofício de teste") and rasc["tipo"] == "judicial" and rasc["urgente"] is True
        assert rasc["foto"].startswith("data:image/jpeg;base64,"), "foto deveria ir no rascunho"
        assert set(rasc) == {"tipo", "urgente", "descricao", "salvoEm", "foto"}, "o rascunho não pode guardar assinatura nem PIN"
        page.click("#dlg-novo [data-fechar]"); page.reload(); page.locator("#view-app").wait_for(state="visible"); page.wait_for_timeout(800)
        page.click("#btn-novo")
        assert page.input_value("#form-novo textarea[name=descricao]") == "Ofício de teste do rascunho 77/2026"
        assert page.input_value("#form-novo select[name=tipo]") == "judicial" and page.is_checked("#form-novo input[name=urgente]")
        assert page.locator("#rascunho-aviso").is_visible() and page.locator("#foto-previa").is_visible(), "rascunho e foto devem voltar"
        page.click("#rascunho-descartar"); page.wait_for_timeout(300)
        assert page.input_value("#form-novo textarea[name=descricao]") == "" and page.locator("#foto-previa").is_hidden() and page.locator("#rascunho-aviso").is_hidden()
        assert page.evaluate("Object.keys(sessionStorage).filter(k => k.startsWith('protocolo.rascunho.')).length") == 0
        page.fill("#form-novo textarea[name=descricao]", "Outro rascunho 88"); page.wait_for_timeout(900)
        assert page.evaluate("Object.keys(sessionStorage).filter(k => k.startsWith('protocolo.rascunho.')).length") == 1
        page.click("#dlg-novo [data-fechar]"); sair(page)
        assert page.evaluate("Object.keys(sessionStorage).filter(k => k.startsWith('protocolo.rascunho.')).length") == 0, "sair apaga o rascunho"
        login(page, "gestor")
        # ---- v5: selo de integridade automático, backup, retenção, versão, manifesto, filtros salvos, freio de login
        page.click("#btn-aba-auditoria"); page.locator("#resultado-verificacao:not(:empty)").wait_for(timeout=8000)
        assert "íntegra" in page.inner_text("#resultado-verificacao"), page.inner_text("#resultado-verificacao")
        print("selo automático:", page.inner_text("#resultado-verificacao"))
        page.click("#btn-aba-painel"); page.click("[data-sub=backup]")
        page.locator("#versao-schema:not(:empty)").wait_for(timeout=8000)
        assert "11 de 11" in page.inner_text("#versao-schema") and "atualizado" in page.inner_text("#versao-schema"), page.inner_text("#versao-schema")
        with page.expect_download() as dl: page.click("#btn-backup")
        import json as _json
        bkp = _json.load(open(dl.value.path(), encoding="utf-8"))
        assert dl.value.suggested_filename.startswith("backup-protocolo-") and dl.value.suggested_filename.endswith(".json")
        assert set(bkp) >= {"gerado_em", "versao_schema", "protocolos", "tramites", "movimentacoes", "auditoria"} and bkp["versao_schema"] == 11
        assert all("assinatura_png" not in t for t in bkp["tramites"]), "backup não deve levar a imagem da assinatura"
        esperar_toast(page, "Backup gerado")
        page.fill("#ret-meses", "1"); page.click("#btn-retencao")
        page.locator("#ret-resultado:not(:empty)").wait_for(timeout=8000); print("retenção:", page.inner_text("#ret-resultado"))
        assert "Nenhum protocolo concluído com mais de 1 mês." in page.inner_text("#ret-resultado")
        page.fill("#ret-meses", "0"); page.click("#btn-retencao"); page.wait_for_timeout(500)
        assert "1 e 600" in page.inner_text("#ret-resultado"), page.inner_text("#ret-resultado")
        page.click("[data-aba=protocolos]"); page.wait_for_timeout(500)
        assert "vencem em até 2 dias" in page.inner_text("#k-crit"), page.inner_text("#k-crit")
        assert "Vence em até 2 dias" in page.inner_text("select[name=alerta]")
        m = page.request.get(URL + "manifest.webmanifest"); assert m.ok and m.json()["short_name"] == "Protocolo"
        assert page.locator("link[rel=manifest]").count() == 1 and page.request.get(URL + "assets/icone.svg").ok
        page.focus("a.pular"); assert page.evaluate("document.activeElement.className") == "pular" and page.locator("a.pular").bounding_box()["y"] >= 0, "link 'Ir para o conteúdo' deve ficar visível ao receber foco"
        assert page.get_attribute("a.pular", "href") == "#conteudo" and page.locator("main#conteudo").count() == 1
        page.select_option("select[name=status]", "concluido"); page.wait_for_timeout(500)
        page.reload(); page.locator("#view-app").wait_for(state="visible"); page.wait_for_timeout(800)
        assert page.input_value("select[name=status]") == "concluido", "filtro de status deveria ser lembrado"
        page.click("#btn-limpar"); page.wait_for_timeout(400)
        assert page.input_value("select[name=status]") == "", "Limpar deve zerar também o filtro lembrado"
        sair(page)
        frs = b.new_context(); pf = frs.new_page(); pf.goto(URL); pf.locator("#form-login").wait_for(state="visible")
        for _ in range(5):
            pf.fill("input[name=email]", "gestor@teste.local"); pf.fill("input[name=senha]", "errada-errada")
            pf.click("#form-login button[type=submit]"); pf.wait_for_timeout(300)
        pf.fill("input[name=senha]", "Trocar@123"); pf.click("#form-login button[type=submit]"); pf.wait_for_timeout(300)
        assert "Muitas tentativas" in pf.inner_text("#login-erro"), pf.inner_text("#login-erro")
        assert pf.locator("#view-app").is_hidden(), "login não pode passar durante o bloqueio"
        frs.close()
        # ---- verificação em duas etapas (TOTP): cadastro, código no login, servidor recusa só-senha, redefinição, exigência
        import base64 as _b64, hashlib as _hl, hmac as _hm, struct as _st, time as _tm
        def totp(seg):
            chave = _b64.b32decode(seg + "=" * (-len(seg) % 8)); n = int(_tm.time() // 30)
            h = _hm.new(chave, _st.pack(">Q", n), _hl.sha1).digest(); o = h[-1] & 15
            return f"{(_st.unpack('>I', h[o:o + 4])[0] & 0x7fffffff) % 1000000:06d}"
        def cadastrar_mfa(pg):
            pg.click("#mfa-gerar"); pg.locator("#mfa-cad-qr").wait_for(state="visible")
            seg = pg.inner_text("#mfa-chave").replace(" ", ""); assert len(seg) >= 16
            assert pg.get_attribute("#mfa-qr", "src").startswith("data:image/svg+xml")
            pg.fill("#form-mfa-cad input[name=codigo]", "000000"); pg.click("#mfa-ativar")
            pg.locator("#form-mfa-cad .erro:not([hidden])").wait_for(timeout=6000)
            assert "inválido" in pg.inner_text("#form-mfa-cad .erro"), pg.inner_text("#form-mfa-cad .erro")
            pg.fill("#form-mfa-cad input[name=codigo]", totp(seg)); pg.click("#mfa-ativar")
            return seg
        def entrar_ate_codigo(pg):
            pg.goto(URL); pg.locator("#form-login").wait_for(state="visible")
            pg.fill("input[name=email]", "gestor@teste.local"); pg.fill("input[name=senha]", SENHA)
            pg.click("#form-login button[type=submit]"); pg.locator("#dlg-mfa").wait_for(state="visible", timeout=8000)
        login(page, "gestor")
        abrir_item_conta(page, "#btn-mfa"); seg = cadastrar_mfa(page); esperar_toast(page, "ativada")
        assert psql("select count(*) from auth.mfa_factors where status='verified'") == "1"
        page.wait_for_timeout(500); assert psql("select count(*) from public.auditoria where acao='MFA_ATIVADO'") == "1"
        abrir_item_conta(page, "#btn-mfa"); page.locator("#mfa-cad-ativo").wait_for(state="visible"); assert page.locator("#mfa-desativar").is_visible()
        page.click("#mfa-cad-fechar"); sair(page)
        entrar_ate_codigo(page)
        sondagem = page.evaluate("""async () => {
          const s = Object.values(sessionStorage).map((v) => { try { return JSON.parse(v); } catch { return null; } }).find((x) => x && x.access_token);
          const h = { apikey: 'x', Authorization: 'Bearer ' + s.access_token, 'Content-Type': 'application/json' };
          const a = await fetch('/rest/v1/rpc/exportar_backup', { method: 'POST', headers: h, body: '{}' });
          const b = await fetch('/rest/v1/perfis?select=nome&user_id=eq.' + s.uid, { headers: h });
          return [a.status, await b.text()]; }""")
        assert sondagem[0] == 400 and sondagem[1].strip() == "[]", ("servidor deveria recusar sessão só com senha", sondagem)
        page.reload(); page.locator("#dlg-mfa").wait_for(state="visible", timeout=8000)     # recarregar não pula o código
        page.fill("#form-mfa input[name=codigo]", "000000"); page.click("#form-mfa button[type=submit]")
        page.locator("#form-mfa .erro:not([hidden])").wait_for(timeout=6000)
        page.fill("#form-mfa input[name=codigo]", totp(seg)); page.click("#form-mfa button[type=submit]")
        page.locator("#view-app").wait_for(state="visible", timeout=8000); page.wait_for_timeout(500)
        assert page.locator("#usr-nome").inner_text().strip() != "", "perfil carregado após o código"
        sair(page); entrar_ate_codigo(page); page.click("#mfa-cancelar"); page.locator("#view-login").wait_for(state="visible")
        assert "cancelada" in page.inner_text("#login-erro"), page.inner_text("#login-erro")
        # gestor redefine a verificação de outro usuário
        psql("insert into auth.mfa_factors (user_id, status) select id, 'verified' from auth.users where email='portaria@teste.local'")
        entrar_ate_codigo(page); page.fill("#form-mfa input[name=codigo]", totp(seg)); page.click("#form-mfa button[type=submit]")
        page.locator("#view-app").wait_for(state="visible"); page.click("#btn-aba-painel"); page.click("[data-sub=usuarios]")
        linha = page.locator("#tbody-usr tr:has-text('Maria (Portaria)')"); linha.wait_for()
        assert "2 etapas" in linha.inner_text() and linha.locator("[data-uacao=mfa]").count() == 1
        assert page.locator("#tbody-usr tr:has-text('Paula')").count() == 0 or page.locator("#tbody-usr tr:has-text('Gestor') [data-uacao=mfa]").count() == 0, "ninguém redefine a própria"
        linha.locator("[data-uacao=mfa]").click(); page.fill("#form-ativo input[name=pin]", "5556"); page.click("#form-ativo button[type=submit]")
        esperar_toast(page, "redefinida"); assert psql("select count(*) from auth.mfa_factors where user_id=(select id from auth.users where email='portaria@teste.local')") == "0"
        # exigência para o gestor: desativa a própria, liga a regra, o próximo acesso obriga o cadastro
        abrir_item_conta(page, "#btn-mfa"); page.locator("#mfa-cad-ativo").wait_for(state="visible")
        page.once("dialog", lambda d: d.accept()); page.click("#mfa-desativar"); esperar_toast(page, "desativada")
        assert psql("select count(*) from auth.mfa_factors") == "0"
        page.click("#btn-aba-painel"); page.click("[data-sub=sistema]"); page.locator("#form-param input[name=mfa_gestor_obrigatorio]").wait_for(); page.wait_for_timeout(900)
        page.check("#form-param input[name=mfa_gestor_obrigatorio]"); page.click("#param-salvar"); esperar_toast(page, "Alterações salvas"); page.wait_for_timeout(500)
        assert psql("select valor from public.parametros where chave='mfa_gestor_obrigatorio'") == "true"
        sair(page); page.goto(URL); page.locator("#form-login").wait_for(state="visible")
        page.fill("input[name=email]", "gestor@teste.local"); page.fill("input[name=senha]", SENHA); page.click("#form-login button[type=submit]")
        page.locator("#dlg-mfa-cad").wait_for(state="visible", timeout=8000)
        assert page.inner_text("#mfa-cad-fechar") == "Sair" and "precisa usar" in page.inner_text("#mfa-cad-info")
        assert page.locator("#view-app").is_hidden(), "sem cadastro o gestor não entra"
        seg = cadastrar_mfa(page); page.locator("#view-app").wait_for(state="visible", timeout=8000); page.wait_for_timeout(500)
        abrir_item_conta(page, "#btn-mfa"); page.locator("#mfa-cad-ativo").wait_for(state="visible"); assert page.locator("#mfa-desativar").is_hidden(), "exigida: não pode desativar"
        page.click("#mfa-cad-fechar")
        # limpeza: volta ao estado sem exigência para o restante da bateria
        psql("update public.parametros set valor='false' where chave='mfa_gestor_obrigatorio'"); psql("delete from auth.mfa_factors")
        sair(page)
        # logout por inatividade: relógio simulado (6 h = padrão do banco)
        rel = b.new_context(); pr = rel.new_page(); pr.clock.install()
        login(pr, "gestor"); pr.clock.fast_forward("05:00:00"); pr.wait_for_timeout(300)
        assert pr.locator("#view-app").is_visible(), "5 h parado ainda não deve deslogar (limite de 6 h)"
        assert pr.locator("#dlg-inatividade").is_hidden(), "sem aviso quando ainda falta muito"
        pr.clock.fast_forward("00:59:30"); pr.wait_for_timeout(400)         # faltam ~30 s
        assert pr.locator("#dlg-inatividade").is_visible(), "aviso deveria aparecer no último minuto"
        seg = int(pr.inner_text("#inat-seg")); assert 20 <= seg <= 31, seg
        pr.click("#inat-continuar"); pr.wait_for_timeout(300)
        assert pr.locator("#dlg-inatividade").is_hidden() and pr.locator("#view-app").is_visible(), "Continuar reinicia a contagem"
        pr.clock.fast_forward("05:59:35"); pr.wait_for_timeout(400)
        assert pr.locator("#dlg-inatividade").is_visible(); pr.click("#inat-sair"); pr.locator("#view-login").wait_for(state="visible", timeout=8000)
        login(pr, "gestor")
        pr.mouse.click(5, 5); pr.clock.fast_forward("05:30:00"); pr.wait_for_timeout(300)
        assert pr.locator("#view-app").is_visible(), "atividade recente reinicia a contagem"
        pr.clock.fast_forward("06:30:00"); pr.locator("#view-login").wait_for(state="visible", timeout=8000)
        assert "inatividade" in pr.inner_text("#login-erro") + pr.inner_text("#toast"), "mensagem de inatividade esperada"
        rel.close()
        login(page, "gestor")
        # devolução e reencaminhamento (protocolo montado direto no banco, na situação "aguardando o setor")
        sair(page)
        psql("insert into public.protocolos (numero, descricao, status, created_by, tipo, urgente) select '2026-9001','Ofício de teste da devolução','pendente_adm', id, 'correspondencia', false from auth.users where email='portaria@teste.local'")
        psql("select public._inserir_tramite((select id from public.protocolos where numero='2026-9001'),'2026-9001',1,(select user_id from public.perfis where email='portaria@teste.local'),'Maria (Portaria)',null,null,null,now())")
        psql("select public._inserir_tramite((select id from public.protocolos where numero='2026-9001'),'2026-9001',2,(select user_id from public.perfis where email='adm@teste.local'),'João (Administração)',null,null,null,now())")
        psql("update public.protocolos set setor_destino_id=(select id from public.setores where nome='Jurídico') where numero='2026-9001'")
        login(page, "juridico"); page.locator("#tbody tr:has-text('2026-9001')").wait_for()
        assert page.locator("#atalho-meus").is_visible()
        page.click("#atalhos [data-alerta=meus]"); page.wait_for_timeout(500); assert page.locator("#tbody tr:has-text('2026-9001')").count() == 1
        assert "sel" in page.get_attribute("#atalhos [data-alerta=meus]", "class")
        page.click("#tbody tr:has-text('2026-9001')"); page.locator("#dlg-detalhe[open]").wait_for()
        assert page.locator("[data-acao=reencaminhar]").count() == 0 and page.locator("[data-acao=devolver]").count() == 1
        page.click("[data-acao=devolver]"); page.locator("#dlg-mov[open]").wait_for(); assert page.locator("#lbl-mov-setor").is_hidden()
        assert "Devolver ao ADM" in page.inner_text("#mov-titulo")
        page.fill("#form-mov textarea[name=justificativa]", "Assunto é da Farmácia, não do Jurídico"); page.fill("#form-mov input[name=pin]", "3333")
        page.click("#form-mov button[type=submit]"); esperar_toast(page, "devolvido ao ADM"); page.wait_for_timeout(700)
        assert page.locator("#dlg-detalhe[open]").count() == 0 and page.locator("#tbody tr:has-text('2026-9001')").count() == 0
        page.screenshot(path=str(OUT / "9a_devolvido_setor.png")); sair(page)
        login(page, "adm"); page.locator("#tbody tr:has-text('2026-9001')").wait_for()
        assert "Devolvido ao ADM" in page.inner_text("#tbody tr:has-text('2026-9001')")
        page.click("#atalhos [data-alerta=devolvidos]"); page.wait_for_timeout(500); assert page.locator("#tbody tr[data-id]").count() == 1
        assert "(1)" in page.inner_text("#atalhos [data-alerta=devolvidos]")
        page.click("#tbody tr:has-text('2026-9001')"); page.locator("#dlg-detalhe[open]").wait_for()
        assert "Aguarda novo encaminhamento" in page.inner_text("#detalhe-corpo") and page.locator("[data-acao=setor]").count() == 0
        page.screenshot(path=str(OUT / "9b_devolvido_adm.png"))
        page.click("[data-acao=reencaminhar]"); page.locator("#form-mov select[name=setor] option", has_text="Farmácia").wait_for(state="attached")
        page.select_option("#form-mov select[name=setor]", label="Farmácia")
        page.fill("#form-mov textarea[name=justificativa]", "Reencaminhado ao setor correto"); page.fill("#form-mov input[name=pin]", "2222")
        page.click("#form-mov button[type=submit]"); esperar_toast(page, "reencaminhado"); page.wait_for_timeout(700)
        txt = page.inner_text("#detalhe-corpo"); assert "Farmácia" in txt and "Devolvido ao ADM" in txt and "Reencaminhado" in txt, txt
        page.screenshot(path=str(OUT / "9c_reencaminhado.png")); page.click("#detalhe-corpo [data-fechar]"); sair(page)
        login(page, "farmacia"); page.locator("#tbody tr:has-text('2026-9001')").wait_for(); sair(page)
        assert psql("select count(*) from public.movimentacoes") == "2"
        login(page, "gestor")
        # tema claro/escuro (Automático → Claro → Escuro), lembrado no navegador
        fundo = lambda: page.evaluate("getComputedStyle(document.body).backgroundColor")
        abrir_item_conta(page, "#menu-conta [data-tema-btn]")
        assert page.evaluate("document.documentElement.dataset.tema") == "claro" and "Claro" in page.inner_text("#menu-conta [data-tema-btn]")
        claro = fundo(); page.click("#menu-conta [data-tema-btn]")
        assert page.evaluate("document.documentElement.dataset.tema") == "escuro" and fundo() != claro
        assert page.evaluate("localStorage.getItem('tema')") == "escuro"
        page.keyboard.press("Escape"); page.wait_for_timeout(200); assert page.locator("#menu-conta").is_hidden()
        page.screenshot(path=str(OUT / "10a_escuro_lista.png"))
        page.locator("#tbody tr[data-id]").first.click(); page.locator("#dlg-detalhe[open]").wait_for(); page.wait_for_timeout(400)
        page.screenshot(path=str(OUT / "10b_escuro_detalhe.png")); page.keyboard.press("Escape")
        page.click("#btn-aba-painel"); page.click("[data-sub=sistema]"); page.wait_for_timeout(900); page.screenshot(path=str(OUT / "10c_escuro_sistema.png"), full_page=True)
        page.click("[data-sub=cadastros]"); page.wait_for_timeout(500); page.screenshot(path=str(OUT / "10d_escuro_cadastros.png"))
        page.click("[data-sub=backup]"); page.wait_for_timeout(500); page.screenshot(path=str(OUT / "10e_escuro_backup.png"))
        page.click("[data-sub=usuarios]"); page.wait_for_timeout(500); page.screenshot(path=str(OUT / "10f_escuro_usuarios.png"))
        page.click("#btn-aba-livro") if page.locator("#btn-aba-livro").count() else None
        sair(page); page.goto(URL); page.locator("#view-login").wait_for(state="visible"); page.wait_for_timeout(500)
        assert page.evaluate("document.documentElement.dataset.tema") == "escuro", "tema deve persistir após recarregar"
        page.screenshot(path=str(OUT / "10g_escuro_login.png"))
        page.click(".tema-login"); assert page.evaluate("document.documentElement.dataset.tema") is None and "Automático" in page.inner_text(".tema-login")
        page.evaluate("localStorage.setItem('tema','claro')"); page.reload(); page.locator("#view-login").wait_for(state="visible")
        login(page, "gestor")
        # layout móvel
        page.set_viewport_size({"width": 390, "height": 800}); page.click("[data-aba=protocolos]"); page.wait_for_timeout(300)
        page.screenshot(path=str(OUT / "7_mobile.png"))
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "scroll horizontal no mobile"
        # descrição longa sem espaços não pode alterar o layout (lista, gaveta de detalhes)
        psql("insert into public.protocolos (numero, descricao, status, created_by, tipo, urgente) select '2026-9002', repeat('A', 240), 'pendente_adm', id, 'correspondencia', false from auth.users where email='portaria@teste.local'")
        psql("select public._inserir_tramite((select id from public.protocolos where numero='2026-9002'),'2026-9002',1,(select user_id from public.perfis where email='portaria@teste.local'),'Maria (Portaria)',null,null,null,now())")
        page.click("[data-aba=protocolos]"); page.reload(); page.locator("#tbody tr:has-text('2026-9002')").wait_for()
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "descrição longa alargou a página (lista)"
        page.locator("#tbody tr:has-text('2026-9002')").click(); page.locator("#dlg-detalhe[open]").wait_for(); page.wait_for_timeout(500)
        assert page.evaluate("(() => { const d = document.querySelector('#dlg-detalhe'); return d.scrollWidth <= d.clientWidth + 1; })()"), "descrição longa alargou a gaveta"
        assert page.evaluate("(() => { const r = document.querySelector('#dlg-detalhe .resumo-doc').getBoundingClientRect(); return r.right <= window.innerWidth; })()")
        page.screenshot(path=str(OUT / "16_descricao_longa_mobile.png")); page.keyboard.press("Escape")
        page.set_viewport_size({"width": 1366, "height": 820}); page.wait_for_timeout(300)
        page.locator("#tbody tr:has-text('2026-9002')").click(); page.locator("#dlg-detalhe[open]").wait_for(); page.wait_for_timeout(400)
        assert page.evaluate("(() => { const d = document.querySelector('#dlg-detalhe'); return d.scrollWidth <= d.clientWidth + 1; })()")
        page.screenshot(path=str(OUT / "16b_descricao_longa_desktop.png")); page.keyboard.press("Escape")
        # e-mail de teste: sem Brevo vai para a fila; com Brevo sai na hora
        page.click("#btn-aba-painel"); page.click("[data-sub=sistema]"); page.locator("#btn-email-teste").wait_for()
        page.click("#btn-email-teste"); expect(page.locator("#email-teste-msg")).to_contain_text("fila", timeout=8000)
        psql("select public.admin_configurar_brevo('chave-e2e-chave-e2e-chave-1234','avisos@teste.local','Livro CECAN')")
        page.reload(); page.click("#btn-aba-painel"); page.click("[data-sub=sistema]"); page.locator("#btn-email-teste").wait_for(); page.wait_for_timeout(700)
        assert "Ativo" in page.inner_text("#sistema-kpis"), page.inner_text("#sistema-kpis")
        page.click("#btn-email-teste"); expect(page.locator("#email-teste-msg")).to_contain_text("enviado para", timeout=8000)
        assert int(psql("select count(*) from net.http_log where url like 'https://api.brevo.com/%'")) >= 1
        page.screenshot(path=str(OUT / "17_email_teste.png"))
        # verificar instalação
        page.click("#btn-diag"); expect(page.locator("#diag-saida .diag-resumo")).to_contain_text("Instalação em ordem", timeout=8000)
        assert page.locator("#diag-saida .diag-erro:not(.diag-resumo)").count() == 0, page.inner_text("#diag-saida")
        page.screenshot(path=str(OUT / "18_verificar_instalacao.png"))
        # chaves para avisos no celular
        page.click("#btn-chaves-push"); expect(page.locator("#push-chaves")).to_be_visible()
        assert len(page.input_value("#push-pub")) == 87 and len(page.input_value("#push-priv")) == 43 and len(page.input_value("#push-seg")) >= 30
        # relatórios
        page.click("[data-sub=relatorios]"); expect(page.locator("#rel-saida .kpis-rel").first).to_be_visible(timeout=8000)
        _t = page.inner_text("#rel-saida").lower(); assert "registrados" in _t and "tempo entre as etapas" in _t, _t
        page.click("[data-rel='90']"); expect(page.locator("#rel-saida .grafico")).to_be_visible(timeout=8000)
        n_rel = int(psql("select count(*) from public.protocolos")); assert str(n_rel) in page.locator("#rel-saida .kpis-rel .kpi").first.inner_text()
        page.fill("#form-rel input[name=inicio]", "2030-01-02"); page.fill("#form-rel input[name=fim]", "2030-01-01"); page.click("#form-rel [type=submit]")
        expect(page.locator("#rel-erro")).to_contain_text("data final", timeout=6000)
        page.click("[data-rel='30']"); expect(page.locator("#rel-saida .grafico")).to_be_visible(timeout=8000)
        with page.expect_download() as dl: page.click("#rel-xlsx")
        assert dl.value.suggested_filename.endswith(".xlsx")
        page.screenshot(path=str(OUT / "19_relatorios.png"), full_page=True)
        # avisos neste aparelho
        page.click("#btn-conta"); page.click("#btn-avisos"); expect(page.locator("#dlg-avisos[open]")).to_be_visible()
        expect(page.locator("#avisos-estado")).not_to_be_empty(timeout=4000)
        page.screenshot(path=str(OUT / "20_avisos_aparelho.png")); page.keyboard.press("Escape")
        b.close()
    print("\nE2E OK")
finally:
    srv.terminate()
print("PROBLEMAS NO NAVEGADOR:", problemas or "nenhum")
sys.exit(1 if problemas else 0)
