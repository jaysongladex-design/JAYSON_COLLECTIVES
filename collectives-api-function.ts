// =============================================================================
//  collectives-public  —  KEYLESS, read-only public catalog (Supabase Edge Function)
// -----------------------------------------------------------------------------
//  Why this exists:
//    Supabase's REST API (/rest/v1/...) always demands the anon key in a header.
//    An Edge Function does not — deploy it with JWT verification OFF and anyone
//    can open the URL with no key at all, straight from a browser or any site.
//
//  What it returns:
//    The rows of the collectives_public view — package, tour code, travel dates,
//    status, slots left, price. Never cost, profit, ROI, balances or customer
//    names (those columns are not in that view).
//
//  How to deploy (no computer setup needed):
//    Supabase Dashboard → Edge Functions → "Deploy a new function"
//      • Name it exactly: collectives-public
//      • Paste this whole file as the code
//      • Turn OFF "Verify JWT" (a.k.a. "Enforce JWT verification")  ← makes it keyless
//      • Deploy
//    Then the public URL is:
//      https://YOUR_PROJECT.supabase.co/functions/v1/collectives-public
//
//  Security:
//    It talks to the database with the ANON key (injected automatically), which
//    can read ONLY the public view and nothing else. So even though the URL is
//    open to the world, it can never reach your financials or customer data.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",          // any website may fetch it
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "*",
  "Content-Type": "application/json",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "Read-only. Use GET." }), { status: 405, headers: CORS });
  }

  // Least privilege: the anon key can read ONLY the public catalog view.
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
  );

  const { data, error } = await supabase
    .from("collectives_public")
    .select("*")
    .order("travel_start", { ascending: true });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: CORS });
  }
  return new Response(JSON.stringify(data ?? []), { headers: CORS });
});
