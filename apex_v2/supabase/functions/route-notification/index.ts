import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/**
 * Smart notification router (Apex plan #6).
 *
 * 1. Inserts an in-app notification via apex_notify_user (returns push_token)
 * 2. Tries FCM push via existing send-push-notification function
 * 3. If push fails / no token / prefs.sms_fallback — send Twilio SMS when configured
 *
 * Body: { target_user_id, title, body, critical?: boolean }
 */
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type Prefs = {
  push_enabled: boolean;
  sms_fallback: boolean;
  quiet_start: string;
  quiet_end: string;
  critical_bypass_quiet: boolean;
};

function inQuietHours(prefs: Prefs, critical: boolean): boolean {
  if (critical && prefs.critical_bypass_quiet) return false;
  const now = new Date();
  const mins = now.getHours() * 60 + now.getMinutes();
  const [sh, sm] = prefs.quiet_start.split(":").map(Number);
  const [eh, em] = prefs.quiet_end.split(":").map(Number);
  const start = sh * 60 + (sm || 0);
  const end = eh * 60 + (em || 0);
  if (start === end) return false;
  // Window crosses midnight (e.g. 23:00–07:00)
  if (start > end) return mins >= start || mins < end;
  return mins >= start && mins < end;
}

async function logDelivery(
  admin: ReturnType<typeof createClient>,
  row: Record<string, unknown>,
) {
  await admin.from("notification_deliveries").insert(row);
}

async function sendSms(to: string, body: string): Promise<{ ok: boolean; detail: string }> {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID");
  const token = Deno.env.get("TWILIO_AUTH_TOKEN");
  const from = Deno.env.get("TWILIO_FROM_NUMBER");
  if (!sid || !token || !from) {
    return { ok: false, detail: "twilio_not_configured" };
  }
  const auth = btoa(`${sid}:${token}`);
  const res = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`,
    {
      method: "POST",
      headers: {
        Authorization: `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({ To: to, From: from, Body: body }),
    },
  );
  const text = await res.text();
  return { ok: res.ok, detail: text.slice(0, 400) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const admin = createClient(supabaseUrl, serviceKey);

    const { target_user_id, title, body, critical } = await req.json();
    if (!target_user_id || !title) {
      throw new Error("target_user_id and title are required");
    }
    const isCritical = critical === true;

    // In-app row + push token (same RPC v1 uses).
    const { data: notifyRows, error: notifyErr } = await userClient.rpc(
      "apex_notify_user",
      {
        target_user_id,
        notify_title: title,
        notify_body: body ?? "",
      },
    );
    if (notifyErr) throw notifyErr;

    const row = Array.isArray(notifyRows) ? notifyRows[0] : notifyRows;
    const notificationId = row?.notification_id as string | undefined;
    const pushToken = (row?.push_token as string | undefined) ?? "";

    const { data: profile } = await admin
      .from("profiles")
      .select("organization_id, phone, push_token")
      .eq("id", target_user_id)
      .maybeSingle();

    const orgId = profile?.organization_id as string | undefined;
    if (!orgId) throw new Error("Target profile missing organization");

    await logDelivery(admin, {
      notification_id: notificationId,
      user_id: target_user_id,
      organization_id: orgId,
      channel: "in_app",
      status: "sent",
    });

    const { data: prefRow } = await admin
      .from("notification_preferences")
      .select(
        "push_enabled, sms_fallback, quiet_start, quiet_end, critical_bypass_quiet",
      )
      .eq("user_id", target_user_id)
      .maybeSingle();

    const prefs: Prefs = {
      push_enabled: prefRow?.push_enabled ?? true,
      sms_fallback: prefRow?.sms_fallback ?? true,
      quiet_start: String(prefRow?.quiet_start ?? "23:00").slice(0, 5),
      quiet_end: String(prefRow?.quiet_end ?? "07:00").slice(0, 5),
      critical_bypass_quiet: prefRow?.critical_bypass_quiet ?? true,
    };

    const quiet = inQuietHours(prefs, isCritical);
    let pushOk = false;

    if (quiet) {
      await logDelivery(admin, {
        notification_id: notificationId,
        user_id: target_user_id,
        organization_id: orgId,
        channel: "push",
        status: "skipped",
        detail: "quiet_hours",
      });
    } else if (!prefs.push_enabled) {
      await logDelivery(admin, {
        notification_id: notificationId,
        user_id: target_user_id,
        organization_id: orgId,
        channel: "push",
        status: "skipped",
        detail: "push_disabled",
      });
    } else if (!pushToken) {
      await logDelivery(admin, {
        notification_id: notificationId,
        user_id: target_user_id,
        organization_id: orgId,
        channel: "push",
        status: "skipped",
        detail: "no_push_token",
      });
    } else {
      const pushRes = await fetch(
        `${supabaseUrl}/functions/v1/send-push-notification`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${serviceKey}`,
            apikey: serviceKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            token: pushToken,
            title,
            body: body ?? "",
          }),
        },
      );
      pushOk = pushRes.ok;
      await logDelivery(admin, {
        notification_id: notificationId,
        user_id: target_user_id,
        organization_id: orgId,
        channel: "push",
        status: pushOk ? "sent" : "failed",
        detail: pushOk ? null : (await pushRes.text()).slice(0, 400),
      });
    }

    // SMS fallback when push did not land (or no token) and prefs allow it.
    const needsSms = prefs.sms_fallback && !pushOk && !quiet;
    let smsStatus: string | null = null;
    if (needsSms) {
      const phone = (profile?.phone as string | undefined)?.trim() ?? "";
      if (!phone) {
        smsStatus = "skipped_no_phone";
        await logDelivery(admin, {
          notification_id: notificationId,
          user_id: target_user_id,
          organization_id: orgId,
          channel: "sms",
          status: "skipped",
          detail: "no_phone",
        });
      } else {
        const sms = await sendSms(phone, `${title}\n${body ?? ""}`.trim());
        smsStatus = sms.ok ? "sent" : `failed:${sms.detail}`;
        await logDelivery(admin, {
          notification_id: notificationId,
          user_id: target_user_id,
          organization_id: orgId,
          channel: "sms",
          status: sms.ok ? "sent" : "failed",
          detail: sms.detail,
        });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        notification_id: notificationId,
        push: pushOk ? "sent" : "not_sent",
        sms: smsStatus,
        quiet,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
