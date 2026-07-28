import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/**
 * Fan-out when a call_out is created.
 *
 * Finds eligible coworkers (same org, role match when set, not on time-off,
 * not already scheduled that day), logs call_out_notifications, and SMS via
 * Twilio when configured. In-app list works even if SMS fails.
 *
 * Body: { call_out_id: string }
 */
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

async function sendSms(
  to: string,
  body: string,
): Promise<{ ok: boolean; detail: string }> {
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

function roleMatches(need: string | null, have: string | null): boolean {
  if (!need || !need.trim()) return true;
  if (!have) return false;
  const n = need.trim().toLowerCase();
  const h = have.trim().toLowerCase();
  if (h === "owner" || h === "manager") return true;
  return h === n || h.includes(n) || n.includes(h);
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

    const { data: authData, error: authErr } = await userClient.auth.getUser();
    if (authErr || !authData.user) throw new Error("Unauthorized");

    const { call_out_id } = await req.json();
    if (!call_out_id) throw new Error("call_out_id is required");

    const { data: callOut, error: coErr } = await admin
      .from("call_outs")
      .select("*")
      .eq("id", call_out_id)
      .maybeSingle();
    if (coErr) throw coErr;
    if (!callOut) throw new Error("Call-out not found");
    if (callOut.status !== "open") {
      return new Response(
        JSON.stringify({ success: true, skipped: "not_open" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const orgId = callOut.organization_id as string;
    const shiftDate = callOut.shift_date as string;
    const excludeUserId = callOut.staff_user_id as string | null;
    const excludeName = (callOut.staff_name as string) ?? "";
    const needRole = (callOut.staff_role as string | null) ?? null;
    const hours = [callOut.start_time, callOut.end_time]
      .filter(Boolean)
      .join("-");
    const hoursLabel = hours || "your shift";

    const { data: profiles, error: pErr } = await admin
      .from("profiles")
      .select("id, name, role, phone")
      .eq("organization_id", orgId);
    if (pErr) throw pErr;

    const { data: timeOff } = await admin
      .from("time_off_requests")
      .select("user_id, user_name")
      .eq("organization_id", orgId)
      .eq("status", "Approved")
      .lte("start_date", shiftDate)
      .gte("end_date", shiftDate);

    const offIds = new Set(
      (timeOff ?? [])
        .map((r: { user_id?: string }) => r.user_id)
        .filter(Boolean),
    );
    const offNames = new Set(
      (timeOff ?? [])
        .map((r: { user_name?: string }) => (r.user_name ?? "").toLowerCase())
        .filter(Boolean),
    );

    const { data: busyShifts } = await admin
      .from("shifts")
      .select("staff")
      .eq("organization_id", orgId)
      .eq("shift_date", shiftDate);

    const busyStaff = new Set(
      (busyShifts ?? [])
        .map((r: { staff?: string }) => (r.staff ?? "").toLowerCase())
        .filter(Boolean),
    );

    const eligible = (profiles ?? []).filter(
      (p: {
        id: string;
        name?: string;
        role?: string;
        phone?: string;
      }) => {
        if (excludeUserId && p.id === excludeUserId) return false;
        const name = (p.name ?? "").trim();
        if (!name) return false;
        if (name.toLowerCase() === excludeName.toLowerCase()) return false;
        if (offIds.has(p.id)) return false;
        if (offNames.has(name.toLowerCase())) return false;
        if (busyStaff.has(name.toLowerCase())) return false;
        if (!roleMatches(needRole, p.role ?? null)) return false;
        return true;
      },
    );

    const smsBody =
      `${excludeName || "A teammate"} called out for ${shiftDate} ${hoursLabel}. ` +
      `Can you cover? Open Call-Outs in Apex and tap I'll take it.`;

    let notified = 0;
    let smsSent = 0;

    for (const p of eligible) {
      const name = (p.name as string).trim();
      const phone = ((p.phone as string | undefined) ?? "").trim();

      await admin.from("call_out_notifications").insert({
        call_out_id,
        organization_id: orgId,
        user_id: p.id,
        staff_name: name,
        phone: phone || null,
      });
      notified++;

      // Prefer the existing router for in-app + push; SMS below is belt-and-suspenders.
      try {
        await fetch(`${supabaseUrl}/functions/v1/route-notification`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${serviceKey}`,
            apikey: serviceKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            target_user_id: p.id,
            title: "Shift needs cover",
            body: smsBody,
            critical: true,
          }),
        });
      } catch {
        // In-app notify is optional here.
      }

      if (phone) {
        const sms = await sendSms(phone, smsBody);
        if (sms.ok) smsSent++;
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        eligible: eligible.length,
        notified,
        sms_sent: smsSent,
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
