-- =====================================================================
-- MIGRAÇÃO 14 — Ajustes do ambiente de testes, blindagem de e-mail e
--               padronização visual de todos os e-mails do sistema.
-- Rode DEPOIS da 13 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- O que muda:
--   1) Qualquer gestor (não só um e-mail fixo) agora pode marcar uma conta como "conta de
--      teste" e usar o filtro "Incluir registros de teste" no Livro/relatórios. A trilha de
--      auditoria continua, como sempre, mostrando TODOS os atos a TODOS os gestores — isso
--      nunca muda (ver nota de recusa enviada junto com esta migração).
--   2) Nenhuma ação sobre um protocolo marcado como "ambiente de teste" dispara e-mail —
--      agora a verificação é centralizada em _enfileirar_email() e vale para qualquer rota
--      futura (recebimento do ADM, do setor, devolução, reencaminhamento, avisos de prazo/SLA),
--      não só para o registro inicial.
--   3) Todo e-mail enviado pelo sistema passa a ter também uma versão HTML com a mesma
--      identidade visual (cabeçalho, tipografia e rodapé), em vez de texto simples.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Ambiente de teste: controle passa a valer para qualquer gestor ativo
-- ---------------------------------------------------------------------
create or replace function public._pode_ver_teste(p_perfil public.perfis) returns boolean
language sql immutable as $$
  select p_perfil.papel = 'gestor'
$$;

-- ---------------------------------------------------------------------
-- 2. E-mail: nenhuma ação sobre protocolo de teste enfileira e-mail, em nenhuma rota
--    (centralizado aqui; os ~15 pontos de chamada em CHEGADA/ENCAMINHADO/REENCAMINHADO/
--    DEVOLVIDO/SLA/PRAZO_* não precisam mudar).
-- ---------------------------------------------------------------------
create or replace function public._enfileirar_email(
  p_chave text, p_evento text, p_pid bigint, p_dest text[], p_assunto text, p_corpo text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_ambiente text;
begin
  if p_dest is null or cardinality(p_dest) = 0 then return false; end if;
  if p_pid is not null then
    select ambiente into v_ambiente from public.protocolos where id = p_pid;
    if v_ambiente = 'teste' then return false; end if;
  end if;
  insert into public.fila_email (chave, evento, protocolo_id, destinatarios, assunto, corpo, corpo_html)
  values (p_chave, p_evento, p_pid, p_dest, p_assunto, p_corpo, public._texto_para_html_email(p_assunto, p_corpo))
  on conflict (chave) do nothing returning id into v_id;
  return v_id is not null;
end $$;

-- ---------------------------------------------------------------------
-- 3. Padronização visual: qualquer e-mail de texto simples ganha uma versão HTML
--    com a mesma identidade do e-mail de boas-vindas (cabeçalho azul, cartão branco,
--    rodapé em cinza-claro), sem precisar mudar nenhum dos pontos que montam o texto.
-- ---------------------------------------------------------------------
create or replace function public._texto_para_html_email(p_assunto text, p_corpo text) returns text
language sql immutable as $$
  select
    '<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8">'
    || '<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light">'
    || '<title>' || public._html_esc(p_assunto) || '</title></head>'
    || '<body style="margin:0;padding:0;background:#eef2f6;">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#eef2f6"><tr><td align="center" style="padding:28px 12px;">'
    || '<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" '
    ||   'style="width:100%;max-width:600px;background:#ffffff;border-radius:10px;overflow:hidden;border:1px solid #d3dce5;">'
    -- cabeçalho
    || '<tr><td bgcolor="#1f4e6e" style="padding:20px 30px;background:#1f4e6e;">'
    ||   '<div style="font-family:Segoe UI,Helvetica,Arial,sans-serif;font-size:19px;font-weight:600;color:#ffffff;letter-spacing:.3px;">'
    ||   'Livro de Protocolo Eletrônico</div></td></tr>'
    -- corpo (o texto simples já vem formatado em linhas; white-space:pre-line preserva as quebras)
    || '<tr><td style="padding:30px 36px 20px;font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#1b2733;'
    ||   'font-size:14.5px;line-height:1.7;white-space:pre-line;">' || public._html_esc(p_corpo) || '</td></tr>'
    -- rodapé
    || '<tr><td bgcolor="#f4f7fa" style="padding:14px 36px;background:#f4f7fa;border-top:1px solid #e1e8ef;'
    ||   'font-family:Segoe UI,Helvetica,Arial,sans-serif;font-size:11.5px;color:#7a8896;text-align:center;">'
    ||   'Mensagem automática. Não responda a este e-mail.</td></tr>'
    || '</table></td></tr></table></body></html>'
$$;

-- ---------------------------------------------------------------------
-- 4. Diagnóstico da instalação: contagem de arquivos aplicados (12 → 13 → 14)
-- ---------------------------------------------------------------------
create or replace function public.painel_diagnostico() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor();
  v_itens jsonb := '[]'::jsonb; v_aux text; v_n int; v_t text; v_sem text := '';
  v_arquivos int := 14;
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

insert into public.schema_versao (versao, arquivo) values (14, '14_melhorias_teste_assinatura_email.sql') on conflict (versao) do nothing;

revoke all on function public._texto_para_html_email(text, text) from public, anon, authenticated;
