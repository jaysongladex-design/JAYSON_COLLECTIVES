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
      return res.status(200).json({ ok: true });
    }
    return res.status(405).json({ ok: false, error: "Use GET or POST." });
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Couldn't reach the database." });
  }
}
