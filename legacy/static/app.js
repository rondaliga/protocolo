/* Livro de Protocolo Eletrônico — frontend (JavaScript puro, sem dependências).
 *
 * Observações de segurança:
 *  - todo texto vindo do servidor passa por esc() antes de entrar no HTML;
 *  - o token CSRF é enviado no cabeçalho X-CSRF-Token em toda requisição que altera dados;
 *  - data e horário NUNCA são enviados pelo cliente (o servidor é a fonte única).
 */
(() => {
  'use strict';

  // ---------------------------------------------------------------- utilidades
  const $ = (sel, raiz = document) => raiz.querySelector(sel);
  const $$ = (sel, raiz = document) => [...raiz.querySelectorAll(sel)];
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmtData = (iso) => (iso ? `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}` : '');
  const fmtHora = (iso, seg = false) => (iso ? iso.slice(11, seg ? 19 : 16) : '');

  const ROTULO_STATUS = {
    PENDENTE_ADM: 'Pendente ADM',
    PENDENTE_SETOR: 'Pendente Setor Final',
    CONCLUIDO: 'Concluído / Entregue',
  };
  const ROTULO_PERFIL = { PORTARIA: 'Portaria', ADM: 'Administração (ADM)', SETOR: 'Setor', GESTOR: 'Gestão / Auditoria' };

  const estado = { me: null, csrf: null, config: {}, pagina: 1, porPagina: 25, total: 0, aberto: null, abaAtual: 'protocolos' };

  // ---------------------------------------------------------------- API
  async function api(caminho, { metodo = 'GET', corpo } = {}) {
    const opts = { method: metodo, headers: { Accept: 'application/json' }, credentials: 'same-origin' };
    if (corpo !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(corpo);
    }
    if (metodo !== 'GET') opts.headers['X-CSRF-Token'] = estado.csrf || '';
    const resp = await fetch(caminho, opts);
    let dados = null;
    try { dados = await resp.json(); } catch { /* resposta sem corpo JSON */ }
    if (resp.status === 401 && caminho !== '/api/login') {
      mostrarLogin();
      throw new Error((dados && dados.erro) || 'Sessão expirada. Entre novamente.');
    }
    if (!resp.ok) throw new Error((dados && dados.erro) || `Erro ${resp.status}`);
    return dados;
  }

  let toastTimer;
  function toast(msg, erro = false) {
    const t = $('#toast');
    t.textContent = msg;
    t.className = erro ? 'erro' : '';
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, 4500);
  }

  function mostrarErro(form, msg) {
    const p = $('.erro', form);
    p.textContent = msg;
    p.hidden = !msg;
  }

  // ---------------------------------------------------------------- quadro de assinatura (canvas)
  class AssinaturaPad {
    constructor(canvas) {
      this.c = canvas;
      this.ctx = canvas.getContext('2d');
      this.ctx.lineWidth = 2.4;
      this.ctx.lineCap = 'round';
      this.ctx.lineJoin = 'round';
      this.ctx.strokeStyle = '#111';
      this.vazio = true;
      this.desenhando = false;
      canvas.addEventListener('pointerdown', (e) => this.inicio(e));
      canvas.addEventListener('pointermove', (e) => this.mover(e));
      ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) => canvas.addEventListener(ev, () => { this.desenhando = false; }));
    }
    pos(e) {
      const r = this.c.getBoundingClientRect();
      return { x: ((e.clientX - r.left) * this.c.width) / r.width, y: ((e.clientY - r.top) * this.c.height) / r.height };
    }
    inicio(e) {
      e.preventDefault();
      this.c.setPointerCapture(e.pointerId);
      this.desenhando = true;
      const p = this.pos(e);
      this.ctx.beginPath();
      this.ctx.moveTo(p.x, p.y);
      this.ctx.lineTo(p.x + 0.1, p.y + 0.1);
      this.ctx.stroke();
      this.vazio = false;
    }
    mover(e) {
      if (!this.desenhando) return;
      e.preventDefault();
      const p = this.pos(e);
      this.ctx.lineTo(p.x, p.y);
      this.ctx.stroke();
    }
    limpar() { this.ctx.clearRect(0, 0, this.c.width, this.c.height); this.vazio = true; }
    dataURL() { return this.vazio ? null : this.c.toDataURL('image/png'); }
  }
  const pads = {};

  // ---------------------------------------------------------------- telas
  function mostrarLogin() {
    estado.me = null;
    estado.csrf = null;
    $$('dialog[open]').forEach((d) => d.close());
    $('#view-app').hidden = true;
    $('#view-login').hidden = false;
    $('#form-login').reset();
  }

  function mostrarApp() {
    const { me } = estado;
    $('#view-login').hidden = true;
    $('#view-app').hidden = false;
    $('#usr-nome').textContent = me.nome;
    $('#usr-perfil').textContent = ROTULO_PERFIL[me.perfil] + (me.setor_nome ? ` · ${me.setor_nome}` : '');
    $('#btn-novo').hidden = me.perfil !== 'PORTARIA';
    $('#btn-aba-auditoria').hidden = me.perfil !== 'GESTOR';
    $$('.eu').forEach((el) => { el.textContent = me.nome; });
    trocarAba('protocolos');
    carregarTudo();
  }

  function trocarAba(nome) {
    estado.abaAtual = nome;
    $$('.aba').forEach((b) => b.classList.toggle('ativa', b.dataset.aba === nome));
    $('#painel-protocolos').hidden = nome !== 'protocolos';
    $('#painel-auditoria').hidden = nome !== 'auditoria';
    if (nome === 'auditoria') carregarAuditoria();
  }

  // ---------------------------------------------------------------- dashboard + tabela
  const chip = (status) => `<span class="chip ${esc(status)}">${esc(ROTULO_STATUS[status] || status)}</span>`;

  function celulaEtapa(em, usuario, setor) {
    if (!em) return '<div class="et pend">—</div>';
    return `<div class="et"><strong>${fmtData(em)} ${fmtHora(em)}</strong>`
      + `<span>${esc(usuario)}${setor ? ` · ${esc(setor)}` : ''}</span></div>`;
  }

  async function carregarResumo() {
    const r = await api('/api/resumo');
    $('#c-total').textContent = r.total;
    $('#c-adm').textContent = r.pendente_adm;
    $('#c-setor').textContent = r.pendente_setor;
    $('#c-ok').textContent = r.concluido;
    $('#c-hoje').textContent = `${r.hoje} registrado(s) hoje`;
  }

  function paramsFiltro() {
    const p = new URLSearchParams();
    new FormData($('#form-filtros')).forEach((v, k) => { if (String(v).trim()) p.set(k, String(v).trim()); });
    return p;
  }

  async function carregarTabela() {
    const p = paramsFiltro();
    p.set('pagina', estado.pagina);
    p.set('por_pagina', estado.porPagina);
    const r = await api(`/api/protocolos?${p}`);
    estado.total = r.total;
    $('#tbody').innerHTML = r.itens.map((x) => `
      <tr data-id="${x.id}" tabindex="0">
        <td class="num">${esc(x.numero)}</td>
        <td class="desc">${esc(x.descricao)}${x.n_correcoes ? ' <span class="tag">corrigida</span>' : ''}</td>
        <td>${chip(x.status)}</td>
        <td>${celulaEtapa(x.e1_em, x.e1_usuario)}</td>
        <td>${celulaEtapa(x.e2_em, x.e2_usuario)}</td>
        <td>${celulaEtapa(x.e3_em, x.e3_usuario, x.e3_setor)}</td>
      </tr>`).join('');
    $('#vazio').hidden = r.itens.length > 0;
    const paginas = Math.max(1, Math.ceil(r.total / r.por_pagina));
    $('#pg-info').textContent = `Página ${r.pagina} de ${paginas}`;
    $('#pg-ant').disabled = r.pagina <= 1;
    $('#pg-prox').disabled = r.pagina >= paginas;
    $('#contagem').textContent = `${r.total} registro(s)`;
  }

  async function carregarTudo() {
    try { await Promise.all([carregarResumo(), carregarTabela()]); } catch (e) { toast(e.message, true); }
  }

  // ---------------------------------------------------------------- detalhe / tramitação
  async function abrirDetalhe(id) {
    try {
      const p = await api(`/api/protocolos/${id}`);
      estado.aberto = p;
      renderDetalhe(p);
      const dlg = $('#dlg-detalhe');
      if (!dlg.open) dlg.showModal();
    } catch (e) { toast(e.message, true); }
  }

  function renderDetalhe(p) {
    const perfil = estado.me.perfil;
    const podeAdm = perfil === 'ADM' && p.status === 'PENDENTE_ADM';
    const podeSetor = perfil === 'SETOR' && p.status === 'PENDENTE_SETOR';
    const podeCorrigir = ['PORTARIA', 'ADM', 'GESTOR'].includes(perfil);

    const etapas = p.etapas.map((e) => {
      if (!e.registrada) {
        return `<li class="pendente"><div><b>${esc(e.nome)}</b><small>Aguardando recebimento</small></div><div></div></li>`;
      }
      const ass = e.tem_png
        ? `<img class="ass-img" src="/api/tramites/${e.tramite_id}/assinatura.png" alt="Assinatura de ${esc(e.usuario)}">`
        : '<span class="pin-ok">✔ Aceite digital por PIN</span>';
      return `<li class="feito"><div><b>${esc(e.nome)}</b>
          <small>${fmtData(e.recebido_em)} às ${fmtHora(e.recebido_em, true)} · ${esc(e.usuario)}</small>
          ${e.setor ? `<small>Setor final: <strong>${esc(e.setor)}</strong></small>` : ''}
          <small>Selo: ${esc(e.selo.slice(0, 16))}…</small></div><div>${ass}</div></li>`;
    }).join('');

    const correcoes = p.correcoes.length ? `
      <div class="correcoes"><h3>Correções de descrição (original preservada)</h3><ul>
        ${p.correcoes.map((c) => `<li>${fmtData(c.corrigido_em)} ${fmtHora(c.corrigido_em)} — ${esc(c.usuario_nome)}:
          “${esc(c.descricao_anterior)}” → “${esc(c.descricao_nova)}”. <em>Justificativa: ${esc(c.justificativa)}</em></li>`).join('')}
      </ul></div>` : '';

    $('#detalhe-corpo').innerHTML = `
      <div class="det-topo"><div><h2>${esc(p.numero)}</h2>${chip(p.status)}</div>
        <button class="btn sec mini" type="button" data-fechar>Fechar ✕</button></div>
      <div class="resumo-doc"><span>${esc(p.descricao)}</span>
        ${p.n_correcoes ? `<div class="original">Descrição original: ${esc(p.descricao_original)}</div>` : ''}</div>
      <ul class="linha-tempo">${etapas}</ul>
      ${correcoes}
      <div class="modal-acoes">
        ${podeCorrigir ? '<button class="btn sec" type="button" data-acao="corrigir">Corrigir descrição</button>' : ''}
        <button class="btn" type="button" data-acao="pdf">Ficha em PDF / Imprimir</button>
        ${podeAdm ? '<button class="btn primario" type="button" data-acao="confirmar-adm">Confirmar recebimento — ADM</button>' : ''}
        ${podeSetor ? '<button class="btn primario" type="button" data-acao="confirmar-setor">Confirmar recebimento — Setor</button>' : ''}
      </div>`;
  }

  // ---------------------------------------------------------------- modais de ação
  function prepararAssinatura(form, padId) {
    const dica = $('[data-dica-assinatura]', form);
    dica.textContent = estado.config.assinatura_obrigatoria
      ? 'O desenho da assinatura é obrigatório. Use o mouse, o dedo ou a caneta no quadro.'
      : 'Opcional: assine no quadro acima. O PIN é sempre obrigatório e vale como aceite formal.';
    pads[padId].limpar();
  }

  function abrirNovo() {
    const f = $('#form-novo');
    f.reset();
    $('#cont-desc').textContent = '0';
    mostrarErro(f, '');
    prepararAssinatura(f, 'pad-novo');
    $('#dlg-novo').showModal();
    f.descricao.focus();
  }

  async function abrirConfirmar(etapa) {
    const p = estado.aberto;
    const f = $('#form-confirmar');
    f.reset();
    mostrarErro(f, '');
    f.dataset.etapa = String(etapa);
    f.dataset.id = String(p.id);
    $('#conf-titulo').textContent = etapa === 2
      ? '2ª etapa — Recebimento na Administração (ADM)'
      : '3ª etapa — Recebimento no Setor final';
    $('#conf-numero').textContent = p.numero;
    $('#conf-desc').textContent = p.descricao;
    const wrap = $('#conf-setor-wrap');
    wrap.hidden = etapa !== 3;
    if (etapa === 3) {
      // O setor de destino é o do usuário logado (travado); o servidor aplica a mesma regra.
      $('#conf-setor').innerHTML = `<option>${esc(estado.me.setor_nome)}</option>`;
    }
    prepararAssinatura(f, 'pad-conf');
    $('#dlg-confirmar').showModal();
    f.pin.focus();
  }

  function abrirCorrecao() {
    const p = estado.aberto;
    const f = $('#form-correcao');
    f.reset();
    mostrarErro(f, '');
    f.dataset.id = String(p.id);
    $('#corr-numero').textContent = p.numero;
    $('#corr-atual').textContent = p.descricao;
    f.descricao_nova.value = p.descricao;
    $('#dlg-correcao').showModal();
    f.descricao_nova.focus();
  }

  async function enviarForm(form, caminho, corpo, aoSucesso) {
    const botao = $('button[type=submit]', form);
    botao.disabled = true;
    mostrarErro(form, '');
    try {
      const resp = await api(caminho, { metodo: 'POST', corpo });
      aoSucesso(resp);
    } catch (e) {
      mostrarErro(form, e.message);
    } finally {
      botao.disabled = false;
      if (form.pin) form.pin.value = '';
    }
  }

  function corpoAssinado(form, padId, extra = {}) {
    const corpo = { pin: form.pin.value, ...extra };
    const png = pads[padId].dataURL();
    if (estado.config.assinatura_obrigatoria && !png) throw new Error('Assine no quadro antes de confirmar.');
    if (png) corpo.assinatura_png = png;
    return corpo;
  }

  // ---------------------------------------------------------------- auditoria
  async function carregarAuditoria() {
    $('#resultado-verificacao').textContent = '';
    try {
      const linhas = await api('/api/auditoria?limite=300');
      $('#tbody-audit').innerHTML = linhas.map((l) => `
        <tr><td>${fmtData(l.ocorrido_em)} ${fmtHora(l.ocorrido_em, true)}</td><td>${esc(l.usuario_nome || '—')}</td>
        <td><strong>${esc(l.acao)}</strong></td><td>${esc(l.protocolo || '')}</td>
        <td class="det">${esc(l.detalhes)}</td><td>${esc(l.ip || '')}</td></tr>`).join('');
    } catch (e) { toast(e.message, true); }
  }

  // ---------------------------------------------------------------- eventos
  function ligarEventos() {
    // login / logout
    $('#form-login').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const f = ev.target;
      const erro = $('#login-erro');
      erro.hidden = true;
      try {
        const r = await api('/api/login', { metodo: 'POST', corpo: { login: f.login.value, senha: f.senha.value } });
        estado.me = r.usuario;
        estado.csrf = r.csrf;
        f.reset();
        mostrarApp();
      } catch (e) {
        erro.textContent = e.message;
        erro.hidden = false;
        f.senha.value = '';
      }
    });
    $('#btn-sair').addEventListener('click', async () => {
      try { await api('/api/logout', { metodo: 'POST', corpo: {} }); } catch { /* sessão já expirada */ }
      mostrarLogin();
    });

    // abas
    $('#abas').addEventListener('click', (ev) => {
      const b = ev.target.closest('.aba');
      if (b) trocarAba(b.dataset.aba);
    });

    // filtros e paginação
    $('#form-filtros').addEventListener('submit', (ev) => { ev.preventDefault(); estado.pagina = 1; carregarTabela().catch((e) => toast(e.message, true)); });
    $('#btn-limpar').addEventListener('click', () => { $('#form-filtros').reset(); estado.pagina = 1; carregarTabela().catch((e) => toast(e.message, true)); });
    $('#form-filtros').status.addEventListener('change', () => $('#form-filtros').requestSubmit());
    $('#pg-ant').addEventListener('click', () => { estado.pagina -= 1; carregarTabela(); });
    $('#pg-prox').addEventListener('click', () => { estado.pagina += 1; carregarTabela(); });

    // PDF da listagem (respeita os filtros atuais)
    $('#btn-pdf-lista').addEventListener('click', () => window.open(`/api/relatorio/pdf?${paramsFiltro()}`, '_blank', 'noopener'));

    // abrir detalhe (clique ou Enter na linha)
    const abrirLinha = (ev) => {
      const tr = ev.target.closest('tr[data-id]');
      if (tr) abrirDetalhe(tr.dataset.id);
    };
    $('#tbody').addEventListener('click', abrirLinha);
    $('#tbody').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') abrirLinha(ev); });

    // ações no detalhe
    $('#detalhe-corpo').addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-acao]');
      if (!b) return;
      const p = estado.aberto;
      if (b.dataset.acao === 'pdf') window.open(`/api/protocolos/${p.id}/pdf`, '_blank', 'noopener');
      if (b.dataset.acao === 'corrigir') abrirCorrecao();
      if (b.dataset.acao === 'confirmar-adm') abrirConfirmar(2);
      if (b.dataset.acao === 'confirmar-setor') abrirConfirmar(3);
    });

    // botões "fechar / cancelar" de qualquer modal
    document.addEventListener('click', (ev) => {
      if (ev.target.closest('[data-fechar]')) ev.target.closest('dialog').close();
      const lim = ev.target.closest('[data-limpar]');
      if (lim) pads[lim.dataset.limpar].limpar();
    });

    // novo registro (1ª etapa)
    $('#btn-novo').addEventListener('click', abrirNovo);
    $('#form-novo').descricao.addEventListener('input', (ev) => { $('#cont-desc').textContent = ev.target.value.length; });
    $('#form-novo').addEventListener('submit', (ev) => {
      ev.preventDefault();
      const f = ev.target;
      let corpo;
      try { corpo = corpoAssinado(f, 'pad-novo', { descricao: f.descricao.value }); } catch (e) { mostrarErro(f, e.message); return; }
      enviarForm(f, '/api/protocolos', corpo, (p) => {
        $('#dlg-novo').close();
        toast(`Protocolo ${p.numero} registrado — aguardando ADM.`);
        estado.pagina = 1;
        carregarTudo();
      });
    });

    // confirmar 2ª / 3ª etapa
    $('#form-confirmar').addEventListener('submit', (ev) => {
      ev.preventDefault();
      const f = ev.target;
      const etapa = Number(f.dataset.etapa);
      let corpo;
      try { corpo = corpoAssinado(f, 'pad-conf'); } catch (e) { mostrarErro(f, e.message); return; }
      enviarForm(f, `/api/protocolos/${f.dataset.id}/${etapa === 2 ? 'adm' : 'setor'}`, corpo, (p) => {
        $('#dlg-confirmar').close();
        estado.aberto = p;
        renderDetalhe(p);
        toast(etapa === 2 ? `${p.numero}: recebimento do ADM registrado.` : `${p.numero}: entrega concluída no setor.`);
        carregarTudo();
      });
    });

    // correção de descrição
    $('#form-correcao').addEventListener('submit', (ev) => {
      ev.preventDefault();
      const f = ev.target;
      enviarForm(f, `/api/protocolos/${f.dataset.id}/correcao`,
        { descricao_nova: f.descricao_nova.value, justificativa: f.justificativa.value, pin: f.pin.value }, (p) => {
          $('#dlg-correcao').close();
          estado.aberto = p;
          renderDetalhe(p);
          toast('Correção registrada. A descrição original foi preservada.');
          carregarTudo();
        });
    });

    // auditoria: verificar cadeia de hash
    $('#btn-verificar').addEventListener('click', async () => {
      const out = $('#resultado-verificacao');
      try {
        const r = await api('/api/auditoria/verificar');
        out.className = `verificacao ${r.ok ? 'ok' : 'falha'}`;
        out.textContent = r.ok
          ? `✔ Trilha íntegra (${r.total} eventos verificados).`
          : `✖ ADULTERAÇÃO DETECTADA a partir do evento nº ${r.primeira_falha_id}.`;
      } catch (e) { toast(e.message, true); }
    });

    // atualização automática do dashboard (somente com a aba aberta e sem modal)
    setInterval(() => {
      if (estado.me && estado.abaAtual === 'protocolos' && !$('dialog[open]') && !document.hidden) carregarTudo();
    }, 30000);
  }

  // ---------------------------------------------------------------- inicialização
  async function iniciar() {
    pads['pad-novo'] = new AssinaturaPad($('#pad-novo'));
    pads['pad-conf'] = new AssinaturaPad($('#pad-conf'));
    ligarEventos();
    try {
      estado.config = await api('/api/config');
      $$('[data-unidade]').forEach((el) => { el.textContent = `Unidade/Instituição: ${estado.config.unidade}`; });
      if (estado.config.logo) {
        $$('img.logo').forEach((img) => { img.src = '/static/logo.png'; img.hidden = false; });
      }
    } catch { /* segue sem configuração */ }
    try {
      const r = await fetch('/api/me', { credentials: 'same-origin' });
      if (r.ok) {
        const dados = await r.json();
        estado.me = dados.usuario;
        estado.csrf = dados.csrf;
        mostrarApp();
        return;
      }
    } catch { /* offline: mostra login */ }
    mostrarLogin();
  }

  iniciar();
})();
