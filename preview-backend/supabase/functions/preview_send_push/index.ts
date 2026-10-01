import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers });
}

serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!url || !serviceKey || !anonKey) return json({ error: "Missing Supabase configuration" }, 500);

  const bearer = request.headers.get("authorization") ?? "";
  if (!bearer.startsWith("Bearer ")) return json({ error: "Sign in to the operator panel" }, 401);
  const token = bearer.slice(7);
  const userClient = createClient(url, anonKey, { auth: { persistSession: false } });
  const { data: { user }, error: authError } = await userClient.auth.getUser(token);
  if (authError || !user) return json({ error: "Invalid operator session" }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: operator, error: operatorError } = await admin
    .from("preview_operators").select("user_id").eq("user_id", user.id).maybeSingle();
  if (operatorError || !operator) return json({ error: "Operator access required" }, 403);

  let payload: { business_slug?: unknown; title?: unknown; body?: unknown };
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }
  const businessSlug = String(payload.business_slug ?? "").trim();
  const title = String(payload.title ?? "").trim();
  const body = String(payload.body ?? "").trim();
  if (!/^[a-z0-9][a-z0-9-]{1,48}$/.test(businessSlug) || !title || !body || title.length > 100 || body.length > 240) {
    return json({ error: "Choose a business and enter a short title and message" }, 400);
  }
  const { data: business, error: businessError } = await admin
    .from("preview_businesses").select("slug,display_name").eq("slug", businessSlug).maybeSingle();
  if (businessError || !business) return json({ error: "Unknown preview business" }, 404);

  const { data: devices, error: deviceError } = await admin
    .from("preview_devices")
    .select("expo_token")
    .eq("active_business_slug", businessSlug)
    .eq("approved", true)
    .limit(6);
  if (deviceError) return json({ error: deviceError.message }, 500);
  const recipients = [...new Set((devices ?? []).map((device) => device.expo_token))];
  if (recipients.length < 1) return json({ error: "No approved test iPhone is active for this business" }, 409);
  if (recipients.length > 5) return json({ error: "Too many test devices; preview push is limited to five" }, 409);

  const pushLogId = crypto.randomUUID();
  const messages = recipients.map((to) => ({
    to,
    sound: "default",
    title,
    body,
    data: { business_slug: businessSlug, screen: "menu", preview: true, campaign_id: pushLogId },
  }));
  let expoResponse: unknown;
  try {
    const result = await fetch("https://exp.host/--/api/v2/push/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(messages),
    });
    expoResponse = await result.json();
    if (!result.ok) return json({ error: "Expo rejected the push request", detail: expoResponse }, 502);
  } catch (error) {
    return json({ error: "Could not reach Expo Push Service", detail: String(error) }, 502);
  }

  const tickets = Array.isArray((expoResponse as { data?: unknown })?.data)
    ? (expoResponse as { data: Array<{ status?: string }> }).data
    : [];
  const accepted = tickets.filter((ticket) => ticket.status === "ok").length;
  const { error: logError } = await admin.from("preview_push_log").insert({
    id: pushLogId,
    business_slug: businessSlug,
    title,
    body,
    operator_id: user.id,
    recipients: recipients.length,
    accepted,
    expo_response: expoResponse,
  });
  if (logError) return json({ error: "Push sent but logging failed", accepted, detail: logError.message }, 500);
  return json({ id: pushLogId, accepted, recipients: recipients.length, tickets });
});
