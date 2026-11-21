-- Testes do schema.sql. Rode via run_local.sh (usa psql, banco descartável).
\set ON_ERROR_STOP on
\set QUIET on
create schema if not exists t;

-- Executa SQL "como" um usuário (role authenticated + auth.uid()), devolvendo resultado ou 'ERRO: ...'
create or replace function t.como(p_email text, p_sql text) returns text language plpgsql as $$
declare v_res text; v_uid uuid;
begin
  select id into v_uid from auth.users where email = p_email;
  perform set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), true);
  execute 'set local role ' || case when p_email = 'anon' then 'anon' else 'authenticated' end;
  begin
    execute p_sql into v_res;
  exception when others then
    v_res := 'ERRO: ' || sqlerrm;
  end;
  reset role;
  return v_res;
end $$;

create or replace function t.afirma(p_nome text, p_ok boolean, p_detalhe text default '') returns void
language plpgsql as $$
begin
  if p_ok then raise notice 'ok   - %', p_nome;
  else raise exception 'FALHOU - %  [%]', p_nome, p_detalhe; end if;
end $$;

-- ---------------------------------------------------------------- massa de dados
insert into auth.users (email) values ('portaria@x'),('adm@x'),('jur@x'),('far@x'),('gestor@x'),('anon-sem-perfil@x');
select public.admin_cadastrar_perfil('portaria@x','Maria Portaria','portaria',null,'1111');
select public.admin_cadastrar_perfil('adm@x','João ADM','adm',null,'2222');
select public.admin_cadastrar_perfil('jur@x','Ana Jurídico','super_setor','Jurídico','3333');
select public.admin_cadastrar_perfil('far@x','Carlos Farmácia','super_setor','Farmácia','4444');
select public.admin_cadastrar_perfil('gestor@x','Paula Gestora','gestor',null,'5555');

do $$
declare r text; j jsonb; v_id bigint; v_num text;
begin
  -- 1. acesso anônimo e usuário sem perfil
  r := t.como('anon', 'select count(*)::text from public.protocolos');
  perform t.afirma('anon não lê protocolos', r like 'ERRO:%', r);
  r := t.como('anon', $q$select public.registrar_protocolo('Ofício teste 1','1111')::text$q$);
  perform t.afirma('anon não executa RPC', r like 'ERRO:%', r);
  r := t.como('anon-sem-perfil@x', 'select count(*)::text from public.protocolos');
  perform t.afirma('autenticado sem perfil enxerga 0 protocolos', r = '0', r);
  r := t.como('anon-sem-perfil@x', $q$select public.registrar_protocolo('Ofício teste 1','1111')::text$q$);
  perform t.afirma('autenticado sem perfil não registra', r like 'ERRO:%permiss%', r);

  -- 2. PIN e criação
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício nº 123/2026 - 2ª Vara Cível','9999')::text$q$);
  perform t.afirma('PIN errado retorna ok=false (sem exceção)', (r::jsonb->>'ok') = 'false', r);
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Intimação de 123.456.789-09','1111')::text$q$);
  perform t.afirma('CPF na descrição é recusado', r like 'ERRO:%CPF%', r);
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Mandado proc. 0001234-56.2026.8.20.0001 - 1ª Vara','1111')::text$q$);
  perform t.afirma('nº de processo CNJ não é confundido com CPF', (r::jsonb->>'ok') = 'true', r);
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício nº 123/2026 - 2ª Vara Cível','1111')::text$q$);
  j := r::jsonb;
  perform t.afirma('criação ok e numeração sequencial', (j->>'ok') = 'true' and j->>'numero' ~ '^\d{4}-0002$', r);
  v_id := (j->>'id')::bigint; v_num := j->>'numero';
  r := t.como('adm@x', $q$select public.registrar_protocolo('Outro ofício qualquer','2222')::text$q$);
  perform t.afirma('ADM não pode criar protocolo', r like 'ERRO:%permiss%', r);

  -- 3. sequência rígida e visibilidade do setor
  r := t.como('portaria@x', format($q$select public.confirmar_etapa(%s,2,'1111')::text$q$, v_id));
  perform t.afirma('Portaria não confirma etapa do ADM', r like 'ERRO:%permiss%', r);
  r := t.como('jur@x', format($q$select public.confirmar_etapa(%s,3,'3333')::text$q$, v_id));
  perform t.afirma('Setor não pula o ADM (e não descobre o protocolo)', r like 'ERRO:%não encontrado%', r);
  r := t.como('jur@x', $q$select (public.listar_livro()->>'total')$q$);
  perform t.afirma('Setor não vê protocolos pendentes no ADM', r = '0', r);

  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null)::text$q$, v_id));
  perform t.afirma('ADM confirma 2ª etapa', (r::jsonb->>'ok') = 'true', r);
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222')::text$q$, v_id));
  perform t.afirma('ADM não confirma duas vezes', r like 'ERRO:%', r);
  r := t.como('jur@x', $q$select (public.listar_livro()->>'total')$q$);
  perform t.afirma('Setor passa a ver o protocolo pendente_setor', r = '1', r);
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,3,'2222')::text$q$, v_id));
  perform t.afirma('ADM não confirma etapa do setor', r like 'ERRO:%permiss%', r);
  r := t.como('jur@x', format($q$select public.confirmar_etapa(%s,3,'3333')::text$q$, v_id));
  perform t.afirma('Setor confirma 3ª etapa', (r::jsonb->>'ok') = 'true', r);
  r := t.como('jur@x', format($q$select public.confirmar_etapa(%s,3,'3333')::text$q$, v_id));
  perform t.afirma('protocolo concluído não aceita novo aceite', r like 'ERRO:%conclu%', r);
  r := t.como('far@x', $q$select (public.listar_livro()->>'total')$q$);
  perform t.afirma('outro setor NÃO vê protocolo concluído em Jurídico', r = '0', r);
  r := t.como('jur@x', $q$select (public.listar_livro()->>'total')$q$);
  perform t.afirma('setor destinatário vê o seu', r = '1', r);
  r := t.como('gestor@x', format($q$select (public.detalhe_protocolo(%s)->>'status')$q$, v_id));
  perform t.afirma('status derivado = concluido', r = 'concluido', r);
  r := t.como('gestor@x', format($q$select jsonb_array_length(public.detalhe_protocolo(%s)->'etapas')::text$q$, v_id));
  perform t.afirma('detalhe traz as 3 etapas', r = '3', r);
  r := t.como('far@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('detalhe oculto para outro setor', r = 'true', r);

  -- 4. escrita direta e imutabilidade
  r := t.como('gestor@x', $q$insert into public.protocolos (numero,descricao,status,created_by) values ('9999-0001','abcdef','pendente_adm', auth.uid())$q$);
  perform t.afirma('cliente não insere direto em protocolos', r like 'ERRO:%', r);
  r := t.como('portaria@x', format($q$update public.protocolos set descricao='adulterada' where id=%s$q$, v_id));
  perform t.afirma('cliente não atualiza protocolos', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$delete from public.tramites$q$);
  perform t.afirma('cliente não apaga tramites', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select pin_hash from public.perfis$q$);
  perform t.afirma('cliente não lê pin_hash', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select count(*)::text from public.perfis$q$);
  perform t.afirma('contagem de perfis permitida ao gestor', r = '5', r);
  r := t.como('portaria@x', $q$select count(*)::text from public.perfis$q$);
  perform t.afirma('portaria só vê o próprio perfil', r = '1', r);
  r := t.como('portaria@x', $q$select count(*)::text from public.sequencias$q$);
  perform t.afirma('sequencias inacessível ao cliente', r like 'ERRO:%', r);

  -- como dono do banco (service_role / SQL Editor): triggers continuam valendo
  begin update public.tramites set recebido_em = '2000-01-01' where protocolo_id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia UPDATE em tramites (mesmo para o dono)', true);
  begin delete from public.tramites where protocolo_id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia DELETE em tramites', true);
  begin update public.protocolos set descricao = 'x adulterada' where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia alterar descrição original', true);
  begin update public.protocolos set numero = '1999-0001' where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia alterar número', true);
  begin update public.protocolos set status = 'pendente_adm' where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia regressão de status', true);
  begin delete from public.protocolos where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia DELETE em protocolos', true);
  begin truncate public.auditoria;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia TRUNCATE na auditoria', true);
  begin update public.auditoria set acao = 'X';
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('trigger bloqueia UPDATE na auditoria', true);

  -- sequência garantida também no banco: etapa 3 direto num protocolo só com a 1ª
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Carta A.R. Correios','1111')::text$q$);
  v_id := (r::jsonb->>'id')::bigint;
  begin
    insert into public.tramites (protocolo_id, etapa, usuario_id, usuario_nome, setor_id, setor_nome, assinatura_tipo, selo)
    values (v_id, 3, (select id from auth.users limit 1), 'x', 1, 'x', 'pin', 'x');
    raise exception 'não deveria permitir';
  exception when sqlstate '23514' then null; end;
  perform t.afirma('trigger impede etapa 3 sem a etapa 2', true);

  -- 5. correção de descrição
  r := t.como('portaria@x', format($q$select public.corrigir_descricao(%s,'Carta A.R. Correios - Vara Federal','curta','1111')::text$q$, v_id));
  perform t.afirma('correção exige justificativa >= 10', r like 'ERRO:%justificativa%', r);
  r := t.como('jur@x', format($q$select public.corrigir_descricao(%s,'Carta A.R. Correios - Vara Federal','Erro de digitação na descrição','3333')::text$q$, v_id));
  perform t.afirma('setor não corrige descrição', r like 'ERRO:%permiss%', r);
  r := t.como('portaria@x', format($q$select public.corrigir_descricao(%s,'Carta A.R. Correios - Vara Federal','Erro de digitação na descrição','0000')::text$q$, v_id));
  perform t.afirma('correção exige PIN correto', (r::jsonb->>'ok') = 'false', r);
  r := t.como('portaria@x', format($q$select public.corrigir_descricao(%s,'Carta A.R. Correios - Vara Federal','Erro de digitação na descrição','1111')::text$q$, v_id));
  perform t.afirma('correção registrada', (r::jsonb->>'ok') = 'true', r);
  r := t.como('gestor@x', format($q$select (public.detalhe_protocolo(%s)->>'descricao') || ' | ' || (public.detalhe_protocolo(%s)->>'descricao_original')$q$, v_id, v_id));
  perform t.afirma('descrição atual muda e a original é preservada', r = 'Carta A.R. Correios - Vara Federal | Carta A.R. Correios', r);

  r := t.como('portaria@x', $q$select public.registrar_acesso('LOGIN')::text$q$);
  perform t.afirma('registrar_acesso grava LOGIN', r is not null and r not like 'ERRO:%', r);
  r := t.como('portaria@x', $q$select public.registrar_acesso('PROTOCOLO_CRIADO')::text$q$);
  perform t.afirma('registrar_acesso recusa eventos arbitrários', r like 'ERRO:%', r);

  -- 6. filtros e busca (curingas tratados como texto)
  r := t.como('gestor@x', $q$select (public.listar_livro('Vara Federal')->>'total')$q$);
  perform t.afirma('busca encontra pela descrição corrigida', r = '1', r);
  r := t.como('gestor@x', $q$select (public.listar_livro('%')->>'total')$q$);
  perform t.afirma('curinga % tratado como texto', r = '0', r);
  r := t.como('gestor@x', $q$select (public.listar_livro(null,'concluido')->>'total')$q$);
  perform t.afirma('filtro por status', r = '1', r);
  r := t.como('gestor@x', $q$select (public.resumo_livro()->>'total') || '/' || (public.resumo_livro()->>'pendente_adm') || '/' || (public.resumo_livro()->>'concluido')$q$);
  perform t.afirma('resumo (total/pendente_adm/concluido)', r = '3/2/1', r);

  -- 7. auditoria
  r := t.como('portaria@x', $q$select count(*)::text from public.auditoria$q$);
  perform t.afirma('portaria não lê auditoria', r = '0', r);
  r := t.como('gestor@x', $q$select (public.verificar_auditoria()->>'ok')$q$);
  perform t.afirma('cadeia de auditoria íntegra', r = 'true', r);
  r := t.como('portaria@x', $q$select (public.verificar_auditoria()->>'ok')$q$);
  perform t.afirma('portaria não verifica auditoria', r like 'ERRO:%', r);
  alter table public.auditoria disable trigger trg_auditoria_imutavel;
  update public.auditoria set detalhes = '{"adulterado":true}'::jsonb where id = (select min(id) from public.auditoria where acao = 'PROTOCOLO_CRIADO');
  r := t.como('gestor@x', $q$select (public.verificar_auditoria()->>'ok')$q$);
  perform t.afirma('adulteração da auditoria é detectada', r = 'false', r);
end $$;

-- 8. bloqueio de PIN (transações separadas: as falhas precisam ser gravadas)
do $$
declare r text; i int;
begin
  for i in 1..5 loop
    r := t.como('far@x', $q$select public.alterar_meu_pin('0000','4321')::text$q$);
  end loop;
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','4321')::text$q$);
  perform t.afirma('após 5 erros o PIN fica bloqueado (mesmo com PIN certo)', r like '%bloqueado%', r);
  perform public.admin_desbloquear_pin('far@x');
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','43')::text$q$);
  perform t.afirma('novo PIN inválido é recusado', r like 'ERRO:%', r);
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','4321')::text$q$);
  perform t.afirma('troca de PIN após desbloqueio', (r::jsonb->>'ok') = 'true', r);
  r := t.como('far@x', $q$select public.alterar_meu_pin('4321','4444')::text$q$);
  perform t.afirma('PIN novo funciona', (r::jsonb->>'ok') = 'true', r);
end $$;
\echo '=== TODOS OS TESTES DO SCHEMA PASSARAM ==='
