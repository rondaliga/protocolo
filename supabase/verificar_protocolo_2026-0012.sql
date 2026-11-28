-- =====================================================================
-- Verificação pontual (SOMENTE LEITURA) — protocolo "2026-0012"
-- Cole e rode no SQL Editor do Supabase. Nenhum comando aqui altera dado nenhum.
-- =====================================================================

-- 1) O protocolo ainda existe? Qual o status e o ambiente (produção/teste)?
select id, numero, status, ambiente, created_at, created_by
  from public.protocolos
 where numero = '2026-0012';

-- 2) Quem o criou tinha (ou tem hoje) a conta marcada como "Teste"?
--    (o ambiente do protocolo é gravado uma única vez, no momento do registro — não muda depois)
select u.email, p.nome, p.papel, p.conta_teste as "conta_teste_hoje"
  from public.protocolos pr
  join public.perfis p on p.user_id = pr.created_by
  join auth.users u on u.id = p.user_id
 where pr.numero = '2026-0012';

-- 3) Existe algum registro de EXCLUSÃO desse protocolo na trilha? (se existir, aparece aqui,
--    com quem excluiu, quando e a justificativa — a trilha nunca esconde isso de nenhum gestor)
select a.ocorrido_em, a.usuario_nome, a.acao, a.detalhes
  from public.auditoria a
  join public.protocolos pr on pr.id = a.protocolo_id
 where pr.numero = '2026-0012' and a.acao = 'PROTOCOLO_EXCLUIDO';

-- 4) Todos os eventos da trilha ligados a esse protocolo, do mais antigo ao mais recente
--    (confirma que nada sumiu do histórico, só eventualmente a tela de detalhe que não abria)
select a.ocorrido_em, a.usuario_nome, a.acao, a.detalhes
  from public.auditoria a
  join public.protocolos pr on pr.id = a.protocolo_id
 where pr.numero = '2026-0012'
 order by a.ocorrido_em;
