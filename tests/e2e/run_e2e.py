#!/usr/bin/env python3
"""
Teste E2E no navegador (Playwright): site real (dist/) + mock_supabase.py + PostgreSQL real.
Pré-requisitos: dist/ gerado com SUPABASE_URL=http://127.0.0.1:5057 ; banco preparado (preparar_db.sh).
Uso: python3 run_e2e.py [pasta_de_saida]
"""
import os, shlex, subprocess, sys, time
from pathlib import Path
from playwright.sync_api import sync_playwright

AQUI = Path(__file__).resolve().parent
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/e2e-out"); OUT.mkdir(parents=True, exist_ok=True)
PORTA = 5057
URL = f"http://127.0.0.1:{PORTA}/"
SENHA = "Trocar@123"
problemas = []

srv = subprocess.Popen([sys.executable, str(AQUI / "mock_supabase.py"), str(PORTA), "protocolo_e2e"],
                       env=dict(os.environ), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
time.sleep(1.5)


def login(page, usuario):
    page.goto(URL)
    page.locator("#form-login").wait_for(state="visible")
    page.fill("input[name=email]", f"{usuario}@teste.local")
    page.fill("input[name=senha]", SENHA)
    page.click("#form-login button[type=submit]")
    page.locator("#view-app").wait_for(state="visible")
    page.locator("#tbody, #vazio").first.wait_for(state="attached")
    page.wait_for_timeout(500)


def assinar(page, sel):
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
        page.fill("#form-novo input[name=pin]", "9999"); page.click("#form-novo button[type=submit]")
        page.wait_for_timeout(600); print("PIN errado:", page.inner_text("#form-novo .erro")); assert "PIN" in page.inner_text("#form-novo .erro")
        assinar(page, "#pad-novo"); page.fill("#form-novo input[name=pin]", "1111")
        page.screenshot(path=str(OUT / "2_modal_novo.png"))
        page.click("#form-novo button[type=submit]"); esperar_toast(page, "registrado")
        page.wait_for_timeout(500)
        assert "<b>" not in page.inner_html("#tbody").replace("&lt;b&gt;", ""), "XSS: HTML não escapado"
        assert "teste-xss" in page.inner_text("#tbody")
        # segundo registro (para filtros)
        page.click("#btn-novo"); page.fill("textarea[name=descricao]", "Carta A.R. Correios"); page.fill("#form-novo input[name=pin]", "1111")
        page.click("#form-novo button[type=submit]"); page.wait_for_timeout(700)
        sair(page)

        # 2) ADM
        login(page, "adm")
        assert page.locator("#btn-novo").is_hidden()
        page.click("#tbody tr:has-text('2026-0001')"); page.locator("#dlg-detalhe[open]").wait_for()
        page.click("[data-acao=adm]")
        page.fill("#form-confirmar input[name=pin]", "0000"); page.click("#form-confirmar button[type=submit]")
        page.locator("#form-confirmar .erro").wait_for(state="visible"); print("PIN errado ADM:", page.inner_text("#form-confirmar .erro"))
        assinar(page, "#pad-conf"); page.fill("#form-confirmar input[name=pin]", "2222")
        page.screenshot(path=str(OUT / "3_confirmar_adm.png"))
        page.click("#form-confirmar button[type=submit]"); esperar_toast(page, "ADM registrado")
        page.wait_for_timeout(700)
        page.screenshot(path=str(OUT / "4_detalhe_apos_adm.png"))
        assert "Pendente Setor Final" in page.inner_text("#detalhe-corpo")
        page.click("#detalhe-corpo [data-fechar]"); sair(page)

        # 3) SETOR (Farmácia não vê; Jurídico confirma)
        login(page, "farmacia")
        page.wait_for_timeout(300); n_far = page.locator("#tbody tr[data-id]").count(); print("farmácia vê:", n_far); assert n_far == 1
        sair(page)
        login(page, "juridico")
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
        page.click(".k-ok"); page.wait_for_timeout(600)
        assert page.locator("#tbody tr[data-id]").count() == 1 and page.inner_text("#contagem").startswith("1 ")
        page.click("#btn-limpar"); page.wait_for_timeout(500)
        page.fill("input[name=q]", "carta"); page.wait_for_timeout(900)   # busca instantânea (debounce)
        assert page.locator("#tbody tr[data-id]").count() == 1, "busca instantânea"
        page.fill("input[name=q]", "%"); page.wait_for_timeout(900)
        assert page.locator("#tbody tr[data-id]").count() == 0, "curinga % deve ser texto"
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
        txt = page.inner_text("#tbody-audit"); assert "IMPRESSAO_LIVRO" in txt and "IMPRESSAO_FICHA" in txt and "LOGIN" in txt and "DESCRICAO_CORRIGIDA" in txt
        page.screenshot(path=str(OUT / "6_auditoria.png"))
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
