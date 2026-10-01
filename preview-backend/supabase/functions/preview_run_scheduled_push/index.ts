import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import cronParser from "https://esm.sh/cron-parser@4.9.0";

type Job = {
  id: string;
  business_slug: string;
  title: string;
  body: string;
  next_run_at: string;
  repeat_cron: string | null;
  time_zone: string;
  operator_id: string;
};

serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const secret = Deno.env.get("PREVIEW_CRON_SECRET");
  if (!secret || request.headers.get("x-cron-secret") !== secret) return new Response("Unauthorized", { status: 401 });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return new Response("Missing configuration", { status: 500 });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const now = new Date();
  const { data: due, error } = await admin.from("preview_push_jobs").select("*")
    .eq("status", "scheduled").lte("next_run_at", now.toISOString()).order("next_run_at").limit(20);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const results: Array<{ id: string; status: string }> = [];
  for (const job of (due ?? []) as Job[]) {
    const { data: claim, error: claimError } = await admin.from("preview_push_jobs")
      .update({ status: "processing", updated_at: now.toISOString() })
      .eq("id", job.id).eq("status", "scheduled").eq("next_run_at", job.next_run_at).select("id").maybeSingle();
    if (claimError || !claim) continue;
    try {
      const { data: devices, error: deviceError } = await admin.from("preview_devices")
        .select("expo_token").eq("active_business_slug", job.business_slug).eq("approved", true).limit(6);
      if (deviceError) throw deviceError;
      const recipients = [...new Set((devices ?? []).map((device) => device.expo_token))];
      if (!recipients.length || recipients.length > 5) throw new Error("No approved recipient or too many test devices");

      const pushLogId = crypto.randomUUID();
      const response = await fetch("https://exp.host/--/api/v2/push/send", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(recipients.map((to) => ({
          to, sound: "default", title: job.title, body: job.body,
          data: { business_slug: job.business_slug, screen: "menu", preview: true, campaign_id: pushLogId },
        }))),
      });
      const expoResponse = await response.json();
      if (!response.ok) throw new Error("Expo rejected the push request");
      const tickets = Array.isArray(expoResponse?.data) ? expoResponse.data : [];
      const accepted = tickets.filter((ticket: { status?: string }) => ticket.status === "ok").length;
      const { error: logError } = await admin.from("preview_push_log").insert({
        id: pushLogId, business_slug: job.business_slug, title: job.title, body: job.body,
        operator_id: job.operator_id, recipients: recipients.length, accepted, expo_response: expoResponse,
      });
      if (logError) throw logError;

      const nextRun = job.repeat_cron
        ? cronParser.parseExpression(job.repeat_cron, { currentDate: now, tz: job.time_zone }).next().toDate().toISOString()
        : null;
      const { error: updateError } = await admin.from("preview_push_jobs").update({
        status: nextRun ? "scheduled" : "sent", next_run_at: nextRun,
        last_run_at: now.toISOString(), updated_at: now.toISOString(),
      }).eq("id", job.id).eq("status", "processing");
      if (updateError) throw updateError;
      results.push({ id: job.id, status: nextRun ? "rescheduled" : "sent" });
    } catch (sendError) {
      const retryAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();
      await admin.from("preview_push_jobs").update({ status: "scheduled", next_run_at: retryAt, updated_at: new Date().toISOString() })
        .eq("id", job.id).eq("status", "processing");
      results.push({ id: job.id, status: String(sendError) });
    }
  }
  return Response.json({ processed: results.length, results });
});
