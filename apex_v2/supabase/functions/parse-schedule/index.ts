import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/**
 * Photo/text → structured shifts (Apex plan #8 / Feature A).
 *
 * Preferred: { text } only — privacy middle path (OCR on device, text here).
 * Optional: { image_base64, media_type } when ANTHROPIC_API_KEY is set.
 *
 * Returns: { shifts: [{ staff, shift_date, start_time, end_time }] }
 */
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function mondayKey(d = new Date()): string {
  const day = d.getDay(); // 0 Sun
  const diff = day === 0 ? -6 : 1 - day;
  const mon = new Date(d);
  mon.setDate(d.getDate() + diff);
  return mon.toISOString().slice(0, 10);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) {
      return new Response(
        JSON.stringify({
          error: "anthropic_not_configured",
          message:
            "Set ANTHROPIC_API_KEY, or paste schedule text for on-device parsing.",
        }),
        {
          status: 501,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const body = await req.json();
    const text = (body.text as string | undefined)?.trim() ?? "";
    const imageBase64 = (body.image_base64 as string | undefined)?.trim();
    const mediaType = (body.media_type as string | undefined) ?? "image/jpeg";
    const weekStart = (body.week_start as string | undefined) ?? mondayKey();

    if (!text && !imageBase64) {
      throw new Error("Provide text and/or image_base64");
    }

    const content: Array<Record<string, unknown>> = [];
    if (imageBase64) {
      content.push({
        type: "image",
        source: {
          type: "base64",
          media_type: mediaType,
          data: imageBase64.replace(/^data:[^;]+;base64,/, ""),
        },
      });
    }
    content.push({
      type: "text",
      text: `Extract restaurant staff shifts from this ${
        imageBase64 ? "photo of a schedule/whiteboard" : "schedule text"
      }.

Week starts Monday ${weekStart} (use that week for weekday names).

Return ONLY valid JSON (no markdown):
{"shifts":[{"staff":"Full Name","shift_date":"YYYY-MM-DD","start_time":"HH:MM","end_time":"HH:MM"}]}

Rules:
- 24-hour times
- One object per person-day
- Skip unclear rows rather than guessing
${text ? `\nSchedule text:\n${text}` : ""}`,
    });

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-20250514",
        max_tokens: 2048,
        messages: [{ role: "user", content }],
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Anthropic error: ${errText.slice(0, 500)}`);
    }

    const json = await res.json();
    const raw =
      (json.content as Array<{ type: string; text?: string }>)
        ?.map((c) => c.text ?? "")
        .join("")
        .trim() ?? "";

    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) throw new Error("Model returned no JSON");
    const parsed = JSON.parse(match[0]);
    const shifts = Array.isArray(parsed.shifts) ? parsed.shifts : [];

    return new Response(JSON.stringify({ shifts }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
