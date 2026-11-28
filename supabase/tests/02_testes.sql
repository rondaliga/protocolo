-- Testes do schema.sql. Rode via run_local.sh (usa psql, banco descartável).
\set ON_ERROR_STOP on
\set QUIET on
create schema if not exists t;

-- Executa SQL "como" um usuário (role authenticated + auth.uid()), devolvendo resultado ou 'ERRO: ...'
create or replace function t.como(p_email text, p_sql text, p_aal text default 'aal1') returns text language plpgsql as $$
declare v_res text; v_uid uuid;
begin
  select id into v_uid from auth.users where email = p_email;
  perform set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'aal', p_aal)::text, true);
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
  begin   -- adulteração simulada dentro de um sub-bloco que é desfeito (não deixa o gatilho desligado)
    alter table public.auditoria disable trigger trg_auditoria_imutavel;
    update public.auditoria set detalhes = '{"adulterado":true}'::jsonb where id = (select min(id) from public.auditoria where acao = 'PROTOCOLO_CRIADO');
    r := t.como('gestor@x', $q$select (public.verificar_auditoria()->>'ok')$q$);
    raise exception 'desfazer-simulacao';
  exception when others then
    if sqlerrm <> 'desfazer-simulacao' then raise; end if;
  end;
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
  r := t.como('gestor@x', format($q$select (sla_limite is null)::text from public.v_livro where id=%s$q$, v_id));
  perform t.afirma('não há mais tempo máximo de recebimento (alerta imediato)', r = 'true', r);

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
  update public.protocolos set prazo_data = (now() at time zone 'America/Fortaleza')::date - 1 where id = v_id;
  alter table public.protocolos enable trigger user;
  r := t.como('gestor@x', format($q$select semaforo || '/' || sla_estourado::text from public.v_livro where id=%s$q$, v_id));
  perform t.afirma('semáforo vencido, sem SLA estourado', r = 'vencido/false', r);
  r := t.como('gestor@x', $q$select (public.resumo_livro()->>'vencidos') || '/' || (public.resumo_livro()->>'sla_estourado')$q$);
  perform t.afirma('KPIs de vencidos (SLA sempre zero)', r = '1/0', r);
  r := t.como('gestor@x', $q$select (public.listar_livro(null,null,null,null,25,0,'vencidos')->>'total')$q$);
  perform t.afirma('filtro de vencidos', r = '1', r);
  r := t.como('gestor@x', $q$select (public.minhas_pendencias()->>'total')$q$);
  perform t.afirma('gestor vê pendências críticas', r::int >= 1, r);

  r := public._verificar_sla()::text;
  perform t.afirma('verificação gera aviso de prazo', r::int >= 1, r);
  perform t.afirma('não existe mais aviso de tempo máximo (SLA)', not exists (select 1 from public.fila_email where chave like 'sla:%'));
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


-- ================================================================= v3: gestor com acesso total, painel, trilha, assinatura digitada
do $$
declare r text; j jsonb; v_id bigint; v_id2 bigint; v_u uuid; v_u2 uuid; v_h text; v_fila public.fila_email%rowtype;
        v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
        v_jur bigint := (select id from public.setores where nome='Jurídico');
        v_far bigint := (select id from public.setores where nome='Farmácia');
begin
  -- ---------- gestor com acesso total ----------
  r := t.como('gestor@x', format($q$select public.registrar_protocolo('Ofício do gestor - Vara Única','5555',%L,'correspondencia',false,null,'digitada')::text$q$, v_png));
  j := r::jsonb; v_id := (j->>'id')::bigint;
  perform t.afirma('gestor registra protocolo (Portaria)', (j->>'ok') = 'true', r);
  r := (select assinatura_tipo from public.tramites where protocolo_id = v_id and etapa = 1);
  perform t.afirma('assinatura digitada gravada como pin_digitada', r = 'pin_digitada', r);
  r := t.como('gestor@x', format($q$select public.registrar_protocolo('Ofício do gestor 2','5555',%L,'correspondencia',false,null,'cursiva')::text$q$, v_png));
  perform t.afirma('modo de assinatura inválido é recusado', r like 'ERRO:%Modo%', r);
  r := t.como('gestor@x', format($q$select public.confirmar_etapa(%s,3,'5555')::text$q$, v_id));
  perform t.afirma('gestor não pula o ADM na 3ª etapa', r like 'ERRO:%aguarda o recebimento do ADM%', r);
  r := t.como('gestor@x', format($q$select public.confirmar_etapa(%s,2,'5555',null,%s)::text$q$, v_id, v_jur));
  perform t.afirma('gestor recebe como ADM (mesma pessoa da Portaria)', (r::jsonb->>'ok') = 'true', r);
  r := t.como('gestor@x', format($q$select public.confirmar_etapa(%s,3,'5555',%L,null,'desenhada')::text$q$, v_id, v_png));
  perform t.afirma('gestor recebe pelo setor de destino', (r::jsonb->>'ok') = 'true', r);
  r := (select setor_nome || '/' || assinatura_tipo from public.tramites where protocolo_id = v_id and etapa = 3);
  perform t.afirma('3ª etapa registra o setor de destino e a assinatura desenhada', r = 'Jurídico/pin_canvas', r);
  r := (select status from public.protocolos where id = v_id);
  perform t.afirma('protocolo concluído pelo gestor', r = 'concluido', r);
  perform public.admin_definir_parametro('gestor_ignora_segregacao', 'false');
  r := t.como('gestor@x', $q$select public.registrar_protocolo('Ofício do gestor 3','5555')::text$q$);
  v_id2 := (r::jsonb->>'id')::bigint;
  r := t.como('gestor@x', format($q$select public.confirmar_etapa(%s,2,'5555',null,%s)::text$q$, v_id2, v_jur));
  perform t.afirma('com segregação ligada o gestor também precisa de outra pessoa', r like 'ERRO:%Segrega%', r);
  perform public.admin_definir_parametro('gestor_ignora_segregacao', 'true');
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,3,'2222')::text$q$, v_id2));
  perform t.afirma('ADM continua sem acesso à 3ª etapa', r like 'ERRO:%permiss%', r);
  r := t.como('gestor@x', $q$select (public.minhas_pendencias()->>'total')::int >= 1$q$);
  perform t.afirma('gestor vê todas as pendências em aberto', r = 'true', r);

  -- ---------- painel: controle de acesso ----------
  foreach r in array array['portaria@x','adm@x','jur@x'] loop
    perform t.afirma('painel_listar_usuarios negado a ' || r, t.como(r, 'select public.painel_listar_usuarios()::text') like 'ERRO:%gestor%');
  end loop;
  r := t.como('adm@x', $q$select public.painel_salvar_setor(null,'Setor Invasor')::text$q$);
  perform t.afirma('ADM não cria setor', r like 'ERRO:%gestor%', r);
  r := t.como('adm@x', $q$select public.listar_auditoria()::text$q$);
  perform t.afirma('ADM não lê a trilha organizada', r like 'ERRO:%gestor%', r);
  r := t.como('anon', $q$select public.painel_resumo()::text$q$);
  perform t.afirma('anon não acessa o painel', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select jsonb_array_length(public.painel_listar_usuarios())::text$q$);
  perform t.afirma('gestor lista usuários', r::int >= 5, r);
  r := t.como('gestor@x', $q$select count(*)::text from (select unnest(array(select jsonb_object_keys(e) from jsonb_array_elements(public.painel_listar_usuarios()) e limit 40))) k where unnest ~ 'pin_hash|senha_provisoria'$q$);
  perform t.afirma('lista de usuários não expõe hashes', r = '0', r);

  -- ---------- criar usuário ----------
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','adm',null,'Senha-Forte-123','2468','0000')::text$q$);
  perform t.afirma('criar usuário exige o PIN do gestor', (r::jsonb->>'ok') = 'false', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','adm',null,'curta1','2468','5555')::text$q$);
  perform t.afirma('senha fraca é recusada', r like 'ERRO:%senha%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','adm',null,'somente-letras-aqui','2468','5555')::text$q$);
  perform t.afirma('senha sem número é recusada', r like 'ERRO:%senha%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('email-invalido','Novo Usuário','adm',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('e-mail inválido é recusado', r like 'ERRO:%e-mail%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','papelx',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('papel inválido é recusado', r like 'ERRO:%Perfil%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','super_setor',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('Super/Setor exige setor', r like 'ERRO:%setor%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','adm',null,'Senha-Forte-123','12','5555')::text$q$);
  perform t.afirma('PIN provisório inválido é recusado', r like 'ERRO:%PIN%', r);
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('novo@x.com','Novo Usuário','adm',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('gestor cria usuário', (r::jsonb->>'ok') = 'true' and (r::jsonb->>'conta_nova') = 'true', r);
  v_u := (r::jsonb->>'user_id')::uuid;
  perform t.afirma('conta criada no Auth com senha em bcrypt',
    exists (select 1 from auth.users where id = v_u and encrypted_password = extensions.crypt('Senha-Forte-123', encrypted_password) and email_confirmed_at is not null and confirmation_token = ''));
  perform t.afirma('identidade de e-mail criada', exists (select 1 from auth.identities where user_id = v_u and provider = 'email'));
  perform t.afirma('usuário nasce com troca de senha e PIN pendentes',
    (select deve_trocar_senha and deve_trocar_pin and ativo and email = 'novo@x.com' from public.perfis where user_id = v_u));
  -- e-mail formal com os dados de acesso
  r := t.como('gestor@x', format($q$select public.painel_enviar_acesso(%L,'Senha-Errada-999','2468','https://exemplo.org/livro/','CECAN – LNRCC')::text$q$, v_u));
  perform t.afirma('e-mail de acesso recusa senha que não é a provisória', r like 'ERRO:%senha%', r);
  r := t.como('gestor@x', format($q$select public.painel_enviar_acesso(%L,'Senha-Forte-123','9999','https://exemplo.org/livro/','CECAN – LNRCC')::text$q$, v_u));
  perform t.afirma('e-mail de acesso recusa PIN que não é o provisório', r like 'ERRO:%PIN%', r);
  r := t.como('adm@x', format($q$select public.painel_enviar_acesso(%L,'Senha-Forte-123','2468','https://exemplo.org/livro/')::text$q$, v_u));
  perform t.afirma('só o gestor envia os dados de acesso', r like 'ERRO:%', r);
  r := t.como('gestor@x', format($q$select public.painel_enviar_acesso(%L,'Senha-Forte-123','2468','https://exemplo.org/livro/','CECAN – LNRCC')::text$q$, v_u));
  perform t.afirma('gestor envia os dados de acesso', r not like 'ERRO:%' and (r::jsonb->>'ok') = 'true' and (r::jsonb->>'email') = 'novo@x.com', r);
  select * into v_fila from public.fila_email where evento = 'BOAS_VINDAS' order by id desc limit 1;
  perform t.afirma('e-mail formal vai só ao novo usuário, com assunto padrão',
    v_fila.destinatarios = array['novo@x.com'] and v_fila.assunto = '[Livro de Protocolo] Dados de acesso ao sistema', v_fila.assunto);
  perform t.afirma('e-mail traz endereço, usuário, senha e PIN provisórios',
    v_fila.corpo like '%https://exemplo.org/livro/%' and v_fila.corpo like '%novo@x.com%' and v_fila.corpo like '%Senha-Forte-123%' and v_fila.corpo like '%2468%', v_fila.corpo);
  perform t.afirma('e-mail tem versão HTML com logo/título, credenciais, botão e sem scripts',
    v_fila.corpo_html like '<!DOCTYPE html>%' and v_fila.corpo_html like '%Livro de Protocolo Eletrônico%' and v_fila.corpo_html like '%Livro de Protocolo Eletrônico%'
    and v_fila.corpo_html like '%Senha-Forte-123%' and v_fila.corpo_html like '%href="https://exemplo.org/livro/"%' and v_fila.corpo_html not like '%<script%', left(v_fila.corpo_html, 80));
  perform t.afirma('e-mail traz saudação formal, primeiro acesso, aviso de segurança e assinatura',
    v_fila.corpo like 'Prezado(a) Novo Usuário,%' and v_fila.corpo like '%PRIMEIRO ACESSO%'
    and v_fila.corpo like '%intransferível%' and v_fila.corpo like '%Atenciosamente,%', v_fila.corpo);
  perform t.afirma('envio dos dados de acesso fica na trilha sem as credenciais',
    exists (select 1 from public.auditoria where acao = 'ACESSO_ENVIADO_POR_EMAIL')
    and not exists (select 1 from public.auditoria where acao = 'ACESSO_ENVIADO_POR_EMAIL' and detalhes::text like '%Senha-Forte-123%'));
  update public.fila_email set status = 'enviado', enviado_em = now() where id = v_fila.id;
  perform t.afirma('depois de enviado, o texto com credenciais é apagado do banco',
    (select corpo from public.fila_email where id = v_fila.id) like '[Conteúdo removido%' and (select corpo from public.fila_email where id = v_fila.id) not like '%Senha-Forte-123%'
    and (select corpo_html from public.fila_email where id = v_fila.id) is null);
  perform t.afirma('escape de HTML e logo inválida não entram no e-mail',
    public._html_esc('<b a="1">&''') = '&lt;b a=&quot;1&quot;&gt;&amp;&#39;');
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('NOVO@x.com','Outro','adm',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('e-mail duplicado (sem diferenciar maiúsculas) é recusado', r like 'ERRO:%Já existe%', r);
  -- vincula conta já existente no Auth (criada pelo painel do Supabase)
  insert into auth.users (email) values ('existente@x.com') returning id into v_u2;
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('existente@x.com','Conta Existente','portaria',null,null,'2468','5555')::text$q$);
  perform t.afirma('vincula conta já existente do Auth', (r::jsonb->>'ok') = 'true' and (r::jsonb->>'conta_nova') = 'false', r);

  -- ---------- primeiro acesso ----------
  r := t.como('novo@x.com', $q$select public.confirmar_troca_senha()::text$q$);
  perform t.afirma('não confirma troca enquanto a senha for a provisória', r like 'ERRO:%provisória%', r);
  update auth.users set encrypted_password = extensions.crypt('Minha-Senha-Nova-9', extensions.gen_salt('bf')) where id = v_u;
  r := t.como('novo@x.com', $q$select public.confirmar_troca_senha()::text$q$);
  perform t.afirma('confirma troca de senha depois que ela mudou', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('flag de senha limpa', (select not deve_trocar_senha and senha_provisoria_hash is null from public.perfis where user_id = v_u));
  r := t.como('novo@x.com', $q$select public.alterar_meu_pin('2468','2468')::text$q$);
  perform t.afirma('novo PIN igual ao atual é recusado', r like 'ERRO:%diferente%', r);
  r := t.como('novo@x.com', $q$select public.alterar_meu_pin('2468','1111')::text$q$);
  perform t.afirma('PIN óbvio é recusado', r like 'ERRO:%fácil%', r);
  r := t.como('novo@x.com', $q$select public.alterar_meu_pin('2468','1357')::text$q$);
  perform t.afirma('troca do PIN provisório', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('flag de PIN limpa', (select not deve_trocar_pin from public.perfis where user_id = v_u));
  r := t.como('novo@x.com', $q$select (deve_trocar_senha or deve_trocar_pin)::text from public.perfis where user_id = auth.uid()$q$);
  perform t.afirma('usuário lê o próprio estado de primeiro acesso', r = 'false', r);
  r := t.como('novo@x.com', $q$select senha_provisoria_hash from public.perfis$q$);
  perform t.afirma('usuário não lê o hash da senha provisória', r like 'ERRO:%', r);

  -- ---------- editar / ativar / redefinir ----------
  r := t.como('gestor@x', format($q$select public.painel_atualizar_usuario(%L,'Novo Usuário Jurídico','super_setor',%s,'5555')::text$q$, v_u, v_jur));
  perform t.afirma('gestor muda papel e setor', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('papel e setor atualizados', (select papel = 'super_setor' and setor_id = v_jur from public.perfis where user_id = v_u));
  r := t.como('gestor@x', format($q$select public.painel_atualizar_usuario(%L,'Gestor','adm',null,'5555')::text$q$, (select id from auth.users where email='gestor@x')));
  perform t.afirma('gestor não retira o próprio acesso', r like 'ERRO:%próprio%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,false,'5555')::text$q$, (select id from auth.users where email='gestor@x')));
  perform t.afirma('gestor não se desativa', r like 'ERRO:%próprio%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,false,'0000')::text$q$, v_u));
  perform t.afirma('desativar exige PIN do gestor', (r::jsonb->>'ok') = 'false', r);
  insert into auth.sessions (user_id) values (v_u);
  r := t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,false,'5555')::text$q$, v_u));
  perform t.afirma('gestor desativa usuário', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('desativado: bloqueado no Auth e sem sessões',
    (select banned_until = 'infinity' from auth.users where id = v_u) and not exists (select 1 from auth.sessions where user_id = v_u));
  r := t.como('novo@x.com', $q$select count(*)::text from public.protocolos$q$);
  perform t.afirma('desativado não enxerga dados', r = '0', r);
  r := t.como('novo@x.com', $q$select public.listar_livro()::text$q$);
  perform t.afirma('desativado não usa o sistema', r like '%"total": 0%' or r like 'ERRO:%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,true,'5555')::text$q$, v_u));
  perform t.afirma('gestor reativa usuário', (r::jsonb->>'ok') = 'true' and (select banned_until is null from auth.users where id = v_u), r);

  r := t.como('gestor@x', format($q$select public.painel_redefinir_senha(%L,'Outra-Senha-456','5555')::text$q$, v_u));
  perform t.afirma('gestor redefine a senha', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('senha redefinida volta a exigir troca',
    (select deve_trocar_senha and senha_provisoria_hash = u.encrypted_password and u.encrypted_password = extensions.crypt('Outra-Senha-456', u.encrypted_password)
       from public.perfis p join auth.users u on u.id = p.user_id where p.user_id = v_u));
  r := t.como('gestor@x', format($q$select public.painel_redefinir_senha(%L,'fraca','5555')::text$q$, v_u));
  perform t.afirma('redefinição respeita a política de senha', r like 'ERRO:%senha%', r);
  r := t.como('gestor@x', format($q$select public.painel_redefinir_pin(%L,'8642','5555')::text$q$, v_u));
  perform t.afirma('gestor redefine o PIN', (r::jsonb->>'ok') = 'true', r);
  r := t.como('novo@x.com', $q$select public.alterar_meu_pin('8642','9753')::text$q$);
  perform t.afirma('PIN redefinido funciona e pode ser trocado', (r::jsonb->>'ok') = 'true', r);
  update public.perfis set pin_bloqueado_ate = now() + interval '5 minutes', pin_falhas = 3 where user_id = v_u;
  r := t.como('gestor@x', format($q$select public.painel_desbloquear_pin(%L)::text$q$, v_u));
  perform t.afirma('gestor desbloqueia PIN', (select pin_bloqueado_ate is null and pin_falhas = 0 from public.perfis where user_id = v_u), r);

  -- ---------- setores ----------
  r := t.como('gestor@x', $q$select public.painel_salvar_setor(null,'Superintendência Médica')::text$q$);
  perform t.afirma('gestor cria setor', (r::jsonb->>'ok') = 'true', r);
  r := t.como('gestor@x', $q$select public.painel_salvar_setor(null,'superintendência médica')::text$q$);
  perform t.afirma('setor duplicado é recusado', r like 'ERRO:%Já existe%', r);
  r := t.como('gestor@x', $q$select public.painel_salvar_setor(null,'A')::text$q$);
  perform t.afirma('nome de setor curto é recusado', r like 'ERRO:%nome%', r);
  r := t.como('gestor@x', format($q$select public.painel_salvar_setor(%s,'Jurídico',false)::text$q$, v_jur));
  perform t.afirma('não desativa setor com usuários ativos', r like 'ERRO:%usuários ativos%', r);
  r := t.como('gestor@x', format($q$select public.painel_salvar_setor(%s,'Farmácia Central')::text$q$, v_far));
  perform t.afirma('renomear setor', (r::jsonb->>'ok') = 'true' and (select nome from public.setores where id = v_far) = 'Farmácia Central', r);
  perform public.painel_salvar_setor(v_far, 'Farmácia');   -- (como dono) volta ao nome original
  r := t.como('gestor@x', $q$select jsonb_array_length(public.painel_listar_setores())::text$q$);
  perform t.afirma('lista de setores', r::int >= 6, r);

  -- ---------- parâmetros e feriados ----------
  r := t.como('gestor@x', $q$select count(*)::text from jsonb_array_elements(public.painel_listar_parametros()) e where e->>'tipo' in ('numero','booleano','texto','hora','duracao')$q$);
  perform t.afirma('parâmetros listados com tipo', r::int >= 10, r);
  r := t.como('gestor@x', $q$select public.painel_definir_parametro('prazo_judicial_dias','10')::text$q$);
  perform t.afirma('gestor altera parâmetro', (r::jsonb->>'alterado') = 'true' and public._param_int('prazo_judicial_dias', 0) = 10, r);
  perform public.admin_definir_parametro('prazo_judicial_dias', '5');
  foreach r in array array['sessao_inatividade_min|2min','sessao_inatividade_min|abc','expediente_inicio|25:00','prazo_judicial_dias|400','prazo_judicial_dias|abc','expediente_fim|7','expediente_inicio|18','gestor_ignora_segregacao|talvez','url_sistema|http://x.com','chave_inexistente|1'] loop
    perform t.afirma('parâmetro inválido recusado: ' || r,
      t.como('gestor@x', format($q$select public.painel_definir_parametro(%L,%L)::text$q$, split_part(r,'|',1), split_part(r,'|',2))) like 'ERRO:%');
  end loop;
  r := t.como('adm@x', $q$select public.painel_definir_parametro('sessao_inatividade_min','8h')::text$q$);
  perform t.afirma('ADM não altera parâmetros', r like 'ERRO:%gestor%', r);
  r := t.como('gestor@x', $q$select public.painel_salvar_feriado('2027-02-09','Carnaval')::text$q$);
  perform t.afirma('gestor cadastra feriado', (r::jsonb->>'ok') = 'true' and public._eh_util('2027-02-09') = false, r);
  r := t.como('gestor@x', $q$select count(*)::text from jsonb_array_elements(public.painel_listar_feriados()) e where e->>'data' = '2027-02-09'$q$);
  perform t.afirma('feriado listado', r = '1', r);
  r := t.como('gestor@x', $q$select public.painel_remover_feriado('2027-02-09')::text$q$);
  perform t.afirma('gestor remove feriado', (r::jsonb->>'ok') = 'true' and public._eh_util('2027-02-09'), r);
  r := t.como('gestor@x', $q$select public.painel_remover_feriado('2027-02-09')::text$q$);
  perform t.afirma('remover feriado inexistente é recusado', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select (public.painel_resumo()->>'usuarios_ativos')::int > 5 and (public.painel_resumo() ? 'email_pendente')$q$);
  perform t.afirma('resumo do painel', r = 'true', r);

  -- ---------- trilha organizada ----------
  r := t.como('gestor@x', $q$select (public.listar_auditoria()->>'total')::int > 20$q$);
  perform t.afirma('trilha lista eventos', r = 'true', r);
  r := t.como('gestor@x', $q$select count(*)::text from jsonb_array_elements(public.listar_auditoria(null,'protocolo')->'itens') e where e->>'acao' <> 'PROTOCOLO_CRIADO' or e->>'numero' is null$q$);
  perform t.afirma('filtro por categoria e nº do protocolo no evento', r = '0', r);
  r := t.como('gestor@x', $q$select count(*)::text from jsonb_array_elements(public.listar_auditoria(null,'administracao')->'itens') e where e->>'categoria' <> 'administracao'$q$);
  perform t.afirma('categoria administração', r = '0', r);
  r := t.como('gestor@x', $q$select (public.listar_auditoria('USUARIO_CRIADO')->>'total')::int >= 2$q$);
  perform t.afirma('busca por ação', r = 'true', r);
  r := t.como('gestor@x', $q$select (public.listar_auditoria(null,null,'Paula Gestora')->>'total')::int > 0$q$);
  perform t.afirma('filtro por usuário', r = 'true', r);
  r := t.como('gestor@x', $q$select (public.listar_auditoria('%')->>'total')::int$q$);
  perform t.afirma('curinga % tratado como texto na trilha', r::int = 0, r);
  r := t.como('gestor@x', $q$select jsonb_array_length(public.listar_auditoria(null,null,null,null,null,5,0)->'itens')::text$q$);
  perform t.afirma('paginação da trilha', r = '5', r);
  r := t.como('gestor@x', $q$select (public.listar_auditoria(null,null,null,current_date + 1,null)->>'total')$q$);
  perform t.afirma('filtro por data', r = '0', r);
  r := t.como('gestor@x', $q$select count(*)::text from jsonb_array_elements(public.listar_auditoria()->'itens') e where e ? 'hash' or e ? 'hash_anterior'$q$);
  perform t.afirma('trilha não expõe os hashes internos', r = '0', r);
  r := t.como('gestor@x', format($q$select public.registrar_exportacao('FICHA',%s,'')$q$, v_id));
  r := (select detalhes::text from public.auditoria where acao = 'IMPRESSAO_FICHA' order by id desc limit 1);
  perform t.afirma('impressão da ficha registra o nº (sem filtros vazios)', r like '%"numero"%' and r not like '%filtros%', r);
  r := t.como('gestor@x', $q$select public.registrar_exportacao('TRILHA',null,'categoria: acesso')$q$);
  perform t.afirma('gestor registra exportação da trilha', not exists (select 1 from public.auditoria where acao = 'IMPRESSAO_TRILHA' and detalhes->>'filtros' is null), r);
  r := t.como('adm@x', $q$select public.registrar_exportacao('TRILHA')::text$q$);
  perform t.afirma('ADM não exporta a trilha', r like 'ERRO:%gestor%', r);
end $$;


-- ---------- v4: formatos de hora, salvar único, logo, exclusões ----------
do $$
declare r text; v_id bigint; v_id2 bigint; v_n int; v_jur bigint := (select id from public.setores where nome='Jurídico');
        v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
begin
  perform t.afirma('cadeia íntegra antes das exclusões', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
  perform t.afirma('formatos de hora', public._parse_hhmm('8h30') = '08:30' and public._parse_hhmm('17') = '17:00'
     and public._parse_hhmm('7:05') = '07:05' and public._parse_hhmm('25:00') is null and public._parse_hhmm('8:75') is null);
  perform t.afirma('formatos de duração', public._parse_duracao_min('1h30') = 90 and public._parse_duracao_min('90min') = 90
     and public._parse_duracao_min('1,5') = 90 and public._parse_duracao_min('2h') = 120 and public._parse_duracao_min('1:30') = 90
     and public._parse_duracao_min('1d') = 540 and public._parse_duracao_min('4 horas 15 min') = 255 and public._parse_duracao_min('abc') is null,
     coalesce(public._parse_duracao_min('1d')::text, 'nulo'));
  perform t.afirma('parâmetros antigos migrados', not exists (select 1 from public.parametros where chave like 'sla\_%')
     and (select valor from public.parametros where chave = 'expediente_inicio') = '08:00');

  r := t.como('gestor@x', $q$select public.painel_salvar_parametros('{"sessao_inatividade_min":"3h","expediente_fim":"7:00"}'::jsonb)::text$q$);
  perform t.afirma('salvar em lote é tudo-ou-nada (expediente incoerente)', r like 'ERRO:%expediente%'
     and (select valor from public.parametros where chave = 'sessao_inatividade_min') = '6:00', r);
  r := t.como('gestor@x', $q$select public.painel_salvar_parametros('{"sessao_inatividade_min":"xx"}'::jsonb)::text$q$);
  perform t.afirma('salvar em lote nomeia o campo inválido', r like 'ERRO:%sessao_inatividade_min%', r);
  r := t.como('gestor@x', $q$select public.painel_salvar_parametros('{"sessao_inatividade_min":"4h30","expediente_inicio":"7h30","alerta_prazo_dias":"3","foto_obrigatoria_judicial":"true"}'::jsonb)::text$q$);
  perform t.afirma('salvar vários parâmetros de uma vez', (r::jsonb->>'alterados') = '3'
     and (select valor from public.parametros where chave = 'sessao_inatividade_min') = '4:30'
     and (select valor from public.parametros where chave = 'expediente_inicio') = '07:30', r);
  perform t.afirma('um único evento de auditoria para o lote', (select count(*) from public.auditoria where acao = 'PARAMETROS_ALTERADOS') = 1);
  r := t.como('adm@x', $q$select public.painel_salvar_parametros('{"alerta_prazo_dias":"1"}'::jsonb)::text$q$);
  perform t.afirma('ADM não salva parâmetros', r like 'ERRO:%gestor%', r);
  perform public.admin_definir_parametro('sessao_inatividade_min', '6:00'); perform public.admin_definir_parametro('expediente_inicio', '08:00');
  perform public.admin_definir_parametro('alerta_prazo_dias', '2');
  perform t.afirma('horas úteis seguem funcionando', public._somar_horas_uteis(now(), 1.5) > now());

  -- logo
  r := t.como('gestor@x', $q$select public.painel_definir_logo('data:text/html;base64,PHNjcmlwdD4=','5555')::text$q$);
  perform t.afirma('logo que não é imagem é recusado', r like 'ERRO:%inválida%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_logo(%L,'0000')::text$q$, v_png));
  perform t.afirma('logo exige o PIN do gestor', (r::jsonb->>'ok') = 'false', r);
  r := t.como('adm@x', format($q$select public.painel_definir_logo(%L,'2222')::text$q$, v_png));
  perform t.afirma('ADM não altera o logo', r like 'ERRO:%gestor%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_logo(%L,'5555')::text$q$, v_png));
  perform t.afirma('gestor define o logo', (r::jsonb->>'ok') = 'true', r);
  r := t.como('anon', $q$select public.identidade_publica()->>'logo'$q$);
  perform t.afirma('logo é lido já na tela de login', r = v_png, left(coalesce(r, 'nulo'), 60));
  perform t.afirma('auditoria do logo não guarda a imagem', exists (select 1 from public.auditoria where acao = 'LOGO_ALTERADO')
     and not exists (select 1 from public.auditoria where detalhes::text like '%iVBOR%'));
  r := t.como('anon', $q$select count(*)::text from public.identidade$q$);
  perform t.afirma('tabela da identidade fechada ao cliente', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select public.painel_remover_logo('5555')::text$q$);
  perform t.afirma('gestor restaura o logo padrão', (r::jsonb->>'ok') = 'true' and (select logo from public.identidade) is null, r);

  -- exclusão de protocolo
  r := t.como('gestor@x', $q$select (public.registrar_protocolo('Documento a excluir (teste)','5555',null,'correspondencia')->>'id')$q$);
  v_id := r::bigint;
  perform t.como('gestor@x', format($q$select public.confirmar_etapa(%s,2,'5555',null,%s)::text$q$, v_id, v_jur));
  r := t.como('adm@x', format($q$select public.excluir_protocolo(%s,'Cadastro em duplicidade','2222')::text$q$, v_id));
  perform t.afirma('ADM não exclui protocolo', r like 'ERRO:%gestor%', r);
  r := t.como('gestor@x', format($q$select public.excluir_protocolo(%s,'curto','5555')::text$q$, v_id));
  perform t.afirma('exclusão exige justificativa', r like 'ERRO:%justificativa%', r);
  r := t.como('gestor@x', format($q$select public.excluir_protocolo(%s,'Cadastro em duplicidade','0000')::text$q$, v_id));
  perform t.afirma('exclusão exige o PIN do gestor', (r::jsonb->>'ok') = 'false' and exists (select 1 from public.protocolos where id = v_id), r);
  r := t.como('gestor@x', 'select public.excluir_protocolo(999999,''Cadastro em duplicidade'',''5555'')::text');
  perform t.afirma('protocolo inexistente', r like 'ERRO:%não encontrado%', r);
  r := t.como('gestor@x', format($q$select public.excluir_protocolo(%s,'Cadastro em duplicidade','5555')::text$q$, v_id));
  perform t.afirma('gestor exclui protocolo com etapas', (r::jsonb->>'ok') = 'true' and not exists (select 1 from public.protocolos where id = v_id)
     and not exists (select 1 from public.tramites where protocolo_id = v_id), r);
  perform t.afirma('exclusão fica na trilha e a cadeia continua íntegra', exists (select 1 from public.auditoria where acao = 'PROTOCOLO_EXCLUIDO' and protocolo_id = v_id
     and detalhes->>'justificativa' = 'Cadastro em duplicidade'),
     (select string_agg(acao||':'||coalesce(protocolo_id::text,'-'),',') from (select * from public.auditoria order by id desc limit 4) z));
  perform t.afirma('cadeia íntegra depois da exclusão', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true',
     t.como('gestor@x', 'select public.verificar_auditoria()::text') || (select string_agg(id||':'||acao, ',' order by id) from public.auditoria));
  perform t.afirma('eventos antigos do protocolo excluído permanecem', exists (select 1 from public.auditoria where acao = 'PROTOCOLO_CRIADO' and protocolo_id = v_id));

  r := t.como('gestor@x', $q$select (public.registrar_protocolo('Segundo documento a excluir','5555',null,'correspondencia')->>'id')$q$);
  v_id2 := r::bigint;
  r := t.como('gestor@x', format($q$select public.excluir_protocolo(%s,'Registro feito por engano','5555',true)::text$q$, v_id2));
  perform t.afirma('exclusão com remoção da trilha do protocolo', (r::jsonb->>'trilha_removida')::int >= 1
     and not exists (select 1 from public.auditoria where protocolo_id = v_id2 and acao <> 'PROTOCOLO_EXCLUIDO'), r);
  perform t.afirma('cadeia íntegra após remover trilha do protocolo', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');

  -- os demais caminhos continuam imutáveis
  begin delete from public.auditoria; perform t.afirma('delete direto na auditoria continua bloqueado', false);
  exception when others then perform t.afirma('delete direto na auditoria continua bloqueado', sqlerrm like '%imutável%', sqlerrm); end;
  begin delete from public.tramites; perform t.afirma('delete direto nas etapas continua bloqueado', false);
  exception when others then perform t.afirma('delete direto nas etapas continua bloqueado', sqlerrm like '%imutável%', sqlerrm); end;
  r := t.como('gestor@x', 'delete from public.protocolos');
  perform t.afirma('cliente não apaga protocolos direto', r like 'ERRO:%', r);

  -- limpar trilha
  r := t.como('adm@x', $q$select public.limpar_trilha('tudo',null,null,'Limpeza geral de testes','2222')::text$q$);
  perform t.afirma('ADM não limpa a trilha', r like 'ERRO:%gestor%', r);
  r := t.como('gestor@x', $q$select public.limpar_trilha('semana',null,null,'Limpeza geral de testes','5555')::text$q$);
  perform t.afirma('modo inválido é recusado', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select public.limpar_trilha('periodo',null,null,'Limpeza geral de testes','5555')::text$q$);
  perform t.afirma('período exige as duas datas', r like 'ERRO:%data%', r);
  r := t.como('gestor@x', $q$select public.limpar_trilha('periodo','2020-01-01','2020-12-31','Limpeza de dados antigos','5555')::text$q$);
  perform t.afirma('período sem eventos não remove nada', (r::jsonb->>'removidos') = '0', r);
  select count(*) into v_n from public.auditoria;
  r := t.como('gestor@x', $q$select public.limpar_trilha('periodo',(now() - interval '1 day')::date,(now() + interval '1 day')::date,'Limpeza de dados de teste','5555')::text$q$);
  perform t.afirma('gestor limpa a trilha por período', (r::jsonb->>'removidos')::int = v_n, r || ' / ' || v_n);
  perform t.afirma('sobra só o registro da exclusão, com cadeia íntegra', (select count(*) from public.auditoria) = 1
     and (select acao from public.auditoria) = 'TRILHA_EXCLUIDA'
     and t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
  r := t.como('gestor@x', $q$select public.limpar_trilha('tudo',null,null,'Reinício da trilha de testes','5555')::text$q$);
  perform t.afirma('gestor limpa toda a trilha e o ato é registrado', (r::jsonb->>'removidos') = '1'
     and (select count(*) from public.auditoria) = 1 and (select detalhes->>'modo' from public.auditoria) = 'tudo', r);
  r := t.como('gestor@x', $q$select public.registrar_exportacao('TRILHA')::text$q$);
  perform t.afirma('trilha segue gravando depois da limpeza', (select count(*) from public.auditoria) = 2
     and t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true', r);
end $$;

-- 7b. melhorias (05): versão do schema, backup, retenção
do $$
declare r text;
begin
  perform t.afirma('schema_versao registra os 16 arquivos', (select count(*) from public.schema_versao) = 16 and public.versao_schema() = 16);
  perform t.afirma('tabela schema_versao não é legível pelo cliente', not has_table_privilege('authenticated', 'public.schema_versao', 'select'));
  update public.parametros set valor = '4' where chave = 'alerta_prazo_dias';
  perform t.afirma('semáforo "vence em breve" acompanha o parâmetro de antecedência',
     public._semaforo((now() at time zone public._fuso())::date + 4, 'pendente_adm') = 'critico' and public._semaforo((now() at time zone public._fuso())::date + 5, 'pendente_adm') = 'atencao'
     and (public.resumo_livro()->>'alerta_dias') = '4');
  perform t.afirma('usuário comum lê o resumo e o semáforo (sem permissão direta ao parâmetro)',
     t.como('far@x', 'select (public.resumo_livro()->>''alerta_dias'')') = '4' and t.como('far@x', 'select count(*) >= 0 from public.v_livro') = 'true');
  update public.parametros set valor = '2' where chave = 'alerta_prazo_dias';
  perform t.afirma('semáforo volta ao padrão de 2 dias', public._semaforo((now() at time zone public._fuso())::date + 3, 'pendente_adm') = 'atencao');
  r := t.como('far@x', $q$select public.exportar_backup()::text$q$);
  perform t.afirma('backup é negado a quem não é gestor', r like 'ERRO:%', r);
  r := t.como('far@x', $q$select public.retencao_resumo(60)::text$q$);
  perform t.afirma('retenção é negada a quem não é gestor', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select public.exportar_backup()::text$q$);
  perform t.afirma('gestor exporta o backup completo', (r::jsonb ? 'protocolos') and (r::jsonb ? 'tramites') and (r::jsonb ? 'auditoria')
     and (r::jsonb->>'versao_schema') = '16', left(r, 120));
  perform t.afirma('backup não leva a imagem da assinatura', r not like '%assinatura_png%');
  perform t.afirma('exportação do backup é registrada na trilha', exists (select 1 from public.auditoria where acao = 'BACKUP_EXPORTADO')
     and t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
  r := t.como('gestor@x', $q$select public.retencao_resumo(0)::text$q$);
  perform t.afirma('prazo de guarda inválido é recusado', r like 'ERRO:%', r);
  r := t.como('gestor@x', $q$select public.retencao_resumo(1)::text$q$);
  perform t.afirma('resumo de retenção devolve contagens', (r::jsonb ? 'protocolos') and (r::jsonb ? 'fotos'), r);
end $$;

-- 7c. tempo de inatividade ajustável (06)
do $$
declare r text;
begin
  perform t.afirma('padrão de inatividade é de 6 horas (usuário comum lê)', t.como('far@x', 'select (public.sessao_config()->>''inatividade_min'')') = '360');
  r := t.como('gestor@x', $q$select public.painel_salvar_parametros('{"sessao_inatividade_min":"8h30"}'::jsonb)::text$q$);
  perform t.afirma('gestor ajusta a inatividade (8h30)', r like '%"ok": true%', r);
  perform t.afirma('valor é guardado em H:MM e aplicado', (select valor from public.parametros where chave = 'sessao_inatividade_min') = '8:30'
     and t.como('far@x', 'select (public.sessao_config()->>''inatividade_min'')') = '510');
  perform t.afirma('alteração da inatividade fica na trilha', exists (select 1 from public.auditoria where acao = 'PARAMETROS_ALTERADOS' and detalhes::text like '%sessao_inatividade_min%'));
  perform t.afirma('formatos aceitos: 90min, 1,5 e 6:00', public._validar_parametro('sessao_inatividade_min', '90min') = '1:30'
     and public._validar_parametro('sessao_inatividade_min', '1,5') = '1:30' and public._validar_parametro('sessao_inatividade_min', '6:00') = '6:00');
  perform t.afirma('tipo do parâmetro é duração', public._tipo_parametro('sessao_inatividade_min') = 'duracao');
  foreach r in array array['0', '4min', '25h', '2d', '1 dia', 'abc', ''] loop
    begin
      perform public._validar_parametro('sessao_inatividade_min', r);
      perform t.afirma('inatividade "' || r || '" deveria ser recusada', false);
    exception when others then
      perform t.afirma('inatividade "' || r || '" é recusada', true);
    end;
  end loop;
  r := t.como('far@x', $q$select public.painel_salvar_parametros('{"sessao_inatividade_min":"1h"}'::jsonb)::text$q$);
  perform t.afirma('quem não é gestor não altera a inatividade', r like 'ERRO:%', r);
  perform public.admin_definir_parametro('sessao_inatividade_min', '6:00');
end $$;

-- 7d. verificação em duas etapas (07)
do $$
declare r text; v_g uuid := (select id from auth.users where email = 'gestor@x'); v_far uuid := (select id from auth.users where email = 'far@x');
        v_n_prot int;
begin
  select count(*) into v_n_prot from public.protocolos;
  perform t.afirma('sem verificação ativa, a sessão aal1 funciona normalmente', t.como('gestor@x', 'select public.meu_papel()') = 'gestor');
  insert into auth.mfa_factors (user_id, status) values (v_g, 'verified');
  perform t.afirma('com fator ativo e sessão aal1 (só a senha) o servidor não reconhece o usuário', t.como('gestor@x', 'select coalesce(public.meu_papel(), ''nenhum'')') = 'nenhum');
  perform t.afirma('com o código (aal2) o acesso volta', t.como('gestor@x', 'select public.meu_papel()', 'aal2') = 'gestor');
  r := t.como('gestor@x', 'select public.exportar_backup()::text');
  perform t.afirma('funções do gestor recusam sessão aal1 com fator ativo', r like 'ERRO:%', r);
  perform t.afirma('funções do gestor funcionam em aal2', t.como('gestor@x', 'select (public.exportar_backup() ? ''protocolos'')::text', 'aal2') = 'true');
  perform t.afirma('as tabelas (RLS) ficam vazias para sessão aal1', t.como('gestor@x', 'select count(*) from public.protocolos') = '0'
     and t.como('gestor@x', 'select count(*) from public.protocolos', 'aal2') = v_n_prot::text, v_n_prot::text);
  r := t.como('gestor@x', 'select public.mfa_estado()::text');
  perform t.afirma('mfa_estado responde mesmo antes do código', (r::jsonb->>'tem_fator') = 'true' and (r::jsonb->>'aal') = 'aal1', r);
  perform t.afirma('outro usuário sem fator não é afetado', t.como('far@x', 'select public.meu_papel()') is not null);
  perform t.afirma('quem não é gestor não lista nem redefine verificação', t.como('far@x', 'select public.painel_mfa_usuarios()::text') like 'ERRO:%');
  perform t.afirma('lista de usuários com verificação (gestor, aal2)', t.como('gestor@x', 'select public.painel_mfa_usuarios()::text', 'aal2') like '%' || v_g::text || '%');
  -- exigência por parâmetro
  delete from auth.mfa_factors where user_id = v_g;
  update public.parametros set valor = 'true' where chave = 'mfa_gestor_obrigatorio';
  r := t.como('gestor@x', 'select public.mfa_estado()::text');
  perform t.afirma('com a exigência ligada, gestor sem fator em aal1 fica barrado e é avisado', t.como('gestor@x', 'select coalesce(public.meu_papel(), ''nenhum'')') = 'nenhum'
     and (r::jsonb->>'exigido') = 'true' and (r::jsonb->>'tem_fator') = 'false', r);
  perform t.afirma('com a exigência ligada, quem não é gestor segue normal', t.como('far@x', 'select public.meu_papel()') is not null);
  update public.parametros set valor = 'false' where chave = 'mfa_gestor_obrigatorio';
  perform t.afirma('exigência desligada libera de novo', t.como('gestor@x', 'select public.meu_papel()') = 'gestor');
  -- eventos na trilha
  r := t.como('far@x', 'select public.mfa_registrar_evento(''MFA_ATIVADO'')::text');
  perform t.afirma('evento de ativação sem fator real é recusado', r like 'ERRO:%', r);
  insert into auth.mfa_factors (user_id, status) values (v_far, 'verified');
  r := t.como('far@x', 'select ''ok'' from (select public.mfa_registrar_evento(''MFA_ATIVADO'')) x', 'aal2');
  perform t.afirma('com fator ativo, a ativação é registrada (em aal2)', r = 'ok' and exists (select 1 from public.auditoria where acao = 'MFA_ATIVADO'), r);
  -- redefinição pelo gestor
  r := t.como('gestor@x', format('select public.painel_resetar_mfa(%L, ''0000'')::text', v_far), 'aal2');
  perform t.afirma('PIN errado do gestor impede a redefinição', r like '%"ok": false%' and exists (select 1 from auth.mfa_factors where user_id = v_far), r);
  r := t.como('gestor@x', format('select public.painel_resetar_mfa(%L, ''5555'')::text', v_far), 'aal2');
  perform t.afirma('gestor redefine a verificação de outro usuário', r like '%"ok": true%' and not exists (select 1 from auth.mfa_factors where user_id = v_far), r);
  perform t.afirma('redefinição fica na trilha', exists (select 1 from public.auditoria where acao = 'MFA_REDEFINIDO' and usuario_nome = 'Paula Gestora'));
  r := t.como('gestor@x', format('select public.painel_resetar_mfa(%L, ''5555'')::text', v_g), 'aal2');
  perform t.afirma('ninguém redefine a própria verificação', r like 'ERRO:%', r);
  -- recuperação pelo SQL Editor
  insert into auth.mfa_factors (user_id, status) values (v_far, 'verified');
  r := t.como('gestor@x', 'select public.admin_resetar_mfa(''far@x'')::text', 'aal2');
  perform t.afirma('admin_resetar_mfa não é chamável pelo cliente', r like 'ERRO:%', r);
  v_n_prot := public.admin_resetar_mfa('far@x');
  perform t.afirma('admin_resetar_mfa (SQL Editor) remove os fatores e registra', v_n_prot = 1 and not exists (select 1 from auth.mfa_factors where user_id = v_far)
     and exists (select 1 from public.auditoria where acao = 'MFA_REDEFINIDO' and usuario_nome = 'SQL Editor'));
  perform t.afirma('cadeia da trilha segue íntegra', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
end $$;

-- 7e. fluxo (08): devolução, reencaminhamento, atalhos da lista e lembretes em escada
do $$
declare r text; j jsonb; v_id bigint; v_jur bigint := (select id from public.setores where nome = 'Jurídico');
        v_far bigint := (select id from public.setores where nome = 'Farmácia'); v_n int; v_ch text;
begin
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício de teste do fluxo 08','1111')::text$q$);
  v_id := (r::jsonb->>'id')::bigint;
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, v_id, v_jur));
  perform t.afirma('fluxo: ADM encaminha ao Jurídico', (r::jsonb->>'ok') = 'true', r);

  r := t.como('far@x', format($q$select public.devolver_protocolo(%s,'Documento enviado ao setor errado','4444')::text$q$, v_id));
  perform t.afirma('devolver: outro setor não enxerga nem devolve', r like 'ERRO:%não encontrado%', r);
  r := t.como('adm@x', format($q$select public.devolver_protocolo(%s,'Documento enviado ao setor errado','2222')::text$q$, v_id));
  perform t.afirma('devolver: ADM não devolve (ele reencaminha)', r like 'ERRO:%permiss%', r);
  r := t.como('jur@x', format($q$select public.devolver_protocolo(%s,'curta','3333')::text$q$, v_id));
  perform t.afirma('devolver exige justificativa', r like 'ERRO:%justificativa%', r);
  r := t.como('jur@x', format($q$select public.devolver_protocolo(%s,'Documento enviado ao setor errado','0000')::text$q$, v_id));
  perform t.afirma('devolver exige PIN', (r::jsonb->>'ok') = 'false', r);
  r := t.como('jur@x', format($q$select public.devolver_protocolo(%s,'Documento enviado ao setor errado','3333')::text$q$, v_id));
  perform t.afirma('setor devolve ao ADM', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('devolução zera o destino e marca o protocolo',
    exists (select 1 from public.protocolos where id = v_id and devolvido and setor_destino_id is null and status = 'pendente_setor'));
  r := t.como('jur@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('setor que devolveu deixa de ver o protocolo', r = 'true', r);
  r := t.como('jur@x', format($q$select public.devolver_protocolo(%s,'Documento enviado ao setor errado','3333')::text$q$, v_id));
  perform t.afirma('não devolve duas vezes', r like 'ERRO:%', r);
  r := t.como('gestor@x', format($q$select public.confirmar_etapa(%s,3,'5555')::text$q$, v_id));
  perform t.afirma('protocolo devolvido não é recebido por setor nenhum', r like 'ERRO:%devolvido%', r);
  perform t.afirma('devolução gera aviso ao ADM e entra na trilha',
    exists (select 1 from public.fila_email where evento = 'DEVOLVIDO' and protocolo_id = v_id and destinatarios = array['adm@x'])
    and exists (select 1 from public.auditoria where acao = 'PROTOCOLO_DEVOLVIDO' and protocolo_id = v_id and detalhes->>'de' = 'Jurídico'));
  perform t.afirma('pendências: ADM recebe o devolvido; setor não',
    (t.como('adm@x', format($q$select (select count(*) from jsonb_array_elements(public.minhas_pendencias()->'itens') e where (e->>'id')::bigint = %s)::text$q$, v_id))) = '1'
    and (t.como('jur@x', $q$select (public.minhas_pendencias()->>'total')$q$)) = '0');
  perform t.afirma('atalhos: devolvidos e meus (ADM)',
    t.como('adm@x', $q$select (public.listar_livro(null,null,null,null,25,0,'devolvidos')->>'total')$q$) = '1'
    and t.como('adm@x', format($q$select (select count(*) from jsonb_array_elements(public.listar_livro(null,null,null,null,100,0,'meus')->'itens') e where (e->>'id')::bigint = %s)::text$q$, v_id)) = '1'
    and t.como('adm@x', $q$select (public.resumo_livro()->>'devolvidos')$q$) = '1');

  r := t.como('jur@x', format($q$select public.reencaminhar_protocolo(%s,%s,'Encaminhar à Farmácia, setor correto','3333')::text$q$, v_id, v_far));
  perform t.afirma('setor não reencaminha', r like 'ERRO:%permiss%', r);
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,%s,'curta','2222')::text$q$, v_id, v_far));
  perform t.afirma('reencaminhar exige justificativa', r like 'ERRO:%justificativa%', r);
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,%s,'Encaminhar à Farmácia, setor correto','0000')::text$q$, v_id, v_far));
  perform t.afirma('reencaminhar exige PIN', (r::jsonb->>'ok') = 'false', r);
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,999999,'Encaminhar à Farmácia, setor correto','2222')::text$q$, v_id));
  perform t.afirma('reencaminhar exige setor ativo existente', r like 'ERRO:%setor%', r);
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,%s,'Encaminhar à Farmácia, setor correto','2222')::text$q$, v_id, v_far));
  perform t.afirma('ADM reencaminha à Farmácia', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('reencaminhamento limpa a devolução e define o novo destino',
    exists (select 1 from public.protocolos where id = v_id and not devolvido and setor_destino_id = v_far and sla_limite is null));
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,%s,'Mesmo setor de novo, sem motivo','2222')::text$q$, v_id, v_far));
  perform t.afirma('não reencaminha ao setor em que já está', r like 'ERRO:%já está%', r);
  perform t.afirma('Farmácia passa a ver; Jurídico não',
    t.como('far@x', format($q$select (public.detalhe_protocolo(%s) is not null)::text$q$, v_id)) = 'true'
    and t.como('jur@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id)) = 'true');
  r := t.como('far@x', format($q$select jsonb_array_length(public.detalhe_protocolo(%s)->'movimentacoes')::text$q$, v_id));
  perform t.afirma('histórico de movimentações no detalhe (devolvido + reencaminhado)', r = '2', r);
  begin update public.protocolos set setor_destino_id = v_jur where id = v_id;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('destino não muda fora do reencaminhamento/devolução', true);
  begin delete from public.movimentacoes;
    raise exception 'não deveria permitir'; exception when sqlstate '42501' then null; end;
  perform t.afirma('histórico de movimentações é imutável', true);
  perform t.afirma('reencaminhamento gera aviso à Farmácia e entra na trilha',
    exists (select 1 from public.fila_email where evento = 'REENCAMINHADO' and protocolo_id = v_id and destinatarios = array['far@x'])
    and exists (select 1 from public.auditoria where acao = 'PROTOCOLO_REENCAMINHADO' and protocolo_id = v_id and detalhes->>'para' = 'Farmácia'));

  -- sem escada de lembretes: o aviso ao setor saiu na hora do reencaminhamento e não há tempo de espera
  update public.protocolos set sla_limite = now() - interval '6 days' where id = v_id;
  perform public._verificar_sla();
  perform t.afirma('sla_limite é sempre zerado e nenhum aviso de SLA é gerado',
    exists (select 1 from public.protocolos where id = v_id and sla_limite is null)
    and not exists (select 1 from public.fila_email where chave like 'sla:%'));
  r := t.como('gestor@x', $q$select public.painel_salvar_parametros('{"sla_lembrete_min":"6:00"}'::jsonb)::text$q$, 'aal1');
  perform t.afirma('parâmetros de SLA não existem mais', r like 'ERRO:%sla_lembrete_min%', r);

  -- conclusão e travas finais
  r := t.como('far@x', format($q$select public.confirmar_etapa(%s,3,'4444')::text$q$, v_id));
  perform t.afirma('Farmácia conclui o protocolo reencaminhado', (r::jsonb->>'ok') = 'true', r);
  r := t.como('adm@x', format($q$select public.reencaminhar_protocolo(%s,%s,'Tentando depois de concluído','2222')::text$q$, v_id, v_jur));
  perform t.afirma('concluído não é reencaminhado', r like 'ERRO:%', r);
  perform t.afirma('exclusão e backup incluem as movimentações',
    (t.como('gestor@x', 'select (public.exportar_backup()->''movimentacoes'' is not null)::text')) = 'true');
  perform t.afirma('cadeia da trilha segue íntegra', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
end $$;

-- 8. bloqueio de PIN (transações separadas: as falhas precisam ser gravadas)
do $$
declare r text; i int;
begin
  for i in 1..5 loop
    r := t.como('far@x', $q$select public.alterar_meu_pin('0000','4321')::text$q$);
  end loop;
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','7351')::text$q$);
  perform t.afirma('após 5 erros o PIN fica bloqueado (mesmo com PIN certo)', r like '%bloqueado%', r);
  perform public.admin_desbloquear_pin('far@x');
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','43')::text$q$);
  perform t.afirma('novo PIN inválido é recusado', r like 'ERRO:%', r);
  r := t.como('far@x', $q$select public.alterar_meu_pin('4444','7351')::text$q$);
  perform t.afirma('troca de PIN após desbloqueio', (r::jsonb->>'ok') = 'true', r);
  r := t.como('far@x', $q$select public.alterar_meu_pin('7351','4455')::text$q$);
  perform t.afirma('PIN novo funciona', (r::jsonb->>'ok') = 'true', r);
end $$;

-- 9. alertas imediatos e e-mail pelo Brevo (pg_net simulado)
do $$
declare r text; v_log net.http_log%rowtype; v_k text := 'chave-brevo-de-teste-0123456789';
begin
  perform public._enfileirar_email('t9:sem-brevo', 'TESTE', null, array['adm@x'], 'Sem Brevo', 'corpo');
  perform t.afirma('sem Brevo configurado o item fica pendente (plano B: SMTP)',
    (select status from public.fila_email where chave = 't9:sem-brevo') = 'pendente');
  perform t.afirma('configuração do Brevo é recusada com chave curta', public.admin_configurar_brevo('curta', 'a@b.com') like 'ERRO:%');
  perform t.afirma('configuração do Brevo é recusada com e-mail inválido', public.admin_configurar_brevo(v_k, 'sem-arroba') like 'ERRO:%');
  perform t.afirma('Brevo configurado', public.admin_configurar_brevo(v_k, 'Avisos@Instituicao.org', 'Livro CECAN') like 'OK:%');

  perform public._enfileirar_email('t9:com-brevo', 'TESTE', null, array['adm@x', 'gestor@x'], 'Assunto 9', 'Corpo 9');
  perform t.afirma('com Brevo o envio sai na hora (status "enviando")',
    (select status || '/' || canal from public.fila_email where chave = 't9:com-brevo') = 'enviando/brevo');
  select * into v_log from net.http_log order by id desc limit 1;
  perform t.afirma('requisição vai à API do Brevo com a chave no cabeçalho',
    v_log.url = 'https://api.brevo.com/v3/smtp/email' and v_log.headers->>'api-key' = v_k, v_log.url);
  perform t.afirma('destinatários reais seguem em cópia oculta; remetente configurado',
    v_log.body->'bcc' @> '[{"email":"adm@x"},{"email":"gestor@x"}]'::jsonb and v_log.body->'sender'->>'email' = 'avisos@instituicao.org'
    and v_log.body->>'subject' = 'Assunto 9', v_log.body::text);
  perform public._conciliar_envios();
  perform t.afirma('resposta 2xx do Brevo marca como enviado',
    (select status from public.fila_email where chave = 't9:com-brevo') = 'enviado');

  perform public.admin_configurar_brevo('chave-ruim-chave-ruim-000000', 'avisos@instituicao.org');
  perform public._enfileirar_email('t9:chave-ruim', 'TESTE', null, array['adm@x'], 'Falha', 'x');
  perform public._conciliar_envios();
  perform t.afirma('resposta de erro do Brevo vira "erro" com motivo (o SMTP tenta de novo)',
    (select status || '|' || coalesce(erro, '') from public.fila_email where chave = 't9:chave-ruim') like 'erro|Brevo 401%');
  perform public.admin_configurar_brevo(v_k, 'avisos@instituicao.org');

  update public.fila_email set status = 'enviando', net_id = 999999, enviando_desde = now() - interval '11 minutes' where chave = 't9:chave-ruim';
  perform public._conciliar_envios();
  perform t.afirma('sem resposta em 10 minutos o item volta à fila do SMTP',
    (select status from public.fila_email where chave = 't9:chave-ruim') = 'pendente');

  -- o registro na Portaria avisa o ADM imediatamente
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício de teste imediato','1111')::text$q$);
  perform t.afirma('registro cria o protocolo', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('aviso de chegada ao ADM sai na hora',
    (select status from public.fila_email where evento = 'CHEGADA' order by id desc limit 1) = 'enviando');
  select * into v_log from net.http_log order by id desc limit 1;
  perform t.afirma('o e-mail não traz a descrição do documento (LGPD) nem tempo máximo',
    v_log.body->>'textContent' not like '%Ofício de teste imediato%' and v_log.body->>'textContent' not like '%Limite para%'
    and v_log.body->'bcc' @> '[{"email":"adm@x"}]'::jsonb, v_log.body->>'textContent');

  -- segurança e painel
  perform t.afirma('o navegador não lê a chave do Brevo',
    t.como('gestor@x', 'select count(*)::text from public.email_brevo') like 'ERRO:%');
  perform t.afirma('o navegador não chama a configuração do Brevo',
    t.como('gestor@x', $q$select public.admin_configurar_brevo('x','y')$q$) like 'ERRO:%');
  perform t.afirma('backup não leva a chave do Brevo', t.como('gestor@x', 'select public.exportar_backup()::text') not like '%' || v_k || '%');
  r := t.como('adm@x', 'select public.painel_email_teste()::text');
  perform t.afirma('só o gestor envia e-mail de teste', r like 'ERRO:%gestor%', r);
  r := t.como('gestor@x', 'select public.painel_email_teste()::text');
  perform t.afirma('e-mail de teste sai na hora ao próprio gestor',
    (r::jsonb->>'ok') = 'true' and (r::jsonb->>'imediato') = 'true' and (r::jsonb->>'destino') = 'gestor@x', r);
  perform t.afirma('painel informa que o Brevo está configurado',
    (t.como('gestor@x', 'select public.painel_resumo()->>''brevo_configurado''')) = 'true');
  perform public.admin_desativar_brevo();
  perform public._enfileirar_email('t9:desativado', 'TESTE', null, array['adm@x'], 'Desativado', 'x');
  perform t.afirma('com o Brevo desativado o item fica pendente',
    (select status from public.fila_email where chave = 't9:desativado') = 'pendente');
  perform t.afirma('cadeia da trilha segue íntegra no fim', t.como('gestor@x', 'select (public.verificar_auditoria()->>''ok'')') = 'true');
end $$;

-- 10. relatórios, verificação da instalação e avisos no aparelho
do $$
declare r text; v_log net.http_log%rowtype; v_pub text := repeat('B', 87); v_n int;
begin
  r := t.como('gestor@x', 'select public.painel_relatorio()::text');
  perform t.afirma('relatório do gestor traz totais, tempos, setores, dias e atrasos',
    (r::jsonb ? 'totais') and (r::jsonb ? 'tempo_horas') and (r::jsonb ? 'por_setor') and (r::jsonb ? 'por_dia') and (r::jsonb ? 'atrasados'), left(r, 200));
  perform t.afirma('relatório: soma por dia = registrados',
    (select sum((d->>'registrados')::int) from jsonb_array_elements(r::jsonb->'por_dia') d) = (r::jsonb->'totais'->>'registrados')::int, r);
  perform t.afirma('relatório: concluídos + em andamento = registrados',
    (r::jsonb->'totais'->>'concluidos')::int + (r::jsonb->'totais'->>'em_andamento')::int = (r::jsonb->'totais'->>'registrados')::int, r);
  perform t.afirma('relatório não carrega descrição de documentos', r not like '%Ofício de teste imediato%');
  r := t.como('gestor@x', $q$select public.painel_relatorio(current_date + 3, current_date)::text$q$);
  perform t.afirma('relatório recusa período invertido', r like 'ERRO:%data final%', r);
  r := t.como('gestor@x', $q$select public.painel_relatorio(current_date - 400, current_date)::text$q$);
  perform t.afirma('relatório recusa período maior que 12 meses', r like 'ERRO:%12 meses%', r);
  r := t.como('adm@x', 'select public.painel_relatorio()::text');
  perform t.afirma('só o gestor gera relatório', r like 'ERRO:%', r);
  perform t.afirma('geração do relatório fica na trilha', exists (select 1 from public.auditoria where acao = 'RELATORIO_GERADO'));

  r := t.como('gestor@x', 'select public.painel_diagnostico()::text');
  perform t.afirma('verificação da instalação lista os itens e não acusa erro', (r::jsonb->>'ok') = 'true' and jsonb_array_length(r::jsonb->'itens') >= 14, r);
  perform t.afirma('verificação confirma RLS e acesso direto bloqueado',
    exists (select 1 from jsonb_array_elements(r::jsonb->'itens') i where i->>'item' like 'Proteção por linha%' and i->>'nivel' = 'ok')
    and exists (select 1 from jsonb_array_elements(r::jsonb->'itens') i where i->>'item' like 'Acesso direto%' and i->>'nivel' = 'ok'), r);
  perform t.afirma('só o gestor roda a verificação', t.como('adm@x', 'select public.painel_diagnostico()::text') like 'ERRO:%');
  execute 'grant select on public.email_brevo to authenticated';
  perform t.afirma('verificação detecta tabela sensível exposta',
    (t.como('gestor@x', 'select public.painel_diagnostico()->>''ok''')) = 'false');
  execute 'revoke all on public.email_brevo from authenticated';

  -- avisos no aparelho
  perform t.afirma('inscrição é recusada enquanto o gestor não ativa o recurso',
    t.como('adm@x', $q$select public.push_registrar('https://push.exemplo/abc', repeat('p', 87), repeat('a', 22))::text$q$) like 'ERRO:%não foram ativados%');
  perform t.afirma('configuração de push recusa endereço sem https', public.admin_configurar_push('http://x', repeat('s', 30), v_pub) like 'ERRO:%');
  perform t.afirma('configuração de push recusa segredo curto', public.admin_configurar_push('https://x.supabase.co/functions/v1/enviar-push', 'curto', v_pub) like 'ERRO:%');
  perform t.afirma('configuração de push recusa chave pública incompleta', public.admin_configurar_push('https://x.supabase.co/functions/v1/enviar-push', repeat('s', 30), 'abc') like 'ERRO:%');
  perform t.afirma('push configurado', public.admin_configurar_push('https://x.supabase.co/functions/v1/enviar-push', repeat('s', 30), v_pub) like 'OK:%');
  perform t.afirma('usuário lê só a chave pública', t.como('adm@x', 'select public.push_chave_publica()') = v_pub);
  perform t.afirma('navegador não lê a configuração do push', t.como('adm@x', 'select count(*)::text from public.push_config') like 'ERRO:%');
  perform t.afirma('navegador não lê as inscrições diretamente', t.como('adm@x', 'select count(*)::text from public.push_inscricoes') like 'ERRO:%');
  perform t.afirma('inscrição recusa endereço sem https',
    t.como('adm@x', $q$select public.push_registrar('http://inseguro', repeat('p', 87), repeat('a', 22))::text$q$) like 'ERRO:%');
  r := t.como('adm@x', $q$select public.push_registrar('https://push.exemplo/adm1', repeat('p', 87), repeat('a', 22), 'Teste')::text$q$);
  perform t.afirma('ADM inscreve o aparelho', r like '%"ok": true%', r);

  perform public._enfileirar_email('t10:push', 'TESTE', null, array['adm@x'], '[Protocolo] 2026-9999 chegou', 'corpo sem descrição');
  select * into v_log from net.http_log where url like 'https://x.supabase.co/functions/%' order by id desc limit 1;
  perform t.afirma('e-mail na fila também aciona o aviso no aparelho do destinatário',
    v_log.id is not null and v_log.body->'subs'->0->>'endpoint' = 'https://push.exemplo/adm1'
    and v_log.headers->>'x-push-secret' = repeat('s', 30), coalesce(v_log.body::text, 'sem chamada'));
  perform t.afirma('aviso no aparelho traz só o número e texto genérico (LGPD)',
    v_log.body->'payload'->>'title' = '2026-9999 chegou' and v_log.body->'payload'->>'body' not like '%descrição%', v_log.body::text);
  select count(*) into v_n from net.http_log where url like 'https://x.supabase.co/functions/%';
  perform public._enfileirar_email('t10:push-sem-aparelho', 'TESTE', null, array['gestor@x'], '[Protocolo] sem aparelho', 'x');
  perform t.afirma('quem não ativou o aparelho não gera chamada', (select count(*) from net.http_log where url like 'https://x.supabase.co/functions/%') = v_n);

  for i in 1..6 loop
    perform t.como('adm@x', format($q$select public.push_registrar('https://push.exemplo/lim%s', repeat('p', 87), repeat('a', 22))::text$q$, i));
  end loop;
  perform t.afirma('cada usuário mantém no máximo 5 aparelhos',
    (select count(*) from public.push_inscricoes i join public.perfis p on p.user_id = i.user_id where p.email = 'adm@x') = 5);
  r := t.como('adm@x', $q$select public.push_remover('https://push.exemplo/lim6')::text$q$);
  perform t.afirma('aparelho pode ser removido', r like '%"ok": true%', r);
  perform t.afirma('aparelho removido some da lista', not exists (select 1 from public.push_inscricoes where endpoint = 'https://push.exemplo/lim6'));
  perform t.afirma('painel informa push configurado e aparelhos',
    (t.como('gestor@x', 'select (public.painel_resumo()->>''push_configurado'') || ''/'' || (public.painel_resumo()->>''push_aparelhos'')')) = 'true/4');
  perform t.afirma('backup não leva segredo do push', t.como('gestor@x', 'select public.exportar_backup()::text') not like '%' || repeat('s', 30) || '%');
  perform public.admin_desativar_push();
  perform t.afirma('com push desativado ninguém recebe a chave', t.como('adm@x', 'select coalesce(public.push_chave_publica(), ''nenhuma'')') = 'nenhuma');
end $$;

-- ---------------------------------------------------------------------
-- 12. QR Code (busca por número), urgência automática e exclusão de usuário
-- ---------------------------------------------------------------------
do $$
declare r text; v_u uuid; v_id bigint; v_foto text; v_num text; v_fotoc text; v_ok boolean; v_ger uuid; v_por uuid;
begin
  v_por := (select id from auth.users where email = 'portaria@x');
  -- toda demanda judicial é urgente, mesmo sem marcar; correspondência nunca é urgente (e não dá mais erro)
  v_foto := v_por::text || '/' || gen_random_uuid()::text || '.jpg';
  perform t.como('portaria@x', format($q$insert into storage.objects (bucket_id,name,owner,metadata) values ('protocolo-fotos',%L,auth.uid(),'{"size":1000}') returning 'ok'$q$, v_foto));
  r := t.como('portaria@x', format($q$select public.registrar_protocolo('Mandado - urgência automática','1111',null,'judicial',false,%L)::text$q$, v_foto));
  perform t.afirma('judicial registrado sem marcar urgência', r like '%"ok": true%', r);
  v_id := (r::jsonb->>'id')::bigint; v_num := r::jsonb->>'numero';
  perform t.afirma('judicial é urgente automaticamente', (select urgente from public.protocolos where id = v_id));
  perform t.afirma('e-mail de chegada do judicial leva URGENTE no assunto',
    exists (select 1 from public.fila_email where chave = 'chegada:' || v_id and assunto like '%URGENTE%'));
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Carta comum','1111',null,'correspondencia',true,null)::text$q$);
  perform t.afirma('correspondência com urgência marcada é aceita e não é urgente', r like '%"ok": true%'
    and not (select urgente from public.protocolos where id = (r::jsonb->>'id')::bigint), r);
  v_ok := true;
  begin update public.protocolos set urgente = false where id = v_id; v_ok := false; exception when others then v_ok := true; end;
  perform t.afirma('urgência não pode ser alterada à mão', v_ok and (select urgente from public.protocolos where id = v_id));
  perform t.afirma('nenhum judicial deixou de ser urgente', not exists (select 1 from public.protocolos where tipo = 'judicial' and not urgente)
    and not exists (select 1 from public.protocolos where tipo <> 'judicial' and urgente));

  -- impressão da folha de identificação entra na auditoria
  r := t.como('portaria@x', format($q$select public.registrar_exportacao('FOLHA', %s)::text$q$, v_id));
  perform t.afirma('impressão da folha de identificação é auditada', r not like 'ERRO:%'
    and exists (select 1 from public.auditoria where acao = 'IMPRESSAO_FOLHA' and detalhes->>'numero' = v_num), r);
  r := t.como('portaria@x', $q$select public.registrar_exportacao('OUTRA')::text$q$);
  perform t.afirma('tipo de impressão inválido é recusado', r like 'ERRO:%', r);

  -- QR Code: número -> protocolo
  r := t.como('gestor@x', format($q$select public.protocolo_por_numero(%L)::text$q$, v_num));
  perform t.afirma('QR: gestor localiza o protocolo pelo número', r = v_id::text, r);
  r := t.como('adm@x', format($q$select public.protocolo_por_numero(%L)::text$q$, v_num));
  perform t.afirma('QR: ADM localiza o protocolo pelo número', r = v_id::text, r);
  r := t.como('far@x', format($q$select coalesce(public.protocolo_por_numero(%L)::text, 'nulo')$q$, v_num));
  perform t.afirma('QR: setor sem acesso não enxerga protocolo que não é seu', r = 'nulo', r);
  r := t.como('gestor@x', $q$select coalesce(public.protocolo_por_numero('0000-0000')::text, 'nulo')$q$);
  perform t.afirma('QR: número inexistente devolve nulo', r = 'nulo', r);
  r := t.como('gestor@x', $q$select coalesce(public.protocolo_por_numero('1; drop table x')::text, 'nulo')$q$);
  perform t.afirma('QR: número malformado devolve nulo', r = 'nulo', r);
  r := (select coalesce(t.como('anon', $q$select public.protocolo_por_numero('2026-0001')::text$q$), ''));
  perform t.afirma('QR: sem login não há busca', r like 'ERRO:%' or r = '', r);

  -- excluir usuário
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('apagar@x.com','Usuário a Apagar','portaria',null,'Senha-Forte-123','2468','5555')::text$q$);
  v_u := (r::jsonb->>'user_id')::uuid;
  perform t.afirma('usuário de teste criado', v_u is not null, r);
  r := t.como('gestor@x', format($q$select public.painel_excluir_usuario(%L,'5555')::text$q$, v_u));
  perform t.afirma('não exclui usuário ativo', r like 'ERRO:%inativo%', r);
  perform t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,false,'5555')::text$q$, v_u));
  r := t.como('gestor@x', format($q$select public.painel_excluir_usuario(%L,'0000')::text$q$, v_u));
  perform t.afirma('exclusão exige o PIN do gestor', r like '%"ok": false%' and exists (select 1 from public.perfis where user_id = v_u), r);
  r := t.como('adm@x', format($q$select public.painel_excluir_usuario(%L,'1111')::text$q$, v_u));
  perform t.afirma('só gestor exclui usuário', r like 'ERRO:%' and exists (select 1 from public.perfis where user_id = v_u), r);
  v_ger := (select id from auth.users where email = 'gestor@x');
  r := t.como('gestor@x', format($q$select public.painel_excluir_usuario(%L,'5555')::text$q$, v_ger));
  perform t.afirma('gestor não exclui a si mesmo', r like 'ERRO:%próprio%', r);
  r := t.como('gestor@x', format($q$select public.painel_excluir_usuario(%L,'5555')::text$q$, v_u));
  perform t.afirma('exclui usuário inativo sem histórico', r like '%"ok": true%', r);
  perform t.afirma('perfil e login foram apagados', not exists (select 1 from public.perfis where user_id = v_u) and not exists (select 1 from auth.users where id = v_u));
  perform t.afirma('exclusão fica na auditoria', exists (select 1 from public.auditoria where acao = 'USUARIO_EXCLUIDO' and detalhes->>'email' = 'apagar@x.com'));
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('apagar@x.com','Mesmo e-mail de novo','portaria',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('o e-mail pode ser reutilizado depois da exclusão', r like '%"ok": true%', r);
  -- quem já participou de protocolos não pode ser excluído (o livro mantém o responsável)
  perform t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,false,'5555')::text$q$, v_por));
  r := t.como('gestor@x', format($q$select public.painel_excluir_usuario(%L,'5555')::text$q$, v_por));
  perform t.afirma('usuário com histórico não é excluído', r like 'ERRO:%participou de protocolos%' and exists (select 1 from public.perfis where user_id = v_por)
    and exists (select 1 from auth.users where id = v_por), r);
  perform t.como('gestor@x', format($q$select public.painel_definir_ativo(%L,true,'5555')::text$q$, v_por));
  -- nomes no padrão "Primeira Letra Maiúscula"
  perform t.afirma('_nome_proprio: maiúsculas', public._nome_proprio('MARIA JOSE DE PAIVA RODRIGUES') = 'Maria Jose de Paiva Rodrigues');
  perform t.afirma('_nome_proprio: minúsculas e espaços extras', public._nome_proprio('  rauan   costa ') = 'Rauan Costa');
  perform t.afirma('_nome_proprio: acentos e partículas', public._nome_proprio('vÂNIA alvares DOS santos e silva') = 'Vânia Alvares dos Santos e Silva', public._nome_proprio('vÂNIA alvares DOS santos e silva'));
  perform t.afirma('_nome_proprio: apóstrofo', public._nome_proprio('joão d''ávila') = 'João D''Ávila', public._nome_proprio('joão d''ávila'));
  r := t.como('gestor@x', $q$select public.painel_criar_usuario('nome1@x.com','JOSÉ DA SILVA','portaria',null,'Senha-Forte-123','2468','5555')::text$q$);
  perform t.afirma('criar usuário padroniza o nome', r like '%"ok": true%' and exists (select 1 from public.perfis where email = 'nome1@x.com' and nome = 'José da Silva'), r);
  perform t.como('gestor@x', format($q$select public.painel_atualizar_usuario(%L,'ana maria de souza','portaria',null,'5555')::text$q$, (select user_id from public.perfis where email = 'nome1@x.com')));
  perform t.afirma('editar usuário padroniza o nome', exists (select 1 from public.perfis where email = 'nome1@x.com' and nome = 'Ana Maria de Souza'));
  perform t.afirma('schema 12 registrado', exists (select 1 from public.schema_versao where versao = 12));
end $$;

-- 13. Contas técnicas de teste: separação do Livro/relatórios, sem jamais ocultar nada da auditoria
--     (migração 14: a visão/posse deste recurso deixou de ser restrita a um e-mail e passou a valer
--     para qualquer gestor — ver seção 14 abaixo)
do $$
declare r text; j jsonb; v_portaria uuid; v_antes int; v_id_teste bigint;
begin
  v_portaria := (select id from auth.users where email = 'portaria@x');

  perform t.afirma('_pode_ver_teste: vale para qualquer gestor', public._pode_ver_teste((select p from public.perfis p where p.user_id = (select id from auth.users where email = 'gestor@x'))));
  perform t.afirma('_pode_ver_teste: não vale para quem não é gestor', not public._pode_ver_teste((select p from public.perfis p where p.user_id = (select id from auth.users where email = 'adm@x'))));

  -- qualquer gestor marca uma conta como técnica de teste; quem não é gestor, não
  r := t.como('adm@x', format($q$select public.painel_definir_conta_teste(%L,true,'1111')::text$q$, v_portaria));
  perform t.afirma('quem não é gestor não marca conta de teste', r like 'ERRO:%', r);
  r := t.como('gestor@x', format($q$select public.painel_definir_conta_teste(%L,true,'5555')::text$q$, v_portaria));
  perform t.afirma('qualquer gestor marca a Portaria como conta de teste', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('marcação de conta de teste fica na auditoria (nada é ocultado)',
    exists (select 1 from public.auditoria where acao = 'CONTA_MARCADA_TESTE' and detalhes->>'email' = 'portaria@x'));

  -- a contagem de produção (resumo_livro) não muda com o registro de teste
  -- (sempre via t.como, com uma identidade explícita — chamar a função "nua" deixaria o auth.uid()
  -- herdado do último t.como(), por ser set_config local à transação, e falsearia o teste)
  r := t.como('gestor@x', $q$select (public.resumo_livro()->>'total')$q$); v_antes := r::int;
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício de teste técnico - validação','1111')::text$q$);
  j := r::jsonb; v_id_teste := (j->>'id')::bigint;
  perform t.afirma('protocolo registrado por conta de teste fica marcado como teste', (j->>'ambiente') = 'teste', r);
  r := t.como('gestor@x', $q$select (public.resumo_livro()->>'total')$q$);
  perform t.afirma('por padrão, nem quem marcou a conta vê o registro de teste no total', r::int = v_antes, r);
  r := t.como('adm@x', $q$select (public.listar_livro()->>'total')$q$);
  perform t.afirma('ADM real não enxerga o protocolo de teste na fila dele', r::int = v_antes, r);

  -- só com o filtro explícito ("Incluir registros de teste") é que aparece
  r := t.como('gestor@x', $q$select (public.resumo_livro(false)->>'total')$q$);
  perform t.afirma('com o filtro desligado, o gestor não vê teste', r::int = v_antes, r);
  r := t.como('gestor@x', $q$select (public.resumo_livro(true)->>'total')$q$);
  perform t.afirma('com o filtro ligado, o gestor vê o registro de teste', r::int = v_antes + 1, r);
  r := t.como('gestor@x', format($q$select (public.detalhe_protocolo(%s)->>'ambiente')$q$, v_id_teste));
  perform t.afirma('gestor abre o detalhe do protocolo de teste', r = 'teste', r);

  -- nada disso tira o ato da trilha de auditoria: qualquer gestor continua vendo tudo
  r := t.como('gestor@x', format($q$select count(*)::text from public.auditoria where protocolo_id = %s and acao = 'PROTOCOLO_CRIADO'$q$, v_id_teste));
  perform t.afirma('a trilha de auditoria NUNCA esconde o ato de teste, nem de outro gestor', r = '1', r);

  -- e-mail de "chegada" não é dirigido ao ADM real para um protocolo que não existe de verdade
  perform t.afirma('protocolo de teste não dispara e-mail de chegada',
    not exists (select 1 from public.fila_email where protocolo_id = v_id_teste and evento = 'CHEGADA'));

  perform t.afirma('schema 13 registrado', exists (select 1 from public.schema_versao where versao = 13));
end $$;

-- 14. Blindagem de e-mail em qualquer etapa de um protocolo de teste + padronização visual (HTML)
do $$
declare r text; v_id_teste bigint; v_id_prod bigint; v_html text; v_portaria_teste uuid;
begin
  v_id_teste := (select id from public.protocolos where descricao = 'Ofício de teste técnico - validação');
  v_portaria_teste := (select id from auth.users where email = 'portaria@x');

  -- recebimento do ADM sobre um protocolo de teste não dispara o e-mail "ENCAMINHADO" ao setor
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,(select id from public.setores where nome='Jurídico'))::text$q$, v_id_teste));
  perform t.afirma('recebimento do ADM em protocolo de teste é registrado normalmente', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('recebimento do ADM em protocolo de teste não dispara e-mail',
    not exists (select 1 from public.fila_email where protocolo_id = v_id_teste and evento = 'ENCAMINHADO'));

  -- um protocolo de produção comum continua disparando e-mail normalmente, agora com versão HTML também
  perform t.como('gestor@x', format($q$select public.painel_definir_conta_teste(%L,false,'5555')::text$q$, v_portaria_teste));
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício comum para checar o HTML do e-mail','1111')::text$q$);
  v_id_prod := (r::jsonb->>'id')::bigint;
  select corpo_html into v_html from public.fila_email where protocolo_id = v_id_prod and evento = 'CHEGADA';
  perform t.afirma('protocolo comum dispara e-mail de chegada', v_html is not null);
  perform t.afirma('o e-mail tem versão HTML com a mesma identidade visual do sistema',
    v_html like '%<!DOCTYPE html%' and v_html like '%Livro de Protocolo Eletrônico%' and v_html not like '%<script%', left(v_html, 60));

  perform t.afirma('schema 14 registrado', exists (select 1 from public.schema_versao where versao = 14));
end $$;

-- 15. Correção: abrir o detalhe de um protocolo de teste a partir da Trilha de auditoria
--     (antes desta migração, detalhe_protocolo() herdava o filtro de ambiente de v_livro — pensado
--     só para o Livro/relatórios — e por isso um ADM ou a própria Portaria viam "Protocolo não
--     encontrado." ao clicar no número de um protocolo de teste na Trilha, embora o registro nunca
--     tivesse sumido: a trilha de auditoria sempre mostrou o ato normalmente, só o detalhe é que
--     estava sendo bloqueado por engano).
do $$
declare r text; v_id_teste bigint;
begin
  v_id_teste := (select id from public.protocolos where descricao = 'Ofício de teste técnico - validação');

  -- ADM (não é gestor, não é a conta de teste) tinha o detalhe ocultado pelo filtro do Livro; agora abre.
  r := t.como('adm@x', format($q$select (public.detalhe_protocolo(%s)->>'ambiente')$q$, v_id_teste));
  perform t.afirma('ADM consegue abrir o detalhe do protocolo de teste a partir da trilha', r = 'teste', r);

  -- a própria Portaria que registrou (hoje já não é conta de teste, ver seção 14) também abre o detalhe.
  r := t.como('portaria@x', format($q$select (public.detalhe_protocolo(%s)->>'ambiente')$q$, v_id_teste));
  perform t.afirma('Portaria consegue abrir o detalhe do protocolo de teste a partir da trilha', r = 'teste', r);

  -- mas a visão do Livro para quem não tem autorização de ver teste continua só em produção
  -- (a correção não muda em nada o que listar_livro/resumo_livro mostram, só o detalhe por id).
  r := t.como('adm@x', $q$select exists (select 1 from jsonb_array_elements((public.listar_livro()->'itens')) i where (i->>'id')::bigint = $q$ || v_id_teste || $q$)::text$q$);
  perform t.afirma('o Livro do ADM continua sem listar o protocolo de teste', r = 'false', r);

  -- quem não tem nenhuma permissão sobre o protocolo (super_setor de outro setor) continua sem acesso
  r := t.como('far@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id_teste));
  perform t.afirma('super_setor sem relação com o protocolo continua sem ver o detalhe (RLS, não o ambiente)', r = 'true', r);

  perform t.afirma('schema 15 registrado', exists (select 1 from public.schema_versao where versao = 15));
end $$;

-- 16. Delegação temporária de recebimento + produtividade por usuário + tendência no relatório
do $$
declare
  r text; j jsonb; v_id bigint; v_id2 bigint; v_del bigint;
  v_jur bigint := (select id from public.setores where nome = 'Jurídico');
  v_far bigint := (select id from public.setores where nome = 'Farmácia');
  v_jur_uid uuid := (select id from auth.users where email = 'jur@x');
  v_far_uid uuid := (select id from auth.users where email = 'far@x');
  v_adm_uid uuid := (select id from auth.users where email = 'adm@x');
begin
  perform t.afirma('schema 16 registrado', exists (select 1 from public.schema_versao where versao = 16));

  -- tabela de delegações fechada ao cliente
  perform t.afirma('tabela delegacoes não é legível pelo cliente',
     not has_table_privilege('authenticated', 'public.delegacoes', 'select')
     and not has_table_privilege('anon', 'public.delegacoes', 'select'));

  -- quem pode delegar
  r := t.como('adm@x', $q$select public.usuarios_para_delegar()::text$q$);
  perform t.afirma('ADM não delega (não é responsável por setor)', r like 'ERRO:%', r);
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date, 'teste', '3333')::text$q$, v_jur_uid));
  perform t.afirma('não é possível delegar para si mesmo', r like 'ERRO:%outra pessoa%', r);
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date, 'teste', '3333')::text$q$,
       (select id from auth.users where email = 'anon-sem-perfil@x')));
  perform t.afirma('não é possível delegar para quem não está ativo no sistema', r like 'ERRO:%não está ativa%', r);
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date + 5, current_date, 'teste', '3333')::text$q$, v_far_uid));
  perform t.afirma('data final anterior à inicial é recusada', r like 'ERRO:%anterior%', r);
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date, 'oi', '3333')::text$q$, v_far_uid));
  perform t.afirma('justificativa curta é recusada', r like 'ERRO:%justificativa%', r);
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date + 5, 'cobertura de férias', '0000')::text$q$, v_far_uid));
  perform t.afirma('PIN errado ao delegar retorna ok=false (sem exceção)', (r::jsonb->>'ok') = 'false', r);

  -- lista de candidatos não inclui quem está pedindo
  r := t.como('jur@x', $q$select public.usuarios_para_delegar()::text$q$);
  perform t.afirma('lista de candidatos à delegação não inclui o próprio responsável',
     not exists (select 1 from jsonb_array_elements(r::jsonb) u where (u->>'user_id')::uuid = v_jur_uid), r);

  -- protocolo pendente no Jurídico, antes de qualquer delegação
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício para delegação 16/2026','1111')::text$q$);
  v_id := (r::jsonb->>'id')::bigint;
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, v_id, v_jur));
  perform t.afirma('protocolo encaminhado ao Jurídico', (r::jsonb->>'ok') = 'true', r);

  r := t.como('far@x', format($q$select public.confirmar_etapa(%s,3,'4455')::text$q$, v_id));
  perform t.afirma('sem delegação ativa, a Farmácia não recebe pelo Jurídico', r like 'ERRO:%não encontrado%', r);
  r := t.como('far@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('sem delegação ativa, a Farmácia não vê o detalhe do protocolo do Jurídico', r = 'true', r);

  -- jur@x delega o recebimento do Jurídico para far@x por 5 dias
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date + 5, 'cobertura de férias', '3333')::text$q$, v_far_uid));
  perform t.afirma('delegação criada', (r::jsonb->>'ok') = 'true', r);
  v_del := (r::jsonb->>'id')::bigint;
  perform t.afirma('delegação registrada na trilha', exists (
     select 1 from public.auditoria where acao = 'DELEGACAO_CRIADA' and (detalhes->>'delegado') = 'Carlos Farmácia'));

  -- com a delegação ativa, far@x passa a enxergar e a poder tramitar o protocolo do Jurídico
  r := t.como('far@x', format($q$select (public.detalhe_protocolo(%s) is null)::text$q$, v_id));
  perform t.afirma('com delegação ativa, a Farmácia vê o detalhe do protocolo do Jurídico', r = 'false', r);
  r := t.como('far@x', format($q$select public.confirmar_etapa(%s,3,'4455')::text$q$, v_id));
  perform t.afirma('com delegação ativa, a Farmácia recebe pelo Jurídico', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('o recebimento via delegação fica marcado na trilha, de forma transparente', exists (
     select 1 from public.auditoria where acao = 'RECEBIMENTO_SETOR' and (detalhes->>'numero') = (select numero from public.protocolos where id = v_id)
       and (detalhes->>'via_delegacao') = 'true'));
  perform t.afirma('o trâmite registrado usa o setor de destino real do protocolo (Jurídico), não o setor da pessoa delegada',
     (select setor_nome from public.tramites where protocolo_id = v_id and etapa = 3) = 'Jurídico');

  -- uma pessoa de outro setor, sem delegação, continua sem acesso
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício para delegação 2 16/2026','1111')::text$q$);
  v_id2 := (r::jsonb->>'id')::bigint;
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, v_id2, v_far));
  r := t.como('jur@x', format($q$select public.confirmar_etapa(%s,3,'3333')::text$q$, v_id2));
  perform t.afirma('a delegação do Jurídico não dá acesso à Farmácia (não é via de mão dupla)', r like 'ERRO:%não encontrado%', r);

  -- devolução ao ADM também aceita quem tem delegação ativa
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício para devolução via delegação 16/2026','1111')::text$q$);
  j := r::jsonb;
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, (j->>'id')::bigint, v_jur));
  r := t.como('far@x', format($q$select public.devolver_protocolo(%s,'Documento não pertence a este setor','4455')::text$q$, (j->>'id')::bigint));
  perform t.afirma('com delegação ativa, a Farmácia também pode devolver ao ADM pelo Jurídico', (r::jsonb->>'ok') = 'true', r);

  -- revogação: pelo delegante, por qualquer gestor, e pela própria pessoa delegada (autoliberação)
  r := t.como('far@x', format($q$select public.painel_revogar_delegacao(%s,'0000')::text$q$, v_del));
  perform t.afirma('PIN errado ao revogar retorna ok=false (sem exceção)', (r::jsonb->>'ok') = 'false', r);
  r := t.como('adm@x', format($q$select public.painel_revogar_delegacao(%s,'2222')::text$q$, v_del));
  perform t.afirma('quem não é gestor nem parte da delegação não pode revogá-la', r like 'ERRO:%não pode revogar%', r);
  r := t.como('jur@x', format($q$select public.painel_revogar_delegacao(%s,'3333')::text$q$, v_del));
  perform t.afirma('o delegante revoga a própria delegação', (r::jsonb->>'ok') = 'true', r);
  perform t.afirma('revogação registrada na trilha', exists (select 1 from public.auditoria where acao = 'DELEGACAO_REVOGADA'));
  r := t.como('jur@x', format($q$select public.painel_revogar_delegacao(%s,'3333')::text$q$, v_del));
  perform t.afirma('não é possível revogar de novo uma delegação já revogada', r like 'ERRO:%já não está mais ativa%', r);

  -- depois de revogada, a Farmácia volta a não ter acesso ao Jurídico
  r := t.como('portaria@x', $q$select public.registrar_protocolo('Ofício pós-revogação 16/2026','1111')::text$q$);
  v_id2 := (r::jsonb->>'id')::bigint;
  r := t.como('adm@x', format($q$select public.confirmar_etapa(%s,2,'2222',null,%s)::text$q$, v_id2, v_jur));
  r := t.como('far@x', format($q$select public.confirmar_etapa(%s,3,'4455')::text$q$, v_id2));
  perform t.afirma('revogada a delegação, a Farmácia volta a não ter acesso ao Jurídico', r like 'ERRO:%não encontrado%', r);

  -- gestor pode revogar qualquer delegação, e a própria pessoa delegada pode se autoliberar
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date + 5, 'nova cobertura', '3333')::text$q$, v_far_uid));
  v_del := (r::jsonb->>'id')::bigint;
  r := t.como('gestor@x', format($q$select public.painel_revogar_delegacao(%s,'5555')::text$q$, v_del));
  perform t.afirma('o gestor revoga qualquer delegação', (r::jsonb->>'ok') = 'true', r);

  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date + 5, 'mais uma cobertura', '3333')::text$q$, v_far_uid));
  v_del := (r::jsonb->>'id')::bigint;
  r := t.como('far@x', format($q$select public.painel_revogar_delegacao(%s,'4455')::text$q$, v_del));
  perform t.afirma('a própria pessoa delegada pode se autoliberar', (r::jsonb->>'ok') = 'true', r);

  -- listagem: cada um vê o que deve ver, e o "pode revogar" é coerente
  r := t.como('jur@x', format($q$select public.painel_delegar_recebimento(%L, current_date, current_date + 5, 'cobertura para teste de listagem', '3333')::text$q$, v_far_uid));
  v_del := (r::jsonb->>'id')::bigint;
  j := t.como('far@x', $q$select public.painel_listar_delegacoes()::text$q$)::jsonb;
  perform t.afirma('a pessoa delegada vê a delegação na listagem e pode revogá-la',
     exists (select 1 from jsonb_array_elements(j) d where (d->>'id')::bigint = v_del and (d->>'pode_revogar')::boolean));
  j := t.como('adm@x', $q$select public.painel_listar_delegacoes()::text$q$)::jsonb;
  perform t.afirma('quem não tem relação com a delegação não a vê na listagem',
     not exists (select 1 from jsonb_array_elements(j) d where (d->>'id')::bigint = v_del));
  j := t.como('gestor@x', $q$select public.painel_listar_delegacoes()::text$q$)::jsonb;
  perform t.afirma('o gestor vê todas as delegações', exists (select 1 from jsonb_array_elements(j) d where (d->>'id')::bigint = v_del));
  perform public.painel_revogar_delegacao(v_del, '3333');   -- (como dono) não deixa pendência para os testes seguintes

  -- relatório: produtividade por usuário e tendência diária com registrados x concluídos
  j := t.como('gestor@x', format($q$select public.painel_relatorio(current_date - 5, current_date, false)::text$q$))::jsonb;
  perform t.afirma('relatório traz produtividade por usuário', jsonb_typeof(j->'por_usuario') = 'array' and jsonb_array_length(j->'por_usuario') > 0, (j->'por_usuario')::text);
  perform t.afirma('produtividade por usuário traz etapas e tempo médio',
     exists (select 1 from jsonb_array_elements(j->'por_usuario') u where (u->>'usuario') = 'João Adm' and (u->>'etapa2')::int > 0));
  perform t.afirma('tendência diária traz registrados e concluídos',
     jsonb_typeof(j->'por_dia') = 'array' and (select bool_and(d ? 'registrados' and d ? 'concluidos') from jsonb_array_elements(j->'por_dia') d));
end $$;
\echo '=== TODOS OS TESTES DO SCHEMA PASSARAM ==='
