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
        try: b = p.chromium.launch()
        except Exception: b = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
        ctx = b.new_context(viewport={"width": 1366, "height": 820})
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
        page.click("#btn-novo"); page.fill("textarea[name=descricao]", "Carta A.R. Correios"); page.fill("#form-novo input[name=pin]", "1111")
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
        assert page.input_value("#form-confirmar .assin-texto") == "João (Administração)"          # nome já vem preenchido
        page.click("#form-confirmar .estilo[data-estilo=elegante]")
        assert page.get_attribute("#form-confirmar .estilo[data-estilo=elegante]", "aria-checked") == "true"
        page.fill("#form-confirmar .assin-texto", "João Pereira"); page.fill("#form-confirmar input[name=pin]", "2222")
        page.screenshot(path=str(OUT / "3_confirmar_adm.png"))
        page.click("#form-confirmar button[type=submit]"); esperar_toast(page, "ADM registrado")
        page.wait_for_timeout(700)
        page.screenshot(path=str(OUT / "4_detalhe_apos_adm.png"))
        assert "Pendente Setor Final" in page.inner_text("#detalhe-corpo")
        assert "Assinatura digitada" in page.inner_text("#detalhe-corpo") and "Assinatura desenhada" in page.inner_text("#detalhe-corpo")
        page.click("#detalhe-corpo [data-fechar]")
        # ajuste de prazo (ADM) na correspondência ainda pendente
        page.click("#tbody tr:has-text('2026-0002')"); page.click("[data-acao=prazo]")
        page.fill("#form-prazo input[name=data]", (__import__("datetime").date.today() + __import__("datetime").timedelta(days=30)).isoformat())
        page.fill("#form-prazo textarea[name=justificativa]", "Prazo de 10 dias informado no ofício"); page.fill("#form-prazo input[name=pin]", "2222")
        page.click("#form-prazo button[type=submit]"); esperar_toast(page, "Prazo ajustado"); page.wait_for_timeout(700)
        assert "Histórico de ajustes de prazo" in page.inner_text("#detalhe-corpo")
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
        page.fill("#form-confirmar input[name=pin]", "3333"); page.click("#form-confirmar button[type=submit]")
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
        page.click("#form-novo .estilo[data-estilo=rubrica]"); page.fill("#form-novo input[name=pin]", "5556")
        page.click("#form-novo button[type=submit]"); esperar_toast(page, "registrado"); page.wait_for_timeout(600)
        page.click("#tbody tr:has-text('Gestão nº 7')"); page.click("[data-acao=adm]")
        page.locator("#sel-destino option", has_text="Farmácia").wait_for(state="attached")
        page.select_option("#sel-destino", label="Farmácia"); page.fill("#form-confirmar input[name=pin]", "5556")
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
        page.click("[data-sub=parametros]"); page.locator("form.param").first.wait_for()
        f = page.locator("form.param[data-chave=prazo_judicial_dias]"); f.locator("input[name=valor]").fill("7"); f.locator("button").click()
        esperar_toast(page, "Regra salva")
        f.locator("input[name=valor]").fill("400"); f.locator("button").click(); page.wait_for_timeout(600)
        assert page.locator("#toast.erro").count() == 1                                                      # valor inválido é recusado
        f.locator("input[name=valor]").fill("5"); f.locator("button").click(); page.wait_for_timeout(500)
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
