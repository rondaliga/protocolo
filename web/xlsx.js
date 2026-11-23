/* Gerador mínimo de planilha .xlsx (Office Open XML), sem bibliotecas: arquivo ZIP sem compressão.
   Uso:  const bytes = window.criarXlsx({ nome:'Trilha', colunas:[{titulo,largura,tipo:'texto'|'data'|'hora'|'texto-longo'}], linhas:[[...]] })
   - 'data' e 'hora' recebem {y,m,d,h,mi,s} (hora local da unidade) e viram data/hora reais do Excel;
   - textos entram como texto puro (nunca como fórmula), então não há "injeção de fórmula";
   - cabeçalho fixo e filtro automático; larguras definidas (sem "#####" nas datas). */
(() => {
  'use strict';
  const enc = new TextEncoder();

  const TABELA_CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n += 1) { let c = n; for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
  const crc32 = (b) => { let c = 0xffffffff; for (let i = 0; i < b.length; i += 1) c = TABELA_CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };

  function zip(arquivos) {                      // arquivos: [{nome, dados:Uint8Array}] — método "stored"
    const partes = [], central = []; let pos = 0;
    const agora = new Date();
    const hora = (agora.getHours() << 11) | (agora.getMinutes() << 5) | (agora.getSeconds() >> 1);
    const dia = ((agora.getFullYear() - 1980) << 9) | ((agora.getMonth() + 1) << 5) | agora.getDate();
    const u16 = (v) => [v & 255, (v >> 8) & 255], u32 = (v) => [v & 255, (v >>> 8) & 255, (v >>> 16) & 255, (v >>> 24) & 255];
    arquivos.forEach((a) => {
      const nome = enc.encode(a.nome), crc = crc32(a.dados), n = a.dados.length;
      const cab = Uint8Array.from([0x50, 0x4b, 3, 4, ...u16(20), ...u16(0x0800), ...u16(0), ...u16(hora), ...u16(dia), ...u32(crc), ...u32(n), ...u32(n), ...u16(nome.length), ...u16(0)]);
      partes.push(cab, nome, a.dados);
      central.push(Uint8Array.from([0x50, 0x4b, 1, 2, ...u16(20), ...u16(20), ...u16(0x0800), ...u16(0), ...u16(hora), ...u16(dia), ...u32(crc), ...u32(n), ...u32(n),
        ...u16(nome.length), ...u16(0), ...u16(0), ...u16(0), ...u16(0), ...u32(0), ...u32(pos)]), nome);
      pos += cab.length + nome.length + n;
    });
    const tamCentral = central.reduce((s, p) => s + p.length, 0);
    const fim = Uint8Array.from([0x50, 0x4b, 5, 6, ...u16(0), ...u16(0), ...u16(arquivos.length), ...u16(arquivos.length), ...u32(tamCentral), ...u32(pos), ...u16(0)]);
    const todos = [...partes, ...central, fim], saida = new Uint8Array(todos.reduce((s, p) => s + p.length, 0));
    let o = 0; todos.forEach((p) => { saida.set(p, o); o += p.length; });
    return saida;
  }

  const xml = (s) => String(s ?? '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const letra = (i) => { let s = '', n = i + 1; while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); } return s; };
  const serialData = (p) => Math.round(Date.UTC(p.y, p.m - 1, p.d) / 86400000) + 25569;       // dias desde 30/12/1899
  const fracHora = (p) => (p.h * 3600 + p.mi * 60 + p.s) / 86400;

  // estilos: 0 padrão · 1 cabeçalho · 2 data · 3 hora · 4 texto (topo) · 5 texto longo (quebra de linha)
  const ESTILOS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/><numFmt numFmtId="165" formatCode="hh:mm:ss"/></numFmts>
<fonts count="2"><font><sz val="10"/><name val="Arial"/></font><font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Arial"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E6E"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFD5DDE5"/></left><right style="thin"><color rgb="FFD5DDE5"/></right><top style="thin"><color rgb="FFD5DDE5"/></top><bottom style="thin"><color rgb="FFD5DDE5"/></bottom><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>
<xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>
<xf numFmtId="165" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="top"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>
<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

  function criarXlsx({ nome = 'Planilha', colunas, linhas }) {
    const estilo = { texto: 4, data: 2, hora: 3, 'texto-longo': 5 };
    const cel = (c, r, v, s, t) => (v === null || v === undefined || v === '' ? `<c r="${letra(c)}${r}" s="${s}"/>`
      : t === 'n' ? `<c r="${letra(c)}${r}" s="${s}"><v>${v}</v></c>`
        : `<c r="${letra(c)}${r}" s="${s}" t="inlineStr"><is><t xml:space="preserve">${xml(v)}</t></is></c>`);
    const cab = `<row r="1" ht="24" customHeight="1">${colunas.map((c, i) => cel(i, 1, c.titulo, 1, 's')).join('')}</row>`;
    const corpo = linhas.map((l, k) => `<row r="${k + 2}">${colunas.map((c, i) => {
      const v = l[i], tipo = c.tipo || 'texto';
      if (tipo === 'data') return cel(i, k + 2, v ? serialData(v) : null, 2, 'n');
      if (tipo === 'hora') return cel(i, k + 2, v ? fracHora(v).toFixed(8) : null, 3, 'n');
      return cel(i, k + 2, v, estilo[tipo] || 4, 's');
    }).join('')}</row>`).join('');
    const ultima = `${letra(colunas.length - 1)}${linhas.length + 1}`;
    const planilha = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetPr><pageSetUpPr fitToPage="1"/></sheetPr><dimension ref="A1:${ultima}"/>
<sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>
<sheetFormatPr defaultRowHeight="15"/><cols>${colunas.map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${c.largura || 14}" customWidth="1"/>`).join('')}</cols>
<sheetData>${cab}${corpo}</sheetData><autoFilter ref="A1:${ultima}"/>
<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/><pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/></worksheet>`;
    const T = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    const arq = (n, s) => ({ nome: n, dados: enc.encode(s) });
    return zip([
      arq('[Content_Types].xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>`),
      arq('_rels/.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="${T}/officeDocument" Target="xl/workbook.xml"/></Relationships>`),
      arq('xl/workbook.xml', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="${T}"><sheets><sheet name="${xml(nome).slice(0, 31)}" sheetId="1" r:id="rId1"/></sheets><definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">'${xml(nome).slice(0, 31)}'!$A$1:$${letra(colunas.length - 1)}$${linhas.length + 1}</definedName></definedNames></workbook>`),
      arq('xl/_rels/workbook.xml.rels', `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="${T}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="${T}/styles" Target="styles.xml"/></Relationships>`),
      arq('xl/styles.xml', ESTILOS),
      arq('xl/worksheets/sheet1.xml', planilha),
    ]);
  }
  window.criarXlsx = criarXlsx;
})();
