-- =====================================================================
-- MIGRAÇÃO 15 — Corrige a abertura do detalhe de um protocolo a partir da Trilha de auditoria
-- Rode DEPOIS da 14 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- PROBLEMA ENCONTRADO: ao clicar no número de um protocolo numa linha da Trilha de auditoria,
-- o sistema buscava o detalhe em public.v_livro — a mesma visão usada pelo Livro de protocolos,
-- que (de propósito, desde a migração 13) deixa de listar os registros com ambiente = 'teste'
-- para quem não tem autorização de ver teste (ou não marcou "Incluir registros de teste").
-- Isso é certo para o Livro (é só uma preferência de EXIBIÇÃO), mas é ERRADO para abrir o
-- detalhe a partir da Trilha: a Trilha já mostra livremente a QUALQUER gestor todas as ações,
-- inclusive as de um protocolo de teste (essa é a garantia que nunca muda) — então o link
-- "número do protocolo" dali não pode esbarrar num filtro pensado para outra tela e aparecer
-- como "Protocolo não encontrado.", dando a falsa impressão de que o registro sumiu ou foi
-- perdido. Nada foi perdido: o protocolo e todo o seu histórico sempre estiveram no banco;
-- só a tela de detalhe estava aplicando um filtro indevido.
--
-- CORREÇÃO: quem pode abrir o detalhe de um protocolo continua sendo decidido só pela
-- permissão de papel em public.pode_ver_protocolo() (já aplicada via RLS na tabela
-- public.protocolos/tramites/etc.) — nunca pelo ambiente. Para isso, a consulta que hoje está
-- dentro da view public.v_livro foi dividida em duas:
--   • public.v_livro_detalhe: as mesmas colunas/cálculos de sempre, sem o filtro de ambiente
--     (a autorização continua vindo só da RLS de public.protocolos) — usada por
--     detalhe_protocolo() para abrir qualquer protocolo que o usuário tenha permissão de ver,
--     seja de produção ou de teste.
--   • public.v_livro: agora é só um filtro em cima de v_livro_detalhe, com a mesma regra de
--     sempre (só produção, por padrão, para quem não é a conta de teste nem o gestor que
--     escolheu incluir teste) — continua sendo a visão usada pelo Livro, pelos relatórios e
--     pelo sino de pendências, sem nenhuma mudança de comportamento ali.
-- =====================================================================

drop view if exists public.v_livro;
drop view if exists public.v_livro_detalhe;

create view public.v_livro_detalhe with (security_invoker = true) as
select p.id, p.numero, p.status, p.created_at,
       coalesce((select c.descricao_nova from public.correcoes_descricao c
                  where c.protocolo_id = p.id order by c.id desc limit 1), p.descricao) as descricao,
       (select count(*) from public.correcoes_descricao c where c.protocolo_id = p.id)::int as n_correcoes,
       t1.recebido_em as e1_em, t1.usuario_nome as e1_usuario, t1.assinatura_tipo as e1_tipo,
       (t1.assinatura_png is not null) as e1_png,
       t2.recebido_em as e2_em, t2.usuario_nome as e2_usuario, t2.assinatura_tipo as e2_tipo,
       (t2.assinatura_png is not null) as e2_png,
       t3.recebido_em as e3_em, t3.usuario_nome as e3_usuario, t3.assinatura_tipo as e3_tipo,
       (t3.assinatura_png is not null) as e3_png, t3.setor_nome as e3_setor,
       p.tipo, p.urgente, p.prazo_data,
       public._dias_restantes(p.prazo_data, p.status) as dias_restantes,
       public._semaforo(p.prazo_data, p.status) as semaforo,
       p.setor_destino_id, sd.nome as setor_destino_nome, p.sla_limite,
       (p.status <> 'concluido' and p.sla_limite is not null and now() > p.sla_limite) as sla_estourado,
       case p.status when 'pendente_adm' then t1.recebido_em
                     when 'pendente_setor' then coalesce((select max(m.em) from public.movimentacoes m where m.protocolo_id = p.id), t2.recebido_em)
       end as aguardando_desde,
       (select count(*) from public.protocolo_fotos f where f.protocolo_id = p.id)::int as n_fotos,
       p.devolvido,
       (select m.de_setor_nome from public.movimentacoes m where m.protocolo_id = p.id and p.devolvido order by m.id desc limit 1) as devolvido_por,
       (select count(*) from public.movimentacoes m where m.protocolo_id = p.id)::int as n_movimentacoes,
       p.ambiente
  from public.protocolos p
  left join public.tramites t1 on t1.protocolo_id = p.id and t1.etapa = 1
  left join public.tramites t2 on t2.protocolo_id = p.id and t2.etapa = 2
  left join public.tramites t3 on t3.protocolo_id = p.id and t3.etapa = 3
  left join public.setores sd on sd.id = p.setor_destino_id;
-- security_invoker = true: quem pode enxergar cada linha continua sendo decidido só pela política de
-- RLS p_protocolos_select (public.pode_ver_protocolo), a mesma de sempre — nenhum filtro extra aqui.
grant select on public.v_livro_detalhe to authenticated;

create view public.v_livro with (security_invoker = true) as
select * from public.v_livro_detalhe b
 where case public._visibilidade_teste()
         -- conta técnica de teste: só enxerga (e só mexe n)os próprios protocolos de teste,
         -- isolados dos de produção — nunca mistura com o trabalho real da equipe.
         when 'teste' then b.ambiente = 'teste'
         -- gestor autorizado a ver teste: enxerga os dois aqui; o padrão "só produção" é aplicado
         -- em listar_livro/resumo_livro/minhas_pendencias (telas de uso diário), nunca escondido de verdade.
         when 'todos' then true
         else b.ambiente = 'producao'
       end;
grant select on public.v_livro to authenticated;

-- detalhe_protocolo: agora busca em v_livro_detalhe (sem filtro de ambiente) — abre qualquer
-- protocolo que o usuário tenha permissão de ver, de produção ou de teste, exatamente como a
-- Trilha de auditoria já mostra as ações de ambos sem distinção.
create or replace function public.detalhe_protocolo(p_id bigint) returns jsonb
language plpgsql stable security invoker set search_path = public as $$
declare v jsonb;
begin
  select to_jsonb(x) into v from public.v_livro_detalhe x where x.id = p_id;
  if v is null then return null; end if;
  return v || jsonb_build_object(
    'descricao_original', (select descricao from public.protocolos where id = p_id),
    'etapas', coalesce((select jsonb_agg(jsonb_build_object(
                'etapa', t.etapa, 'recebido_em', t.recebido_em, 'usuario', t.usuario_nome,
                'setor', t.setor_nome, 'assinatura_tipo', t.assinatura_tipo,
                'assinatura_png', t.assinatura_png, 'selo', t.selo) order by t.etapa)
                from public.tramites t where t.protocolo_id = p_id), '[]'::jsonb),
    'correcoes', coalesce((select jsonb_agg(jsonb_build_object(
                'corrigido_em', c.corrigido_em, 'usuario', c.usuario_nome, 'anterior', c.descricao_anterior,
                'nova', c.descricao_nova, 'justificativa', c.justificativa) order by c.id)
                from public.correcoes_descricao c where c.protocolo_id = p_id), '[]'::jsonb),
    'prazos', coalesce((select jsonb_agg(jsonb_build_object(
                'ajustado_em', h.ajustado_em, 'usuario', h.usuario_nome, 'anterior', h.prazo_anterior,
                'novo', h.prazo_novo, 'justificativa', h.justificativa) order by h.id)
                from public.prazo_historico h where h.protocolo_id = p_id), '[]'::jsonb),
    'movimentacoes', coalesce((select jsonb_agg(jsonb_build_object(
                'tipo', m.tipo, 'em', m.em, 'usuario', m.usuario_nome, 'de', m.de_setor_nome, 'para', m.para_setor_nome,
                'justificativa', m.justificativa) order by m.id)
                from public.movimentacoes m where m.protocolo_id = p_id), '[]'::jsonb),
    'fotos', coalesce((select jsonb_agg(jsonb_build_object('caminho', f.caminho, 'enviado_em', f.enviado_em) order by f.id)
                from public.protocolo_fotos f where f.protocolo_id = p_id), '[]'::jsonb));
end $$;

create or replace function public.painel_diagnostico() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_itens jsonb := '[]'::jsonb; v_aux text; v_n int; v_t text; v_sem text := '';
  v_arquivos int := 15;
begin
  -- cada item tem nivel: ok | aviso | erro
  -- Versão do banco
  select max(versao) into v_n from public.schema_versao;
  v_itens := v_itens || jsonb_build_object('grupo', 'Banco de dados', 'item', 'Versão do banco',
     'nivel', case when v_n = v_arquivos then 'ok' else 'erro' end,
     'detalhe', case when v_n = v_arquivos then 'Atualizado (' || v_n || ' de ' || v_arquivos || ').'
                     else 'Versão ' || coalesce(v_n::text, '?') || ' de ' || v_arquivos || '. Rode o instalacao_completa.sql no SQL Editor.' end);

  -- RLS em todas as tabelas
  select string_agg(c.relname, ', ' order by c.relname) into v_aux
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Proteção por linha (RLS) em todas as tabelas',
     'nivel', case when v_aux is null then 'ok' else 'erro' end,
     'detalhe', coalesce('Sem proteção: ' || v_aux, 'Todas as tabelas protegidas.'));

  -- acesso direto negado
  v_aux := null;
  foreach v_t in array array['protocolos', 'tramites', 'perfis', 'auditoria', 'parametros', 'fila_email', 'email_brevo', 'push_inscricoes', 'push_config', 'integracao'] loop
    if to_regclass('public.' || v_t) is not null then
      if has_table_privilege('anon', 'public.' || v_t, 'select') or has_table_privilege('anon', 'public.' || v_t, 'insert') then
        v_aux := coalesce(v_aux || ', ', '') || v_t || ' (visitante)';
      end if;
    end if;
  end loop;
  foreach v_t in array array['email_brevo', 'push_inscricoes', 'push_config', 'integracao', 'fila_email'] loop
    if to_regclass('public.' || v_t) is not null and has_table_privilege('authenticated', 'public.' || v_t, 'select') then
      v_aux := coalesce(v_aux || ', ', '') || v_t || ' (usuário logado)';
    end if;
  end loop;
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Acesso direto às tabelas sensíveis bloqueado',
     'nivel', case when v_aux is null then 'ok' else 'erro' end,
     'detalhe', coalesce('Acesso indevido: ' || v_aux, 'Visitantes e usuários só usam as funções do sistema.'));

  -- cadeia da trilha
  v_aux := (public.verificar_auditoria() ->> 'ok');
  v_itens := v_itens || jsonb_build_object('grupo', 'Segurança', 'item', 'Trilha de auditoria íntegra',
     'nivel', case when v_aux = 'true' then 'ok' else 'erro' end,
     'detalhe', case when v_aux = 'true' then 'Cadeia de hashes conferida.' else 'ADULTERAÇÃO DETECTADA. Use "Verificar trilha" na aba Auditoria.' end);

  -- quem opera o sistema
  select count(*) into v_n from public.perfis where ativo and papel = 'gestor';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Gestor ativo',
     'nivel', case when v_n >= 1 then 'ok' else 'erro' end, 'detalhe', v_n || ' gestor(es) ativo(s).');
  select count(*) into v_n from public.perfis where ativo and papel = 'adm';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'ADM ativo (recebe os avisos de chegada)',
     'nivel', case when v_n >= 1 then 'ok' else 'erro' end, 'detalhe', v_n || ' ADM ativo(s).');
  select count(*) into v_n from public.perfis where ativo and papel = 'portaria';
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Portaria ativa',
     'nivel', case when v_n >= 1 then 'ok' else 'aviso' end, 'detalhe', v_n || ' usuário(s) da Portaria.');
  select string_agg(s.nome, ', ' order by s.nome) into v_aux from public.setores s
   where s.ativo and not exists (select 1 from public.perfis p where p.ativo and p.papel = 'super_setor' and p.setor_id = s.id);
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Todo setor ativo tem responsável',
     'nivel', case when v_aux is null then 'ok' else 'aviso' end, 'detalhe', coalesce('Sem responsável: ' || v_aux, 'Todos os setores ativos têm responsável.'));
  select count(*) into v_n from public.perfis where ativo and email is null;
  v_itens := v_itens || jsonb_build_object('grupo', 'Usuários e setores', 'item', 'Usuários com e-mail cadastrado',
     'nivel', case when v_n = 0 then 'ok' else 'aviso' end, 'detalhe', case when v_n = 0 then 'Todos podem receber avisos.' else v_n || ' usuário(s) sem e-mail não recebem avisos.' end);

  -- e-mail
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Endereço do sistema nos e-mails',
     'nivel', case when public._param_text('url_sistema', '') <> '' then 'ok' else 'aviso' end,
     'detalhe', case when public._param_text('url_sistema', '') <> '' then public._param_text('url_sistema', '') else 'Preencha em Sistema > Prazos e regras, para o e-mail trazer o link.' end);
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Extensão pg_net (envio imediato)',
     'nivel', case when exists (select 1 from pg_extension where extname = 'pg_net') then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from pg_extension where extname = 'pg_net') then 'Ativa.' else 'Ative em Database > Extensions > pg_net.' end);
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'Brevo configurado',
     'nivel', case when exists (select 1 from public.email_brevo where ativo) then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from public.email_brevo where ativo) then 'Remetente: ' || (select remetente_email from public.email_brevo where ativo)
                     else 'Sem envio imediato. Veja o GUIA_BREVO.md.' end);
  select count(*) into v_n from public.fila_email where status = 'erro';
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos por e-mail', 'item', 'E-mails com erro',
     'nivel', case when v_n = 0 then 'ok' else 'aviso' end,
     'detalhe', case when v_n = 0 then 'Nenhum.' else v_n || ' com erro. Último: ' || coalesce((select left(erro, 120) from public.fila_email where status = 'erro' order by id desc limit 1), '?') end);

  -- push
  v_itens := v_itens || jsonb_build_object('grupo', 'Avisos no aparelho', 'item', 'Notificações no celular (Web Push)',
     'nivel', case when exists (select 1 from public.push_config where ativo) then 'ok' else 'aviso' end,
     'detalhe', case when exists (select 1 from public.push_config where ativo)
                     then (select count(distinct user_id) from public.push_inscricoes) || ' usuário(s) com aparelho ativado.'
                     else 'Opcional. Veja o GUIA_AVISOS_NO_CELULAR.md.' end);

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_itens) i where i->>'nivel' = 'erro'),
    'erros', (select count(*) from jsonb_array_elements(v_itens) i where i->>'nivel' = 'erro'),
    'avisos', (select count(*) from jsonb_array_elements(v_itens) i where i->>'nivel' = 'aviso'),
    'itens', v_itens, 'gerado_em', now());
end $$;

insert into public.schema_versao (versao, arquivo) values (15, '15_corrigir_detalhe_teste.sql') on conflict (versao) do nothing;
