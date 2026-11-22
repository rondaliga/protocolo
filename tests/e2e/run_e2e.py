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


def sair(page):
    page.click("#btn-sair"); page.locator("#view-login").wait_for(state="visible")


def pdf_da_impressao(page, nome, paisagem):
    page.emulate_media(media="print")
    page.pdf(path=str(OUT / nome), prefer_css_page_size=True, print_background=True)
    page.emulate_media(media="screen")


def esperar_toast(page, trecho):
    page.locator("#toast:not([hidden])", has_text=trecho).wait_for(timeout=8000)
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
        assert page.inner_text("#k-venc") == "0" and page.inner_text("#k-sla") == "0"
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
        pdf_da_impressao(page, "livro.pdf", True)
        # alterar PIN
        page.click("#btn-pin"); page.fill("#form-pin input[name=atual]", "5555"); page.fill("#form-pin input[name=novo]", "5556")
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
        page.click("#aud-imprimir"); page.wait_for_timeout(1200)
        assert page.locator("#print-root.livro table.p-tab tbody tr").count() >= 5
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
        page.screenshot(path=str(OUT / "8b_credenciais.png")); page.click("#dlg-credencial [data-fechar]"); page.wait_for_timeout(300)
        assert page.locator("#tbody-usr tr").count() == 6
        assert "Primeiro acesso pendente" in page.inner_text("#tbody-usr tr:has-text('Rita Nova')")
        page.select_option("#usr-filtro-papel", "adm"); assert page.locator("#tbody-usr tr").count() == 2; page.select_option("#usr-filtro-papel", "")
        # setor, regras e feriado
        page.click("[data-sub=setores]"); page.click("#set-novo"); page.fill("#form-setor input[name=nome]", "Superintendência Teste")
        page.click("#form-setor button[type=submit]"); esperar_toast(page, "Setor salvo"); page.wait_for_timeout(400)
        assert "Superintendência Teste" in page.inner_text("#tbody-set")
        page.click("[data-sub=parametros]"); page.locator("#form-param input[name=sla_adm_min]").wait_for()
        page.click("[data-sub=feriados]"); page.fill("#form-feriado input[name=data]", "2027-02-09"); page.fill("#form-feriado input[name=descricao]", "Carnaval")
        page.click("#form-feriado button[type=submit]"); esperar_toast(page, "Feriado cadastrado"); page.wait_for_timeout(400)
        assert "Carnaval" in page.inner_text("#tbody-fer"); page.click("#tbody-fer button"); page.wait_for_timeout(500)
        page.click("[data-sub=sistema]"); page.locator("#sistema-kpis .kpi").first.wait_for(); assert "usuários ativos" in page.inner_text("#sistema-kpis").lower()
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
        page.click("#btn-aba-painel"); page.click("[data-sub=parametros]"); page.locator("#form-param input[name=sla_adm_min]").wait_for()
        assert page.locator("#form-param button[type=submit]").count() == 1 and page.locator("#form-param button:has-text('Salvar')").count() == 1
        expect(page.locator("#param-corpo input[name=sla_adm_min]")).to_have_value("4h", timeout=6000)
        assert page.locator("#param-salvar").is_disabled(), page.inner_text("#param-estado")
        page.screenshot(path=str(OUT / "14_parametros.png"), full_page=True)
        page.fill("#form-param input[name=sla_adm_min]", "xx"); assert page.locator("#param-salvar").is_disabled() and "inválido" in page.inner_text("#p-sla_adm_min")
        page.fill("#form-param input[name=sla_adm_min]", "1h30"); assert "90 min" in page.inner_text("#p-sla_adm_min") and page.locator("#param-salvar").is_enabled()
        page.fill("#form-param input[name=sla_setor_min]", "1d"); assert "9h" in page.inner_text("#p-sla_setor_min")
        page.fill("#form-param input[name=expediente_inicio]", "07:30"); page.fill("#form-param input[name=prazo_judicial_dias]", "6")
        page.click("#param-salvar"); esperar_toast(page, "Alterações salvas"); page.wait_for_timeout(500)
        assert page.input_value("#form-param input[name=sla_adm_min]") == "1h30" and page.input_value("#form-param input[name=expediente_inicio]") == "07:30"
        assert psql("select valor from public.parametros where chave='sla_adm_min'") == "1:30"
        page.fill("#form-param input[name=expediente_fim]", "07:00"); assert page.locator("#p-exped").is_visible() and page.locator("#param-salvar").is_disabled()
        page.click("#param-descartar"); page.wait_for_timeout(500); assert page.input_value("#form-param input[name=expediente_fim]") == "17:00"
        page.fill("#form-param input[name=sla_adm_min]", "4h"); page.fill("#form-param input[name=sla_setor_min]", "9h"); page.fill("#form-param input[name=expediente_inicio]", "08:00")
        page.fill("#form-param input[name=prazo_judicial_dias]", "5"); page.click("#param-salvar"); esperar_toast(page, "Alterações salvas")

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
        cel = b.new_context(viewport={"width": 390, "height": 800}, is_mobile=True, has_touch=True)
        pc = cel.new_page(); pc.on("pageerror", lambda e: problemas.append(f"pageerror(cel): {e}"))
        login(pc, "gestor"); pc.click("#btn-novo")
        with pc.expect_file_chooser() as fc: pc.click("#btn-foto-camera")
        fc.value.set_files(str(FOTO)); pc.locator("#foto-previa").wait_for(state="visible", timeout=8000)
        assert pc.get_attribute("#inp-foto-camera", "capture") == "environment"
        pc.screenshot(path=str(OUT / "15_celular_foto.png")); cel.close()
        login(page, "gestor")
        # layout móvel
        page.set_viewport_size({"width": 390, "height": 800}); page.click("[data-aba=protocolos]"); page.wait_for_timeout(300)
        page.screenshot(path=str(OUT / "7_mobile.png"))
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "scroll horizontal no mobile"
        b.close()
    print("\nE2E OK")
finally:
    srv.terminate()
print("PROBLEMAS NO NAVEGADOR:", problemas or "nenhum")
sys.exit(1 if problemas else 0)
