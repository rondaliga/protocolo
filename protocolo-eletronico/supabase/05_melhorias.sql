-- =====================================================================
-- 05 · MELHORIAS: controle de versão do schema, índices, backup e retenção (LGPD)
-- Rode DEPOIS de schema.sql → 02 → 03 → 04. É idempotente: pode ser reexecutado.
-- =====================================================================

-- 1. Controle de versão: registra quais arquivos já foram aplicados ----------------------------
create table if not exists public.schema_versao (
  versao      int primary key,
  arquivo     text not null,
  aplicado_em timestamptz not null default now()
);
alter table public.schema_versao enable row level security;      -- sem políticas: só funções do servidor leem
revoke all on public.schema_versao from anon, authenticated;
insert into public.schema_versao (versao, arquivo) values
  (1, 'schema.sql'), (2, '02_prazos_alertas.sql'), (3, '03_painel_gestor.sql'),
  (4, '04_logo_horas_exclusoes.sql'), (5, '05_melhorias.sql')
on conflict (versao) do nothing;

create or replace function public.versao_schema() returns int
language sql stable security definer set search_path = public as $$
  select coalesce(max(versao), 0) from public.schema_versao
$$;

-- 2. Índices para os filtros e junções mais usados ----------------------------------------------
create index if not exists ix_protocolos_setor_destino on public.protocolos(setor_destino_id) where setor_destino_id is not null;
create index if not exists ix_protocolos_criador       on public.protocolos(created_by);
create index if not exists ix_tramites_protocolo       on public.tramites(protocolo_id);
create index if not exists ix_fotos_protocolo          on public.protocolo_fotos(protocolo_id);
create index if not exists ix_auditoria_ocorrido       on public.auditoria(ocorrido_em desc);
create index if not exists ix_auditoria_acao           on public.auditoria(acao, ocorrido_em desc);

-- 3. Backup (somente gestor): protocolos, etapas e trilha em JSON; o ato fica registrado ---------
create or replace function public.exportar_backup() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_perfil public.perfis%rowtype; v_prot jsonb; v_tram jsonb; v_aud jsonb;
begin
  select * into v_perfil from public.perfis where user_id = auth.uid() and ativo;
  if not found or v_perfil.papel <> 'gestor' then
    raise exception 'Apenas o gestor pode exportar o backup.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.id), '[]'::jsonb) into v_prot from public.protocolos p;
  -- a imagem da assinatura não entra no backup leve (continua no banco); o selo de integridade segue junto
  select coalesce(jsonb_agg((to_jsonb(t) - 'assinatura_png') order by t.id), '[]'::jsonb) into v_tram from public.tramites t;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.id), '[]'::jsonb) into v_aud from public.auditoria a;
  perform public._auditar(auth.uid(), v_perfil.nome, 'BACKUP_EXPORTADO', null,
            jsonb_build_object('protocolos', jsonb_array_length(v_prot), 'tramites', jsonb_array_length(v_tram),
                               'eventos', jsonb_array_length(v_aud)));
  return jsonb_build_object('gerado_em', now(), 'versao_schema', public.versao_schema(),
                            'protocolos', v_prot, 'tramites', v_tram, 'auditoria', v_aud);
end $$;

-- 4. Retenção (LGPD): quantos protocolos concluídos passaram do prazo de guarda -------------------
-- Apenas informa; a exclusão continua sendo ato explícito do gestor (excluir_protocolo), com justificativa e PIN.
create or replace function public.retencao_resumo(p_meses int default 60) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_perfil public.perfis%rowtype; v_corte timestamptz; v_n int; v_f int; v_mais timestamptz;
begin
  select * into v_perfil from public.perfis where user_id = auth.uid() and ativo;
  if not found or v_perfil.papel <> 'gestor' then
    raise exception 'Apenas o gestor pode consultar a retenção.' using errcode = '42501';
  end if;
  if p_meses is null or p_meses not between 1 and 600 then raise exception 'Informe o prazo de guarda entre 1 e 600 meses.'; end if;
  v_corte := now() - make_interval(months => p_meses);
  select count(*), min(p.created_at) into v_n, v_mais from public.protocolos p
   where p.status = 'concluido' and p.created_at < v_corte;
  select count(*) into v_f from public.protocolo_fotos f join public.protocolos p on p.id = f.protocolo_id
   where p.status = 'concluido' and p.created_at < v_corte;
  return jsonb_build_object('meses', p_meses, 'corte', v_corte, 'protocolos', v_n, 'fotos', v_f, 'mais_antigo', v_mais);
end $$;

-- 5. Permissões -------------------------------------------------------------------------------------
revoke all on function public.versao_schema(), public.exportar_backup(), public.retencao_resumo(int)
  from public, anon, authenticated;
grant execute on function public.versao_schema(), public.exportar_backup(), public.retencao_resumo(int) to authenticated;
