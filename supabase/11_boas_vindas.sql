-- =====================================================================
-- MIGRAÇÃO 11 — E-mail formal com os dados de acesso ao criar um usuário
-- Rode DEPOIS da 10 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- Ao cadastrar um usuário, o painel chama painel_enviar_acesso(): o sistema confere que a senha e o PIN
-- informados são mesmo os provisórios do usuário e enfileira um e-mail formal (sai na hora pelo Brevo).
-- Por segurança, depois do envio o texto do e-mail (que contém as credenciais provisórias) é APAGADO do banco.
-- =====================================================================

-- apaga o corpo do e-mail de boas-vindas assim que ele é enviado
create or replace function public._trg_fila_apagar_credenciais() returns trigger
language plpgsql as $$
begin
  if new.evento = 'BOAS_VINDAS' and new.status = 'enviado' then
    new.corpo := '[Conteúdo removido após o envio, por segurança: continha credenciais provisórias.]';
  end if;
  return new;
end $$;

drop trigger if exists trg_fila_apagar_credenciais on public.fila_email;
create trigger trg_fila_apagar_credenciais before update on public.fila_email
  for each row execute function public._trg_fila_apagar_credenciais();

-- itens de boas-vindas que ficaram com erro por mais de 7 dias também perdem o texto
create or replace function public._limpar_boas_vindas() returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.fila_email set corpo = '[Conteúdo removido por segurança: continha credenciais provisórias.]', status = 'erro'
   where evento = 'BOAS_VINDAS' and status in ('pendente', 'erro') and criado_em < now() - interval '7 days'
     and corpo not like '[Conteúdo removido%';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.painel_enviar_acesso(
  p_user_id uuid, p_senha text, p_pin text, p_url text, p_unidade text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor(); u public.perfis%rowtype; v_enc text;
  v_url text := btrim(coalesce(p_url, '')); v_un text := regexp_replace(btrim(coalesce(p_unidade, '')), '\s+', ' ', 'g');
  v_setor text; v_papel text; v_corpo text; v_min int; v_tempo text; v_id bigint; v_dados text;
begin
  perform public._limpar_boas_vindas();
  select * into u from public.perfis where user_id = p_user_id;
  if not found or u.email is null then raise exception 'Usuário não encontrado ou sem e-mail.'; end if;
  if not u.deve_trocar_pin then raise exception 'Este usuário já concluiu o primeiro acesso. Use "Redefinir" para gerar novos dados.'; end if;
  if p_pin is null or u.pin_hash is null or crypt(p_pin, u.pin_hash) <> u.pin_hash then
    raise exception 'O PIN informado não é o PIN provisório deste usuário.';
  end if;
  if coalesce(u.deve_trocar_senha, false) then
    select encrypted_password into v_enc from auth.users where id = p_user_id;
    if p_senha is null or v_enc is null or crypt(p_senha, v_enc) <> v_enc then
      raise exception 'A senha informada não é a senha provisória deste usuário.';
    end if;
  end if;
  if v_url !~ '^https?://[^\s]+$' or length(v_url) > 200 then v_url := ''; end if;
  if length(v_un) > 120 or v_un ~ '[\r\n]' then v_un := ''; end if;

  v_papel := case u.papel when 'portaria' then 'Portaria' when 'adm' then 'ADM (Administração)'
                          when 'super_setor' then 'Responsável de setor' else 'Gestor' end;
  select nome into v_setor from public.setores where id = u.setor_id;
  v_min := public._param_min('sessao_inatividade_min', 360);
  v_tempo := case when v_min % 60 = 0 then (v_min / 60) || case when v_min = 60 then ' hora' else ' horas' end
             else v_min || ' minutos' end;

  v_dados := 'DADOS DE ACESSO' || E'\n'
    || '  Endereço do sistema: ' || case when v_url <> '' then v_url else '(solicite o endereço ao gestor)' end || E'\n'
    || '  Usuário (e-mail):    ' || u.email || E'\n'
    || '  Senha provisória:    ' || case when coalesce(u.deve_trocar_senha, false) then p_senha
                                        else '(mantida: a mesma senha que o(a) usuário(a) já utiliza)' end || E'\n'
    || '  PIN provisório:      ' || p_pin;

  v_corpo := 'Prezado(a) ' || u.nome || ',' || E'\n\n'
    || 'Informamos que foi criado o seu acesso ao Livro de Protocolo Eletrônico'
    || case when v_un <> '' then ' — ' || v_un else '' end || E'.\n\n'
    || 'SEU CADASTRO' || E'\n'
    || '  Nome:    ' || u.nome || E'\n'
    || '  Perfil:  ' || v_papel || case when v_setor is not null then ' — ' || v_setor else '' end || E'\n'
    || '  Criado em ' || to_char(now() at time zone public._fuso(), 'DD/MM/YYYY "às" HH24:MI') || ' por ' || g.nome || E'.\n\n'
    || v_dados || E'\n\n'
    || 'COMO FAZER O PRIMEIRO ACESSO' || E'\n'
    || '  1. Acesse o endereço do sistema e entre com o e-mail e a senha provisória acima.' || E'\n'
    || '  2. O sistema solicitará a criação de uma nova senha (de 10 a 72 caracteres, com letras e números) e de um novo PIN (de 4 a 6 dígitos).' || E'\n'
    || '  3. Se a verificação em duas etapas estiver ativada, cadastre o aplicativo autenticador no seu celular quando o sistema solicitar.' || E'\n'
    || '  4. O PIN é utilizado para confirmar cada recebimento e funciona como a sua assinatura eletrônica.' || E'\n\n'
    || 'ORIENTAÇÕES DE SEGURANÇA' || E'\n'
    || '  - O acesso é pessoal e intransferível. Não compartilhe a senha nem o PIN, nem os anote em local visível.' || E'\n'
    || '  - A senha e o PIN provisórios perdem a validade assim que forem substituídos no primeiro acesso.' || E'\n'
    || '  - Após o primeiro acesso, recomendamos excluir esta mensagem, que contém credenciais provisórias.' || E'\n'
    || '  - O PIN é bloqueado após tentativas incorretas consecutivas; nesse caso, solicite o desbloqueio ao gestor.' || E'\n'
    || '  - Por segurança, a sessão é encerrada após ' || v_tempo || ' sem uso.' || E'\n'
    || '  - Todas as ações realizadas ficam registradas na trilha de auditoria (data, hora e usuário), em conformidade com a Lei Geral de Proteção de Dados (LGPD).' || E'\n\n'
    || 'AVISOS' || E'\n'
    || '  Conforme o seu perfil, o(a) usuário(a) receberá e-mails e avisos no sistema quando houver protocolos que dependam de sua atenção.' || E'\n'
    || '  Opcionalmente, ative os avisos no celular em "Minha conta > Avisos neste aparelho".' || E'\n\n'
    || 'Em caso de dúvida, ou se não reconhecer esta mensagem, entre em contato com o gestor responsável pelo sistema.' || E'\n\n'
    || 'Atenciosamente,' || E'\n'
    || g.nome || E'\n'
    || 'Gestão do Livro de Protocolo' || case when v_un <> '' then E'\n' || v_un else '' end || E'\n\n'
    || 'Mensagem automática, enviada por solicitação do gestor. Não responda a este e-mail.';

  insert into public.fila_email (chave, evento, destinatarios, assunto, corpo)
  values ('boasvindas:' || p_user_id || ':' || extract(epoch from clock_timestamp())::bigint, 'BOAS_VINDAS', array[lower(u.email)],
          '[Livro de Protocolo] Dados de acesso ao sistema', v_corpo)
  returning id into v_id;
  perform public._auditar(g.user_id, g.nome, 'ACESSO_ENVIADO_POR_EMAIL', null, jsonb_build_object('usuario', u.nome, 'email', lower(u.email)));
  return jsonb_build_object('ok', true, 'email', lower(u.email),
           'imediato', coalesce((select status = 'enviando' from public.fila_email where id = v_id), false));
end $$;

insert into public.schema_versao (versao, arquivo) values (11, '11_boas_vindas.sql') on conflict (versao) do nothing;

revoke all on function public._trg_fila_apagar_credenciais(), public._limpar_boas_vindas(),
  public.painel_enviar_acesso(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.painel_enviar_acesso(uuid, text, text, text, text) to authenticated;
