/* Livro de Protocolo Eletrônico — frontend estático (GitHub Pages + Supabase).
 *
 * Sem bibliotecas de terceiros: fala direto com a API do Supabase (Auth e PostgREST) por fetch.
 *
 * Segurança:
 *  - só a chave "anon" (pública) está no navegador; os dados são protegidos por login + RLS no banco;
 *  - toda gravação passa por funções RPC do banco (validam perfil, sequência, PIN e gravam auditoria);
 *  - data e hora nunca são enviados pelo cliente — vêm do relógio do servidor (now());
 *  - todo texto vindo do banco passa por esc() antes de virar HTML; a CSP bloqueia scripts inline;
 *  - sessão em sessionStorage (some ao fechar a aba) + logout automático por inatividade.
 */
(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const pl = (n, um, varios) => `${n} ${Number(n) === 1 ? um : varios}`;
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ------------------------------------------------------------------ configuração
  const CFG = Object.assign({ UNIDADE: 'CECAN – LNRCC', TIMEZONE: 'America/Fortaleza', IDLE_MINUTES: 30,
                              ASSINATURA_OBRIGATORIA: false }, window.APP_CONFIG || {});
  const BASE = String(CFG.SUPABASE_URL || '').replace(/\/+$/, '');
  const KEY = String(CFG.SUPABASE_ANON_KEY || '');
  const CONFIG_OK = /^(https:\/\/|http:\/\/(localhost|127\.0\.0\.1)[:/]?)/.test(BASE) && KEY.length > 20 && !/SEU-PROJETO|SUA_CHAVE/.test(BASE + KEY);

  const ORIENTACAO = 'Preencher um registro por documento. Informar data e hora em cada etapa e colher a assinatura de '
    + 'quem recebe. Evitar registrar informações pessoais ou sigilosas além do necessário para identificar o documento.';
  const FINALIDADE = 'Registrar o recebimento e o encaminhamento de demandas judiciais e correspondências recebidas pelos '
    + 'Correios, mantendo o histórico de entrega entre os setores responsáveis.';

  const STATUS = { pendente_adm: 'Aguardando ADM', pendente_setor: 'Aguardando setor de destino', concluido: 'Concluído / Entregue' };
  const PAPEL = { portaria: 'Portaria', adm: 'Administração (ADM)', super_setor: 'Setor de destino', gestor: 'Gestor (acesso total)' };
  const ASSIN_ROTULO = { pin: 'Ciência por PIN', pin_canvas: 'Assinatura desenhada', pin_digitada: 'Assinatura digitada' };
  const ETAPA_NOME = { 1: '1ª Etapa — Portaria', 2: '2ª Etapa — ADM', 3: '3ª Etapa — Setor de destino' };
  const LIMITE_LIVRO_IMPRESSO = 300;

  // ------------------------------------------------------------------ datas (sempre no fuso da unidade)
  const FD = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, day: '2-digit', month: '2-digit', year: 'numeric' });
  const FH = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, hour: '2-digit', minute: '2-digit', hour12: false });
  const FHS = new Intl.DateTimeFormat('pt-BR', { timeZone: CFG.TIMEZONE, hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false });
  const data = (iso) => (iso ? FD.format(new Date(iso)) : '');
  const hora = (iso, seg = false) => (iso ? (seg ? FHS : FH).format(new Date(iso)) : '');

  // tempo decorrido legível ("há 3 h 20 min")
  const ha = (iso) => {
    if (!iso) return '';
    const m = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 60000));
    if (m < 1) return 'agora mesmo';
    if (m < 60) return `há ${m} min`;
    const h = Math.floor(m / 60);
    if (h < 48) return `há ${h} h${m % 60 ? ` ${m % 60} min` : ''}`;
    return `há ${Math.floor(h / 24)} dias`;
  };
  const SEM = { ok: 'No prazo', atencao: 'Atenção', critico: 'Vence em breve', vencido: 'VENCIDO', sem_prazo: 'Sem prazo', concluido: 'Concluído' };
  const diasTxt = (x) => (x.status === 'concluido' ? '' : x.dias_restantes == null ? '' : x.dias_restantes < 0
    ? `${pl(-x.dias_restantes, 'dia', 'dias')} de atraso` : x.dias_restantes === 0 ? 'vence hoje' : pl(x.dias_restantes, 'dia', 'dias'));
  const prazoHtml = (x) => (x.status === 'concluido' ? '<span class="sem concluido">Concluído</span>'
    : `<span class="sem ${esc(x.semaforo)}">${esc(SEM[x.semaforo] || x.semaforo)}</span>${x.prazo_data ? `<small class="et-sub">${data(x.prazo_data + 'T12:00:00')} · ${esc(diasTxt(x))}</small>` : ''}`);
  const tipoHtml = (x) => (x.tipo === 'judicial' ? '<span class="tipo-jud">JUDICIAL</span>' : '') + (x.urgente ? '<span class="tipo-urg">URGENTE</span>' : '');
  const ondeHtml = (x) => {
    if (x.status === 'concluido') return `${chip(x.status)}<small>Entregue a ${esc(x.e3_setor || '')}</small>`;
    const quem = x.status === 'pendente_adm' ? 'Aguardando o ADM' : `Aguardando ${esc(x.setor_destino_nome || 'o setor')}`;
    return `${chip(x.status)}<small class="${x.sla_estourado ? 'atraso' : ''}">${quem} · ${esc(ha(x.aguardando_desde))}${x.sla_estourado ? ' ⚠ além do tempo' : ''}</small>`;
  };

  const estado = { sessao: null, perfil: null, aba: 'protocolos', pagina: 1, porPagina: 25, total: 0,
                   aberto: null, logo: false, logoSrc: null, setores: null, alertasVistos: null, fotoBlob: null, fotoUrl: null, ultimaAtividade: Date.now(), reqSeq: 0 };

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
    if (!s) throw new ErroApi('Entre no sistema para continuar.', 401);
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

  // ------------------------------------------------------------------ assinatura (digitada / desenhada / só PIN)
  const assinaturas = {};            // 'novo' e 'conf' (ver assinatura.js)
  let painelMod = null;              // trilha + painel de controle (painel.js)

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
    const linhas = await rest(`perfis?select=nome,papel,setor_id,deve_trocar_senha,deve_trocar_pin,setores(nome)&user_id=eq.${encodeURIComponent(estado.sessao.uid)}`);
    if (!linhas || !linhas.length) throw new ErroApi('Seu usuário não possui perfil ativo neste sistema. Procure o administrador.', 403);
    const p = linhas[0];
    estado.perfil = { nome: p.nome, papel: p.papel, setor_id: p.setor_id, setor: p.setores && p.setores.nome,
                      deveTrocarSenha: !!p.deve_trocar_senha, deveTrocarPin: !!p.deve_trocar_pin };
  }

  async function iniciarApp(registrarLogin) {
    await carregarPerfil();
    if (registrarLogin) { try { await rpc('registrar_acesso', { p_evento: 'LOGIN' }); } catch { /* não bloqueia */ } }
    const { perfil } = estado;
    $('#usr-nome').textContent = perfil.nome;
    $('#usr-papel').textContent = PAPEL[perfil.papel] + (perfil.setor ? ` · ${perfil.setor}` : '');
    $('#btn-novo').hidden = !['portaria', 'gestor'].includes(perfil.papel);
    $('#btn-aba-auditoria').hidden = perfil.papel !== 'gestor';
    $('#btn-aba-painel').hidden = perfil.papel !== 'gestor';
    $$('.eu').forEach((e) => { e.textContent = perfil.nome; });
    $('.sino-wrap').hidden = perfil.papel === 'portaria'; estado.alertasVistos = null; estado.setores = null;
    estado.ultimaAtividade = Date.now();
    mostrar('app');
    restaurarFiltros();
    trocarAba('protocolos');
    await recarregar();
    await verificarAlertas(false);
    if (perfil.deveTrocarSenha || perfil.deveTrocarPin) abrirConta(true);
  }

  function trocarAba(n) {
    estado.aba = n;
    $$('.aba').forEach((b) => b.classList.toggle('ativa', b.dataset.aba === n));
    $('#painel-protocolos').hidden = n !== 'protocolos';
    $('#painel-auditoria').hidden = n !== 'auditoria';
    $('#painel-controle').hidden = n !== 'painel';
    if (n === 'auditoria') painelMod.abrirAuditoria();
    if (n === 'painel') painelMod.abrirPainel();
  }

  // ------------------------------------------------------------------ dashboard e tabela
  // filtros de conveniência lembrados por usuário neste navegador (só status, alerta e ordem; nunca busca livre nem datas)
  const chaveFiltros = () => `protocolo.filtros.${estado.sessao ? estado.sessao.uid : ''}`;
  const FILTROS_SALVOS = ['status', 'alerta', 'ordem'];
  function salvarFiltros() {
    const f = $('#form-filtros'); const o = {}; FILTROS_SALVOS.forEach((n) => { o[n] = f[n].value; });
    try { localStorage.setItem(chaveFiltros(), JSON.stringify(o)); } catch { /* sem armazenamento */ }
  }
  function restaurarFiltros() {
    const f = $('#form-filtros');
    try {
      const o = JSON.parse(localStorage.getItem(chaveFiltros()) || 'null'); if (!o) return;
      FILTROS_SALVOS.forEach((n) => { const op = [...f[n].options].find((x) => x.value === o[n]); if (op) f[n].value = op.value; });
    } catch { /* ignora */ }
  }
  function filtros() {
    const f = $('#form-filtros');
    const v = (n) => (f[n].value || '').trim() || null;
    return { p_q: v('q'), p_status: v('status'), p_data_ini: v('data_ini'), p_data_fim: v('data_fim'),
             p_alerta: v('alerta'), p_ordem: f.ordem.value || 'recentes' };
  }

  async function carregarResumo() {
    const r = await rpc('resumo_livro');
    $('#k-total').textContent = r.total; $('#k-adm').textContent = r.pendente_adm;
    $('#k-setor').textContent = r.pendente_setor; $('#k-ok').textContent = r.concluido;
    $('#k-hoje').textContent = `${r.hoje} ${r.hoje === 1 ? 'registrado' : 'registrados'} hoje`;
    $('#k-venc').textContent = r.vencidos; const dias = Number(r.alerta_dias ?? 2);
    $('#k-crit').textContent = `${r.criticos} vencem em até ${dias} ${dias === 1 ? 'dia' : 'dias'}`;
    const opc = $('select[name="alerta"] option[value="criticos"]'); if (opc) opc.textContent = `Vence em até ${dias} ${dias === 1 ? 'dia' : 'dias'}`;
    $('#k-sla').textContent = r.sla_estourado;
    const fx = $('#faixa-alertas');
    fx.hidden = !(r.vencidos || r.sla_estourado) || estado.perfil.papel === 'portaria';
    fx.textContent = `⚠ Atenção: ${r.vencidos === 1 ? '1 demanda com prazo vencido' : `${r.vencidos} demandas com prazo vencido`} e ${r.sla_estourado === 1 ? '1 parada' : `${r.sla_estourado} paradas`} além do tempo máximo de recebimento.`;
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
      <tr data-id="${esc(x.id)}" tabindex="0" class="${x.semaforo === 'vencido' && x.status !== 'concluido' ? 'linha-vencida' : x.sla_estourado ? 'linha-sla' : ''}">
        <td class="num">${esc(x.numero)}</td>
        <td class="desc">${tipoHtml(x)}${esc(x.descricao)}${x.n_correcoes ? ' <span class="tag">corrigida</span>' : ''}${x.n_fotos ? ' <span class="tag">📷</span>' : ''}</td>
        <td class="onde">${ondeHtml(x)}</td>
        <td class="prazo">${prazoHtml(x)}</td>
        <td>${celulaEtapa(x.e1_em, x.e1_usuario)}</td>
        <td>${celulaEtapa(x.e2_em, x.e2_usuario)}</td>
        <td>${celulaEtapa(x.e3_em, x.e3_usuario, x.e3_setor)}</td>
      </tr>`).join('');
    $('#vazio').hidden = r.itens.length > 0;
    const paginas = Math.max(1, Math.ceil(r.total / estado.porPagina));
    $('#pg-info').textContent = `Página ${estado.pagina} de ${paginas}`;
    $('#pg-ant').disabled = estado.pagina <= 1; $('#pg-prox').disabled = estado.pagina >= paginas;
    $('#contagem').textContent = pl(r.total, 'registro', 'registros');
    const ff = $('#form-filtros');
    $$('.kpi').forEach((k) => k.classList.toggle('sel', k.dataset.alerta
      ? ff.alerta.value === k.dataset.alerta : (k.dataset.status === ff.status.value && ff.alerta.value === '' && ff.status.value !== '')));
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
    const podeAdm = ['adm', 'gestor'].includes(papel) && p.status === 'pendente_adm';
    const podeSetor = ['super_setor', 'gestor'].includes(papel) && p.status === 'pendente_setor';
    const podeCorrigir = ['portaria', 'adm', 'gestor'].includes(papel);
    const podePrazo = ['adm', 'gestor'].includes(papel) && p.status !== 'concluido';
    const linhas = etapasCompletas(p).map((e) => {
      if (!e.feito) return `<li class="pendente"><span class="no">${e.n}</span><div class="et-corpo">
        <div class="et-cab"><b>${esc(e.nome)}</b><span class="et-st aguarda">Aguardando</span></div>
        <p class="et-vazio">Ainda não recebido nesta etapa.</p></div></li>`;
      const png = pngSeguro(e.assinatura_png);
      const ass = png
        ? `<img class="ass-img" src="${png}" alt="Assinatura de ${esc(e.usuario)}"><span class="et-sub">${esc(ASSIN_ROTULO[e.assinatura_tipo] || 'Assinatura')}</span>`
        : '<span class="pin-ok">✔ Ciência confirmada por PIN</span><span class="et-sub">sem imagem de assinatura</span>';
      return `<li class="feito"><span class="no">${e.n}</span><div class="et-corpo">
        <div class="et-cab"><b>${esc(e.nome)}</b><span class="et-st">✔ Concluída</span></div>
        <dl class="et-meta">
          <div><dt>Data e hora</dt><dd>${data(e.recebido_em)} às ${hora(e.recebido_em, true)}</dd></div>
          <div><dt>Responsável</dt><dd>${esc(e.usuario)}</dd></div>
          ${e.setor ? `<div><dt>Setor final</dt><dd>${esc(e.setor)}</dd></div>` : ''}
          <div><dt>Selo de integridade</dt><dd><code title="${esc(String(e.selo))}">${esc(String(e.selo).slice(0, 16))}…</code></dd></div>
        </dl>
        <div class="et-ass"><span class="et-ass-rot">Assinatura</span><div class="et-ass-caixa">${ass}</div></div></div></li>`;
    }).join('');
    const hist = [];
    (p.correcoes || []).forEach((c) => hist.push({ em: c.corrigido_em, tit: 'Descrição corrigida', usr: c.usuario,
      txt: `de “${c.anterior}” para “${c.nova}”`, just: c.justificativa }));
    (p.prazos || []).forEach((h) => hist.push({ em: h.ajustado_em, tit: 'Prazo ajustado', usr: h.usuario,
      txt: `${h.anterior ? data(`${h.anterior}T12:00:00`) : 'sem prazo'} → ${data(`${h.novo}T12:00:00`)}`, just: h.justificativa }));
    hist.sort((x, y) => String(x.em).localeCompare(String(y.em)));
    const histHtml = hist.length ? `<section class="det-sec"><h3>Histórico de alterações</h3><ul class="hist">
      ${hist.map((h) => `<li><div class="hist-cab"><b>${esc(h.tit)}</b><span>${data(h.em)} ${hora(h.em)} · ${esc(h.usr)}</span></div>
        <div>${esc(h.txt)}</div><div class="hist-just">Justificativa: ${esc(h.just)}</div></li>`).join('')}</ul></section>` : '';
    const tipoTxt = `${p.tipo === 'judicial' ? 'Demanda judicial' : 'Correspondência'}${p.urgente ? ' · URGENTE' : ''}`;
    $('#detalhe-corpo').innerHTML = `
      <div class="det-topo"><div><span class="det-rot">Protocolo</span><h2>${esc(p.numero)}</h2>
        <div class="det-chips">${chip(p.status)}${p.urgente ? '<span class="chip urg">URGENTE</span>' : ''}</div></div>
        <button class="btn mini sec" type="button" data-fechar>Fechar ✕</button></div>
      <section class="det-sec"><h3>Documento</h3>
        <div class="resumo-doc"><span>${esc(p.descricao)}</span>
          ${p.n_correcoes ? `<div class="original">Descrição original: ${esc(p.descricao_original)}</div>` : ''}</div>
        <dl class="det-grade">
          <div><dt>Tipo</dt><dd>${esc(tipoTxt)}</dd></div>
          <div><dt>Prazo</dt><dd>${p.prazo_data ? `${data(`${p.prazo_data}T12:00:00`)} ${prazoHtml(p)}` : 'Sem prazo informado'}</dd></div>
          <div><dt>Onde está agora</dt><dd>${p.status === 'concluido' ? `Entregue (${esc(p.e3_setor || '')})` : ondeHtml(p)}</dd></div>
          <div><dt>Setor de destino</dt><dd>${esc(p.setor_destino_nome || (p.status === 'pendente_adm' ? 'Será definido pelo ADM' : '—'))}</dd></div>
          <div><dt>Registrado em</dt><dd>${data(p.created_at)} às ${hora(p.created_at, true)}</dd></div>
          <div><dt>Registrado por</dt><dd>${esc(p.e1_usuario || '—')}</dd></div>
        </dl></section>
      ${(p.fotos || []).length ? '<section class="det-sec"><h3>Foto do envelope ou da capa</h3><div id="det-fotos"></div></section>' : ''}
      <section class="det-sec"><h3>Tramitação</h3><ol class="linha-tempo">${linhas}</ol></section>
      ${histHtml}
      <div class="det-rodape">
        <div class="det-rodape-sec">
          ${podeCorrigir ? '<button class="btn sec" type="button" data-acao="corrigir">Corrigir descrição</button>' : ''}
          ${podePrazo ? '<button class="btn sec" type="button" data-acao="prazo">Ajustar prazo</button>' : ''}
          <button class="btn sec" type="button" data-acao="imprimir">Imprimir ficha / PDF</button>
          ${papel === 'gestor' ? '<button class="btn perigo" type="button" data-acao="excluir">Excluir protocolo</button>' : ''}
        </div>
        <div class="det-rodape-pri">
          ${podeAdm ? '<button class="btn primario" type="button" data-acao="adm">Confirmar recebimento — ADM</button>' : ''}
          ${podeSetor ? `<button class="btn primario" type="button" data-acao="setor">Confirmar recebimento — ${papel === 'gestor' ? esc(p.setor_destino_nome || 'Setor') : 'Setor'}</button>` : ''}
        </div>
      </div>`;
    carregarFotos(p);
  }

  // fotos: bucket privado, baixadas com o token do usuário e exibidas como blob (nunca há link público)
  async function baixarFoto(caminho) {
    const token = await garantirToken();
    const resp = await fetch(`${BASE}/storage/v1/object/authenticated/protocolo-fotos/${caminho.split('/').map(encodeURIComponent).join('/')}`,
      { headers: { apikey: KEY, Authorization: `Bearer ${token}` } });
    if (!resp.ok) throw new ErroApi('Não foi possível carregar a foto.', resp.status);
    return URL.createObjectURL(await resp.blob());
  }
  async function carregarFotos(p) {
    const alvo = $('#det-fotos'); if (!alvo || !(p.fotos || []).length) return;
    for (const f of p.fotos) {
      try {
        const url = await baixarFoto(f.caminho);
        if (estado.aberto !== p) { URL.revokeObjectURL(url); return; }
        const fig = document.createElement('figure'); fig.className = 'foto-fig';
        const img = document.createElement('img'); img.className = 'foto-det'; img.alt = 'Foto do envelope ou da capa'; img.src = url;
        img.title = 'Clique para ampliar'; img.addEventListener('click', () => window.open(url, '_blank', 'noopener'));
        const leg = document.createElement('figcaption'); leg.textContent = `Registrada na chegada, em ${data(f.enviado_em)} às ${hora(f.enviado_em)}. Clique para ampliar.`;
        fig.append(img, leg); alvo.appendChild(fig);
      } catch { alvo.textContent = 'Foto indisponível.'; }
    }
  }

  // ------------------------------------------------------------------ modais de ação
  function montarAssinaturas() {
    $$('[data-assinatura]').forEach((fs) => {
      assinaturas[fs.dataset.assinatura] = window.Assinatura.montar(fs, { obrigatoria: !!CFG.ASSINATURA_OBRIGATORIA });
    });
  }
  const prepararAssinatura = (chave) => assinaturas[chave].reiniciar(estado.perfil.nome);
  const assinaturaDe = (chave) => assinaturas[chave].obter();      // { png, modo } — lança Error se faltar

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
    limparFoto(); ajustarTipo();
    prepararAssinatura('novo'); $('#dlg-novo').showModal(); f.descricao.focus();
  }
  const fotoObrigatoria = () => $('#form-novo').tipo.value === 'judicial';
  function ajustarTipo() {
    const f = $('#form-novo'), jud = f.tipo.value === 'judicial';
    $('#lbl-urgente').hidden = !jud; if (!jud) f.urgente.checked = false;
    $('#foto-obrig').textContent = jud ? '(obrigatória para demanda judicial)' : '(opcional)';
    $('#dica-tipo').textContent = jud
      ? 'Demanda judicial: o prazo padrão é aplicado automaticamente e o ADM é avisado na hora. O ADM pode ajustar o prazo real depois.'
      : 'Correspondência comum: sem prazo. O ADM é avisado da chegada.';
  }
  function limparFoto() {
    if (estado.fotoUrl) URL.revokeObjectURL(estado.fotoUrl);
    estado.fotoBlob = null; estado.fotoUrl = null;
    const im = $('#foto-previa'); im.hidden = true; im.removeAttribute('src'); $('#btn-foto-remover').hidden = true;
    ['#inp-foto', '#inp-foto-camera'].forEach((q) => { const i = $(q); if (i) i.value = ''; });
  }
  // reduz a foto no navegador (máx. 1600 px, JPEG) — o banco aceita até 1,5 MB e só image/jpeg
  async function prepararFoto(arquivo) {
    if (!arquivo.type.startsWith('image/')) throw new Error('Escolha um arquivo de imagem.');
    const bmp = await createImageBitmap(arquivo);
    const esc1 = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * esc1); c.height = Math.round(bmp.height * esc1);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    for (const q of [0.8, 0.65, 0.5, 0.35]) {
      const blob = await new Promise((ok) => c.toBlob(ok, 'image/jpeg', q));
      if (blob && blob.size <= 1500000) return blob;
    }
    throw new Error('A foto ficou grande demais. Aproxime-se do documento e tente novamente.');
  }
  async function enviarFoto(blob) {
    const token = await garantirToken();
    const caminho = `${estado.sessao.uid}/${crypto.randomUUID()}.jpg`;
    const resp = await fetch(`${BASE}/storage/v1/object/protocolo-fotos/${caminho}`, { method: 'POST',
      headers: { apikey: KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'image/jpeg', 'x-upsert': 'false' }, body: blob });
    if (!resp.ok) throw new ErroApi('Não foi possível enviar a foto. Verifique a conexão e tente novamente.', resp.status);
    return caminho;
  }

  // ------------------------------------------------------------------ setores (destino do ADM)
  async function carregarSetores() {
    if (!estado.setores) estado.setores = await rest('setores?select=id,nome&ativo=eq.true&order=nome');
    return estado.setores;
  }

  function abrirConfirmar(etapa) {
    const p = estado.aberto, f = $('#form-confirmar');
    f.reset(); erroForm(f, ''); f.dataset.etapa = String(etapa); f.dataset.id = String(p.id);
    $('#conf-titulo').textContent = etapa === 2 ? '2º recebimento — Administração (ADM)' : '3º recebimento — Setor de destino';
    $('#conf-numero').textContent = p.numero; $('#conf-desc').textContent = p.descricao;
    const info = $('#conf-setor-info'); info.hidden = etapa !== 3;
    if (etapa === 3) {
      info.textContent = estado.perfil.papel === 'gestor'
        ? `Você está confirmando em nome do setor de destino: ${p.setor_destino_nome || '—'} (acesso total do gestor; fica registrado na trilha).`
        : `Setor final de destino: ${estado.perfil.setor} (definido pelo seu perfil).`;
    }
    const lbl = $('#lbl-destino'); lbl.hidden = etapa !== 2;
    if (etapa === 2) {
      carregarSetores().then((l) => {
        f.destino.innerHTML = '<option value="">Selecione o setor…</option>' + l.map((x) => `<option value="${esc(x.id)}">${esc(x.nome)}</option>`).join('');
      }).catch((e) => erroForm(f, e.message));
    }
    prepararAssinatura('conf'); $('#dlg-confirmar').showModal(); f.pin.focus();
  }

  function abrirPrazo() {
    const p = estado.aberto, f = $('#form-prazo');
    f.reset(); erroForm(f, ''); f.dataset.id = String(p.id);
    $('#prazo-numero').textContent = p.numero;
    $('#prazo-atual').textContent = p.prazo_data ? `Prazo atual: ${data(p.prazo_data + 'T12:00:00')}` : 'Sem prazo definido.';
    if (p.prazo_data) f.data.value = p.prazo_data;
    $('#dlg-prazo').showModal(); f.data.focus();
  }

  function abrirCorrecao() {
    const p = estado.aberto, f = $('#form-correcao');
    f.reset(); erroForm(f, ''); f.dataset.id = String(p.id);
    $('#corr-numero').textContent = p.numero; $('#corr-atual').textContent = p.descricao;
    f.descricao_nova.value = p.descricao; $('#dlg-correcao').showModal(); f.descricao_nova.focus();
  }


  // ------------------------------------------------------------------ exclusão de protocolo (gestor)
  function abrirExclusao() {
    const p = estado.aberto, f = $('#form-excluir');
    f.reset(); erroForm(f, ''); f.dataset.id = String(p.id); $('#exc-numero').textContent = p.numero;
    $('#dlg-excluir').showModal(); f.justificativa.focus();
  }
  async function apagarFotosDoBucket(caminhos) {
    let falhas = 0; const token = await garantirToken();
    for (const c of caminhos) {
      try {
        const r = await fetch(`${BASE}/storage/v1/object/protocolo-fotos/${c.split('/').map(encodeURIComponent).join('/')}`,
          { method: 'DELETE', headers: { apikey: KEY, Authorization: `Bearer ${token}` } });
        if (!r.ok && r.status !== 404) falhas += 1;
      } catch { falhas += 1; }
    }
    return falhas;
  }

  // ------------------------------------------------------------------ logo do sistema (cabeçalho, login, impressões, aba do navegador)
  const LOGO_OK = /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/;
  function aplicarLogo(src) {
    const ok = typeof src === 'string' && (LOGO_OK.test(src) || src === 'assets/logo.png');
    estado.logo = ok; estado.logoSrc = ok ? src : null;
    $$('img.logo').forEach((i) => { if (ok) { i.src = src; i.hidden = false; } else { i.hidden = true; i.removeAttribute('src'); } });
    const fav = $('link[rel=icon]'); if (fav) fav.href = ok ? src : 'data:,';
  }
  const LOGO_CACHE = 'protocolo.logo';
  async function carregarIdentidade() {
    try { const c = sessionStorage.getItem(LOGO_CACHE); if (c && LOGO_OK.test(c)) aplicarLogo(c); } catch { /* sem cache */ }
    try {
      const resp = await fetch(`${BASE}/rest/v1/rpc/identidade_publica`, { method: 'POST',
        headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }, body: '{}' });
      if (resp.ok) { const j = await resp.json(); if (j && j.logo) { aplicarLogo(j.logo); try { sessionStorage.setItem(LOGO_CACHE, j.logo); } catch { /* cheio */ } return; }
        try { sessionStorage.removeItem(LOGO_CACHE); } catch { /* ok */ } }
    } catch { /* segue para o arquivo opcional */ }
    const img = new Image();                              // alternativa: web/assets/logo.png (se existir)
    img.onload = () => aplicarLogo('assets/logo.png');
    img.src = 'assets/logo.png';
  }

  // ------------------------------------------------------------------ IMPRESSÃO (livro e ficha)
  function cabecalhoImpressao(subtitulo) {
    const marca = estado.logoSrc ? `<img src="${estado.logoSrc}" alt="">` : '<span class="p-cruz">+</span>';
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
      const cab = ['Nº', '1º Recebimento<br>Portaria<br>Data', 'Hora', 'DESCRIÇÃO DO DOCUMENTO', 'Assinatura<br>— Portaria',
        '2º Recebimento<br>ADM<br>Data', 'Hora', 'Assinatura<br>ADM', '3º Recebimento<br>Setor de destino<br>Data', 'Hora', 'Assinatura<br>Setor de destino'];
      const linhas = r.itens.map((x) => `<tr>
        <td><b>${esc(x.numero)}</b></td><td>${data(x.e1_em)}</td><td>${hora(x.e1_em)}</td>
        <td class="d">${x.tipo === 'judicial' ? '<b>[JUDICIAL' + (x.urgente ? ' URGENTE' : '') + ']</b> ' : ''}${esc(x.descricao)}${x.n_correcoes ? ' <i>(descrição corrigida)</i>' : ''}${x.prazo_data ? `<br><small>Prazo: ${data(x.prazo_data + 'T12:00:00')}</small>` : ''}</td>
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

  const e3Setor = (p) => ((p.etapas || []).find((e) => e.etapa === 3) || {}).setor;

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
          <tr><th>Situação</th><td>${esc(STATUS[p.status])}${p.status !== 'concluido' ? ` — ${esc(p.status === 'pendente_adm' ? 'aguardando o ADM' : 'aguardando ' + (p.setor_destino_nome || 'o setor'))}` : ''}</td></tr>
          <tr><th>Tipo / prazo</th><td>${p.tipo === 'judicial' ? 'Demanda judicial' : 'Correspondência'}${p.urgente ? ' (URGENTE)' : ''} · Prazo: ${p.prazo_data ? data(p.prazo_data + 'T12:00:00') : 'sem prazo informado'}</td></tr>
          <tr><th>Setor de destino</th><td>${esc(p.setor_destino_nome || e3Setor(p) || '—')}</td></tr>
          <tr><th>Descrição do documento</th><td>${esc(p.descricao)}</td></tr></tbody></table>
        <div class="p-sec">Tramitação (3 etapas)</div>
        <table class="p-ficha-tab p-etapas"><thead><tr><th class="n">Etapa</th><th>Data</th><th>Hora</th><th>Responsável</th><th>Assinatura</th></tr></thead>
          <tbody>${linhas}</tbody></table>${corr}
        <div class="p-sec">Selos de integridade (SHA-256)</div>${selos}
        <p class="p-meta">Registrado em ${data(p.created_at)} às ${hora(p.created_at, true)} (hora do servidor). Datas, horas e responsáveis são gerados pelo
          sistema e não podem ser editados. Emitido por ${esc(estado.perfil.nome)} em ${data(agora)} ${hora(agora)}.</p>${rodapeImpressao()}`);
    } catch (e) { toast(e.message, true); }
  }

  // ------------------------------------------------------------------ conta: troca de senha / primeiro acesso
  function abrirConta(obrigatoria) {
    const f = $('#form-conta'), p = estado.perfil;
    estado.contaObrigatoria = obrigatoria; f.reset(); erroForm(f, '');
    const senha = !obrigatoria || p.deveTrocarSenha, pin = obrigatoria && p.deveTrocarPin;
    $('#conta-bloco-senha').hidden = !senha; $('#conta-bloco-pin').hidden = !pin;
    $('#conta-titulo').textContent = obrigatoria ? 'Primeiro acesso: defina suas credenciais' : 'Alterar minha senha';
    $('#conta-info').textContent = obrigatoria
      ? 'O gestor lhe entregou uma senha e um PIN provisórios. Por segurança, escolha agora os seus próprios.' : 'Escolha uma nova senha de acesso.';
    $('#conta-cancelar').hidden = obrigatoria;
    $('#dlg-conta').showModal();
  }
  async function enviarConta(ev) {
    ev.preventDefault();
    const f = ev.target, p = estado.perfil, obrigatoria = estado.contaObrigatoria;
    const querSenha = !$('#conta-bloco-senha').hidden, querPin = !$('#conta-bloco-pin').hidden;
    if (querSenha) {
      if (f.senha.value !== f.senha2.value) { erroForm(f, 'As senhas não conferem.'); return; }
      if (f.senha.value.length < 10 || !/[A-Za-z]/.test(f.senha.value) || !/\d/.test(f.senha.value)) { erroForm(f, 'A senha deve ter 10 caracteres ou mais, com letras e números.'); return; }
    }
    if (querPin) {
      if (!/^\d{4,6}$/.test(f.pin_novo.value)) { erroForm(f, 'O novo PIN deve ter de 4 a 6 dígitos numéricos.'); return; }
      if (f.pin_novo.value !== f.pin_novo2.value) { erroForm(f, 'Os PINs não conferem.'); return; }
    }
    await enviar(f, async () => {
      if (querSenha) {
        const token = await garantirToken();
        const resp = await fetch(`${BASE}/auth/v1/user`, { method: 'PUT', headers: { apikey: KEY, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ password: f.senha.value }) });
        if (!resp.ok) {
          const j = await resp.json().catch(() => ({}));
          throw new Error(/same|diferente/i.test(j.msg || j.message || '') ? 'A nova senha deve ser diferente da atual.' : (j.msg || j.message || 'Não foi possível alterar a senha.'));
        }
        await rpc('confirmar_troca_senha'); p.deveTrocarSenha = false;
        $('#conta-bloco-senha').hidden = true;                   // se o PIN falhar, só ele é pedido de novo
      }
      if (querPin) {
        const r = await rpc('alterar_meu_pin', { p_atual: f.pin_atual.value, p_novo: f.pin_novo.value });
        if (r && r.ok === false) throw new Error(r.erro || 'PIN provisório incorreto.');
        p.deveTrocarPin = false;
      }
      return { ok: true };
    }, async () => {
      estado.contaObrigatoria = false; $('#dlg-conta').close();
      toast(obrigatoria ? 'Credenciais definidas. Bem-vindo(a)!' : 'Senha alterada com sucesso.');
    });
  }

  // ------------------------------------------------------------------ alertas (sino, som, aviso do navegador)
  // Importante: só funcionam com o sistema aberto no navegador. Fora dele, valem os e-mails.
  let audioCtx = null;
  function iniciarAudio() { try { audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)(); if (audioCtx.state === 'suspended') audioCtx.resume(); } catch { /* sem áudio */ } }
  function bipe() {
    if (!audioCtx || !$('#chk-som').checked) return;
    [0, 0.25, 0.5].forEach((t) => {
      const o = audioCtx.createOscillator(), g = audioCtx.createGain();
      o.type = 'sine'; o.frequency.value = t === 0.5 ? 1175 : 880; g.gain.value = 0.15;
      o.connect(g); g.connect(audioCtx.destination); o.start(audioCtx.currentTime + t); o.stop(audioCtx.currentTime + t + 0.18);
    });
  }
  const TXT_SINO = { adm: 'aguardando o seu recebimento', super_setor: 'encaminhado ao seu setor', gestor: 'em atraso' };

  async function verificarAlertas(avisar) {
    if (!estado.perfil || estado.perfil.papel === 'portaria') return;
    let r; try { r = await rpc('minhas_pendencias'); } catch { return; }
    const itens = r.itens || [];
    const n = $('#sino-n'); n.textContent = itens.length; n.hidden = itens.length === 0;
    document.title = `${itens.length ? `(${itens.length}) ` : ''}Livro de Protocolo · ${CFG.UNIDADE}`;
    $('#vazio-sino').hidden = itens.length > 0;
    $('#lista-sino').innerHTML = itens.map((x) => `<li data-id="${esc(x.id)}" class="${x.sla_estourado || x.semaforo === 'vencido' ? 'alerta' : ''}">
      <strong>${esc(x.numero)}</strong> ${tipoHtml(x)} ${esc(TXT_SINO[r.papel] || '')}
      <small>${x.aguardando_desde ? esc(ha(x.aguardando_desde)) : ''}${x.prazo_data ? ` · prazo ${data(x.prazo_data + 'T12:00:00')} (${esc(diasTxt(x))})` : ''}${x.sla_estourado ? ' · ⚠ além do tempo' : ''}</small></li>`).join('');
    const ids = new Set(itens.map((x) => `${x.id}:${x.status}`));
    if (avisar && estado.alertasVistos) {
      const novos = itens.filter((x) => !estado.alertasVistos.has(`${x.id}:${x.status}`));
      if (novos.length) {
        bipe(); $('#btn-sino').classList.add('toca'); setTimeout(() => $('#btn-sino').classList.remove('toca'), 2000);
        const txt = novos.length === 1 ? `Protocolo ${novos[0].numero}${novos[0].urgente ? ' URGENTE' : ''} ${TXT_SINO[r.papel] || 'precisa de atenção'}.`
          : `${novos.length} protocolos novos precisam da sua atenção.`;
        toast(`🔔 ${txt}`);
        try { if ('Notification' in window && Notification.permission === 'granted' && document.hidden) new Notification('Livro de Protocolo', { body: txt, tag: 'protocolo' }); } catch { /* ignora */ }
      }
    }
    estado.alertasVistos = ids;
  }

  // ------------------------------------------------------------------ eventos
  function ligarEventos() {
    // login
    // freio de tentativas no próprio navegador (o Supabase também limita no servidor): 5 erros → espera de 60 s
    const freio = { erros: 0, ate: 0 };
    $('#form-login').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const f = ev.target, btn = $('button[type=submit]', f), erro = $('#login-erro');
      const espera = Math.ceil((freio.ate - Date.now()) / 1000);
      if (espera > 0) { erro.textContent = `Muitas tentativas. Aguarde ${espera} s e tente novamente.`; erro.hidden = false; return; }
      btn.disabled = true; erro.hidden = true;
      try {
        await tokenGrant('password', { email: f.email.value.trim(), password: f.senha.value });
        freio.erros = 0;
        f.reset();
        await iniciarApp(true);
      } catch (e) {
        if (estado.sessao) salvarSessao(null);
        freio.erros += 1; if (freio.erros >= 5) { freio.erros = 0; freio.ate = Date.now() + 60000; }
        erro.textContent = e.message; erro.hidden = false; f.senha.value = '';
      } finally { btn.disabled = false; }
    });
    $('#btn-sair').addEventListener('click', () => sair('LOGOUT'));

    $('#abas').addEventListener('click', (ev) => { const b = ev.target.closest('.aba'); if (b) trocarAba(b.dataset.aba); });

    // busca instantânea + filtros
    const f = $('#form-filtros');
    let t;
    const aplicar = () => { estado.pagina = 1; salvarFiltros(); recarregar(); };
    f.addEventListener('submit', (ev) => ev.preventDefault());
    f.q.addEventListener('input', () => { clearTimeout(t); t = setTimeout(aplicar, 300); });
    ['status', 'alerta', 'ordem', 'data_ini', 'data_fim'].forEach((n) => f[n].addEventListener('change', aplicar));
    $('#btn-limpar').addEventListener('click', () => { f.reset(); aplicar(); });
    $('#kpis').addEventListener('click', (ev) => { const k = ev.target.closest('.kpi');
      if (k) { f.status.value = k.dataset.status || ''; f.alerta.value = k.dataset.alerta || ''; aplicar(); } });
    $('#pg-ant').addEventListener('click', () => { estado.pagina -= 1; carregarTabela().catch((e) => toast(e.message, true)); });
    $('#pg-prox').addEventListener('click', () => { estado.pagina += 1; carregarTabela().catch((e) => toast(e.message, true)); });

    const abrirLinha = (ev) => { const tr = ev.target.closest('tr[data-id]'); if (tr) abrirDetalhe(tr.dataset.id); };
    $('#tbody').addEventListener('click', abrirLinha);
    $('#tbody').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') abrirLinha(ev); });

    $('#detalhe-corpo').addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-acao]'); if (!b) return;
      ({ imprimir: imprimirFicha, corrigir: abrirCorrecao, prazo: abrirPrazo, excluir: abrirExclusao, adm: () => abrirConfirmar(2), setor: () => abrirConfirmar(3) })[b.dataset.acao]();
    });
    document.addEventListener('click', (ev) => {
      if (ev.target.closest('[data-fechar]')) ev.target.closest('dialog').close();
    });
    $$('dialog').forEach((d) => d.addEventListener('close', () => { $$('form', d).forEach((x) => x.reset()); }));

    $('#btn-imprimir-livro').addEventListener('click', imprimirLivro);
    $('#btn-novo').addEventListener('click', abrirNovo);
    $('#form-novo').tipo.addEventListener('change', ajustarTipo);
    const usarFoto = async (arq, entrada) => {
      const form = $('#form-novo');
      estado.fotoBlob = null; $('#foto-previa').hidden = true; $('#btn-foto-remover').hidden = true; if (!arq) return;
      try {
        erroForm(form, ''); const blob = await prepararFoto(arq);
        if (estado.fotoUrl) URL.revokeObjectURL(estado.fotoUrl);
        estado.fotoBlob = blob; estado.fotoUrl = URL.createObjectURL(blob);
        const im = $('#foto-previa'); im.src = estado.fotoUrl; im.hidden = false; $('#btn-foto-remover').hidden = false;
      } catch (e) { erroForm(form, e.message); }
      if (entrada) entrada.value = '';
    };
    $('#inp-foto').addEventListener('change', (ev) => usarFoto(ev.target.files[0], ev.target));
    $('#inp-foto-camera').addEventListener('change', (ev) => usarFoto(ev.target.files[0], ev.target));
    $('#btn-foto-arquivo').addEventListener('click', () => $('#inp-foto').click());
    $('#btn-foto-remover').addEventListener('click', limparFoto);
    // "Tirar foto": no celular abre a câmera do aparelho; no computador abre a webcam numa janela
    let fluxo = null;
    const pararCamera = () => { if (fluxo) fluxo.getTracks().forEach((t) => t.stop()); fluxo = null; $('#cam-video').srcObject = null; };
    $('#btn-foto-camera').addEventListener('click', async () => {
      const toque = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
      if (toque || !(navigator.mediaDevices && navigator.mediaDevices.getUserMedia)) { $('#inp-foto-camera').click(); return; }
      const dlg = $('#dlg-camera'), er = $('#cam-erro'); er.hidden = true; $('#btn-capturar').disabled = true;
      dlg.showModal();
      try {
        fluxo = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 } }, audio: false });
        const v = $('#cam-video'); v.srcObject = fluxo; await v.play().catch(() => {});
        $('#btn-capturar').disabled = false;
      } catch {
        dlg.close(); toast('Não foi possível usar a câmera. Escolha uma foto do aparelho.', true); $('#inp-foto-camera').click();
      }
    });
    $('#btn-capturar').addEventListener('click', async () => {
      const v = $('#cam-video'); if (!v.videoWidth) return;
      const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
      c.getContext('2d').drawImage(v, 0, 0);
      const blob = await new Promise((ok) => c.toBlob(ok, 'image/jpeg', 0.92));
      $('#dlg-camera').close();
      if (blob) await usarFoto(blob, null);
    });
    $('#dlg-camera').addEventListener('close', pararCamera);
    $('#form-novo').descricao.addEventListener('input', (ev) => { $('#cont-desc').textContent = ev.target.value.length; });

    $('#form-novo').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      let ass; try { ass = assinaturaDe('novo'); } catch (e) { erroForm(form, e.message); return; }
      if (fotoObrigatoria() && !estado.fotoBlob) { erroForm(form, 'Demandas judiciais exigem a foto do envelope ou da capa.'); return; }
      enviar(form, async () => {
        const caminho = estado.fotoBlob ? await enviarFoto(estado.fotoBlob) : null;
        return rpc('registrar_protocolo', { p_descricao: form.descricao.value, p_pin: form.pin.value, p_assinatura: ass.png, p_assinatura_modo: ass.modo,
          p_tipo: form.tipo.value, p_urgente: form.urgente.checked, p_foto_caminho: caminho });
      }, async (r) => {
        $('#dlg-novo').close(); limparFoto();
        toast(`Protocolo ${r.numero} registrado — o ADM foi avisado.`); estado.pagina = 1; await recarregar();
      });
    });


    $('#form-excluir').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      enviar(form, () => rpc('excluir_protocolo', { p_protocolo_id: Number(form.dataset.id), p_justificativa: form.justificativa.value,
          p_pin_gestor: form.pin.value, p_excluir_trilha: form.trilha.checked }),
        async (r) => {
          const falhas = await apagarFotosDoBucket(r.fotos || []);
          $('#dlg-excluir').close(); $('#dlg-detalhe').close(); estado.aberto = null;
          toast(`Protocolo ${r.numero} excluído.${falhas ? ' A foto não pôde ser removida do armazenamento: remova-a no painel do Supabase.' : ''}`, !!falhas);
          await recarregar();
        });
    });

    $('#form-confirmar').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target, etapa = Number(form.dataset.etapa);
      let ass; try { ass = assinaturaDe('conf'); } catch (e) { erroForm(form, e.message); return; }
      if (etapa === 2 && !form.destino.value) { erroForm(form, 'Selecione o setor de destino.'); return; }
      enviar(form, () => rpc('confirmar_etapa', { p_protocolo_id: Number(form.dataset.id), p_etapa: etapa, p_pin: form.pin.value, p_assinatura: ass.png,
        p_assinatura_modo: ass.modo, p_setor_destino_id: etapa === 2 ? Number(form.destino.value) : null }), async (r) => {
        $('#dlg-confirmar').close();
        toast(etapa === 2 ? `${r.numero}: recebimento do ADM registrado e setor de destino avisado.` : `${r.numero}: entrega concluída no setor.`);
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

    $('#form-prazo').addEventListener('submit', (ev) => {
      ev.preventDefault(); const form = ev.target;
      enviar(form, () => rpc('ajustar_prazo', { p_protocolo_id: Number(form.dataset.id), p_nova_data: form.data.value,
        p_justificativa: form.justificativa.value, p_pin: form.pin.value }), async () => {
        $('#dlg-prazo').close(); toast('Prazo ajustado e registrado no histórico.');
        await abrirDetalhe(form.dataset.id); await recarregar(); await verificarAlertas(false);
      });
    });

    // sino de pendências
    $('#btn-sino').addEventListener('click', () => {
      const p = $('#painel-sino'); p.hidden = !p.hidden; $('#btn-sino').setAttribute('aria-expanded', String(!p.hidden)); iniciarAudio();
    });
    document.addEventListener('click', (ev) => { if (!ev.target.closest('.sino-wrap')) $('#painel-sino').hidden = true; });
    $('#lista-sino').addEventListener('click', (ev) => {
      const li = ev.target.closest('li[data-id]'); if (li) { $('#painel-sino').hidden = true; abrirDetalhe(li.dataset.id); }
    });
    $('#btn-notif').addEventListener('click', async () => {
      if (!('Notification' in window)) { toast('Este navegador não oferece avisos do sistema.', true); return; }
      const r = await Notification.requestPermission();
      toast(r === 'granted' ? 'Avisos ativados enquanto o sistema estiver aberto.' : 'Avisos não autorizados no navegador.', r !== 'granted');
    });
    document.addEventListener('pointerdown', iniciarAudio, { once: true });

    $('#btn-senha').addEventListener('click', () => abrirConta(false));
    $('#dlg-conta').addEventListener('cancel', (ev) => { if (estado.contaObrigatoria) ev.preventDefault(); });   // Esc não pula o primeiro acesso
    $('#form-conta').addEventListener('submit', enviarConta);
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
      verificarAlertas(true);
      if (estado.aba === 'protocolos' && !$('dialog[open]') && !document.hidden) recarregar();
    }, 30000);
  }

  // ------------------------------------------------------------------ inicialização
  async function iniciar() {
    $$('[data-unidade]').forEach((e) => { e.textContent = `Unidade/Instituição: ${CFG.UNIDADE}`; });
    if (!CONFIG_OK) { mostrar('config'); return; }
    montarAssinaturas();
    painelMod = window.criarPainel(Object.freeze({
      $, $$, esc, data, hora, rpc, toast, erroForm, enviar, abrirDetalhe, imprimir, cabecalhoImpressao, rodapeImpressao,
      estado: () => estado, aplicarLogo, limparSetores: () => { estado.setores = null; },
      enderecoSistema: () => (CFG.URL_SISTEMA || `${location.origin}${location.pathname.replace(/[^/]*$/, '')}`),
    }));
    ligarEventos(); painelMod.ligar();
    carregarIdentidade();
    const s = lerSessao();
    if (s) {
      estado.sessao = s;
      try { await iniciarApp(false); return; } catch { salvarSessao(null); }
    }
    mostrar('login');
  }
  iniciar();
})();
