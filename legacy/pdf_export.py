"""
Exportação em PDF (ReportLab):
  * listagem_pdf -> espelha as colunas do livro físico (paisagem, A4)
  * ficha_pdf    -> ficha individual do protocolo, com as 3 etapas, correções e selos
"""
import io
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas
from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

AZUL = colors.HexColor("#24506f")
AZUL_CLARO = colors.HexColor("#dce6f1")
CINZA = colors.HexColor("#555555")
ROTULO_STATUS = {"PENDENTE_ADM": "Pendente ADM", "PENDENTE_SETOR": "Pendente Setor Final",
                 "CONCLUIDO": "Concluído / Entregue"}

FINALIDADE = ("<b>Finalidade:</b> Registrar o recebimento e o encaminhamento de demandas judiciais e "
              "correspondências recebidas pelos Correios, mantendo o histórico de entrega entre os setores "
              "responsáveis.")
ORIENTACAO = ("<b>Orientação de preenchimento:</b> Preencher um registro por documento. Informar data e "
              "horário em cada etapa e colher a assinatura de quem recebe. Evitar registrar informações "
              "pessoais ou sigilosas além do necessário para identificar o documento.")


def _fd(iso):  # dd/mm/aaaa
    return f"{iso[8:10]}/{iso[5:7]}/{iso[0:4]}" if iso else ""


def _fh(iso):  # HH:MM:SS
    return iso[11:19] if iso else ""


def _e(txt):
    return escape(str(txt or ""))


def _estilo(nome, **kw):
    base = dict(fontName="Helvetica", fontSize=8, leading=10, textColor=colors.black)
    base.update(kw)
    return ParagraphStyle(nome, **base)


def _canvas_numerado(texto_esq):
    """Canvas que escreve rodapé com 'Página X de Y' (precisa conhecer o total)."""
    class Numerado(canvas.Canvas):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self._paginas = []

        def showPage(self):
            self._paginas.append(dict(self.__dict__))
            self._startPage()

        def save(self):
            total = len(self._paginas)
            for estado in self._paginas:
                self.__dict__.update(estado)
                self._rodape(total)
                super().showPage()
            super().save()

        def _rodape(self, total):
            w, _ = self._pagesize
            self.setFont("Helvetica", 7.5)
            self.setFillColor(CINZA)
            self.drawCentredString(w / 2, 8 * mm, "PROTOCOLO INTERNO • Demandas judiciais e correspondências")
            self.drawString(12 * mm, 8 * mm, texto_esq)
            self.drawRightString(w - 12 * mm, 8 * mm, f"Página {self._pageNumber} de {total}")
    return Numerado


def _png(png_bytes, max_w, max_h):
    """Imagem proporcional dentro de uma caixa (ou None se os bytes forem inválidos)."""
    try:
        w, h = ImageReader(io.BytesIO(png_bytes)).getSize()
        esc = min(max_w / w, max_h / h)
        return Image(io.BytesIO(png_bytes), width=w * esc, height=h * esc)
    except Exception:
        return None


def _cabecalho(unidade, logo_path, largura, titulo_extra=None):
    est_t = _estilo("t", fontName="Helvetica-Bold", fontSize=18, leading=22, textColor=AZUL, alignment=1)
    est_s = _estilo("s", fontName="Helvetica-Bold", fontSize=9.5, leading=12, alignment=1)
    est_u = _estilo("u", fontName="Helvetica-Bold", fontSize=11, leading=14, alignment=1)
    centro = [Paragraph("LIVRO DE PROTOCOLO", est_t),
              Paragraph("RECEBIMENTO E TRAMITAÇÃO DE DEMANDAS JUDICIAIS E CORRESPONDÊNCIAS", est_s),
              Spacer(1, 3),
              Paragraph(f"Unidade/Instituição: {_e(unidade)}", est_u)]
    if titulo_extra:
        centro += [Spacer(1, 2), Paragraph(titulo_extra, est_s)]
    logo = ""
    if logo_path and logo_path.exists():
        logo = _png(logo_path.read_bytes(), 38 * mm, 18 * mm) or ""
    t = Table([[logo, centro, ""]], colWidths=[42 * mm, largura - 84 * mm, 42 * mm])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LEFTPADDING", (0, 0), (-1, -1), 0)]))
    return t


def _celula_assinatura(tipo, png, nome, setor=None):
    """Conteúdo da coluna 'Assinatura': desenho do canvas (se houver) + identificação."""
    est = _estilo("a", fontSize=6.3, leading=7.5, alignment=1)
    itens = []
    if png:
        img = _png(png, 24 * mm, 9 * mm)
        if img:
            itens.append(img)
    elif tipo:
        itens.append(Paragraph("<i>Aceite digital (PIN)</i>", est))
    if nome:
        itens.append(Paragraph(_e(nome), est))
    if setor:
        itens.append(Paragraph(f"<b>{_e(setor)}</b>", est))
    return itens or ""


# ======================================================================
# Listagem (espelha o livro físico)
# ======================================================================
def listagem_pdf(linhas, total, descr_filtros, unidade, logo_path, gerado_por, gerado_em) -> bytes:
    buf = io.BytesIO()
    pagina = landscape(A4)
    doc = SimpleDocTemplate(buf, pagesize=pagina, leftMargin=12 * mm, rightMargin=12 * mm,
                            topMargin=10 * mm, bottomMargin=15 * mm,
                            title="Livro de Protocolo", author=unidade)
    largura = pagina[0] - 24 * mm

    est_txt = _estilo("txt", fontSize=8, leading=10)
    est_h = _estilo("h", fontName="Helvetica-Bold", fontSize=6.6, leading=8, alignment=1)
    est_c = _estilo("c", fontSize=7, leading=8.5, alignment=1)
    est_d = _estilo("d", fontSize=7.3, leading=9)

    cab = [Paragraph(x, est_h) for x in (
        "Nº", "1º Rece<br/>Portaria<br/>Data", "Horário", "DESCRIÇÃO DO DOCUMENTO", "Assinatura<br/>— Portaria",
        "2º Rece<br/>ADM<br/>Data", "Horário", "Assinatura<br/>ADM",
        "3º Rece<br/>Super/Setor<br/>Data", "Horário", "Assinatura<br/>Super/Setor")]
    dados = [cab]
    for r in linhas:
        desc = _e(r["descricao"]) + (" <font color='#8a5a00'><i>(descrição corrigida)</i></font>"
                                     if r.get("n_correcoes") else "")
        dados.append([
            Paragraph(f"<b>{_e(r['numero'])}</b>", est_c),
            Paragraph(_fd(r["e1_em"]), est_c), Paragraph(_fh(r["e1_em"])[:5], est_c),
            Paragraph(desc, est_d),
            _celula_assinatura(r["e1_tipo"], r.get("e1_png"), r["e1_usuario"]),
            Paragraph(_fd(r["e2_em"]), est_c), Paragraph(_fh(r["e2_em"])[:5], est_c),
            _celula_assinatura(r["e2_tipo"], r.get("e2_png"), r["e2_usuario"]),
            Paragraph(_fd(r["e3_em"]), est_c), Paragraph(_fh(r["e3_em"])[:5], est_c),
            _celula_assinatura(r["e3_tipo"], r.get("e3_png"), r["e3_usuario"], r["e3_setor"]),
        ])
    mm_cols = [17, 17, 12, 79, 28, 17, 12, 28, 17, 12, 34]  # soma = 273 mm
    t = Table(dados, colWidths=[c * mm for c in mm_cols], repeatRows=1)
    t.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, colors.black),
        ("BACKGROUND", (0, 0), (-1, 0), AZUL_CLARO),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 1), (-1, -1), 5), ("BOTTOMPADDING", (0, 1), (-1, -1), 5),
        ("LEFTPADDING", (0, 0), (-1, -1), 3), ("RIGHTPADDING", (0, 0), (-1, -1), 3),
    ]))

    filtros = "; ".join(descr_filtros) if descr_filtros else "nenhum (todos os registros)"
    historia = [
        _cabecalho(unidade, logo_path, largura), Spacer(1, 5),
        Paragraph(FINALIDADE, est_txt), Spacer(1, 3), Paragraph(ORIENTACAO, est_txt), Spacer(1, 4),
        Paragraph(f"<b>Filtros:</b> {_e(filtros)} &nbsp;&nbsp;|&nbsp;&nbsp; <b>Registros:</b> {total}"
                  + (" (exibindo os 2000 mais recentes)" if total > len(linhas) else ""), est_txt),
        Spacer(1, 5), t if linhas else Paragraph("Nenhum registro encontrado.", est_txt),
    ]
    doc.build(historia, canvasmaker=_canvas_numerado(f"Emitido por {gerado_por} em {_fd(gerado_em)} {_fh(gerado_em)}"))
    return buf.getvalue()


# ======================================================================
# Ficha individual
# ======================================================================
def ficha_pdf(p, pngs, unidade, logo_path, gerado_por, gerado_em) -> bytes:
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm,
                            topMargin=12 * mm, bottomMargin=16 * mm,
                            title=f"Protocolo {p['numero']}", author=unidade)
    largura = A4[0] - 30 * mm
    est = _estilo("n", fontSize=9, leading=11.5)
    est_h = _estilo("h", fontName="Helvetica-Bold", fontSize=8.5, leading=10.5, alignment=1)
    est_c = _estilo("c", fontSize=8.5, leading=10.5, alignment=1)
    est_sec = _estilo("sec", fontName="Helvetica-Bold", fontSize=10.5, leading=13, textColor=AZUL)
    est_mono = _estilo("m", fontName="Courier", fontSize=7.5, leading=9.5)

    dados_reg = Table([
        [Paragraph("<b>Nº do protocolo</b>", est), Paragraph(f"<font size=14><b>{_e(p['numero'])}</b></font>", est)],
        [Paragraph("<b>Situação</b>", est), Paragraph(_e(ROTULO_STATUS[p["status"]]), est)],
        [Paragraph("<b>Descrição do documento</b>", est), Paragraph(_e(p["descricao"]), est)],
    ], colWidths=[48 * mm, largura - 48 * mm])
    dados_reg.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, colors.black), ("BACKGROUND", (0, 0), (0, -1), AZUL_CLARO),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5)]))

    linhas = [[Paragraph(x, est_h) for x in ("Etapa", "Data", "Horário", "Responsável", "Assinatura")]]
    for e in p["etapas"]:
        nome = e["nome"] + (f"<br/><font size=7.5>Destino: {_e(e['setor'])}</font>" if e["setor"] else "")
        if e["registrada"]:
            linhas.append([Paragraph(f"<b>{nome}</b>", est), Paragraph(_fd(e["recebido_em"]), est_c),
                           Paragraph(_fh(e["recebido_em"]), est_c), Paragraph(_e(e["usuario"]), est_c),
                           _celula_assinatura(e["assinatura_tipo"], pngs.get(e["etapa"]), None)])
        else:
            linhas.append([Paragraph(f"<b>{nome}</b>", est), Paragraph("—", est_c), Paragraph("—", est_c),
                           Paragraph("<i>Pendente</i>", est_c), ""])
    etapas = Table(linhas, colWidths=[50 * mm, 24 * mm, 22 * mm, 42 * mm, largura - 138 * mm],
                   rowHeights=[8 * mm] + [17 * mm] * 3)
    etapas.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.5, colors.black), ("BACKGROUND", (0, 0), (-1, 0), AZUL_CLARO),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))

    h = [_cabecalho(unidade, logo_path, largura, "FICHA DO PROTOCOLO"), Spacer(1, 8),
         Paragraph(ORIENTACAO, _estilo("o", fontSize=8, leading=10)), Spacer(1, 8),
         dados_reg, Spacer(1, 10), Paragraph("Tramitação (3 etapas)", est_sec), Spacer(1, 3), etapas,
         Spacer(1, 4), Paragraph(
             f"Registrado em {_fd(p['criado_em'])} às {_fh(p['criado_em'])} (horário do servidor). "
             "Datas, horários e responsáveis são gerados pelo sistema e não podem ser editados.",
             _estilo("i", fontSize=7.5, leading=9.5, textColor=CINZA))]

    if p["correcoes"]:
        h += [Spacer(1, 10), Paragraph("Correções de descrição (original preservada)", est_sec), Spacer(1, 3)]
        linhas_c = [[Paragraph(x, est_h) for x in ("Data/hora", "Responsável", "Justificativa", "De → Para")]]
        for c in p["correcoes"]:
            linhas_c.append([
                Paragraph(f"{_fd(c['corrigido_em'])}<br/>{_fh(c['corrigido_em'])}", est_c),
                Paragraph(_e(c["usuario_nome"]), est_c), Paragraph(_e(c["justificativa"]), est),
                Paragraph(f"<i>{_e(c['descricao_anterior'])}</i><br/>→ {_e(c['descricao_nova'])}", est)])
        tc = Table(linhas_c, colWidths=[24 * mm, 32 * mm, 50 * mm, largura - 106 * mm], repeatRows=1)
        tc.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.5, colors.black),
                                ("BACKGROUND", (0, 0), (-1, 0), AZUL_CLARO), ("VALIGN", (0, 0), (-1, -1), "TOP")]))
        h.append(tc)

    selos = [f"Etapa {e['etapa']}: {e['selo']}" for e in p["etapas"] if e["registrada"]]
    if selos:
        h += [Spacer(1, 10), Paragraph("Selos de integridade (SHA-256)", est_sec), Spacer(1, 3)]
        h += [Paragraph(_e(s), est_mono) for s in selos]

    doc.build(h, canvasmaker=_canvas_numerado(f"Emitido por {gerado_por} em {_fd(gerado_em)} {_fh(gerado_em)}"))
    return buf.getvalue()
