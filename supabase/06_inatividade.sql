-- =====================================================================
-- 06 · TEMPO DE INATIVIDADE AJUSTÁVEL (logout automático)
-- Rode DEPOIS de schema.sql → 02 → 03 → 04 → 05. Idempotente.
-- O gestor ajusta o tempo em "Prazos e regras"; o padrão passa a ser 6 horas.
-- =====================================================================

insert into public.parametros (chave, valor, descricao) values
  ('sessao_inatividade_min', '6:00', 'Tempo sem uso (horas:minutos) após o qual o sistema encerra a sessão. De 5 min a 24 h.')
on conflict (chave) do nothing;

-- Quem ainda estava no padrão antigo de 30 minutos do navegador não tem valor no banco: passa a valer o padrão acima.

-- validação e tipo do novo parâmetro (cópias das funções do 04 com o ramo novo)
create or replace function public._validar_parametro(p_chave text, p_valor text) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := btrim(coalesce(p_valor, '')); n int; t time; m int;
begin
  if not exists (select 1 from public.parametros where chave = p_chave) then
    raise exception 'Parâmetro desconhecido: %.', p_chave;
  end if;
  if p_chave = 'url_sistema' then
    if v <> '' and v !~ '^https://[^\s]+$' then raise exception 'O endereço do sistema deve começar com https://'; end if;
  elsif p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao', 'mfa_gestor_obrigatorio') then
    if v not in ('true', 'false') then raise exception 'Use true ou false.'; end if;
  elsif p_chave in ('expediente_inicio', 'expediente_fim') then
    t := public._parse_hhmm(v);
    if t is null then raise exception 'Hora inválida. Use um formato como 08:00, 8h30 ou 17.'; end if;
    v := public._fmt_hhmm(t);
  elsif p_chave = 'sessao_inatividade_min' then
    if v ~* '\d\s*(d|dia|dias)$' then raise exception 'Use horas ou minutos (por exemplo 6h, 6:00 ou 90min); "dia" não vale aqui.'; end if;
    m := public._parse_duracao_min(v);
    if m is null then raise exception 'Tempo inválido. Use um formato como 6h, 6:00, 90min ou 1,5.'; end if;
    if m < 5 then raise exception 'O tempo de inatividade deve ser de pelo menos 5 minutos.'; end if;
    if m > 1440 then raise exception 'O tempo de inatividade não pode passar de 24 horas.'; end if;
    v := public._fmt_duracao(m);
  elsif p_chave like 'sla\_%\_min' then
    m := public._parse_duracao_min(v);
    if m is null then raise exception 'Tempo inválido. Use um formato como 4:00, 4h30, 90min ou 1d.'; end if;
    if m < 5 then raise exception 'O tempo máximo deve ser de pelo menos 5 minutos.'; end if;
    if m > 14400 then raise exception 'O tempo máximo não pode passar de 240 horas.'; end if;
    v := public._fmt_duracao(m);
  else
    if v !~ '^\d{1,3}$' then raise exception 'Informe um número inteiro de 0 a 365.'; end if;
    n := v::int;
    if n > 365 then raise exception 'Valor máximo: 365 dias.'; end if;
    v := n::text;
  end if;
  return v;
end $$;

create or replace function public._tipo_parametro(p_chave text) returns text
language sql immutable as $$
  select case when p_chave = 'url_sistema' then 'texto'
              when p_chave in ('foto_obrigatoria_judicial', 'gestor_ignora_segregacao', 'mfa_gestor_obrigatorio') then 'booleano'
              when p_chave in ('expediente_inicio', 'expediente_fim') then 'hora'
              when p_chave like 'sla\_%\_min' or p_chave = 'sessao_inatividade_min' then 'duracao'
              else 'numero' end
$$;


-- lido por qualquer usuário logado (o navegador aplica o tempo ao entrar)
create or replace function public.sessao_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('inatividade_min', public._param_min('sessao_inatividade_min', 360))
$$;

insert into public.schema_versao (versao, arquivo) values (6, '06_inatividade.sql') on conflict (versao) do nothing;

revoke all on function public.sessao_config() from public, anon;
grant execute on function public.sessao_config() to authenticated;
