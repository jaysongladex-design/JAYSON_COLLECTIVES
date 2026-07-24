// =============================================================================
//  /api/state  —  load & save the whole app document to Supabase (Vercel func)
// -----------------------------------------------------------------------------
//  GET  -> returns the stored app data (the single 'main' row).
//  POST -> saves the app data (upserts the 'main' row).
//
//  Both require the access passphrase, sent as the `x-state-secret` header or in
//  the body as { secret }. The Supabase SERVICE key lives ONLY in Vercel env —
//  never in the app — so the public can't read or write your data directly.
//
//  Vercel env vars needed:
//    SUPABASE_URL          e.g. https://fakdedmkhtmfpjarlelh.supabase.co
//    SUPABASE_SERVICE_KEY  the project's service_role key (Settings → API)
//    STATE_SECRET          an access passphrase you make up
// =============================================================================

const ROW_ID = "main";

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type, x-state-secret");
  if (req.method === "OPTIONS") return res.status(204).end();

  const URL_ = process.env.SUPABASE_URL;
  const KEY = process.env.SUPABASE_SERVICE_KEY;
  const SECRET = process.env.STATE_SECRET;
  if (!URL_ || !KEY || !SECRET) return res.status(500).json({ ok: false, error: "Not configured yet (missing Vercel settings)." });

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  const secret = req.headers["x-state-secret"] || (body && body.secret);
  if (secret !== SECRET) return res.status(401).json({ ok: false, error: "Wrong access passphrase." });

  const base = URL_.replace(/\/+$/, "") + "/rest/v1/app_state";
  const sb = { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json" };

  try {
    if (req.method === "GET") {
      const r = await fetch(`${base}?id=eq.${ROW_ID}&select=data,updated_at`, { headers: sb });
      if (!r.ok) return res.status(502).json({ ok: false, error: "Load failed (" + r.status + ")." });
      const rows = await r.json();
      return res.status(200).json({ ok: true, data: rows[0] ? rows[0].data : null, updated_at: rows[0] ? rows[0].updated_at : null });
    }
    if (req.method === "POST") {
      if (!body || typeof body.data === "undefined") return res.status(400).json({ ok: false, error: "No data sent." });
      const r = await fetch(`${base}?on_conflict=id`, {
        method: "POST",
        headers: { ...sb, Prefer: "resolution=merge-duplicates,return=minimal" },
        body: JSON.stringify({ id: ROW_ID, data: body.data, updated_at: new Date().toISOString() }),
      });
      if (!r.ok) return res.status(502).json({ ok: false, error: "Save failed (" + r.status + ")." });
      // Best-effort: also mirror the departures into a readable collectives_public table.
      try { await mirrorPublic(URL_, sb, body.data); } catch (e) {}
      return res.status(200).json({ ok: true });
    }
    return res.status(405).json({ ok: false, error: "Use GET or POST." });
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Couldn't reach the database." });
  }
}

// Rebuild the readable collectives_public table (one row per departure) from the app data.
async function mirrorPublic(URL_, sb, data) {
  const entries = data && Array.isArray(data.entries) ? data.entries : [];
  const cp = URL_.replace(/\/+$/, "") + "/rest/v1/collectives_public";
  const num = (v) => { const n = Number(v); return isFinite(n) ? n : 0; };
  const isoMDY = (s) => { const p = String(s || "").trim().split("/"); if (p.length !== 3) return null; const [m, d, y] = p; if (!m || !d || !y) return null; return String(y).padStart(4, "0") + "-" + String(m).padStart(2, "0") + "-" + String(d).padStart(2, "0"); };
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const rows = entries.map((e) => {
    const parts = String(e.travelRaw || "").split(/\s+-\s+/);
    const start = isoMDY(parts[0]), end = isoMDY(parts[parts.length - 1]);
    const paid = (e.payments || []).reduce((s, p) => s + num(p.amount), 0);
    const collected = (e.sales || []).reduce((s, x) => s + num(x.amount), 0);
    const slotsSold = (e.sales || []).reduce((s, x) => s + num(x.slots), 0);
    const totalSlots = num(e.slot) + num(e.foc);
    const status = e.voided ? "VOID" : (end && new Date(end) < today ? "FINISHED" : "PENDING");
    return {
      id: e.id, package: e.package || "", tour_code: e.tourCode || "", travel_raw: e.travelRaw || "",
      travel_start: start, travel_end: end, status,
      total_slots: totalSlots, slots_sold: slotsSold, slots_left: Math.max(0, totalSlots - slotsSold),
      price_per_pax: e.amountPerPax == null ? null : num(e.amountPerPax),
      total_cost: num(e.totalCost), current_payment: paid, balance_payable: num(e.totalCost) - paid,
      collected, profit: collected - paid, voided: !!e.voided, updated_at: new Date().toISOString(),
    };
  });
  if (rows.length) {
    await fetch(cp + "?on_conflict=id", { method: "POST", headers: { ...sb, Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(rows) });
    const ids = rows.map((r) => r.id).filter(Boolean);
    if (ids.length) await fetch(cp + "?id=not.in.(" + ids.join(",") + ")", { method: "DELETE", headers: sb });
  } else {
    await fetch(cp + "?id=not.is.null", { method: "DELETE", headers: sb });
  }
}
