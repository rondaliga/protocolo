// Edge Function "enviar-push" — envia avisos Web Push aos aparelhos cadastrados.
// Chamada SOMENTE pelo banco (pg_net) com o cabeçalho x-push-secret. Não recebe descrição de documentos.
// Segredos (Edge Functions > Secrets): VAPID_PUBLIC, VAPID_PRIVATE, PUSH_SECRET, VAPID_SUBJECT (mailto:...)
import webpush from "npm:web-push@3.6.7";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("método não permitido", { status: 405 });
  const segredo = Deno.env.get("PUSH_SECRET") ?? "";
  if (segredo.length < 24 || req.headers.get("x-push-secret") !== segredo) {
    return new Response("não autorizado", { status: 401 });
  }
  const pub = Deno.env.get("VAPID_PUBLIC"), priv = Deno.env.get("VAPID_PRIVATE");
  if (!pub || !priv) return new Response("chaves VAPID ausentes", { status: 500 });
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:avisos@example.org", pub, priv);

  let corpo: { subs?: Array<{ endpoint: string; keys: { p256dh: string; auth: string } }>; payload?: Record<string, unknown> };
  try { corpo = await req.json(); } catch { return new Response("json inválido", { status: 400 }); }
  const subs = (corpo.subs ?? []).slice(0, 200);
  const carga = JSON.stringify({
    title: String(corpo.payload?.title ?? "Livro de Protocolo").slice(0, 120),
    body: String(corpo.payload?.body ?? "Toque para abrir o Livro de Protocolo.").slice(0, 200),
    url: "./",
  });
  const resultados = await Promise.allSettled(
    subs.map((s) => webpush.sendNotification(s, carga, { TTL: 86400, urgency: "high" })),
  );
  const enviados = resultados.filter((r) => r.status === "fulfilled").length;
  return Response.json({ enviados, falhas: resultados.length - enviados });
});
