/* Configuração PÚBLICA do frontend.
 *
 * No GitHub Pages este arquivo é GERADO no deploy (scripts/build-site.sh) a partir das
 * variáveis do repositório — você não precisa commitá-lo.
 * Para testar localmente: copie para config.js e preencha.
 *
 * A chave "anon" é pública por desenho: quem protege os dados são o login e as
 * políticas RLS do banco. NUNCA coloque aqui a chave "service_role".
 */
window.APP_CONFIG = {
  SUPABASE_URL: 'https://SEU-PROJETO.supabase.co',
  SUPABASE_ANON_KEY: 'SUA_CHAVE_ANON_PUBLICA',
  UNIDADE: 'CECAN – LNRCC',
  TIMEZONE: 'America/Fortaleza',
  IDLE_MINUTES: 30,                 // logout automático por inatividade
  ASSINATURA_OBRIGATORIA: false     // true = exige desenho no quadro além do PIN
};
