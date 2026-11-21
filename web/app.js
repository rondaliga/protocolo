/* Livro de Protocolo Eletrônico — frontend estático (GitHub Pages + Supabase).
 *
 * Sem bibliotecas de terceiros: fala direto com a API do Supabase (Auth e PostgREST) por fetch.
 *
 * Segurança:
 *  - só a chave "anon" (pública) está no navegador; os dados são protegidos por login + RLS no banco;
 *  - toda gravação passa por funções RPC do banco (validam perfil, sequência, PIN e gravam auditoria);
 *  - data e horário nunca são enviados pelo cliente — vêm do relógio do servidor (now());
 *  - todo texto vindo do banco passa por esc() antes de virar HTML; a CSP bloqueia scripts inline;
 *  - sessão em sessionStorage (some ao fechar a aba) + logout automático por inatividade.
 */
(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ------------------------------------------------------------------ configuração
  const CFG = Object.assign({ UNIDADE: 'CECAN - LNRCC', TIMEZONE: 'America/Fortaleza', IDLE_MINUTES: 30,
                              ASSINATURA_OBRIGATORIA: false }, window.APP_CONFIG || {});
  const BASE = String(CFG.SUPABASE_URL || '').replace(/\/+$/, '');
  const KEY = String(CFG.SUPABASE_ANON_KEY || '');
  const CONFIG_OK = /^(https:\/\/|http:\/\/(localhost|127\.0\.0\.1)[:/]?)/.test(BASE) && KEY.length > 20 && !/SEU-PROJETO|SUA_CHAVE/.test(BASE + KEY);

  const ORIENTACAO = 'Preencher um registro por documento. Informar data e horário em cada etapa e colher a assinatura de '
    + 'quem recebe. Evitar registrar informações pessoais ou sigilosas além do necessário para identificar o documento.';
  const FINALIDADE = 'Registrar o recebimento e o encaminhamento de demandas judiciais e correspondências recebidas pelos '
    + 'Correios, mantendo o histórico de entrega entre os setores responsáveis.';

  const STATUS = { pendente_adm: 'Pendente ADM', pendente_setor: 'Pendente Setor Final', concluido: 'Concluído / Entregue' };
  const PAPEL = { portaria: 'Portaria', adm: 'Administração (ADM)', super_setor: 'Super/Setor', gestor: 'Gestão / Auditoria' };
  const ETAPA_NOME = { 1: '1ª Etapa — Portaria', 2: '2ª Etapa — ADM', 3: '3ª Etapa — Super/Setor' };
  const LIMITE_LIVRO_IMPRESSO = 300;

  // ------------------------------------------------------------------ datas (sempre no fuso da unidade)
  const FD = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, day: '2-digit', month: '2-digit', year: 'numeric' });
  const FH = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, hour: '2-digit', minute: '2-digit', hour12: false });
  const FHS = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
  const data = (iso) => (iso ? FD.format(new Date(iso)) : '');
  const hora = (iso, seg = false) => (iso ? (seg ? FHS : FH).format(new Date(iso)) : '');

  const estado = { sessao: null, perfil: null, aba: 'protocolos', pagina: 1, porPagina: 25, total: 0,
                   aberto: null, logo: false, ultimaAtividade: Date.now(), reqSeq: 0 };

  // ------------------------------------------------------------------ cliente Supabase (Auth + REST)
  const SK = 'lp.sessao';
  const salvarSessao = (s) => { estado.sessao = s; try { s ? sessionStorage.setItem(SK, JSON.stringify(s)) : sessionStorage.removeItem(SK); } catch { /* modo privado */ } };
  const lerSessao = () => { try { return JSON.parse(sessionStorage.getItem(SK) || 'null'); } catch { return null; } };

  class ErroApi extends Error { constructor(msg, status) { super(msg); this.status = status; } }

  async function lerResposta(resp) {
    const txt = await resp.text();
    let corpo = null;
    if (txt) { try { corpo = JSON.parse(txt); } catch { corpo = { message: txt.slice(0, 200) }; } }
    return corpo;
  }

  async function tokenGrant(grant, corpo) {
    const resp = await fetch(`${BASE}/auth/v1/token?grant_type=${grant}`, {
      method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) });
    const j = await lerResposta(resp);
    if (!resp.ok) {
      const cod = (j && (j.error_code || j.error)) || '';
      const msg = resp.status === 429 ? 'Muitas tentativas. Aguarde alguns minutos e tente novamente.'
        : /invalid_credentials|invalid_grant/.test(cod) ? 'E-mail ou senha inválidos.'
        : (j && (j.msg || j.message || j.error_description)) || `Falha na autenticação (${resp.status}).`;
      throw new ErroApi(msg, resp.status);
    }
    salvarSessao({ access_token: j.access_token, refresh_token: j.refresh_token,
                   expires_at: Math.floor(Date.now() / 1000) + (j.expires_in || 3600), uid: j.user && j.user.id });
    return j;
  }

  async function garantirToken() {
    const s = estado.sessao;
    if (!s) throw new ErroApi('Faça login para continuar.', 401);
    if (s.expires_at - 60 > Date.now() / 1000) return s.access_token;
    try { await tokenGrant('refresh_token', { refresh_token: s.refresh_token }); } catch { encerrarSessao('Sessão expirada. Entre novamente.'); throw new ErroApi('Sessão expirada.', 401); }
    return estado.sessao.access_token;
  }

  async function rest(caminho, { metodo = 'GET', corpo, repetir = true } = {}) {
    const token = await garantirToken();
    const headers = { apikey: KEY, Authorization: `Bearer ${token}`, Accept: 'application/json' };
    if (corpo !== undefined) headers['Content-Type'] = 'application/json';
    const resp = await fetch(`${BASE}/rest/v1/${caminho}`, { method: metodo, headers, body: corpo === undefined ? undefined : JSON.stringify(corpo) });
    const j = await lerResposta(resp);
    if (resp.status === 401 && repetir) { estado.sessao.expires_at = 0; return rest(caminho, { metodo, corpo, repetir: false }); }
    if (!resp.ok) {
      if (resp.status === 401) { encerrarSessao('Sessão expirada. Entre novamente.'); }
      throw new ErroApi((j && (j.message || j.hint)) || `Erro ${resp.status}`, resp.status);
    }
    return j;
  }
  const rpc = (nome, args = {}) => rest(`rpc/${nome}`, { metodo: 'POST', corpo: args });

  // ------------------------------------------------------------------ utilidades de interface
  let tToast;
  function toast(msg, erro = false) {
    const t = $('#toast'); t.textContent = msg; t.className = erro ? 'erro' : ''; t.hidden = false;
    clearTimeout(tToast); tToast = setTimeout(() => { t.hidden = true; }, 5000);
  }
  function erroForm(form, msg) { const p = $('.erro', form); p.textContent = msg || ''; p.hidden = !msg; }
  const chip = (s) => `<span class="chip ${esc(s)}">${esc(STATUS[s] || s)}</span>`;
  const pngSeguro = (s) => (typeof s === 'string' && /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(s) ? s : null);

  // ------------------------------------------------------------------ quadro de assinatura (canvas)
  class Pad {
    constructor(c) {
      this.c = c; this.x = c.getContext('2d'); this.vazio = true; this.on = false;
      Object.assign(this.x, { lineWidth: 2.4, lineCap: 'round', lineJoin: 'round', strokeStyle: '#111' });
      c.addEventListener('pointerdown', (e) => { e.preventDefault(); c.setPointerCapture(e.pointerId); this.on = true;
        const p = this.p(e); this.x.beginPath(); this.x.moveTo(p.x, p.y); this.x.lineTo(p.x + .1, p.y + .1); this.x.stroke(); this.vazio = false; });
      c.addEventListener('pointermove', (e) => { if (!this.on) return; e.preventDefault(); const p = this.p(e); this.x.lineTo(p.x, p.y); this.x.stroke(); });
      ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) => c.addEventListener(ev, () => { this.on = false; }));
    }
    p(e) { const r = this.c.getBoundingClientRect(); return { x: (e.clientX - r.left) * this.c.width / r.width, y: (e.clientY - r.top) * this.c.height / r.height }; }
    limpar() { this.x.clearRect(0, 0, this.c.width, this.c.height); this.vazio = true; }
    png() { return this.vazio ? null : this.c.toDataURL('image/png'); }
  }
  const pads = {};

  // ------------------------------------------------------------------ sessão / telas
  function mostrar(qual) {
    ['config', 'login', 'app'].forEach((n) => { $(`#view-${n}`).hidden = n !== qual; });
  }

  function encerrarSessao(aviso) {
    salvarSessao(null); estado.perfil = null;
    $$('dialog[open]').forEach((d) => d.close());
    $('#print-root').innerHTML = '';
    mostrar('login');
    const f = $('#form-login'); f.reset();
    const e = $('#login-erro'); e.textContent = aviso || ''; e.hidden = !aviso;
  }

  async function sair(evento = 'LOGOUT') {
    try { await rpc('registrar_acesso', { p_evento: evento }); } catch { /* segue */ }
    try { await fetch(`${BASE}/auth/v1/logout`, { method: 'POST', headers: { apikey: KEY, Authorization: `Bearer ${estado.sessao.access_token}` } }); } catch { /* segue */ }
    encerrarSessao(evento === 'LOGOUT_INATIVIDADE' ? 'Sessão encerrada por inatividade.' : '');
  }

  async function carregarPerfil() {
    const linhas = await rest(`perfis?select=nome,papel,setor_id,setores(nome)&user_id=eq.${encodeURIComponent(estado.sessao.uid)}`);
    if (!linhas || !linhas.length) throw new ErroApi('Seu usuário não possui perfil ativo neste sistema. Procure o administrador.', 403);
    const p = linhas[0];
    estado.perfil = { nome: p.nome, papel: p.papel, setor_id: p.setor_id, setor: p.setores && p.setores.nome };
  }

  async function iniciarApp(registrarLogin) {
    await carregarPerfil();
    if (registrarLogin) { try { await rpc('registrar_acesso', { p_evento: 'LOGIN' }); } catch { /* não bloqueia */ } }
    const { perfil } = estado;
    $('#usr-nome').textContent = perfil.nome;
    $('#usr-papel').textContent = PAPEL[perfil.papel] + (perfil.setor ? ` · ${perfil.setor}` : '');
    $('#btn-novo').hidden = perfil.papel !== 'portaria';
    $('#btn-aba-auditoria').hidden = perfil.papel !== 'gestor';
    $$('.eu').forEach((e) => { e.textContent = perfil.nome; });
    estado.ultimaAtividade = Date.now();
    mostrar('app');
    trocarAba('protocolos');
    await recarregar();
  }

  function trocarAba(n) {
    estado.aba = n;
    $$('.aba').forEach((b) => b.classList.toggle('ativa', b.dataset.aba === n));
    $('#painel-protocolos').hidden = n !== 'protocolos';
    $('#painel-auditoria').hidden = n !== 'auditoria';
    if (n === 'auditoria') carregarAuditoria();
  }

  // ------------------------------------------------------------------ dashboard e tabela
  function filtros() {
    const f = $('#form-filtros');
    const v = (n) => (f[n].value || '').trim() || null;
    return { p_q: v('q'), p_status: v('status'), p_data_ini: v('data_ini'), p_data_fim: v('data_fim') };
  }

  async function carregarResumo() {
    const r = await rpc('resumo_livro');
    $('#k-total').textContent = r.total; $('#k-adm').textContent = r.pendente_adm;
    $('#k-setor').textContent = r.pendente_setor; $('#k-ok').textContent = r.concluido;
    $('#k-hoje').textContent = `${r.hoje} registrado(s) hoje`;
  }

  function celulaEtapa(em, user, setor) {
    if (!em) return '<div class="et pend">—</div>';
    return `<div class="et"><strong>${data(em)} ${hora(em)}</strong><span>${esc(user)}${setor ? ` · ${esc(setor)}` : ''}</span></div>`;
  }

  async function carregarTabela() {
    const seq = ++estado.reqSeq;
    const r = await rpc('listar_livro', { ...filtros(), p_limite: estado.porPagina, p_offset: (estado.pagina - 1) * estado.porPagina });
    if (seq !== estado.reqSeq) return;                    // resposta antiga: ignora
    estado.total = r.total;
    $('#tbody').innerHTML = r.itens.map((x) => `
      <tr data-id="${esc(x.id)}" tabindex="0">
        <td class="num">${esc(x.numero)}</td>
        <td class="desc">${esc(x.descricao)}${x.n_correcoes ? ' <span class="tag">corrigida</span>' : ''}</td>
        <td>${chip(x.status)}</td>
        <td>${celulaEtapa(x.e1_em, x.e1_usuario)}</td>
        <td>${celulaEtapa(x.e2_em, x.e2_usuario)}</td>
        <td>${celulaEtapa(x.e3_em, x.e3_usuario, x.e3_setor)}</td>
      </tr>`).join('');
    $('#vazio').hidden = r.itens.length > 0;
    const paginas = Math.max(1, Math.ceil(r.total / estado.porPagina));
    $('#pg-info').textContent = `Página ${estado.pagina} de ${paginas}`;
    $('#pg-ant').disabled = estado.pagina <= 1; $('#pg-prox').disabled = estado.pagina >= paginas;
    $('#contagem').textContent = `${r.total} registro(s)`;
    const st = $('#form-filtros').status.value;
    $$('.kpi').forEach((k) => k.classList.toggle('sel', k.dataset.status === st && st !== ''));
  }

  async function recarregar() {
    try { await Promise.all([carregarResumo(), carregarTabela()]); } catch (e) { if (e.status !== 401) toast(e.message, true); }
  }

  // ------------------------------------------------------------------ detalhe / tramitação
  async function abrirDetalhe(id) {
    try {
      const p = await rpc('detalhe_protocolo', { p_id: Number(id) });
      if (!p) { toast('Protocolo não encontrado.', true); return; }
      estado.aberto = p; renderDetalhe(p);
      const d = $('#dlg-detalhe'); if (!d.open) d.showModal();
    } catch (e) { toast(e.message, true); }
  }

  function etapasCompletas(p) {
    return [1, 2, 3].map((n) => {
      const t = (p.etapas || []).find((e) => e.etapa === n);
      return { n, nome: ETAPA_NOME[n], feito: !!t, ...(t || {}) };
    });
  }

  function renderDetalhe(p) {
    const papel = estado.perfil.papel;
    const podeAdm = papel === 'adm' && p.status === 'pendente_adm';
    const podeSetor = papel === 'super_setor' && p.status === 'pendente_setor';
    const podeCorrigir = ['portaria', 'adm', 'gestor'].includes(papel);
    const linhas = etapasCompletas(p).map((e) => {
      if (!e.feito) return `<li class="pendente"><div><b>${esc(e.nome)}</b><small>Aguardando recebimento</small></div><div></div></li>`;
      const png = pngSeguro(e.assinatura_png);
      const ass = png ? `<img class="ass-img" src="${png}" alt="Assinatura de ${esc(e.usuario)}">` : '<span class="pin-ok">✔ Ciência por PIN</span>';
      return `<li class="feito"><div><b>${esc(e.nome)}</b>
        <small>${data(e.recebido_em)} às ${hora(e.recebido_em, true)} · ${esc(e.usuario)}</small>
        ${e.setor ? `<small>Setor final: <strong>${esc(e.setor)}</strong></small>` : ''}
        <small>Selo: ${esc(String(e.selo).slice(0, 16))}…</small></div><div>${ass}</div></li>`;
    }).join('');
    const corr = (p.correcoes || []).length ? `<div class="correcoes"><h3>Correções de descrição (original preservada)</h3><ul>
      ${p.correcoes.map((c) => `<li>${data(c.corrigido_em)} ${hora(c.corrigido_em)} — ${esc(c.usuario)}: “${esc(c.anterior)}” → “${esc(c.nova)}”.
        <em>Justificativa: ${esc(c.justificativa)}</em></li>`).join('')}</ul></div>` : '';
    $('#detalhe-corpo').innerHTML = `
      <div class="det-topo"><div><h2>${esc(p.numero)}</h2>${chip(p.status)}</div>
        <button class="btn mini sec" type="button" data-fechar>Fechar ✕</button></div>
      <div class="resumo-doc"><span>${esc(p.descricao)}</span>
        ${p.n_correcoes ? `<div class="original">Descrição original: ${esc(p.descricao_original)}</div>` : ''}</div>
      <ul class="linha-tempo">${linhas}</ul>${corr}
      <div class="modal-acoes">
        ${podeCorrigir ? '<button class="btn sec" type="button" data-acao="corrigir">Corrigir descrição</button>' : ''}
        <button class="btn" type="button" data-acao="imprimir">Imprimir ficha / PDF</button>
        ${podeAdm ? '<button class="btn primario" type="button" data-acao="adm">Confirmar recebimento — ADM</button>' : ''}
        ${podeSetor ? '<button class="btn primario" type="button" data-acao="setor">Confirmar recebimento — Setor</button>' : ''}
      </div>`;
  }

  // ------------------------------------------------------------------ modais de ação
  function prepararAssinatura(form, padId) {
    $('[data-dica-assinatura]', form).textContent = CFG.ASSINATURA_OBRIGATORIA
      ? 'O desenho da assinatura é obrigatório. Use o mouse, o dedo ou a caneta no quadro.'
      : 'Opcional: assine no quadro. O PIN é sempre obrigatório e vale como ciência formal.';
    pads[padId].limpar();
  }
  function assinaturaDe(form, padId) {
    const png = pads[padId].png();
    if (CFG.ASSINATURA_OBRIGATORIA && !png) throw new Error('Assine no quadro antes de confirmar.');
    return png;
  }
  async function enviar(form, acao, aoSucesso) {
    const btn = $('button[type=submit]', form); btn.disabled = true; erroForm(form, '');
    try {
      const r = await acao();
      if (r && r.ok === false) throw new Error(r.erro || 'Operação não autorizada.');
      await aoSucesso(r);
    } catch (e) { erroForm(form, e.message); }
    finally { btn.disabled = false; $$('input.pin', form).forEach((i) => { i.value = ''; }); }
  }

  function abrirNovo() {
    const f = $('#form-novo'); f.reset(); $('#cont-desc').textContent = '0'; erroForm(f, '');
    prepararAssinatura(f, 'pad-novo'); $('#dlg-novo').showModal(); f.descricao.focus();
  }

  function abrirConfirmar(etapa) {
    const p = estado.aberto, f = $('#form-confirmar');
    f.reset(); erroForm(f, ''); f.dataset.etapa = String(etapa); f.dataset.id = String(p.id);
    $('#conf-titulo').textContent = etapa === 2 ? '2º recebimento — Administração (ADM)' : '3º recebimento — Super/Setor';
    $('#conf-numero').textContent = p.numero; $('#conf-desc').textContent = p.descricao;
    const info = $('#conf-setor-info'); info.hidden = etapa !== 3;
    if (etapa === 3) info.textContent = `Setor final de destino: ${estado.perfil.setor} (definido pelo seu perfil).`;
    prepararAssinatura(f, 'pad-conf'); $('#dlg-confirmar').showModal(); f.pin.focus();
  }

  function abrirCorrecao() {
    const p = estado.aberto, f = $('#form-correcao');
    f.reset(); erroForm(f, ''); f.dataset.id = String(p.id);
    $('#corr-numero').textContent = p.numero; $('#corr-atual').textContent = p.descricao;
    f.descricao_nova.value = p.descricao; $('#dlg-correcao').showModal(); f.descricao_nova.focus();
  }

  // ------------------------------------------------------------------ auditoria
  async function carregarAuditoria() {
    $('#resultado-verificacao').textContent = '';
    try {
      const l = await rest('auditoria?select=id,ocorrido_em,usuario_nome,acao,protocolo_id,detalhes&order=id.desc&limit=300');
      $('#tbody-audit').innerHTML = l.map((x) => `<tr><td>${data(x.ocorrido_em)} ${hora(x.ocorrido_em, true)}</td>
        <td>${esc(x.usuario_nome || '—')}</td><td><strong>${esc(x.acao)}</strong></td>
        <td>${esc((x.detalhes && x.detalhes.numero) || x.protocolo_id || '')}</td>
        <td class="detalhes">${esc(JSON.stringify(x.detalhes || {}))}</td></tr>`).join('');
    } catch (e) { toast(e.message, true); }
  }

  // ------------------------------------------------------------------ IMPRESSÃO (livro e ficha)
  function cabecalhoImpressao(subtitulo) {
    const marca = estado.logo ? '<img src="assets/logo.png" alt="">' : '<span class="p-cruz">+</span>';
    return `<div class="p-cab"><div>${marca}</div>
      <div class="p-tit"><h1>LIVRO DE PROTOCOLO</h1>
        <div class="s">RECEBIMENTO E TRAMITAÇÃO DE DEMANDAS JUDICIAIS E CORRESPONDÊNCIAS</div>
        <div class="u">Unidade/Instituição: ${esc(CFG.UNIDADE)}</div>${subtitulo ? `<div class="s">${esc(subtitulo)}</div>` : ''}</div><div></div></div>`;
  }
  const rodapeImpressao = () => '<div class="p-rodape">PROTOCOLO INTERNO • Demandas judiciais e correspondências</div>';

  function celulaAssinatura(tipo, png, nome, setor) {
    const img = pngSeguro(png);
    return `<div class="p-ass">${img ? `<img src="${img}" alt="">` : (tipo ? '<small><i>Ciência digital (PIN)</i></small>' : '')}
      ${nome ? `<small>${esc(nome)}</small>` : ''}${setor ? `<small><b>${esc(setor)}</b></small>` : ''}</div>`;
  }

  function imprimir(classe, html) {
    const raiz = $('#print-root');
    raiz.className = classe; raiz.innerHTML = html;
    const limpar = () => { raiz.innerHTML = ''; raiz.className = ''; window.removeEventListener('afterprint', limpar); };
    window.addEventListener('afterprint', limpar);
    window.print();
  }

  async function imprimirLivro() {
    const btn = $('#btn-imprimir-livro'); btn.disabled = true;
    try {
      const f = filtros();
      const r = await rpc('listar_livro', { ...f, p_limite: LIMITE_LIVRO_IMPRESSO, p_offset: 0 });
      const descr = [f.p_q && `busca “${f.p_q}”`, f.p_status && `situação: ${STATUS[f.p_status]}`,
        f.p_data_ini && `a partir de ${data(f.p_data_ini + 'T12:00:00')}`, f.p_data_fim && `até ${data(f.p_data_fim + 'T12:00:00')}`].filter(Boolean).join('; ');
      await rpc('registrar_exportacao', { p_tipo: 'LIVRO', p_filtros: descr || 'sem filtros' });
      // imagens das assinaturas (uma consulta só)
      const ids = r.itens.map((x) => x.id);
      const sig = {};
      if (ids.length) {
        const rows = await rest(`tramites?select=protocolo_id,etapa,assinatura_png&assinatura_png=not.is.null&protocolo_id=in.(${ids.join(',')})`);
        rows.forEach((x) => { sig[`${x.protocolo_id}:${x.etapa}`] = x.assinatura_png; });
      }
      const largura = new Array(11).fill(0);
      const cab = ['Nº', '1º Receb.<br>Portaria<br>Data', 'Horário', 'DESCRIÇÃO DO DOCUMENTO', 'Assinatura<br>— Portaria',
        '2º Receb.<br>ADM<br>Data', 'Horário', 'Assinatura<br>ADM', '3º Receb.<br>Super/Setor<br>Data', 'Horário', 'Assinatura<br>Super/Setor'];
      const linhas = r.itens.map((x) => `<tr>
        <td><b>${esc(x.numero)}</b></td><td>${data(x.e1_em)}</td><td>${hora(x.e1_em)}</td>
        <td class="d">${esc(x.descricao)}${x.n_correcoes ? ' <i>(descrição corrigida)</i>' : ''}</td>
        <td>${celulaAssinatura(x.e1_tipo, sig[`${x.id}:1`], x.e1_usuario)}</td>
        <td>${data(x.e2_em)}</td><td>${hora(x.e2_em)}</td><td>${celulaAssinatura(x.e2_tipo, sig[`${x.id}:2`], x.e2_usuario)}</td>
        <td>${data(x.e3_em)}</td><td>${hora(x.e3_em)}</td><td>${celulaAssinatura(x.e3_tipo, sig[`${x.id}:3`], x.e3_usuario, x.e3_setor)}</td></tr>`).join('');
      const agora = new Date().toISOString();
      imprimir('livro', `${cabecalhoImpressao('')}
        <p class="p-txt"><b>Finalidade:</b> ${esc(FINALIDADE)}</p>
        <p class="p-txt"><b>Orientação de preenchimento:</b> ${esc(ORIENTACAO)}</p>
        <p class="p-meta">Filtros: ${esc(descr || 'nenhum')} · Registros: ${r.total}${r.total > r.itens.length ? ` (impressos os ${r.itens.length} mais recentes)` : ''}
          · Emitido por ${esc(estado.perfil.nome)} em ${data(agora)} ${hora(agora)}</p>
        <table class="p-tab"><colgroup>${largura.map((w, i) => `<col class="w${i}">`).join('')}</colgroup>
          <thead><tr>${cab.map((c) => `<th>${c}</th>`).join('')}</tr></thead>
          <tbody>${linhas || '<tr><td colspan="11">Nenhum registro.</td></tr>'}</tbody></table>${rodapeImpressao()}`);
      if (r.total > r.itens.length) toast(`Foram impressos os ${r.itens.length} registros mais recentes de ${r.total}. Use filtros para os demais.`);
    } catch (e) { toast(e.message, true); } finally { btn.disabled = false; }
  }

  async function imprimirFicha() {
    const p = estado.aberto;
    try {
      await rpc('registrar_exportacao', { p_tipo: 'FICHA', p_protocolo_id: p.id });
      const linhas = etapasCompletas(p).map((e) => e.feito
        ? `<tr><td class="n"><b>${esc(e.nome)}</b>${e.setor ? `<br>Destino: ${esc(e.setor)}` : ''}</td><td>${data(e.recebido_em)}</td><td>${hora(e.recebido_em, true)}</td>
           <td>${esc(e.usuario)}</td><td class="p-ass">${celulaAssinatura(e.assinatura_tipo, e.assinatura_png, null)}</td></tr>`
        : `<tr><td class="n"><b>${esc(e.nome)}</b></td><td>—</td><td>—</td><td><i>Pendente</i></td><td></td></tr>`).join('');
      const corr = (p.correcoes || []).length ? `<div class="p-sec">Correções de descrição (original preservada)</div>
        <table class="p-ficha-tab"><tbody>${p.correcoes.map((c) => `<tr><th>${data(c.corrigido_em)} ${hora(c.corrigido_em)}<br>${esc(c.usuario)}</th>
          <td><i>${esc(c.anterior)}</i> → ${esc(c.nova)}<br><small>Justificativa: ${esc(c.justificativa)}</small></td></tr>`).join('')}</tbody></table>` : '';
      const selos = etapasCompletas(p).filter((e) => e.feito).map((e) => `<div class="p-selo">Etapa ${e.n}: ${esc(e.selo)}</div>`).join('');
      const agora = new Date().toISOString();
      imprimir('ficha', `${cabecalhoImpressao('FICHA DO PROTOCOLO')}
        <p class="p-txt"><b>Orientação de preenchimento:</b> ${esc(ORIENTACAO)}</p>
        <table class="p-ficha-tab"><tbody>
          <tr><th>Nº do protocolo</th><td><b class="p-num">${esc(p.numero)}</b></td></tr>
          <tr><th>Situação</th><td>${esc(STATUS[p.status])}</td></tr>
          <tr><th>Descrição do documento</th><td>${esc(p.descricao)}</td></tr></tbody></table>
        <div class="p-sec">Tramitação (3 etapas)</div>
        <table class="p-ficha-tab p-etapas"><thead><tr><th class="n">Etapa</th><th>Data</th><th>Horário</th><th>Responsável</th><th>Assinatura</th></tr></thead>
          <tbody>${linhas}</tbody></table>${corr}
        <div class="p-sec">Selos de integridade (SHA-256)</div>${selos}
        <p class="p-meta">Registrado em ${data(p.created_at)} às ${hora(p.created_at, true)} (horário do servidor). Datas, horários e responsáveis são gerados pelo
          sistema e não podem ser editados. Emitido por ${esc(estado.perfil.nome)} em ${data(agora)} ${hora(agora)}.</p>${rodapeImpressao()}`);
    } catch (e) { toast(e.message, true); }
  }

  // ------------------------------------------------------------------ eventos
  function ligarEventos() {
    // login
    $('#form-login').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const f = ev.target, btn = $('button[type=submit]', f), erro = $('#login-erro');
      btn.disabled = true; erro.hidden = true;
      try {
        await tokenGrant('password', { email: f.email.value.trim(), password: f.senha.value });
        f.reset();
        await iniciarApp(true);
      } catch (e) {
        if (estado.sessao) salvarSessao(null);
        erro.textContent = e.message; erro.hidden = false; f.senha.value = '';
      } finally { btn.disabled = false; }
    });
    $('#btn-sair').addEventListener('click', () => sair('LOGOUT'));

    $('#abas').addEventListener('click', (ev) => { const b = ev.target.closest('.aba'); if (b) trocarAba(b.dataset.aba); });

    // busca instantânea + filtros
    const f = $('#form-filtros');
    let t;
    const aplicar = () => { estado.pagina = 1; recarregar(); };
    f.addEventListener('submit', (ev) => ev.preventDefault());
    f.q.addEventListener('input', () => { clearTimeout(t); t = setTimeout(aplicar, 300); });
    ['status', 'data_ini', 'data_fim'].forEach((n) => f[n].addEventListener('change', aplicar));
    $('#btn-limpar').addEventListener('click', () => { f.reset(); aplicar(); });
    $('#kpis').addEventListener('click', (ev) => { const k = ev.target.closest('.kpi'); if (k) { f.status.value = k.dataset.status; aplicar(); } });
    $('#pg-ant').addEventListener('click', () => { estado.pagina -= 1; carregarTabela().catch((e) => toast(e.message, true)); });
    $('#pg-prox').addEventListener('click', () => { estado.pagina += 1; carregarTabela().catch((e) => toast(e.message, true)); });

    const abrirLinha = (ev) => { const tr = ev.target.closest('tr[data-id]'); if (tr) abrirDetalhe(tr.dataset.id); };
    $('#tbody').addEventListener('click', abrirLinha);
    $('#tbody').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') abrirLinha(ev); });

    $('#detalhe-corpo').addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-acao]'); if (!b) return;
      ({ imprimir: imprimirFicha, corrigir: abrirCorrecao, adm: () => abrirConfirmar(2), setor: () => abrirConfirmar(3) })[b.dataset.acao]();
    });
    document.addEventListener('click', (ev) => {
      if (ev.target.closest('[data-fechar]')) ev.target.closest('dialog').close();
      const l = ev.target.closest('[data-limpar]'); if (l) pads[l.dataset.limpar].limpar();
    });
    $$('dialog').forEach((d) => d.addEventListener('close', () => { $$('form', d).forEach((x) => x.reset()); }));

    $('#btn-imprimir-livro').addEventListener('click', imprimirLivro);
    $('#btn-novo').addEventListener('click', abrirNovo);
    $('#form-novo').descricao.addEventListener('input', (ev) => { $('#cont-desc').textContent = ev.target.value.length; });

    $('#form-novo').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      let png; try { png = assinaturaDe(form, 'pad-novo'); } catch (e) { erroForm(form, e.message); return; }
      enviar(form, () => rpc('registrar_protocolo', { p_descricao: form.descricao.value, p_pin: form.pin.value, p_assinatura: png }), async (r) => {
        $('#dlg-novo').close(); toast(`Protocolo ${r.numero} registrado — aguardando ADM.`); estado.pagina = 1; await recarregar();
      });
    });

    $('#form-confirmar').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target, etapa = Number(form.dataset.etapa);
      let png; try { png = assinaturaDe(form, 'pad-conf'); } catch (e) { erroForm(form, e.message); return; }
      enviar(form, () => rpc('confirmar_etapa', { p_protocolo_id: Number(form.dataset.id), p_etapa: etapa, p_pin: form.pin.value, p_assinatura: png }), async (r) => {
        $('#dlg-confirmar').close();
        toast(etapa === 2 ? `${r.numero}: recebimento do ADM registrado.` : `${r.numero}: entrega concluída no setor.`);
        await abrirDetalhe(form.dataset.id); await recarregar();
      });
    });

    $('#form-correcao').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      enviar(form, () => rpc('corrigir_descricao', { p_protocolo_id: Number(form.dataset.id), p_nova: form.descricao_nova.value,
        p_justificativa: form.justificativa.value, p_pin: form.pin.value }), async () => {
        $('#dlg-correcao').close(); toast('Correção registrada. A descrição original foi preservada.');
        await abrirDetalhe(form.dataset.id); await recarregar();
      });
    });

    $('#btn-pin').addEventListener('click', () => { const form = $('#form-pin'); form.reset(); erroForm(form, ''); $('#dlg-pin').showModal(); form.atual.focus(); });
    $('#form-pin').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      enviar(form, () => rpc('alterar_meu_pin', { p_atual: form.atual.value, p_novo: form.novo.value }), async () => {
        $('#dlg-pin').close(); toast('PIN alterado com sucesso.');
      });
    });

    $('#btn-verificar').addEventListener('click', async () => {
      const out = $('#resultado-verificacao');
      try {
        const r = await rpc('verificar_auditoria');
        out.className = `verificacao ${r.ok ? 'ok' : 'falha'}`;
        out.textContent = r.ok ? `✔ Trilha íntegra (${r.total} eventos verificados).` : `✖ ADULTERAÇÃO DETECTADA a partir do evento nº ${r.primeira_falha_id}.`;
      } catch (e) { toast(e.message, true); }
    });

    // inatividade + atualização automática
    ['pointerdown', 'keydown', 'scroll'].forEach((n) => document.addEventListener(n, () => { estado.ultimaAtividade = Date.now(); }, { passive: true }));
    setInterval(() => {
      if (!estado.perfil) return;
      if (Date.now() - estado.ultimaAtividade > CFG.IDLE_MINUTES * 60000) { sair('LOGOUT_INATIVIDADE'); return; }
      if (estado.aba === 'protocolos' && !$('dialog[open]') && !document.hidden) recarregar();
    }, 30000);
  }

  // ------------------------------------------------------------------ inicialização
  async function iniciar() {
    $$('[data-unidade]').forEach((e) => { e.textContent = `Unidade/Instituição: ${CFG.UNIDADE}`; });
    if (!CONFIG_OK) { mostrar('config'); return; }
    pads['pad-novo'] = new Pad($('#pad-novo')); pads['pad-conf'] = new Pad($('#pad-conf'));
    ligarEventos();
    const img = new Image();                              // logotipo opcional: web/assets/logo.png
    img.onload = () => { estado.logo = true; $$('img.logo').forEach((i) => { i.src = 'assets/logo.png'; i.hidden = false; }); };
    img.src = 'assets/logo.png';
    const s = lerSessao();
    if (s) {
      estado.sessao = s;
      try { await iniciarApp(false); return; } catch { salvarSessao(null); }
    }
    mostrar('login');
  }
  iniciar();
})();
