import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

/**
 * Server-side CapacityEngine.autoAdjust for every restaurant with
 * auto_pause_enabled. Intended for a 2-minute cron (see migration
 * 20260801020000_check_capacity_cron.sql). Uses the service role.
 *
 * Auth: Authorization Bearer = service role key (cron) or a member JWT.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function isKitchenRole(role: string | null | undefined): boolean {
  const r = (role ?? "").trim().toLowerCase();
  if (!r) return false;
  return (
    r === "kitchen" ||
    r === "cook" ||
    r === "chef" ||
    r === "line cook" ||
    r === "line_cook" ||
    r.includes("cook") ||
    r.includes("kitchen") ||
    r.includes("chef")
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) throw new Error("Missing Authorization");

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

    // Allow cron (service role) or an authenticated manager.
    const token = authHeader.replace(/^Bearer\s+/i, "");
    const isService = token === serviceKey;
    if (!isService) {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: authData, error: authErr } = await userClient.auth.getUser();
      if (authErr || !authData.user) throw new Error("Unauthorized");
    }

    const admin = createClient(supabaseUrl, serviceKey);

    const { data: settingsRows, error: settingsErr } = await admin
      .from("restaurant_settings")
      .select(
        "restaurant_id, organization_id, paused, auto_pause_enabled, auto_pause_threshold, max_orders_per_hour",
      )
      .eq("auto_pause_enabled", true);
    if (settingsErr) throw settingsErr;

    const summary: Array<Record<string, unknown>> = [];

    for (const row of settingsRows ?? []) {
      const restaurantId = row.restaurant_id as string;
      const organizationId = row.organization_id as string;
      const threshold = (row.auto_pause_threshold as number) ?? 1;
      const isPaused = (row.paused as boolean) ?? false;

      const { data: profiles } = await admin
        .from("profiles")
        .select("id, role")
        .eq("organization_id", organizationId);

      const usesKitchen = (profiles ?? []).some((p) =>
        isKitchenRole(p.role as string | null),
      );
      const kitchenIds = new Set(
        (profiles ?? [])
          .filter((p) => isKitchenRole(p.role as string | null))
          .map((p) => p.id as string),
      );

      const { data: openPunches } = await admin
        .from("time_entries")
        .select("user_id")
        .eq("organization_id", organizationId)
        .is("clock_out", null);

      const staffOnShift = usesKitchen
        ? (openPunches ?? []).filter((t) =>
          kitchenIds.has(t.user_id as string),
        ).length
        : (openPunches ?? []).length;

      const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
      const { data: waiting } = await admin
        .from("online_orders")
        .select("id")
        .eq("organization_id", organizationId)
        .eq("restaurant_id", restaurantId)
        .eq("status", "waiting")
        .gte("submitted_at", hourAgo);

      const ordersLastHour = (waiting ?? []).length;
      const maxPerHour = (row.max_orders_per_hour as number) ?? 15;
      const maxCapacity = staffOnShift * maxPerHour;

      let action: string | null = null;

      if (staffOnShift < threshold && !isPaused) {
        await admin
          .from("restaurant_settings")
          .update({ paused: true })
          .eq("restaurant_id", restaurantId);
        await admin.from("capacity_events").insert({
          organization_id: organizationId,
          restaurant_id: restaurantId,
          event: "auto_pause",
          staff_on_shift: staffOnShift,
          orders_last_hour: ordersLastHour,
          max_capacity: maxCapacity,
          detail:
            `Staff on shift (${staffOnShift}) below threshold (${threshold})`,
        });
        action = "auto_paused";
      } else if (staffOnShift >= threshold && isPaused) {
        const { data: lastEvent } = await admin
          .from("capacity_events")
          .select("event")
          .eq("restaurant_id", restaurantId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        if (lastEvent?.event === "auto_pause") {
          await admin
            .from("restaurant_settings")
            .update({ paused: false })
            .eq("restaurant_id", restaurantId);
          await admin.from("capacity_events").insert({
            organization_id: organizationId,
            restaurant_id: restaurantId,
            event: "auto_resume",
            staff_on_shift: staffOnShift,
            orders_last_hour: ordersLastHour,
            max_capacity: maxCapacity,
            detail:
              `Staff on shift (${staffOnShift}) meets threshold (${threshold})`,
          });
          action = "auto_resumed";
        }
      }

      summary.push({
        restaurant_id: restaurantId,
        staff_on_shift: staffOnShift,
        orders_last_hour: ordersLastHour,
        max_capacity: maxCapacity,
        action,
      });
    }

    return new Response(JSON.stringify({ ok: true, restaurants: summary }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
