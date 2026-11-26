-- =====================================================================
-- MIGRAÇÃO 11 — E-mail formal com os dados de acesso ao criar um usuário
-- Rode DEPOIS da 10 (ou use instalacao_completa.sql). Pode ser executada mais de uma vez.
--
-- Ao cadastrar um usuário, o painel chama painel_enviar_acesso(): o sistema confere que a senha e o PIN
-- informados são mesmo os provisórios do usuário e enfileira um e-mail formal (sai na hora pelo Brevo).
-- Por segurança, depois do envio o texto do e-mail (que contém as credenciais provisórias) é APAGADO do banco.
-- =====================================================================

-- versão visual (HTML) do e-mail, além do texto simples (reserva para leitores sem HTML)
alter table public.fila_email add column if not exists corpo_html text;

-- escapa texto para uso dentro de HTML
create or replace function public._html_esc(p text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

-- apaga o corpo do e-mail de boas-vindas assim que ele é enviado
create or replace function public._trg_fila_apagar_credenciais() returns trigger
language plpgsql as $$
begin
  if new.evento = 'BOAS_VINDAS' and new.status = 'enviado' then
    new.corpo := '[Conteúdo removido após o envio, por segurança: continha credenciais provisórias.]';
    new.corpo_html := null;
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
  update public.fila_email set corpo = '[Conteúdo removido por segurança: continha credenciais provisórias.]', corpo_html = null, status = 'erro'
   where evento = 'BOAS_VINDAS' and status in ('pendente', 'erro') and criado_em < now() - interval '7 days'
     and corpo not like '[Conteúdo removido%';
  get diagnostics v_n = row_count;
  return v_n;
end $$;


-- envio imediato (Brevo): agora com versão HTML quando existir
create or replace function public._enviar_imediato(p_id bigint) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c public.email_brevo%rowtype; f public.fila_email%rowtype; v_net bigint; v_body jsonb;
begin
  select * into c from public.email_brevo where id = 1 and ativo;
  if not found then return; end if;
  select * into f from public.fila_email where id = p_id;
  if not found or f.status <> 'pendente' then return; end if;
  v_body := jsonb_build_object(
            'sender',      jsonb_build_object('name', c.remetente_nome, 'email', c.remetente_email),
            'to',          jsonb_build_array(jsonb_build_object('email', c.remetente_email)),
            'bcc',         (select jsonb_agg(jsonb_build_object('email', e)) from unnest(f.destinatarios) e),
            'subject',     f.assunto,
            'textContent', f.corpo);
  if f.corpo_html is not null then v_body := v_body || jsonb_build_object('htmlContent', f.corpo_html); end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)' into v_net
    using 'https://api.brevo.com/v3/smtp/email', v_body,
          jsonb_build_object('api-key', c.api_key, 'content-type', 'application/json', 'accept', 'application/json');
  update public.fila_email set status = 'enviando', net_id = v_net, canal = 'brevo', enviando_desde = now() where id = p_id;
exception when others then
  update public.fila_email set erro = left('Envio imediato: ' || sqlerrm, 300) where id = p_id;
end $$;

-- fila do SMTP (GitHub Actions): inclui a versão HTML
create or replace function public.integracao_fila(p_segredo text, p_limite int default 20) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public._segredo_ok(p_segredo);
  perform public._conciliar_envios();
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'destinatarios', f.destinatarios,
                          'assunto', f.assunto, 'corpo', f.corpo, 'corpo_html', f.corpo_html) order by f.id)
                     from (select * from public.fila_email
                            where status in ('pendente', 'erro') and tentativas < 5
                            order by id limit least(greatest(coalesce(p_limite, 20), 1), 50)) f), '[]'::jsonb);
end $$;

drop function if exists public.painel_enviar_acesso(uuid, text, text, text, text);
create or replace function public.painel_enviar_acesso(
  p_user_id uuid, p_senha text, p_pin text, p_url text, p_unidade text default null, p_logo_url text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  g public.perfis%rowtype := public._exigir_gestor(); u public.perfis%rowtype; v_enc text;
  v_url text := btrim(coalesce(p_url, '')); v_un text := regexp_replace(btrim(coalesce(p_unidade, '')), '\s+', ' ', 'g');
  v_logo text := btrim(coalesce(p_logo_url, ''));
  v_corpo text; v_html text; v_id bigint; v_senha text;
  v_em text; v_quando text; v_botao text; v_acesso text;
  c_azul constant text := '#1f4e6e'; c_fonte constant text := 'font-family:Segoe UI,Helvetica,Arial,sans-serif;';
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
  if v_url !~ '^https?://[^\s"''<>]+$' or length(v_url) > 200 then v_url := ''; end if;
  if v_logo !~ '^https?://[^\s"''<>]+\.(png|jpe?g|gif)$' or length(v_logo) > 300 then v_logo := ''; end if;
  if length(v_un) > 120 or v_un ~ '[\r\n]' then v_un := ''; end if;

  v_senha := case when coalesce(u.deve_trocar_senha, false) then p_senha else 'a mesma que você já utiliza' end;
  v_quando := to_char(now() at time zone public._fuso(), 'DD/MM/YYYY "às" HH24:MI');

  -- ---------- versão em texto simples (reserva; sem recuos, para copiar só o necessário) ----------
  v_corpo := 'Prezado(a) ' || u.nome || ',' || E'\n\n'
    || 'Seus dados de acesso:' || E'\n'
    || 'Usuário: ' || u.email || E'\n'
    || 'Senha provisória: ' || v_senha || E'\n'
    || 'PIN provisório: ' || p_pin || E'\n'
    || case when v_url <> '' then 'Acesse: ' || v_url || E'\n' else '' end || E'\n'
    || 'PRIMEIRO ACESSO' || E'\n'
    || 'Entre com o e-mail e a senha provisória e, quando solicitado, defina uma nova senha (10 a 72 caracteres, com letras e números) e um novo PIN (4 a 6 dígitos).' || E'\n\n'
    || 'O acesso é pessoal e intransferível. Exclua esta mensagem após o primeiro acesso.' || E'\n\n'
    || 'Atenciosamente,' || E'\n' || g.nome || E'\n' || 'Gestão do Livro de Protocolo' || case when v_un <> '' then ' · ' || v_un else '' end || E'\n\n'
    || 'Mensagem automática. Não responda a este e-mail.';

  -- ---------- versão visual (HTML: tabelas e estilos em linha, compatível com Outlook/Gmail) ----------
  v_botao := case when v_url <> ''
    then '<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:28px auto 6px;"><tr>'
      || '<td align="center" bgcolor="' || c_azul || '" style="border-radius:6px;"><a href="' || public._html_esc(v_url)
      || '" style="display:inline-block;padding:14px 40px;' || c_fonte || 'font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:6px;letter-spacing:.3px;">Acessar o sistema</a></td></tr></table>'
    else '' end;
  -- cada dado fica sozinho em sua célula, sem espaços em volta: seleciona-se (duplo clique) e copia-se só o valor
  v_acesso := '<tr><td style="padding:12px 0;border-bottom:1px solid #dbe5ee;' || c_fonte || 'font-size:12px;letter-spacing:1px;text-transform:uppercase;color:#6b7c8c;width:36%;">%L</td>'
           || '<td style="padding:12px 0;border-bottom:1px solid #dbe5ee;' || c_fonte || 'font-size:16px;color:#1b2733;font-weight:600;word-break:break-all;"><span style="user-select:all;-webkit-user-select:all;">%V</span></td></tr>';
  v_em := replace(replace(v_acesso, '%L', 'Usuário'), '%V', public._html_esc(u.email));
  v_em := v_em || replace(replace(v_acesso, '%L', 'Senha provisória'), '%V',
          case when coalesce(u.deve_trocar_senha, false)
               then '<span style="font-family:Consolas,Menlo,monospace;font-size:17px;letter-spacing:.5px;">' || public._html_esc(p_senha) || '</span>'
               else public._html_esc(v_senha) end);
  v_em := v_em || replace(replace(v_acesso, '%L', 'PIN provisório'), '%V',
          '<span style="font-family:Consolas,Menlo,monospace;font-size:17px;letter-spacing:3px;">' || public._html_esc(p_pin) || '</span>');

  v_html := '<!DOCTYPE html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    || '<meta name="color-scheme" content="light"><title>Dados de acesso</title></head>'
    || '<body style="margin:0;padding:0;background:#eef2f6;">'
    || '<div style="display:none;max-height:0;overflow:hidden;opacity:0;">Seus dados de acesso ao Livro de Protocolo Eletrônico.</div>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#eef2f6"><tr><td align="center" style="padding:28px 12px;">'
    || '<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background:#ffffff;border-radius:10px;overflow:hidden;border:1px solid #d3dce5;">'
    -- cabeçalho azul: logo da Liga à esquerda, título à direita
    || '<tr><td bgcolor="' || c_azul || '" style="padding:24px 30px;background:' || c_azul || ';"><table role="presentation" cellpadding="0" cellspacing="0" border="0" align="left"><tr>'
    || case when v_logo <> '' then '<td valign="middle" style="padding-right:18px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" width="64" height="64" bgcolor="#ffffff" style="width:64px;height:64px;background:#ffffff;border-radius:14px;">'
         || '<img src="' || public._html_esc(v_logo) || '" alt="Liga Contra o Câncer" width="48" height="48" style="display:block;margin:0 auto;border:0;width:48px;height:48px;"></td></tr></table></td>' else '' end
    || '<td valign="middle" align="left">'
    || '<div style="' || c_fonte || 'font-size:21px;font-weight:600;color:#ffffff;letter-spacing:.3px;line-height:1.25;">Livro de Protocolo Eletrônico</div>'
    || case when v_un <> '' then '<div style="' || c_fonte || 'font-size:13px;color:#cfe0ee;margin-top:4px;letter-spacing:1px;">' || public._html_esc(upper(v_un)) || '</div>' else '' end
    || '</td></tr></table></td></tr>'
    -- saudação e dados
    || '<tr><td style="padding:34px 40px 6px;' || c_fonte || 'color:#1b2733;font-size:15px;line-height:1.6;">'
    || '<p style="margin:0 0 6px;font-size:17px;">Prezado(a) <strong>' || public._html_esc(u.nome) || '</strong>,</p>'
    || '<p style="margin:0 0 22px;color:#44576a;">Seus dados de acesso:</p>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#f5f8fb" style="background:#f5f8fb;border:1px solid #d3dce5;border-top:4px solid ' || c_azul || ';border-radius:6px;">'
    || '<tr><td style="padding:4px 22px 6px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">' || v_em || '</table></td></tr></table>'
    || v_botao
    || '</td></tr>'
    -- primeiro acesso (curto)
    || '<tr><td style="padding:24px 40px 4px;' || c_fonte || 'color:#1b2733;font-size:14px;line-height:1.65;">'
    || '<div style="font-size:12px;font-weight:700;letter-spacing:1.4px;color:' || c_azul || ';margin-bottom:6px;">PRIMEIRO ACESSO</div>'
    || 'Entre com o e-mail e a senha provisória e, quando solicitado, defina uma <strong>nova senha</strong> (10 a 72 caracteres, com letras e números) e um <strong>novo PIN</strong> (4 a 6 dígitos).'
    || '</td></tr>'
    -- segurança (uma linha)
    || '<tr><td style="padding:18px 40px 4px;' || c_fonte || 'font-size:13px;line-height:1.55;color:#7a5a00;">'
    || '<span style="display:inline-block;background:#fff7e0;border-left:3px solid #e0b43c;padding:10px 14px;border-radius:3px;">O acesso é pessoal e intransferível. Exclua esta mensagem após o primeiro acesso.</span>'
    || '</td></tr>'
    -- assinatura
    || '<tr><td style="padding:26px 40px 32px;' || c_fonte || 'font-size:14px;line-height:1.6;color:#1b2733;">'
    || 'Atenciosamente,<br><strong>' || public._html_esc(g.nome) || '</strong><br>'
    || '<span style="color:#6b7c8c;">Gestão do Livro de Protocolo' || case when v_un <> '' then ' · ' || public._html_esc(v_un) else '' end || '</span></td></tr>'
    -- rodapé
    || '<tr><td bgcolor="#f4f7fa" style="padding:14px 40px;background:#f4f7fa;border-top:1px solid #e1e8ef;' || c_fonte || 'font-size:11.5px;color:#7a8896;text-align:center;">'
    || 'Mensagem automática, enviada em ' || v_quando || '. Não responda a este e-mail.'
    || '</td></tr></table></td></tr></table></body></html>';

  insert into public.fila_email (chave, evento, destinatarios, assunto, corpo, corpo_html)
  values ('boasvindas:' || p_user_id || ':' || extract(epoch from clock_timestamp())::bigint, 'BOAS_VINDAS', array[lower(u.email)],
          '[Livro de Protocolo] Dados de acesso ao sistema', v_corpo, v_html)
  returning id into v_id;
  perform public._auditar(g.user_id, g.nome, 'ACESSO_ENVIADO_POR_EMAIL', null, jsonb_build_object('usuario', u.nome, 'email', lower(u.email)));
  return jsonb_build_object('ok', true, 'email', lower(u.email),
           'imediato', coalesce((select status = 'enviando' from public.fila_email where id = v_id), false));
end $$;

insert into public.schema_versao (versao, arquivo) values (11, '11_boas_vindas.sql') on conflict (versao) do nothing;

revoke all on function public._trg_fila_apagar_credenciais(), public._limpar_boas_vindas(), public._html_esc(text),
  public._enviar_imediato(bigint), public.painel_enviar_acesso(uuid, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.integracao_fila(text, int) from public, anon, authenticated;
grant execute on function public.integracao_fila(text, int) to anon, authenticated;
grant execute on function public.painel_enviar_acesso(uuid, text, text, text, text, text) to authenticated;
