-- =====================================================================
-- Verificação pós-instalação + recarga do cache de API (PostgREST)
--
-- Rode este arquivo no SQL Editor do Supabase DEPOIS de rodar o
-- instalacao_completa.sql mais recente (o que já traz a migração 13 —
-- "ambiente de testes técnicos" / conta de teste do Rauan Costa).
--
-- Ele não altera nenhum dado: só confere a versão instalada e avisa o
-- PostgREST para recarregar as funções/colunas novas.
-- =====================================================================

do $$
declare
  v_versao int;
  v_assinatura text;
begin
  select public.versao_schema() into v_versao;
  if v_versao is distinct from 13 then
    raise exception 'Schema está na versão % (esperado 13). O instalacao_completa.sql não terminou de rodar — '
      'role a tela do SQL Editor para cima e veja se apareceu algum ERROR no meio da execução.', v_versao;
  end if;

  select pg_get_function_identity_arguments(oid) into v_assinatura
  from pg_proc where proname = 'listar_livro';
  if v_assinatura is null or v_assinatura not like '%p_incluir_teste%' then
    raise exception 'A função listar_livro ainda não tem o parâmetro p_incluir_teste. '
      'A migração 13 não foi aplicada corretamente.';
  end if;

  raise notice 'OK: schema na versão 13, função listar_livro com p_incluir_teste presente.';
end $$;

-- avisa o PostgREST para recarregar o cache de funções/colunas agora
-- (o Supabase normalmente faz isso sozinho após um DDL, mas pode demorar
-- ou falhar silenciosamente quando uma função muda de assinatura)
notify pgrst, 'reload schema';

select 'cache do PostgREST: pedido de recarga enviado. Atualize a página do sistema (F5) em alguns segundos.' as resultado;
