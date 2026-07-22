// =============================================================================
//  /api/login  —  secure staff login for Collectives (Vercel serverless function)
// -----------------------------------------------------------------------------
//  Staff sign in with their PAYROLL employee code + password. This function
//  checks them against the GDX payroll directory and returns ONLY that one
//  person's name + role. It never returns the directory or any password.
//
//  THE KEY IS NEVER IN THIS FILE. It is read from a hidden Vercel setting:
//    Vercel → Project → Settings → Environment Variables →
//      Name:  PAYROLL_API_KEY
//      Value: <your NEW rotated psk_… key>
//  So this file is safe to keep in the public repo — it has no secret in it.
//
//  All payroll staff get role "regular". Admin is a separate app login.
// =============================================================================

const PAYROLL_URL =
  "https://gdxpayroll.base44.app/api/apps/6a1686805d8389bea4666b9d/functions/userManagementApi";

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "content-type");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method !== "POST") return res.status(405).json({ ok: false, error: "Use POST." });

  const key = process.env.PAYROLL_API_KEY;
  if (!key) return res.status(500).json({ ok: false, error: "Login is not configured yet." });

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { body = {}; } }
  const code = ((body && body.employee_code) || "").trim();
  const password = (body && body.password) || "";
  if (!code || !password) {
    return res.status(400).json({ ok: false, error: "Enter your employee code and password." });
  }

  // Look up the directory server-side (the key stays here, never reaches the browser).
  let data;
  try {
    const r = await fetch(PAYROLL_URL, { headers: { "x-api-key": key } });
    if (!r.ok) return res.status(502).json({ ok: false, error: "Couldn't reach the staff directory." });
    data = await r.json();
  } catch (e) {
    return res.status(502).json({ ok: false, error: "Couldn't reach the staff directory." });
  }

  const accounts = Array.isArray(data && data.accounts) ? data.accounts : [];
  const want = code.trim().toUpperCase();
  const u = accounts.find(
    (a) => (a.employee_code || "").trim().toUpperCase() === want && a.status === "active"
  );

  // Same message whether the code is unknown or the password is wrong (no user enumeration).
  if (!u || String(u.generated_password) !== String(password)) {
    return res.status(401).json({ ok: false, error: "Incorrect employee code or password." });
  }

  // Return ONLY the matched person's minimal info — never the list, never a password.
  return res.status(200).json({
    ok: true,
    employee_code: u.employee_code,
    name: u.full_name,
    role: "regular",
  });
}
