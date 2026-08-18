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
  if (!URL_ || !KEY) return res.status(500).json({ ok: false, error: "Not configured yet (missing Supabase settings)." });

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  const secret = req.headers["x-state-secret"] || (body && body.secret);
  // Accepts the Vercel STATE_SECRET (if set) OR this built-in passcode.
  // NOTE: this passcode lives in a PUBLIC repo — anyone who reads it + has the
  // app URL can open the app. It's a low bar by design (owner's choice).
  const PASSCODE = "GLADEX123";
  if (!secret || (secret !== PASSCODE && secret !== SECRET)) return res.status(401).json({ ok: false, error: "Wrong passcode." });

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
      const incoming = body.data;
      const selUrl = `${base}?id=eq.${ROW_ID}&select=data,updated_at`;
      let merged = null, savedOk = false, now = new Date().toISOString();
      // Merge the incoming document into whatever is stored (never overwrite), with a
      // compare-and-set retry so two simultaneous saves can't lose each other's changes.
      // The final attempt writes unconditionally, so a save can never hard-fail (it still merges).
      const ATTEMPTS = 7;
      for (let attempt = 0; attempt < ATTEMPTS && !savedOk; attempt++) {
        const gr = await fetch(selUrl, { headers: sb });
        if (!gr.ok) return res.status(502).json({ ok: false, error: "Load failed (" + gr.status + ")." });
        const rows = await gr.json();
        const cur = rows[0];
        merged = mergeState(cur ? cur.data : null, incoming);
        now = new Date().toISOString();
        const lastTry = attempt === ATTEMPTS - 1;
        if (!cur) {
          // no row yet -> insert. A concurrent insert fails here -> retry (row will then exist).
          const ir = await fetch(base + (lastTry ? "?on_conflict=id" : ""), { method: "POST", headers: { ...sb, Prefer: lastTry ? "resolution=merge-duplicates,return=minimal" : "return=minimal" }, body: JSON.stringify({ id: ROW_ID, data: merged, updated_at: now }) });
          savedOk = ir.ok;
        } else if (lastTry) {
          // fallback: unconditional merge-write by id (still merged; just not CAS-protected)
          const wr = await fetch(`${base}?id=eq.${ROW_ID}`, { method: "PATCH", headers: { ...sb, Prefer: "return=minimal" }, body: JSON.stringify({ data: merged, updated_at: now }) });
          savedOk = wr.ok;
        } else {
          // compare-and-set on updated_at: only write if nobody else wrote since we read
          const pr = await fetch(`${base}?id=eq.${ROW_ID}&updated_at=eq.${encodeURIComponent(cur.updated_at)}`, { method: "PATCH", headers: { ...sb, Prefer: "return=representation" }, body: JSON.stringify({ data: merged, updated_at: now }) });
          if (pr.ok) { const pj = await pr.json().catch(() => []); savedOk = Array.isArray(pj) && pj.length >= 1; }
        }
      }
      if (!savedOk) return res.status(502).json({ ok: false, error: "Save failed." });
      // Best-effort: also mirror the departures into a readable collectives_public table.
      try { await mirrorPublic(URL_, sb, merged); } catch (e) {}
      return res.status(200).json({ ok: true, data: merged, updated_at: now });
    }
    return res.status(405).json({ ok: false, error: "Use GET or POST." });
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Couldn't reach the database." });
  }
}

// Conflict-free merge of two app documents — IDENTICAL logic to mergeState() in the client.
// Union entries by id (newest updatedAt wins), honour deletion tombstones, newer doc wins for scalars.
function mergeState(base, incoming) {
  if (!base || !Array.isArray(base.entries)) return incoming || base || null;
  if (!incoming || !Array.isArray(incoming.entries)) return base;
  const del = {};
  [base, incoming].forEach((d) => { const m = d && d.deletedIds; if (m && typeof m === "object") for (const k in m) { const t = m[k] || ""; if (!del[k] || t > del[k]) del[k] = t; } });
  const em = new Map();
  const put = (e) => { if (!e || !e.id) return; const ex = em.get(e.id); if (!ex || (e.updatedAt || "") >= (ex.updatedAt || "")) em.set(e.id, e); };
  base.entries.forEach(put); incoming.entries.forEach(put);
  const entries = [...em.values()].filter((e) => !(del[e.id] && del[e.id] >= (e.updatedAt || "")));
  const um = new Map();
  (base.users || []).forEach((u) => u && u.id && um.set(u.id, u));
  (incoming.users || []).forEach((u) => u && u.id && um.set(u.id, u));
  const bt = base.updatedAt || "", it = incoming.updatedAt || "";
  const newer = it >= bt ? incoming : base, older = it >= bt ? base : incoming;
  const out = Object.assign({}, older, newer);
  out.version = 1; out.updatedAt = it >= bt ? it : bt;
  out.users = [...um.values()]; out.entries = entries; out.deletedIds = del;
  return out;
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
    const bookings = Array.isArray(e.bookings) ? e.bookings : [];
    const slotsSold = bookings.reduce((s, b) => s + num(b.pax), 0);
    const collected = bookings.reduce((s, b) => s + (b.payments || []).reduce((t, p) => t + num(p.amount), 0), 0);
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
