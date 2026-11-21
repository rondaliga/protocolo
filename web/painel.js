/* Trilha de auditoria organizada + Painel de controle do gestor.
 * Carregado antes de app.js; app.js chama window.criarPainel(LP) com as funções que este módulo precisa.
 * Todo texto vindo do banco passa por esc() antes de virar HTML.
 */
(() => {
  'use strict';

  window.criarPainel = (LP) => {
    const { $, $$, esc, data, hora, rpc, toast, erroForm, enviar } = LP;

    // ================================================================== TRILHA DE AUDITORIA
    const CATEGORIAS = {
      acesso: 'Acesso', protocolo: 'Protocolo', tramitacao: 'Tramitação', correcao: 'Correção',
      prazo: 'Prazo / alerta', impressao: 'Impressão', seguranca: 'Segurança', administracao: 'Administração',
    };
    const ACOES = {
      LOGIN: 'Entrou no sistema', LOGOUT: 'Saiu do sistema', LOGOUT_INATIVIDADE: 'Sessão encerrada por inatividade',
      FALHA_PIN: 'PIN incorreto', USUARIO_BLOQUEADO: 'PIN bloqueado',
      PROTOCOLO_CRIADO: 'Protocolo registrado (1ª etapa)', RECEBIMENTO_ADM: 'Recebimento do ADM (2ª etapa)',
      RECEBIMENTO_SETOR: 'Recebimento do setor (3ª etapa)', DESCRICAO_CORRIGIDA: 'Descrição corrigida',
      PRAZO_AJUSTADO: 'Prazo ajustado', ALERTA_SLA: 'Alerta: tempo máximo excedido', ALERTA_PRAZO_VENCIDO: 'Alerta: prazo vencido',
      ALERTA_PRAZO_PROXIMO: 'Alerta: prazo próximo', IMPRESSAO_FICHA: 'Ficha impressa', IMPRESSAO_LIVRO: 'Livro impresso',
      IMPRESSAO_TRILHA: 'Trilha impressa/exportada', PIN_ALTERADO: 'PIN alterado pelo próprio usuário',
      SENHA_ALTERADA: 'Senha alterada pelo próprio usuário', PIN_REDEFINIDO: 'PIN redefinido pelo gestor',
      PIN_DESBLOQUEADO: 'PIN desbloqueado', SENHA_REDEFINIDA: 'Senha redefinida pelo gestor', USUARIO_CRIADO: 'Usuário criado',
      USUARIO_ATUALIZADO: 'Usuário atualizado', USUARIO_ATIVADO: 'Usuário reativado', USUARIO_DESATIVADO: 'Usuário desativado',
      SETOR_SALVO: 'Setor salvo', PARAMETRO_ALTERADO: 'Regra/parâmetro alterado', FERIADO_SALVO: 'Feriado cadastrado',
      FERIADO_REMOVIDO: 'Feriado removido', PERFIL_CADASTRADO: 'Perfil cadastrado (SQL)', PERFIL_DESATIVADO: 'Perfil desativado (SQL)',
      PERFIL_REATIVADO: 'Perfil reativado (SQL)', SEGREDO_INTEGRACAO_DEFINIDO: 'Segredo dos e-mails definido',
    };
    const PAPEIS = { portaria: 'Portaria', adm: 'ADM', super_setor: 'Super/Setor', gestor: 'Gestor' };
    const ASSIN = { pin: 'somente PIN', pin_digitada: 'assinatura digitada', pin_canvas: 'assinatura desenhada', digitada: 'assinatura digitada', desenhada: 'assinatura desenhada' };
    const dia = (v) => (v ? data(`${String(v).slice(0, 10)}T12:00:00`) : 'sem prazo');
    const aspas = (v) => `“${v}”`;

    // texto legível (sem HTML) a partir do JSON gravado
    function resumo(acao, d = {}) {
      const L = [];
      const add = (x) => { if (x) L.push(x); };
      switch (acao) {
        case 'PROTOCOLO_CRIADO':
          add(`${d.tipo === 'judicial' ? 'Demanda judicial' : 'Correspondência'}${d.urgente ? ' URGENTE' : ''}`);
          add(`descrição: ${aspas(d.descricao || '')}`);
          add(`prazo: ${dia(d.prazo)}`); add(d.foto ? 'com foto' : 'sem foto'); add(ASSIN[d.assinatura]);
          break;
        case 'RECEBIMENTO_ADM': add(`destino: ${d.setor || '—'}`); add(ASSIN[d.assinatura]); if (d.como_gestor) add('feito pelo gestor'); break;
        case 'RECEBIMENTO_SETOR': add(`setor: ${d.setor || '—'}`); add(ASSIN[d.assinatura]); if (d.como_gestor) add('feito pelo gestor'); break;
        case 'DESCRICAO_CORRIGIDA': add(`de ${aspas(d.anterior)} para ${aspas(d.nova)}`); add(`justificativa: ${d.justificativa}`); break;
        case 'PRAZO_AJUSTADO': add(`de ${dia(d.anterior)} para ${dia(d.novo)}`); add(`justificativa: ${d.justificativa}`); break;
        case 'ALERTA_SLA': add(`etapa ${d.etapa === 2 ? 'do ADM' : 'do setor'} sem recebimento no tempo máximo`); break;
        case 'ALERTA_PRAZO_PROXIMO': add(`faltam ${d.dias} dia(s) para o prazo`); break;
        case 'ALERTA_PRAZO_VENCIDO': add('prazo vencido sem conclusão'); break;
        case 'IMPRESSAO_FICHA': add(d.numero ? `protocolo ${d.numero}` : ''); break;
        case 'IMPRESSAO_LIVRO': case 'IMPRESSAO_TRILHA': add(`filtros: ${d.filtros || 'nenhum'}`); break;
        case 'USUARIO_BLOQUEADO': add('5 PINs incorretos seguidos: bloqueio de 5 minutos'); break;
        case 'USUARIO_CRIADO': add(`${d.nome} (${d.email})`); add(`papel: ${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''}`); add(d.conta_nova === false ? 'conta já existia no Auth' : ''); break;
        case 'USUARIO_ATUALIZADO':
          add(`${d.nome_anterior || ''}${d.nome_anterior !== d.nome ? ` → ${d.nome}` : ''} (${d.email || ''})`);
          add(`papel: ${PAPEIS[d.papel_anterior] || d.papel_anterior} → ${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''}`); break;
        case 'USUARIO_ATIVADO': case 'USUARIO_DESATIVADO': case 'SENHA_REDEFINIDA': case 'PIN_REDEFINIDO': case 'PIN_DESBLOQUEADO':
          add(`${d.nome || ''} (${d.email || ''})`); break;
        case 'SETOR_SALVO': add(`${d.setor} — ${d.ativo ? 'ativo' : 'inativo'}${d.novo ? ' (novo)' : ''}`); break;
        case 'PARAMETRO_ALTERADO': add(`${d.chave}: ${d.anterior != null ? `${d.anterior} → ` : ''}${d.valor}`); break;
        case 'FERIADO_SALVO': case 'FERIADO_REMOVIDO': add(`${dia(d.data)} — ${d.descricao}`); break;
        case 'PERFIL_CADASTRADO': add(`${d.email} (${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''})`); break;
        case 'PERFIL_DESATIVADO': case 'PERFIL_REATIVADO': add(d.email); break;
        default:
          Object.entries(d || {}).forEach(([k, v]) => add(`${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`));
      }
      return L.filter(Boolean).join(' · ');
    }

    const aud = { pagina: 1, por: 50, total: 0, seq: 0 };
    const filtrosAud = () => {
      const f = $('#form-aud'), v = (n) => (f[n].value || '').trim() || null;
      return { p_q: v('q'), p_categoria: v('categoria'), p_usuario: v('usuario'), p_data_ini: v('data_ini'), p_data_fim: v('data_fim') };
    };
    const descFiltrosAud = () => {
      const f = filtrosAud();
      return [f.p_q && `busca “${f.p_q}”`, f.p_categoria && `tipo: ${CATEGORIAS[f.p_categoria]}`, f.p_usuario && `usuário: ${f.p_usuario}`,
        f.p_data_ini && `de ${dia(f.p_data_ini)}`, f.p_data_fim && `até ${dia(f.p_data_fim)}`].filter(Boolean).join('; ');
    };

    async function carregarAuditoria() {
      const seq = ++aud.seq;
      try {
        const r = await rpc('listar_auditoria', { ...filtrosAud(), p_limite: aud.por, p_offset: (aud.pagina - 1) * aud.por });
        if (seq !== aud.seq) return;
        aud.total = r.total;
        $('#tbody-audit').innerHTML = r.itens.map((x) => `<tr>
          <td class="nw">${data(x.ocorrido_em)}<br><small>${hora(x.ocorrido_em, true)}</small></td>
          <td><span class="cat cat-${esc(x.categoria)}">${esc(CATEGORIAS[x.categoria] || x.categoria)}</span></td>
          <td>${esc(x.usuario_nome || 'Sistema')}</td>
          <td><strong>${esc(ACOES[x.acao] || x.acao)}</strong></td>
          <td>${x.numero ? `<button type="button" class="link" data-prot="${esc(x.protocolo_id)}">${esc(x.numero)}</button>` : '—'}</td>
          <td class="detalhes">${esc(resumo(x.acao, x.detalhes))}</td></tr>`).join('')
          || '<tr><td colspan="6" class="vazio">Nenhum evento encontrado com estes filtros.</td></tr>';
        const paginas = Math.max(1, Math.ceil(r.total / aud.por));
        $('#aud-contagem').textContent = `${r.total} evento(s)`;
        $('#aud-pg').textContent = `Página ${aud.pagina} de ${paginas}`;
        $('#aud-ant').disabled = aud.pagina <= 1; $('#aud-prox').disabled = aud.pagina >= paginas;
      } catch (e) { toast(e.message, true); }
    }
    function abrirAuditoria() { $('#resultado-verificacao').textContent = ''; $('#resultado-verificacao').className = 'verificacao'; carregarAuditoria(); }

    async function todosEventos(max) {
      const out = []; const f = filtrosAud();
      for (let off = 0; off < max; off += 1000) {
        const r = await rpc('listar_auditoria', { ...f, p_limite: Math.min(1000, max - off), p_offset: off });
        out.push(...r.itens); if (out.length >= r.total) break;
      }
      return out;
    }
    const celulaCsv = (v) => {                       // aspas + proteção contra "injeção de fórmula" em planilhas
      let t = String(v ?? '').replace(/\r?\n/g, ' ');
      if (/^[=+\-@\t]/.test(t)) t = `'${t}`;
      return `"${t.replace(/"/g, '""')}"`;
    };
    async function exportarCsv() {
      const btn = $('#aud-csv'); btn.disabled = true;
      try {
        const itens = await todosEventos(5000);
        await rpc('registrar_exportacao', { p_tipo: 'TRILHA', p_filtros: `CSV · ${descFiltrosAud() || 'sem filtros'}` });
        const linhas = [['Data', 'Hora', 'Tipo', 'Usuário', 'Ação', 'Protocolo', 'Detalhes'].map(celulaCsv).join(';')]
          .concat(itens.map((x) => [data(x.ocorrido_em), hora(x.ocorrido_em, true), CATEGORIAS[x.categoria] || x.categoria, x.usuario_nome || 'Sistema',
            ACOES[x.acao] || x.acao, x.numero || '', resumo(x.acao, x.detalhes)].map(celulaCsv).join(';')));
        const blob = new Blob([`﻿${linhas.join('\r\n')}`], { type: 'text/csv;charset=utf-8' });
        const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
        a.download = `trilha-auditoria-${new Date().toISOString().slice(0, 10)}.csv`; document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 4000);
        toast(`Exportados ${itens.length} evento(s)${aud.total > itens.length ? ` de ${aud.total} (limite de 5000)` : ''}.`);
      } catch (e) { toast(e.message, true); } finally { btn.disabled = false; }
    }
    async function imprimirTrilha() {
      const btn = $('#aud-imprimir'); btn.disabled = true;
      try {
        const itens = await todosEventos(500);
        const desc = descFiltrosAud();
        await rpc('registrar_exportacao', { p_tipo: 'TRILHA', p_filtros: `impressão · ${desc || 'sem filtros'}` });
        const agora = new Date().toISOString();
        const linhas = itens.map((x) => `<tr><td>${data(x.ocorrido_em)}<br>${hora(x.ocorrido_em, true)}</td><td>${esc(CATEGORIAS[x.categoria] || x.categoria)}</td>
          <td>${esc(x.usuario_nome || 'Sistema')}</td><td><b>${esc(ACOES[x.acao] || x.acao)}</b></td><td>${esc(x.numero || '—')}</td>
          <td class="d">${esc(resumo(x.acao, x.detalhes))}</td></tr>`).join('');
        LP.imprimir('livro', `${LP.cabecalhoImpressao('TRILHA DE AUDITORIA')}
          <p class="p-meta">Filtros: ${esc(desc || 'nenhum')} · Eventos: ${aud.total}${aud.total > itens.length ? ` (impressos os ${itens.length} mais recentes)` : ''}
            · Emitido por ${esc(LP.estado().perfil.nome)} em ${data(agora)} ${hora(agora)}</p>
          <table class="p-tab"><colgroup>${[0, 1, 2, 3, 4, 5].map((i) => `<col class="t${i}">`).join('')}</colgroup>
            <thead><tr><th>Data / hora</th><th>Tipo</th><th>Usuário</th><th>Ação</th><th>Protocolo</th><th>O que aconteceu</th></tr></thead>
            <tbody>${linhas || '<tr><td colspan="6">Nenhum evento.</td></tr>'}</tbody></table>${LP.rodapeImpressao()}`);
      } catch (e) { toast(e.message, true); } finally { btn.disabled = false; }
    }

    // ================================================================== PAINEL DE CONTROLE
    const painel = { sub: 'usuarios', usuarios: [], setores: [] };
    const SUBS = ['usuarios', 'setores', 'parametros', 'feriados', 'sistema'];

    function abrirPainel() { trocarSub(painel.sub); }
    function trocarSub(n) {
      painel.sub = n;
      $$('.subaba').forEach((b) => b.classList.toggle('ativa', b.dataset.sub === n));
      SUBS.forEach((s) => { $(`#sub-${s}`).hidden = s !== n; });
      ({ usuarios: carregarUsuarios, setores: carregarSetores, parametros: carregarParametros, feriados: carregarFeriados, sistema: carregarSistema })[n]();
    }
    const falha = (e) => toast(e.message, true);

    // ---------- geração de credenciais provisórias (aleatórias, no navegador)
    const sorteio = (n) => { const b = new Uint32Array(1); crypto.getRandomValues(b); return b[0] % n; };
    function gerarSenha() {
      const L = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ', N = '23456789', S = L + N, out = [L[sorteio(L.length)], N[sorteio(N.length)]];
      while (out.length < 12) out.push(S[sorteio(S.length)]);
      for (let i = out.length - 1; i > 0; i -= 1) { const j = sorteio(i + 1); [out[i], out[j]] = [out[j], out[i]]; }
      return out.join('');
    }
    function gerarPin() {
      for (;;) {
        const p = Array.from({ length: 6 }, () => sorteio(10)).join('');
        if (!/^(\d)\1+$/.test(p) && !/012345|123456|234567|345678|456789|987654/.test(p)) return p;
      }
    }

    // ---------- usuários
    const usuarioPorId = (id) => painel.usuarios.find((u) => u.user_id === id);
    async function carregarUsuarios() {
      try { painel.usuarios = await rpc('painel_listar_usuarios'); renderUsuarios(); } catch (e) { falha(e); }
    }
    function situacao(u) {
      const b = [u.ativo ? '<span class="sit ok">Ativo</span>' : '<span class="sit off">Inativo</span>'];
      if (u.pin_bloqueado) b.push('<span class="sit alerta">PIN bloqueado</span>');
      if (u.deve_trocar_senha || u.deve_trocar_pin) b.push('<span class="sit atencao">Primeiro acesso pendente</span>');
      if (u.sem_pin) b.push('<span class="sit alerta">Sem PIN</span>');
      return b.join(' ');
    }
    function renderUsuarios() {
      const q = $('#usr-busca').value.trim().toLowerCase(), papel = $('#usr-filtro-papel').value, at = $('#usr-filtro-ativo').value;
      const l = painel.usuarios.filter((u) => (!q || `${u.nome} ${u.email}`.toLowerCase().includes(q)) && (!papel || u.papel === papel)
        && (at === '' || (at === 'ativos' ? u.ativo : !u.ativo)));
      const eu = LP.estado().sessao.uid;
      $('#usr-contagem').textContent = `${l.length} usuário(s)`;
      $('#tbody-usr').innerHTML = l.map((u) => `<tr class="${u.ativo ? '' : 'inativo'}">
        <td><strong>${esc(u.nome)}</strong>${u.user_id === eu ? ' <span class="tag">você</span>' : ''}<small class="et-sub">${esc(u.email || '')}</small></td>
        <td>${esc(PAPEIS[u.papel] || u.papel)}${u.setor_nome ? `<small class="et-sub">${esc(u.setor_nome)}</small>` : ''}</td>
        <td>${situacao(u)}</td>
        <td class="nw">${u.ultimo_acesso ? `${data(u.ultimo_acesso)} ${hora(u.ultimo_acesso)}` : 'nunca entrou'}</td>
        <td class="acoes" data-uid="${esc(u.user_id)}">
          <button type="button" class="btn mini sec" data-uacao="editar">Editar</button>
          ${u.user_id === eu ? '' : `<button type="button" class="btn mini sec" data-uacao="senha">Nova senha</button>
          <button type="button" class="btn mini sec" data-uacao="pin">Novo PIN</button>`}
          ${u.pin_bloqueado ? '<button type="button" class="btn mini sec" data-uacao="desbloquear">Desbloquear PIN</button>' : ''}
          ${u.user_id === eu ? '' : `<button type="button" class="btn mini ${u.ativo ? 'perigo' : 'sec'}" data-uacao="ativo">${u.ativo ? 'Desativar' : 'Reativar'}</button>`}
        </td></tr>`).join('') || '<tr><td colspan="5" class="vazio">Nenhum usuário encontrado.</td></tr>';
    }
    async function setoresAtivos() {
      if (!painel.setores.length) painel.setores = await rpc('painel_listar_setores');
      return painel.setores.filter((s) => s.ativo);
    }
    async function abrirUsuario(u) {
      const f = $('#form-usuario'); f.reset(); erroForm(f, '');
      f.dataset.uid = u ? u.user_id : '';
      $('#usr-titulo').textContent = u ? `Editar usuário — ${u.nome}` : 'Novo usuário';
      f.email.value = u ? u.email || '' : ''; f.email.disabled = !!u; f.nome.value = u ? u.nome : '';
      f.papel.value = u ? u.papel : 'portaria';
      $('#bloco-credenciais').hidden = !!u; f.senha.value = u ? '' : gerarSenha(); f.pin_novo.value = u ? '' : gerarPin();
      try {
        painel.setores = await rpc('painel_listar_setores');
        f.setor.innerHTML = painel.setores.filter((s) => s.ativo || (u && s.id === u.setor_id))
          .map((s) => `<option value="${esc(s.id)}">${esc(s.nome)}</option>`).join('');
        if (u && u.setor_id) f.setor.value = String(u.setor_id);
      } catch (e) { falha(e); return; }
      ajustarSetor(); $('#dlg-usuario').showModal(); (u ? f.nome : f.email).focus();
    }
    const ajustarSetor = () => { const f = $('#form-usuario'); $('#lbl-usr-setor').hidden = f.papel.value !== 'super_setor'; };

    function mostrarCredenciais(linhas) {
      $('#cred-dados').innerHTML = linhas.map(([k, v]) => `<dt>${esc(k)}</dt><dd><code>${esc(v)}</code></dd>`).join('');
      $('#cred-copiar').dataset.texto = linhas.map(([k, v]) => `${k}: ${v}`).join('\n');
      $('#dlg-credencial').showModal();
    }

    function abrirReset(u, tipo) {
      const f = $('#form-reset'); f.reset(); erroForm(f, ''); f.dataset.uid = u.user_id; f.dataset.tipo = tipo;
      $('#reset-titulo').textContent = tipo === 'senha' ? `Nova senha provisória — ${u.nome}` : `Novo PIN provisório — ${u.nome}`;
      $('#reset-info').textContent = tipo === 'senha'
        ? 'As sessões abertas deste usuário serão encerradas e ele será obrigado a trocar a senha no próximo acesso.'
        : 'O usuário será obrigado a trocar o PIN no próximo acesso. O PIN bloqueado (se houver) é liberado.';
      $('#reset-rotulo').textContent = tipo === 'senha' ? 'Senha provisória' : 'PIN provisório (4 a 6 dígitos)';
      f.valor.value = tipo === 'senha' ? gerarSenha() : gerarPin(); f.valor.maxLength = tipo === 'senha' ? 72 : 6;
      $('#dlg-reset').showModal(); f.pin.focus();
    }
    function abrirAtivo(u) {
      const f = $('#form-ativo'); f.reset(); erroForm(f, ''); f.dataset.uid = u.user_id; f.dataset.ativar = u.ativo ? '0' : '1';
      $('#ativo-titulo').textContent = u.ativo ? `Desativar ${u.nome}?` : `Reativar ${u.nome}?`;
      $('#ativo-info').textContent = u.ativo
        ? 'O usuário perde o acesso imediatamente (sessões encerradas). Todo o histórico é mantido; nada é apagado.'
        : 'O usuário volta a poder entrar com a senha e o PIN atuais.';
      $('#dlg-ativo').showModal(); f.pin.focus();
    }

    // ---------- setores
    async function carregarSetores() {
      try { painel.setores = await rpc('painel_listar_setores'); renderSetores(); } catch (e) { falha(e); }
    }
    function renderSetores() {
      $('#tbody-set').innerHTML = painel.setores.map((s) => `<tr class="${s.ativo ? '' : 'inativo'}"><td><strong>${esc(s.nome)}</strong></td><td>${esc(s.usuarios)}</td>
        <td>${s.ativo ? '<span class="sit ok">Ativo</span>' : '<span class="sit off">Inativo</span>'}</td>
        <td class="acoes"><button type="button" class="btn mini sec" data-sid="${esc(s.id)}">Editar</button></td></tr>`).join('')
        || '<tr><td colspan="4" class="vazio">Nenhum setor cadastrado.</td></tr>';
    }
    function abrirSetor(s) {
      const f = $('#form-setor'); f.reset(); erroForm(f, ''); f.dataset.id = s ? s.id : '';
      $('#setor-titulo').textContent = s ? 'Editar setor' : 'Novo setor'; f.nome.value = s ? s.nome : ''; f.ativo.checked = s ? s.ativo : true;
      $('#dlg-setor').showModal(); f.nome.focus();
    }

    // ---------- parâmetros
    const PARAM_ROTULOS = {
      prazo_judicial_dias: ['Prazo padrão das demandas judiciais', 'dias úteis'],
      prazo_correspondencia_dias: ['Prazo padrão das correspondências', 'dias úteis (0 = sem prazo)'],
      sla_adm_horas: ['Tempo máximo para o ADM receber', 'horas úteis'],
      sla_adm_urgente_horas: ['Tempo máximo do ADM — urgentes', 'horas úteis'],
      sla_setor_horas: ['Tempo máximo para o setor receber', 'horas úteis (9 = 1 dia útil)'],
      sla_setor_urgente_horas: ['Tempo máximo do setor — urgentes', 'horas úteis'],
      expediente_inicio: ['Início do expediente', 'hora (0–23)'], expediente_fim: ['Fim do expediente', 'hora (1–24)'],
      alerta_prazo_dias: ['Avisar quando faltarem até', 'dias para o prazo'],
      foto_obrigatoria_judicial: ['Exigir foto nas demandas judiciais', ''],
      gestor_ignora_segregacao: ['Gestor pode assinar mais de uma etapa do mesmo protocolo', ''],
      url_sistema: ['Endereço do sistema (usado nos e-mails)', 'https://…'],
    };
    async function carregarParametros() {
      try {
        const l = await rpc('painel_listar_parametros');
        $('#lista-param').innerHTML = l.map((p) => {
          const [rot, un] = PARAM_ROTULOS[p.chave] || [p.chave, ''];
          const campo = p.tipo === 'booleano'
            ? `<select name="valor"><option value="true"${p.valor === 'true' ? ' selected' : ''}>Sim</option><option value="false"${p.valor === 'false' ? ' selected' : ''}>Não</option></select>`
            : `<input name="valor" type="${p.tipo === 'numero' ? 'number' : 'text'}" ${p.tipo === 'numero' ? 'min="0" max="999"' : 'maxlength="200"'} value="${esc(p.valor)}">`;
          return `<form class="param" data-chave="${esc(p.chave)}" autocomplete="off"><div><strong>${esc(rot)}</strong><small class="dica">${esc(p.descricao || '')}</small></div>
            <div class="param-campo">${campo}<span class="un">${esc(un)}</span><button class="btn mini primario" type="submit">Salvar</button></div></form>`;
        }).join('');
      } catch (e) { falha(e); }
    }

    // ---------- feriados
    async function carregarFeriados() {
      try {
        const l = await rpc('painel_listar_feriados');
        $('#tbody-fer').innerHTML = l.map((x) => `<tr><td>${dia(x.data)}</td><td>${esc(x.descricao)}</td>
          <td class="acoes"><button type="button" class="btn mini sec" data-fdata="${esc(x.data)}">Remover</button></td></tr>`).join('')
          || '<tr><td colspan="3" class="vazio">Nenhum feriado cadastrado.</td></tr>';
      } catch (e) { falha(e); }
    }

    // ---------- sistema
    async function carregarSistema() {
      try {
        const r = await rpc('painel_resumo');
        const k = (rot, v, sub = '') => `<div class="kpi estatico"><span class="kpi-rot">${esc(rot)}</span><strong>${esc(v)}</strong><small>${esc(sub) || '&nbsp;'}</small></div>`;
        $('#sistema-kpis').innerHTML = k('Usuários ativos', r.usuarios_ativos, `${r.usuarios_inativos} inativo(s)`)
          + k('PIN bloqueado', r.pin_bloqueado, 'aguardam desbloqueio') + k('Sem e-mail no perfil', r.sem_email, 'não recebem avisos')
          + k('E-mails na fila', r.email_pendente, 'aguardando envio') + k('E-mails com erro', r.email_erro, r.ultimo_erro_email || 'nenhum erro')
          + k('E-mails enviados', r.email_enviado);
        $('#sistema-aviso').textContent = r.integracao_configurada
          ? 'Integração de e-mail configurada. Se a fila crescer sem enviar, confira o fluxo “Avisos por e-mail” na aba Actions do GitHub.'
          : 'Integração de e-mail ainda não configurada: os avisos ficam só no sistema (sino). Veja a seção 4B do README.';
      } catch (e) { falha(e); }
    }

    // ================================================================== EVENTOS
    function ligar() {
      // trilha
      const f = $('#form-aud'); let t;
      const aplicar = () => { aud.pagina = 1; carregarAuditoria(); };
      f.addEventListener('submit', (ev) => ev.preventDefault());
      ['q', 'usuario'].forEach((n) => f[n].addEventListener('input', () => { clearTimeout(t); t = setTimeout(aplicar, 350); }));
      ['categoria', 'data_ini', 'data_fim'].forEach((n) => f[n].addEventListener('change', aplicar));
      $('#aud-limpar').addEventListener('click', () => { f.reset(); aplicar(); });
      $('#aud-ant').addEventListener('click', () => { aud.pagina -= 1; carregarAuditoria(); });
      $('#aud-prox').addEventListener('click', () => { aud.pagina += 1; carregarAuditoria(); });
      $('#aud-csv').addEventListener('click', exportarCsv);
      $('#aud-imprimir').addEventListener('click', imprimirTrilha);
      $('#tbody-audit').addEventListener('click', (ev) => { const b = ev.target.closest('[data-prot]'); if (b) LP.abrirDetalhe(b.dataset.prot); });

      // painel
      $('#subabas').addEventListener('click', (ev) => { const b = ev.target.closest('.subaba'); if (b) trocarSub(b.dataset.sub); });
      ['#usr-busca', '#usr-filtro-papel', '#usr-filtro-ativo'].forEach((s) => $(s).addEventListener('input', renderUsuarios));
      $('#usr-novo').addEventListener('click', () => abrirUsuario(null));
      $('#tbody-usr').addEventListener('click', async (ev) => {
        const b = ev.target.closest('[data-uacao]'); if (!b) return;
        const u = usuarioPorId(b.closest('[data-uid]').dataset.uid); if (!u) return;
        if (b.dataset.uacao === 'editar') abrirUsuario(u);
        else if (b.dataset.uacao === 'senha') abrirReset(u, 'senha');
        else if (b.dataset.uacao === 'pin') abrirReset(u, 'pin');
        else if (b.dataset.uacao === 'ativo') abrirAtivo(u);
        else if (b.dataset.uacao === 'desbloquear') {
          try { await rpc('painel_desbloquear_pin', { p_user_id: u.user_id }); toast(`PIN de ${u.nome} desbloqueado.`); carregarUsuarios(); } catch (e) { falha(e); }
        }
      });
      $('#form-usuario').papel.addEventListener('change', ajustarSetor);
      $('#form-usuario').addEventListener('click', (ev) => {
        const g = ev.target.closest('[data-gerar]'); if (!g) return;
        const form = $('#form-usuario'); if (g.dataset.gerar === 'senha') form.senha.value = gerarSenha(); else form.pin_novo.value = gerarPin();
      });
      $('#form-usuario').addEventListener('submit', (ev) => {
        ev.preventDefault(); const form = ev.target, uid = form.dataset.uid;
        if (form.papel.value === 'super_setor' && !form.setor.value) { erroForm(form, 'Escolha o setor do usuário.'); return; }
        const setor = form.papel.value === 'super_setor' ? Number(form.setor.value) : null;
        if (uid) {
          enviar(form, () => rpc('painel_atualizar_usuario', { p_user_id: uid, p_nome: form.nome.value, p_papel: form.papel.value, p_setor_id: setor, p_pin_gestor: form.pin.value }),
            async () => { $('#dlg-usuario').close(); toast('Usuário atualizado.'); await carregarUsuarios(); });
          return;
        }
        const senha = form.senha.value, pin = form.pin_novo.value, email = form.email.value.trim(), nome = form.nome.value.trim();
        enviar(form, () => rpc('painel_criar_usuario', { p_email: email, p_nome: form.nome.value, p_papel: form.papel.value, p_setor_id: setor,
          p_senha: senha || null, p_pin: pin, p_pin_gestor: form.pin.value }), async (r) => {
          $('#dlg-usuario').close(); await carregarUsuarios();
          const linhas = [['Endereço', LP.enderecoSistema()], ['Login (e-mail)', email]];
          linhas.push(r.conta_nova ? ['Senha provisória', senha] : ['Senha', 'a mesma que o usuário já tinha no Supabase']);
          linhas.push(['PIN provisório', pin]);
          mostrarCredenciais(linhas);
          toast(`Usuário ${nome} criado.`);
        });
      });
      $('#form-reset').addEventListener('click', (ev) => {
        if (ev.target.closest('#reset-gerar')) { const form = $('#form-reset'); form.valor.value = form.dataset.tipo === 'senha' ? gerarSenha() : gerarPin(); }
      });
      $('#form-reset').addEventListener('submit', (ev) => {
        ev.preventDefault(); const form = ev.target, tipo = form.dataset.tipo, u = usuarioPorId(form.dataset.uid), valor = form.valor.value;
        enviar(form, () => (tipo === 'senha'
          ? rpc('painel_redefinir_senha', { p_user_id: u.user_id, p_senha: valor, p_pin_gestor: form.pin.value })
          : rpc('painel_redefinir_pin', { p_user_id: u.user_id, p_pin: valor, p_pin_gestor: form.pin.value })), async () => {
          $('#dlg-reset').close(); await carregarUsuarios();
          mostrarCredenciais([['Usuário', `${u.nome} (${u.email})`], [tipo === 'senha' ? 'Nova senha provisória' : 'Novo PIN provisório', valor]]);
        });
      });
      $('#form-ativo').addEventListener('submit', (ev) => {
        ev.preventDefault(); const form = ev.target, ativar = form.dataset.ativar === '1';
        enviar(form, () => rpc('painel_definir_ativo', { p_user_id: form.dataset.uid, p_ativo: ativar, p_pin_gestor: form.pin.value }),
          async () => { $('#dlg-ativo').close(); toast(ativar ? 'Usuário reativado.' : 'Usuário desativado.'); await carregarUsuarios(); });
      });
      $('#cred-copiar').addEventListener('click', async () => {
        try { await navigator.clipboard.writeText($('#cred-copiar').dataset.texto || ''); toast('Dados copiados.'); } catch { toast('Não foi possível copiar. Selecione e copie manualmente.', true); }
      });
      $('#dlg-credencial').addEventListener('close', () => { $('#cred-dados').innerHTML = ''; $('#cred-copiar').dataset.texto = ''; });

      // setores
      $('#set-novo').addEventListener('click', () => abrirSetor(null));
      $('#tbody-set').addEventListener('click', (ev) => { const b = ev.target.closest('[data-sid]'); if (b) abrirSetor(painel.setores.find((s) => String(s.id) === b.dataset.sid)); });
      $('#form-setor').addEventListener('submit', (ev) => {
        ev.preventDefault(); const form = ev.target;
        enviar(form, () => rpc('painel_salvar_setor', { p_id: form.dataset.id ? Number(form.dataset.id) : null, p_nome: form.nome.value, p_ativo: form.ativo.checked }),
          async () => { $('#dlg-setor').close(); toast('Setor salvo.'); painel.setores = []; LP.limparSetores(); await carregarSetores(); });
      });

      // parâmetros
      $('#lista-param').addEventListener('submit', async (ev) => {
        ev.preventDefault(); const form = ev.target, btn = $('button', form); btn.disabled = true;
        try {
          const r = await rpc('painel_definir_parametro', { p_chave: form.dataset.chave, p_valor: String(form.valor.value) });
          toast(r.alterado ? 'Regra salva. Vale para os próximos protocolos.' : 'Nada mudou.');
        } catch (e) { falha(e); } finally { btn.disabled = false; }
      });

      // feriados
      $('#form-feriado').addEventListener('submit', async (ev) => {
        ev.preventDefault(); const form = ev.target;
        try { await rpc('painel_salvar_feriado', { p_data: form.data.value, p_descricao: form.descricao.value }); form.reset(); toast('Feriado cadastrado.'); await carregarFeriados(); } catch (e) { falha(e); }
      });
      $('#tbody-fer').addEventListener('click', async (ev) => {
        const b = ev.target.closest('[data-fdata]'); if (!b) return;
        try { await rpc('painel_remover_feriado', { p_data: b.dataset.fdata }); toast('Feriado removido.'); await carregarFeriados(); } catch (e) { falha(e); }
      });
    }

    return { ligar, abrirAuditoria, abrirPainel };
  };
})();
