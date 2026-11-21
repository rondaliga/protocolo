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

  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,(select id from public.setores where nome='Jurídico'))::text$q$, v_id));
  perform t.afirma('ADM confirma 2ª etapa', (r::jsonb->>'ok') = 'true', r);
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,(select id from public.setores where nome='Jurídico'))::text$q$, v_id));
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


-- ================================================================= v2: prazos, SLA, foto, destino, alertas
do $$
declare r text; j jsonb; v_id bigint; v_id2 bigint; v_uid uuid; v_foto text; v_foto2 text; v_seg text := repeat('s3gr3d0-', 6);
        v_jur bigint := (select id from public.setores where nome='Jurídico');
        v_far bigint := (select id from public.setores where nome='Farmácia');
begin
  select id into v_uid from auth.users where email = 'portaria@x';

  -- horas e dias úteis (Fortaleza = UTC-3)
  r := to_char(public._somar_horas_uteis('2026-11-27 16:00-03'::timestamptz, 4) at time zone 'America/Fortaleza', 'YYYY-MM-DD HH24:MI');
  perform t.afirma('4h úteis a partir de sexta 16h → segunda 11h', r = '2026-11-30 11:00', r);
  r := to_char(public._somar_horas_uteis('2026-11-28 10:00-03'::timestamptz, 2) at time zone 'America/Fortaleza', 'YYYY-MM-DD HH24:MI');
  perform t.afirma('sábado conta a partir de segunda 8h', r = '2026-11-30 10:00', r);
  r := to_char(public._somar_horas_uteis('2026-11-24 07:00-03'::timestamptz, 9) at time zone 'America/Fortaleza', 'YYYY-MM-DD HH24:MI');
  perform t.afirma('9h úteis = um dia útil de expediente', r = '2026-11-24 17:00', r);
  r := public._somar_dias_uteis('2026-11-27', 5)::text;
  perform t.afirma('5 dias úteis a partir de 27/11', r = '2026-12-04', r);
  r := public._somar_dias_uteis('2026-11-19', 1)::text;
  perform t.afirma('feriado 20/11 e fim de semana são pulados', r = '2026-11-23', r);

  -- foto e regras do registro
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Mandado de segurança - 3ª Vara','1111',null,'judicial',false,null)::text$q$);
  perform t.afirma('judicial exige foto', r like 'ERRO:%foto%', r);
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Carta simples','1111',null,'correspondencia',true,null)::text$q$);
  perform t.afirma('urgência só para judicial', r like 'ERRO:%urg%', r);
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Carta simples','1111',null,'outro',false,null)::text$q$);
  perform t.afirma('tipo inválido é recusado', r like 'ERRO:%', r);

  v_foto := v_uid::text || '/' || gen_random_uuid()::text || '.jpg';
  r := t.como('portaria@x', format($q$select public.registrar_protocolo('Mandado de segurança - 3ª Vara','1111',null,'judicial',true,%L)::text$q$, v_foto));
  perform t.afirma('foto inexistente no storage é recusada', r like 'ERRO:%não foi encontrada%', r);
  r := t.como('portaria@x', format($q$select public.registrar_protocolo('Mandado','1111',null,'judicial',false,%L)::text$q$, 'outro-uid/' || gen_random_uuid()::text || '.jpg'));
  perform t.afirma('caminho de foto de outra pasta é recusado', r like 'ERRO:%inválido%', r);

  r := t.como('portaria@x', format($q$insert into storage.objects (bucket_id,name,owner,metadata) values ('protocolo-fotos',%L,auth.uid(),'{"size":1000}') returning 'ok'$q$, v_foto));
  perform t.afirma('portaria envia foto à própria pasta', r = 'ok', r);
  r := t.como('adm@x', format($q$insert into storage.objects (bucket_id,name,owner,metadata) values ('protocolo-fotos',%L,auth.uid(),'{"size":1}') returning 'ok'$q$, (select id from auth.users where email='adm@x')::text || '/' || gen_random_uuid()::text || '.jpg'));
  perform t.afirma('ADM não envia foto', r like 'ERRO:%', r);
  r := t.como('portaria@x', format($q$insert into storage.objects (bucket_id,name,owner,metadata) values ('protocolo-fotos',%L,auth.uid(),'{"size":1}') returning 'ok'$q$, 'outra-pasta/' || gen_random_uuid()::text || '.jpg'));
  perform t.afirma('portaria não envia foto para pasta alheia', r like 'ERRO:%', r);

  r := t.como('portaria@x', format($q$select public.registrar_protocolo('Mandado de segurança - 3ª Vara','1111',null,'judicial',true,%L)::text$q$, v_foto));
  j := r::jsonb;
  perform t.afirma('judicial urgente com foto é registrado', (j->>'ok') = 'true', r);
  v_id := (j->>'id')::bigint;
  r := t.como('portaria@x', format($q$select public.registrar_protocolo('Outro mandado - 4ª Vara','1111',null,'judicial',false,%L)::text$q$, v_foto));
  perform t.afirma('a mesma foto não vale para dois protocolos', r like 'ERRO:%já foi usada%', r);

  r := t.como('gestor@x', format($q$select (public.detalhe_protocolo(%s)->>'prazo_data') || '|' || (public.detalhe_protocolo(%s)->>'tipo') || '|' || (public.detalhe_protocolo(%s)->>'n_fotos')$q$, v_id, v_id, v_id));
  perform t.afirma('prazo padrão de 5 dias úteis, tipo e foto', r = public._somar_dias_uteis((now() at time zone 'America/Fortaleza')::date, 5)::text || '|judicial|1', r);
  r := t.como('gestor@x', format($q$select (sla_limite > now())::text from public.v_livro where id=%s$q$, v_id));
  perform t.afirma('SLA do ADM definido no futuro', r = 'true', r);

  -- visibilidade da foto
  r := t.como('adm@x', format($q$select count(*)::text from public.protocolo_fotos where protocolo_id=%s$q$, v_id));
  perform t.afirma('ADM vê a foto vinculada', r = '1', r);
  r := t.como('far@x', format($q$select count(*)::text from public.protocolo_fotos where protocolo_id=%s$q$, v_id));
  perform t.afirma('setor sem acesso não vê a foto', r = '0', r);
  r := t.como('far@x', format($q$select count(*)::text from storage.objects where name=%L$q$, v_foto));
  perform t.afirma('setor sem acesso não lê o arquivo', r = '0', r);
  r := t.como('adm@x', format($q$select count(*)::text from storage.objects where name=%L$q$, v_foto));
  perform t.afirma('ADM lê o arquivo', r = '1', r);

  -- e-mail de chegada (sem descrição)
  perform t.afirma('e-mail de chegada enfileirado para o ADM',
    exists (select 1 from public.fila_email where chave = 'chegada:' || v_id and destinatarios = array['adm@x'] and assunto like '%URGENTE%'));
  perform t.afirma('e-mail não vaza a descrição',
    not exists (select 1 from public.fila_email where corpo ilike '%Mandado de seguran%' or assunto ilike '%Mandado de seguran%'));

  -- ADM: destino obrigatório
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222')::text$q$, v_id));
  perform t.afirma('ADM precisa escolher o setor de destino', r like 'ERRO:%destino%', r);
  r := t.como('jur@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('setor não vê protocolo antes do ADM', r = 'true', r);
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, v_id, v_far));
  perform t.afirma('ADM encaminha à Farmácia', (r::jsonb->>'ok') = 'true', r);
  r := t.como('jur@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('Jurídico não vê o que foi para a Farmácia', r = 'true', r);
  r := t.como('jur@x', format($q$select public.confirmar_etapa(%s,3,'3333')::text$q$, v_id));
  perform t.afirma('Jurídico não confirma protocolo da Farmácia', r like 'ERRO:%não encontrado%', r);
  r := t.como('far@x', format($q$select (public.detalhe_protocolo(%s)->>'setor_destino_nome')$q$, v_id));
  perform t.afirma('Farmácia vê o protocolo encaminhado', r = 'Farmácia', r);
  perform t.afirma('e-mail de encaminhamento só para a Farmácia',
    exists (select 1 from public.fila_email where chave = 'encaminhado:' || v_id and destinatarios = array['far@x']));
  begin update public.protocolos set setor_destino_id = v_jur where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('destino não pode ser trocado depois', true);
  begin update public.protocolos set tipo = 'correspondencia' where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('tipo é imutável', true);

  -- pendências (sino)
  r := t.como('far@x', $q$select (public.minhas_pendencias()->>'total')$q$);
  perform t.afirma('Farmácia tem 1 pendência', r = '1', r);
  r := t.como('jur@x', $q$select (public.minhas_pendencias()->>'total')$q$);
  perform t.afirma('Jurídico tem 0 pendências', r = '0', r);
  r := t.como('adm@x', $q$select (public.minhas_pendencias()->>'total')$q$);
  perform t.afirma('ADM tem as pendências do seu estágio', r::int >= 2, r);

  -- ajuste de prazo
  r := t.como('far@x', format($q$select public.ajustar_prazo(%s, current_date + 20, 'Prazo real consta no mandado', '4444')::text$q$, v_id));
  perform t.afirma('setor não ajusta prazo', r like 'ERRO:%permiss%', r);
  r := t.como('adm@x', format($q$select public.ajustar_prazo(%s, current_date + 20, 'curta', '2222')::text$q$, v_id));
  perform t.afirma('ajuste exige justificativa', r like 'ERRO:%justificativa%', r);
  r := t.como('adm@x', format($q$select public.ajustar_prazo(%s, current_date + 20, 'Prazo real consta no mandado', '0000')::text$q$, v_id));
  perform t.afirma('ajuste exige PIN', (r::jsonb->>'ok') = 'false', r);
  r := t.como('adm@x', format($q$select public.ajustar_prazo(%s, current_date - 400, 'Prazo real consta no mandado', '2222')::text$q$, v_id));
  perform t.afirma('data anterior ao registro é recusada', r like 'ERRO:%inválida%', r);
  r := t.como('adm@x', format($q$select public.ajustar_prazo(%s, (now() at time zone 'America/Fortaleza')::date + 20, 'Prazo real consta no mandado', '2222')::text$q$, v_id));
  perform t.afirma('ADM ajusta prazo', (r::jsonb->>'ok') = 'true', r);
  r := t.como('gestor@x', format($q$select jsonb_array_length(public.detalhe_protocolo(%s)->'prazos')::text$q$, v_id));
  perform t.afirma('histórico do prazo registrado', r = '1', r);
  begin delete from public.prazo_historico;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('histórico de prazo é imutável', true);

  -- semáforo e escalada (simulando passagem do tempo como dono do banco)
  r := t.como('gestor@x', format($q$select semaforo from public.v_livro where id=%s$q$, v_id));
  perform t.afirma('semáforo ok com 20 dias', r = 'ok', r);
  alter table public.protocolos disable trigger user;
  update public.protocolos set prazo_data = (now() at time zone 'America/Fortaleza')::date - 1,
                               sla_limite = now() - interval '1 hour' where id = v_id;
  alter table public.protocolos enable trigger user;
  r := t.como('gestor@x', format($q$select semaforo || '/' || sla_estourado::text from public.v_livro where id=%s$q$, v_id));
  perform t.afirma('semáforo vencido e SLA estourado', r = 'vencido/true', r);
  r := t.como('gestor@x', $q$select (public.resumo_livro()->>'vencidos') || '/' || (public.resumo_livro()->>'sla_estourado')$q$);
  perform t.afirma('KPIs de vencidos e SLA', r = '1/1', r);
  r := t.como('gestor@x', $q$select (public.listar_livro(null,null,null,null,25,0,'vencidos')->>'total')$q$);
  perform t.afirma('filtro de vencidos', r = '1', r);
  r := t.como('gestor@x', $q$select (public.minhas_pendencias()->>'total')$q$);
  perform t.afirma('gestor vê pendências críticas', r::int >= 1, r);

  r := public._verificar_sla()::text;
  perform t.afirma('verificação gera avisos novos', r::int >= 2, r);
  perform t.afirma('aviso de SLA vai ao setor atual e ao gestor',
    exists (select 1 from public.fila_email where chave = 'sla:' || v_id || ':3' and destinatarios @> array['far@x','gestor@x']));
  perform t.afirma('aviso de prazo vencido enfileirado', exists (select 1 from public.fila_email where chave = 'vencido:' || v_id));
  r := public._verificar_sla()::text;
  perform t.afirma('verificação repetida não duplica avisos', r = '0', r);

  -- integração (e-mail) protegida por segredo
  r := t.como('anon', $q$select public.integracao_fila('segredo-errado-segredo-errado-12345')::text$q$);
  perform t.afirma('integração sem segredo configurado é recusada', r like 'ERRO:%autorizado%', r);
  perform public.admin_definir_segredo_integracao(v_seg);
  r := t.como('anon', $q$select public.integracao_fila('segredo-errado-segredo-errado-12345')::text$q$);
  perform t.afirma('segredo errado é recusado', r like 'ERRO:%autorizado%', r);
  r := t.como('anon', format($q$select jsonb_array_length(public.integracao_fila(%L))::text$q$, v_seg));
  perform t.afirma('segredo certo lê a fila', r::int >= 3, r);
  r := t.como('anon', format($q$select public.integracao_marcar(%L, %s, true)::text$q$, v_seg, (select min(id) from public.fila_email)));
  perform t.afirma('segredo certo marca envio', r is not null and r not like 'ERRO:%', r);
  perform t.afirma('item marcado como enviado', (select status from public.fila_email order by id limit 1) = 'enviado');
  r := t.como('anon', $q$select count(*)::text from public.fila_email$q$);
  perform t.afirma('anon não lê a fila diretamente', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select count(*)::text from public.fila_email$q$);
  perform t.afirma('usuário autenticado não lê a fila', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select count(*)::text from public.parametros$q$);
  perform t.afirma('parâmetros inacessíveis ao cliente', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select public.integracao_verificar('x')::text$q$);
  perform t.afirma('autenticado não executa integração', r like 'ERRO:%', r);

  -- parâmetros
  perform public.admin_definir_parametro('prazo_judicial_dias', '3');
  begin perform public.admin_definir_parametro('prazo_judicial_dias', 'abc'); raise exception 'não deveria'; exception when others then
    perform t.afirma('parâmetro numérico inválido é recusado', sqlerrm like '%inteiro%', sqlerrm); end;
  begin perform public.admin_definir_parametro('url_sistema', 'http://inseguro'); raise exception 'não deveria'; exception when others then
    perform t.afirma('url_sistema exige https', sqlerrm like '%https%', sqlerrm); end;
  perform public.admin_definir_parametro('prazo_judicial_dias', '5');
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
