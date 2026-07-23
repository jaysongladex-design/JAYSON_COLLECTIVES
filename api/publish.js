// =============================================================================
//  /api/publish  —  update the public catalog from the app (Vercel function)
// -----------------------------------------------------------------------------
//  The app's "Publish" button POSTs its current catalog here. This function
//  writes it to docs/collectives-public.json in the repo, so the public API
//  (GitHub Pages) reflects it about a minute later.
//
//  SECRETS LIVE ONLY IN VERCEL ENV VARS — never in the app or repo:
//    GH_TOKEN         a GitHub token with "Contents: write" on this repo
//    PUBLISH_SECRET   a passphrase; the app must send the same one to publish
//
//  Only the safe catalog fields are ever written — cost/profit/PII are stripped
//  here as a backstop even if the app sent extra fields.
// =============================================================================

const OWNER = "jaysongladex-design";
const REPO = "JAYSON_COLLECTIVES";
const FILE = "docs/collectives-public.json";
const BRANCH = "main";
const SAFE = ["package", "tour_code", "travel_raw", "travel_start", "travel_end",
  "status", "total_slots", "slots_left", "sold_out", "price_per_pax"];

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Use POST." });

  const token = process.env.GH_TOKEN;
  const secret = process.env.PUBLISH_SECRET;
  if (!token || !secret) return res.status(500).json({ ok: false, error: "Publishing isn't set up yet (missing Vercel settings)." });

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  if (!body || body.secret !== secret) return res.status(401).json({ ok: false, error: "Wrong publish passphrase." });
  if (!Array.isArray(body.catalog)) return res.status(400).json({ ok: false, error: "No catalog data was sent." });

  // Backstop: keep ONLY the safe fields, whatever the app sent.
  const rows = body.catalog.map((r) => {
    const o = {};
    for (const k of SAFE) o[k] = (r == null ? null : (r[k] ?? null));
    return o;
  });
  const json = JSON.stringify(rows, null, 2);
  const content = Buffer.from(json, "utf8").toString("base64");

  const api = `https://api.github.com/repos/${OWNER}/${REPO}/contents/${FILE}`;
  const gh = {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "User-Agent": "collectives-publish",
    "X-GitHub-Api-Version": "2022-11-28",
  };

  try {
    // Look up the file's current sha (required to update an existing file).
    let sha;
    const getR = await fetch(`${api}?ref=${BRANCH}`, { headers: gh });
    if (getR.ok) sha = (await getR.json()).sha;
    else if (getR.status !== 404) return res.status(502).json({ ok: false, error: "GitHub read failed (" + getR.status + ")." });

    const putR = await fetch(api, {
      method: "PUT",
      headers: { ...gh, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: "Publish catalog from app (" + rows.length + " departures)",
        content,
        branch: BRANCH,
        ...(sha ? { sha } : {}),
      }),
    });
    if (!putR.ok) return res.status(502).json({ ok: false, error: "GitHub write failed (" + putR.status + ")." });
    return res.status(200).json({ ok: true, count: rows.length });
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Couldn't reach GitHub." });
  }
}
