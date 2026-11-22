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
      prazo: 'Prazo / aviso', impressao: 'Impressão', seguranca: 'Segurança', administracao: 'Administração',
    };
    const ACOES = {
      LOGIN: 'Entrou no sistema', LOGOUT: 'Saiu do sistema', LOGOUT_INATIVIDADE: 'Sessão encerrada por inatividade',
      FALHA_PIN: 'PIN incorreto', USUARIO_BLOQUEADO: 'PIN bloqueado',
      PROTOCOLO_CRIADO: 'Protocolo registrado (1ª etapa)', RECEBIMENTO_ADM: 'Recebimento do ADM (2ª etapa)',
      RECEBIMENTO_SETOR: 'Recebimento do setor (3ª etapa)', DESCRICAO_CORRIGIDA: 'Descrição corrigida',
      PRAZO_AJUSTADO: 'Prazo ajustado', ALERTA_SLA: 'Aviso: tempo máximo excedido', ALERTA_PRAZO_VENCIDO: 'Aviso: prazo vencido',
      ALERTA_PRAZO_PROXIMO: 'Aviso: prazo próximo', IMPRESSAO_FICHA: 'Ficha impressa', IMPRESSAO_LIVRO: 'Livro impresso',
      IMPRESSAO_TRILHA: 'Trilha impressa/exportada', PIN_ALTERADO: 'PIN alterado pelo próprio usuário',
      SENHA_ALTERADA: 'Senha alterada pelo próprio usuário', PIN_REDEFINIDO: 'PIN redefinido pelo gestor',
      PIN_DESBLOQUEADO: 'PIN desbloqueado', SENHA_REDEFINIDA: 'Senha redefinida pelo gestor', USUARIO_CRIADO: 'Usuário criado',
      USUARIO_ATUALIZADO: 'Usuário atualizado', USUARIO_ATIVADO: 'Usuário reativado', USUARIO_DESATIVADO: 'Usuário desativado',
      SETOR_SALVO: 'Setor salvo', PARAMETRO_ALTERADO: 'Regra/parâmetro alterado', FERIADO_SALVO: 'Feriado cadastrado',
      FERIADO_REMOVIDO: 'Feriado removido', PARAMETROS_ALTERADOS: 'Regras e prazos alterados', LOGO_ALTERADO: 'Logotipo do sistema alterado',
      PROTOCOLO_EXCLUIDO: 'Protocolo excluído', TRILHA_EXCLUIDA: 'Registros da trilha excluídos', PERFIL_CADASTRADO: 'Perfil cadastrado (SQL)', PERFIL_DESATIVADO: 'Perfil desativado (SQL)',
      PERFIL_REATIVADO: 'Perfil reativado (SQL)', SEGREDO_INTEGRACAO_DEFINIDO: 'Segredo dos e-mails definido',
    };

    // ---------- parâmetros: rótulos, formatos de hora e de duração (espelham as regras do banco)
    const ROTULO_PARAM = {
      prazo_judicial_dias: 'Prazo das demandas judiciais', prazo_correspondencia_dias: 'Prazo das correspondências',
      sla_adm_min: 'Tempo máximo do ADM', sla_adm_urgente_min: 'Tempo máximo do ADM (urgente)',
      sla_setor_min: 'Tempo máximo do setor', sla_setor_urgente_min: 'Tempo máximo do setor (urgente)',
      expediente_inicio: 'Início do expediente', expediente_fim: 'Fim do expediente', alerta_prazo_dias: 'Avisar com antecedência (dias)',
      foto_obrigatoria_judicial: 'Foto obrigatória nas demandas judiciais', gestor_ignora_segregacao: 'Gestor assina mais de uma etapa',
      url_sistema: 'Endereço do sistema',
    };
    // "H:MM" (como o banco guarda) → minutos
    const minDeHM = (v) => { const m = /^(\d{1,3}):(\d{2})$/.exec(String(v)); return m ? Number(m[1]) * 60 + Number(m[2]) : null; };
    // minutos → "4h30", "2h", "45min"
    const fmtDur = (min) => { const h = Math.floor(min / 60), m = min % 60; return h && m ? `${h}h${String(m).padStart(2, '0')}` : h ? `${h}h` : `${m}min`; };
    // interpreta o que o usuário digitou: 4h30 · 4:30 · 90min · 1,5 (horas) · 2 horas · 1d (jornada)
    function lerDuracao(txt, jornada) {
      const v = String(txt || '').trim().toLowerCase().replace(',', '.'); let m;
      if ((m = /^(\d{1,3}):(\d{2})$/.exec(v))) return Number(m[2]) > 59 ? null : Number(m[1]) * 60 + Number(m[2]);
      if ((m = /^(\d{1,3}(?:\.\d{1,2})?)$/.exec(v))) return Math.round(parseFloat(m[1]) * 60);
      if ((m = /^(\d{1,3})\s*(?:h|hr|hrs|hora|horas)(?:\s*(\d{1,2})\s*(?:m|min|minutos?)?)?$/.exec(v))) return Number(m[2] || 0) > 59 ? null : Number(m[1]) * 60 + Number(m[2] || 0);
      if ((m = /^(\d{1,5})\s*(?:m|min|minuto|minutos)$/.exec(v))) return Number(m[1]);
      if ((m = /^(\d{1,2}(?:\.\d)?)\s*(?:d|dia|dias)$/.exec(v))) return Math.round(parseFloat(m[1]) * jornada);
      return null;
    }
    const valorParam = (chave, v) => {
      if (/^sla_.*_min$/.test(chave)) { const m = minDeHM(v); return m == null ? String(v) : fmtDur(m); }
      if (chave === 'foto_obrigatoria_judicial' || chave === 'gestor_ignora_segregacao') return v === 'true' ? 'sim' : 'não';
      return String(v);
    };
    const PAPEIS = { portaria: 'Portaria', adm: 'ADM', super_setor: 'Setor de destino', gestor: 'Gestor' };
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
        case 'ALERTA_PRAZO_PROXIMO': add(`${d.dias === 1 ? 'falta 1 dia' : `faltam ${d.dias} dias`} para o prazo`); break;
        case 'ALERTA_PRAZO_VENCIDO': add('prazo vencido sem conclusão'); break;
        case 'IMPRESSAO_FICHA': add(d.numero ? `protocolo ${d.numero}` : ''); break;
        case 'IMPRESSAO_LIVRO': case 'IMPRESSAO_TRILHA': add(`filtros: ${d.filtros || 'nenhum'}`); break;
        case 'USUARIO_BLOQUEADO': add('5 PINs incorretos seguidos: bloqueio de 5 minutos'); break;
        case 'USUARIO_CRIADO': add(`${d.nome} (${d.email})`); add(`perfil: ${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''}`); add(d.conta_nova === false ? 'conta já existia no Auth' : ''); break;
        case 'USUARIO_ATUALIZADO':
          add(`${d.nome_anterior || ''}${d.nome_anterior !== d.nome ? ` → ${d.nome}` : ''} (${d.email || ''})`);
          add(`perfil: ${PAPEIS[d.papel_anterior] || d.papel_anterior} → ${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''}`); break;
        case 'USUARIO_ATIVADO': case 'USUARIO_DESATIVADO': case 'SENHA_REDEFINIDA': case 'PIN_REDEFINIDO': case 'PIN_DESBLOQUEADO':
          add(`${d.nome || ''} (${d.email || ''})`); break;
        case 'SETOR_SALVO': add(`${d.setor} — ${d.ativo ? 'ativo' : 'inativo'}${d.novo ? ' (novo)' : ''}`); break;
        case 'PARAMETRO_ALTERADO': add(`${ROTULO_PARAM[d.chave] || d.chave}: ${d.anterior != null ? `${valorParam(d.chave, d.anterior)} → ` : ''}${valorParam(d.chave, d.valor)}`); break;
        case 'PARAMETROS_ALTERADOS':
          Object.entries(d.alteracoes || {}).forEach(([k, v]) => add(`${(ROTULO_PARAM[k] || k)}: ${v.anterior != null ? `${valorParam(k, v.anterior)} → ` : ''}${valorParam(k, v.valor)}`)); break;
        case 'LOGO_ALTERADO': add(d.acao || ''); break;
        case 'PROTOCOLO_EXCLUIDO':
          add(`protocolo ${d.numero || ''}`); add(`${d.tipo === 'judicial' ? 'demanda judicial' : 'correspondência'}, ${pl(d.etapas_registradas ?? 0, 'etapa', 'etapas')}${d.fotos ? ', com foto' : ''}`);
          if (d.trilha_removida) add(`${pl(d.trilha_removida, 'evento removido', 'eventos removidos')} da trilha`); add(`justificativa: ${d.justificativa}`); break;
        case 'TRILHA_EXCLUIDA':
          add(`${pl(d.removidos, 'evento removido', 'eventos removidos')} — ${d.modo === 'tudo' ? 'toda a trilha' : `período de ${dia(d.de)} a ${dia(d.ate)}`}`); add(`justificativa: ${d.justificativa}`); break;
        case 'FERIADO_SALVO': case 'FERIADO_REMOVIDO': add(`${dia(d.data)} — ${d.descricao}`); break;
        case 'PERFIL_CADASTRADO': add(`${d.email} (${PAPEIS[d.papel] || d.papel}${d.setor ? ` — ${d.setor}` : ''})`); break;
        case 'PERFIL_DESATIVADO': case 'PERFIL_REATIVADO': add(d.email); break;
        default:
          Object.entries(d || {}).forEach(([k, v]) => add(`${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`));
      }
      return L.filter(Boolean).join(' · ');
    }

    // número do protocolo; se ele foi excluído, o número vem do registro da exclusão ou aparece "(excluído)"
    const textoProt = (x, vazio = '—') => {
      const n = x.numero || (x.detalhes && x.detalhes.numero);
      if (x.numero) return x.numero;
      return n ? `${n} (excluído)` : (x.protocolo_id ? '(excluído)' : vazio);
    };
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
          <td>${x.numero ? `<button type="button" class="link" data-prot="${esc(x.protocolo_id)}">${esc(x.numero)}</button>` : esc(textoProt(x)) }</td>
          <td class="detalhes">${esc(resumo(x.acao, x.detalhes))}</td></tr>`).join('')
          || '<tr><td colspan="6" class="vazio">Nenhum evento encontrado com estes filtros.</td></tr>';
        const paginas = Math.max(1, Math.ceil(r.total / aud.por));
        $('#aud-contagem').textContent = pl(r.total, 'evento', 'eventos');
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
            ACOES[x.acao] || x.acao, textoProt(x, ''), resumo(x.acao, x.detalhes)].map(celulaCsv).join(';')));
        const blob = new Blob([`﻿${linhas.join('\r\n')}`], { type: 'text/csv;charset=utf-8' });
        const a = document.createElement('a'); a.href = URL.createObjectURL(blob);
        a.download = `trilha-auditoria-${new Date().toISOString().slice(0, 10)}.csv`; document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 4000);
        toast(`${pl(itens.length, 'evento exportado', 'eventos exportados')}${aud.total > itens.length ? ` de ${aud.total} (limite de 5000)` : ''}.`);
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
          <td>${esc(x.usuario_nome || 'Sistema')}</td><td><b>${esc(ACOES[x.acao] || x.acao)}</b></td><td>${esc(textoProt(x))}</td>
          <td class="d">${esc(resumo(x.acao, x.detalhes))}</td></tr>`).join('');
        LP.imprimir('livro', `${LP.cabecalhoImpressao('TRILHA DE AUDITORIA')}
          <p class="p-meta">Filtros: ${esc(desc || 'nenhum')} · Eventos: ${aud.total}${aud.total > itens.length ? ` (impressos os ${itens.length} mais recentes)` : ''}
            · Emitido por ${esc(LP.estado().perfil.nome)} em ${data(agora)} ${hora(agora)}</p>
          <table class="p-tab"><colgroup>${[0, 1, 2, 3, 4, 5].map((i) => `<col class="t${i}">`).join('')}</colgroup>
            <thead><tr><th>Data e hora</th><th>Tipo</th><th>Usuário</th><th>Ação</th><th>Protocolo</th><th>O que aconteceu</th></tr></thead>
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
    const pl = (n, um, varios) => `${n} ${Number(n) === 1 ? um : varios}`;

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
      $('#usr-contagem').textContent = pl(l.length, 'usuário', 'usuários');
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

    // ---------- parâmetros (um único formulário, um único botão Salvar)
    const prm = { valores: {}, jornada: 540 };
    const campoDur = (chave) => `<div class="dur"><input type="text" name="${chave}" data-dur maxlength="14" inputmode="text" autocomplete="off" aria-describedby="p-${chave}">
      <small id="p-${chave}" class="dur-previa"></small></div>`;
    function montarParametros() {
      $('#param-corpo').innerHTML = `
        <div class="param-grade">
          <section class="cartao-cfg"><h3>Expediente</h3>
            <p class="dica">As horas úteis contam somente neste horário, de segunda a sexta, exceto feriados.</p>
            <div class="param-linhas two">
              <label>Início <input type="time" name="expediente_inicio" required></label>
              <label>Fim <input type="time" name="expediente_fim" required></label>
            </div><p class="param-aviso" id="p-exped" hidden></p></section>
          <section class="cartao-cfg"><h3>Prazos padrão</h3>
            <p class="dica">Em dias úteis. Para correspondências, 0 = sem prazo.</p>
            <div class="param-linhas">
              <label>Demandas judiciais <span class="un-in"><input type="number" name="prazo_judicial_dias" min="0" max="365" step="1" required><i>dias</i></span></label>
              <label>Correspondências <span class="un-in"><input type="number" name="prazo_correspondencia_dias" min="0" max="365" step="1" required><i>dias</i></span></label>
              <label>Avisar com antecedência de <span class="un-in"><input type="number" name="alerta_prazo_dias" min="0" max="365" step="1" required><i>dias</i></span></label>
            </div></section>
          <section class="cartao-cfg larga"><h3>Tempo máximo para receber (horas úteis)</h3>
            <p class="dica">Aceita 4h30, 4:30, 90min, 1,5 (horas) ou 1d (uma jornada de expediente). Ao estourar, o sistema envia aviso.</p>
            <table class="param-tab"><thead><tr><th>Etapa</th><th>Normal</th><th>Urgente</th></tr></thead><tbody>
              <tr><th scope="row">ADM recebe o documento</th><td>${campoDur('sla_adm_min')}</td><td>${campoDur('sla_adm_urgente_min')}</td></tr>
              <tr><th scope="row">Setor de destino recebe</th><td>${campoDur('sla_setor_min')}</td><td>${campoDur('sla_setor_urgente_min')}</td></tr>
            </tbody></table></section>
          <section class="cartao-cfg larga"><h3>Regras gerais</h3>
            <div class="param-linhas">
              <label class="chk neutro"><input type="checkbox" name="foto_obrigatoria_judicial"> Exigir foto do envelope nas demandas judiciais</label>
              <label class="chk neutro"><input type="checkbox" name="gestor_ignora_segregacao"> Permitir que o gestor assine mais de uma etapa do mesmo protocolo</label>
              <label>Endereço do sistema (usado nos e-mails) <input type="url" name="url_sistema" maxlength="200" placeholder="https://…"></label>
            </div></section>
        </div>`;
    }
    const valoresForm = () => {
      const f = $('#form-param'), o = {};
      Object.keys(ROTULO_PARAM).forEach((k) => {
        const el = f.elements[k]; if (!el) return;
        o[k] = el.type === 'checkbox' ? String(el.checked) : String(el.value).trim();
      });
      return o;
    };
    function preencherParametros(lista) {
      const f = $('#form-param'); prm.valores = {};
      lista.forEach((p) => { prm.valores[p.chave] = p.valor; });
      prm.jornada = Math.max(1, (hmEmMin(prm.valores.expediente_fim) - hmEmMin(prm.valores.expediente_inicio)) || 540);
      lista.forEach((p) => {
        const el = f.elements[p.chave]; if (!el) return;
        if (el.type === 'checkbox') el.checked = p.valor === 'true';
        else if (/^sla_.*_min$/.test(p.chave)) { const m = minDeHM(p.valor); el.value = m == null ? p.valor : fmtDur(m); }
        else el.value = p.valor;
      });
      atualizarParametros();
    }
    const hmEmMin = (v) => { const m = /^(\d{1,2}):(\d{2})$/.exec(String(v || '')); return m ? Number(m[1]) * 60 + Number(m[2]) : NaN; };
    function atualizarParametros() {
      const f = $('#form-param'); let invalido = false;
      const jornada = Math.max(1, (hmEmMin(f.elements.expediente_fim.value) - hmEmMin(f.elements.expediente_inicio.value)) || prm.jornada);
      $$('[data-dur]', f).forEach((el) => {
        const m = lerDuracao(el.value, jornada), prev = $(`#p-${el.name}`);
        const ok = m != null && m >= 5 && m <= 14400; el.classList.toggle('invalido', !ok);
        if (!ok) { invalido = true; prev.textContent = el.value.trim() ? 'Formato inválido (mín. 5 min)' : 'Informe o tempo'; prev.className = 'dur-previa ruim'; }
        else { prev.textContent = `= ${fmtDur(m)} · ${m} min${m >= jornada ? ` · ${(m / jornada).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} ${m / jornada === 1 ? 'dia útil' : 'dias úteis'}` : ''}`; prev.className = 'dur-previa'; }
      });
      const i = hmEmMin(f.elements.expediente_inicio.value), fim = hmEmMin(f.elements.expediente_fim.value), av = $('#p-exped');
      const exped = !(i < fim); av.hidden = !exped; av.textContent = exped ? 'O fim do expediente deve ser depois do início.' : ''; if (exped) invalido = true;
      const mudou = Object.entries(valoresForm()).some(([k, v]) => paramMudou(k, v));
      $('#param-salvar').disabled = !mudou || invalido; $('#param-descartar').disabled = !mudou;
      $('#param-estado').textContent = invalido ? 'Corrija os campos destacados para salvar.' : mudou ? 'Há alterações não salvas.' : 'Nenhuma alteração pendente.';
      $('#param-estado').classList.toggle('pendente', mudou && !invalido);
    }
    const paramMudou = (k, atual) => {
      const orig = prm.valores[k]; if (orig === undefined) return false;
      if (/^sla_.*_min$/.test(k)) { const j = lerDuracao(atual, prm.jornada); return j !== minDeHM(orig); }
      return atual !== String(orig);
    };
    async function carregarParametros() {
      try {
        if (!$('#form-param').elements.expediente_inicio) montarParametros();
        preencherParametros(await rpc('painel_listar_parametros'));
        $('#param-erro').hidden = true;
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

    // ---------- logo do sistema
    const logoEst = { novo: null };
    function mostrarLogoPrevia(src) {
      const im = $('#logo-previa'), ok = !!src;
      im.hidden = !ok; if (ok) im.src = src; else im.removeAttribute('src');
      $('#logo-padrao').hidden = ok;
    }
    // reduz a imagem escolhida (máx. 480×200) e a regrava como PNG/WebP/JPEG dentro do limite do banco
    async function prepararLogo(arq) {
      if (!/^image\/(png|jpeg|webp)$/.test(arq.type)) throw new Error('Use uma imagem PNG, JPEG ou WebP.');
      if (arq.size > 10 * 1024 * 1024) throw new Error('Imagem muito grande (máximo de 10 MB).');
      const bmp = await createImageBitmap(arq);
      const k = Math.min(1, 480 / bmp.width, 200 / bmp.height);
      const c = document.createElement('canvas'); c.width = Math.max(1, Math.round(bmp.width * k)); c.height = Math.max(1, Math.round(bmp.height * k));
      const x = c.getContext('2d'); x.drawImage(bmp, 0, 0, c.width, c.height);
      const cabe = (u) => u && u.length <= 380000 && /^data:image\/(png|jpeg|webp);base64,/.test(u);
      let u = c.toDataURL('image/png'); if (cabe(u)) return u;
      for (const q of [0.92, 0.8, 0.65]) { u = c.toDataURL('image/webp', q); if (cabe(u) && u.startsWith('data:image/webp')) return u; }
      const b = document.createElement('canvas'); b.width = c.width; b.height = c.height;       // JPEG não tem transparência: fundo branco
      const y = b.getContext('2d'); y.fillStyle = '#fff'; y.fillRect(0, 0, b.width, b.height); y.drawImage(c, 0, 0);
      for (const q of [0.9, 0.75, 0.6]) { u = b.toDataURL('image/jpeg', q); if (cabe(u)) return u; }
      throw new Error('Não foi possível reduzir a imagem o bastante. Escolha uma imagem mais simples.');
    }

    // ---------- sistema
    async function carregarSistema() {
      try {
        logoEst.novo = null; $('#logo-salvar').disabled = true; $('#logo-pin').value = ''; mostrarLogoPrevia(LP.estado().logoSrc);
        const r = await rpc('painel_resumo');
        const k = (rot, v, sub = '') => `<div class="kpi estatico"><span class="kpi-rot">${esc(rot)}</span><strong>${esc(v)}</strong><small>${esc(sub) || '&nbsp;'}</small></div>`;
        $('#sistema-kpis').innerHTML = k('Usuários ativos', r.usuarios_ativos, pl(r.usuarios_inativos, 'inativo', 'inativos'))
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
          const linhas = [['Endereço', LP.enderecoSistema()], ['Usuário de acesso (e-mail)', email]];
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

      // parâmetros: um só botão "Salvar alterações"
      const fp = $('#form-param');
      fp.addEventListener('input', atualizarParametros); fp.addEventListener('change', atualizarParametros);
      $('#param-descartar').addEventListener('click', () => { carregarParametros(); });
      fp.addEventListener('submit', async (ev) => {
        ev.preventDefault(); const btn = $('#param-salvar'), er = $('#param-erro'); btn.disabled = true; er.hidden = true;
        try {
          const env = {}; Object.entries(valoresForm()).forEach(([k, v]) => {
            if (!paramMudou(k, v)) return;
            env[k] = /^sla_.*_min$/.test(k) ? `${lerDuracao(v, prm.jornada)}min` : v;
          });
          const r = await rpc('painel_salvar_parametros', { p_valores: env });
          toast(r.alterados ? 'Alterações salvas. Valem para os próximos protocolos.' : 'Nada mudou.');
          await carregarParametros();
        } catch (e) { er.textContent = e.message; er.hidden = false; atualizarParametros(); }
      });

      // logo
      $('#logo-escolher').addEventListener('click', () => $('#logo-arquivo').click());
      $('#logo-arquivo').addEventListener('change', async (ev) => {
        const form = $('#form-logo'), arq = ev.target.files[0]; ev.target.value = ''; if (!arq) return;
        try { erroForm(form, ''); logoEst.novo = await prepararLogo(arq); mostrarLogoPrevia(logoEst.novo); $('#logo-salvar').disabled = false; }
        catch (e) { erroForm(form, e.message); }
      });
      $('#form-logo').addEventListener('submit', (ev) => {
        ev.preventDefault(); const form = ev.target;
        if (!logoEst.novo) { erroForm(form, 'Escolha uma imagem.'); return; }
        if (!form.pin.value) { erroForm(form, 'Informe o seu PIN de gestor.'); return; }
        enviar(form, () => rpc('painel_definir_logo', { p_logo: logoEst.novo, p_pin_gestor: form.pin.value }), () => {
          LP.aplicarLogo(logoEst.novo); logoEst.novo = null; $('#logo-salvar').disabled = true; form.pin.value = ''; toast('Logotipo atualizado em todo o sistema.');
        });
      });
      $('#logo-restaurar').addEventListener('click', () => {
        const form = $('#form-logo'); if (!form.pin.value) { erroForm(form, 'Informe o seu PIN de gestor para restaurar o padrão.'); return; }
        enviar(form, () => rpc('painel_remover_logo', { p_pin_gestor: form.pin.value }), () => {
          LP.aplicarLogo(null); logoEst.novo = null; mostrarLogoPrevia(null); $('#logo-salvar').disabled = true; form.pin.value = ''; toast('Logotipo padrão restaurado.');
        });
      });

      // excluir registros da trilha
      $('#aud-excluir').addEventListener('click', () => {
        const f = $('#form-limpar-trilha'); f.reset(); erroForm(f, ''); f.data_ini.disabled = false; f.data_fim.disabled = false; $('#dlg-limpar-trilha').showModal();
      });
      $('#form-limpar-trilha').addEventListener('change', (ev) => {
        if (ev.target.name !== 'modo') return; const f = ev.currentTarget, tudo = f.modo.value === 'tudo';
        f.data_ini.disabled = tudo; f.data_fim.disabled = tudo;
      });
      $('#form-limpar-trilha').addEventListener('submit', (ev) => {
        ev.preventDefault(); const f = ev.target, modo = f.modo.value;
        if (modo === 'periodo' && (!f.data_ini.value || !f.data_fim.value)) { erroForm(f, 'Informe a data inicial e a final.'); return; }
        enviar(f, () => rpc('limpar_trilha', { p_modo: modo, p_data_ini: modo === 'periodo' ? f.data_ini.value : null,
            p_data_fim: modo === 'periodo' ? f.data_fim.value : null, p_justificativa: f.justificativa.value, p_pin_gestor: f.pin.value }),
          async (r) => {
            $('#dlg-limpar-trilha').close(); aud.pagina = 1;
            toast(r.removidos ? `${pl(r.removidos, 'registro excluído', 'registros excluídos')} da trilha.` : 'Nenhum registro encontrado nesse período.');
            $('#resultado-verificacao').textContent = ''; await carregarAuditoria();
          });
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
