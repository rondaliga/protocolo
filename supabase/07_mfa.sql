-- =====================================================================
-- 07 · VERIFICAÇÃO EM DUAS ETAPAS (TOTP) — apoio no banco
-- Rode DEPOIS de schema.sql → 02 → 03 → 04 → 05 → 06. Idempotente.
-- O cadastro e a conferência do código ficam no Supabase Auth (MFA/TOTP). Aqui o banco:
--   • recusa sessões sem o código quando ele é exigido (função public._uid(), definida no schema.sql);
--   • guarda o parâmetro "mfa_gestor_obrigatorio";
--   • registra na trilha quem ativou/desativou; permite ao gestor redefinir o acesso de quem perdeu o aparelho.
-- =====================================================================

insert into public.parametros (chave, valor, descricao) values
  ('mfa_gestor_obrigatorio', 'false', 'Quando "true", todo gestor precisa ter a verificação em duas etapas (código do aplicativo autenticador) para entrar.')
on conflict (chave) do nothing;

-- Situação do usuário logado. Usa o auth.uid() cru de propósito: precisa responder também antes do código (aal1).
create or replace function public.mfa_estado() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_aal text; v_tem boolean; v_gestor boolean; v_exige boolean;
begin
  if v_uid is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  begin v_aal := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'aal', 'aal1');
  exception when others then v_aal := 'aal1'; end;
  v_tem := exists (select 1 from auth.mfa_factors where user_id = v_uid and status::text = 'verified');
  v_gestor := exists (select 1 from public.perfis where user_id = v_uid and ativo and papel = 'gestor');
  v_exige := v_gestor and coalesce((select valor = 'true' from public.parametros where chave = 'mfa_gestor_obrigatorio'), false);
  return jsonb_build_object('aal', v_aal, 'tem_fator', v_tem, 'exigido', v_exige, 'gestor', v_gestor);
end $$;

-- Quem ativou ou desativou: o próprio usuário (já com o código) avisa a trilha; o banco confere o estado real.
create or replace function public.mfa_registrar_evento(p_evento text) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := public._uid(); v_nome text; v_tem boolean;
begin
  if v_uid is null then raise exception 'Sessão inválida.' using errcode = '28000'; end if;
  select nome into v_nome from public.perfis where user_id = v_uid and ativo;
  if v_nome is null then raise exception 'Usuário sem perfil ativo.'; end if;
  v_tem := exists (select 1 from auth.mfa_factors where user_id = v_uid and status::text = 'verified');
  if p_evento = 'MFA_ATIVADO' and v_tem then perform public._auditar(v_uid, v_nome, 'MFA_ATIVADO', null, '{}'::jsonb);
  elsif p_evento = 'MFA_DESATIVADO' and not v_tem then perform public._auditar(v_uid, v_nome, 'MFA_DESATIVADO', null, '{}'::jsonb);
  else raise exception 'Evento não confere com a situação atual da verificação em duas etapas.'; end if;
end $$;

-- Gestor: quais usuários têm a verificação ativa (para o selo na lista de usuários)
create or replace function public.painel_mfa_usuarios() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare g public.perfis%rowtype := public._exigir_gestor();
begin
  return coalesce((select jsonb_agg(distinct user_id) from auth.mfa_factors where status::text = 'verified'), '[]'::jsonb);
end $$;

-- Gestor: redefine a verificação de OUTRO usuário (perdeu o celular). Ele entra só com senha e cadastra de novo.
create or replace function public.painel_resetar_mfa(p_user_id uuid, p_pin_gestor text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare g public.perfis%rowtype := public._exigir_gestor(); a public.perfis%rowtype; v_msg text; v_n int;
begin
  select * into a from public.perfis where user_id = p_user_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if a.user_id = g.user_id then raise exception 'Peça a outro gestor para redefinir a sua verificação em duas etapas.'; end if;
  v_msg := public._checar_pin(g.user_id, p_pin_gestor);
  if v_msg is not null then return jsonb_build_object('ok', false, 'erro', v_msg); end if;
  delete from auth.mfa_factors where user_id = p_user_id; get diagnostics v_n = row_count;
  delete from auth.sessions where user_id = p_user_id;                   -- derruba as sessões abertas
  perform public._auditar(g.user_id, g.nome, 'MFA_REDEFINIDO', null, jsonb_build_object('email', a.email, 'nome', a.nome, 'fatores', v_n));
  return jsonb_build_object('ok', true, 'fatores', v_n);
end $$;

-- Recuperação pelo SQL Editor (último recurso, ex.: único gestor perdeu o celular):
--   select public.admin_resetar_mfa('gestor@exemplo.com');
create or replace function public.admin_resetar_mfa(p_email text) returns int
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_n int;
begin
  select user_id into v_id from public.perfis where lower(email) = lower(p_email);
  if v_id is null then raise exception 'E-mail não encontrado.'; end if;
  delete from auth.mfa_factors where user_id = v_id; get diagnostics v_n = row_count;
  delete from auth.sessions where user_id = v_id;
  perform public._auditar(null, 'SQL Editor', 'MFA_REDEFINIDO', null, jsonb_build_object('email', lower(p_email), 'fatores', v_n));
  return v_n;
end $$;

insert into public.schema_versao (versao, arquivo) values (7, '07_mfa.sql') on conflict (versao) do nothing;

revoke all on function public.mfa_estado(), public.mfa_registrar_evento(text), public.painel_mfa_usuarios(),
  public.painel_resetar_mfa(uuid, text), public.admin_resetar_mfa(text) from public, anon, authenticated;
grant execute on function public.mfa_estado(), public.mfa_registrar_evento(text), public.painel_mfa_usuarios(),
  public.painel_resetar_mfa(uuid, text) to authenticated;
