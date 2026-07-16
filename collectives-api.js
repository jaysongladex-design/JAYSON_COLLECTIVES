/* =============================================================================
 * collectives-api.js  -  read-only client for the Collectives public catalog
 * -----------------------------------------------------------------------------
 * Drop this into the front-end site. No dependencies, no build step - it uses
 * the browser's fetch. Every method only READS; there is no write path.
 *
 * The anon key below is safe to ship in a public site ONLY because the API it
 * talks to (the collectives_public view) contains no cost, profit or customer
 * data. Do not paste any other Supabase key here.
 * ========================================================================== */

const CollectivesAPI = (() => {
  // ---- configure once, at startup -----------------------------------------
  //   CollectivesAPI.configure("https://YOUR_PROJECT.supabase.co", "YOUR_ANON_KEY");
  let BASE = "";
  let KEY = "";

  function configure(url, anonKey) {
    BASE = String(url || "").replace(/\/+$/, "") + "/rest/v1";
    KEY = anonKey || "";
  }

  async function get(path) {
    if (!BASE || !KEY) throw new Error("Call CollectivesAPI.configure(url, anonKey) first.");
    const res = await fetch(BASE + path, {
      headers: { apikey: KEY, Authorization: "Bearer " + KEY },
    });
    if (!res.ok) throw new Error("API " + res.status + ": " + (await res.text()));
    return res.json();
  }

  const enc = encodeURIComponent;

  // ---- read methods --------------------------------------------------------

  /** All non-void departures, soonest first. Pass filters to narrow. */
  function departures({ pkg, status, availableOnly, order } = {}) {
    const q = ["select=*"];
    if (pkg) q.push("package=eq." + enc(pkg));
    if (status) q.push("status=eq." + enc(status)); // PENDING | FINISHED
    if (availableOnly) q.push("slots_left=gt.0");
    q.push("order=" + enc(order || "travel_start.asc"));
    return get("/collectives_public?" + q.join("&"));
  }

  /** Only what a customer can still book: upcoming and with slots left. */
  function available(pkg) {
    return departures({ pkg, status: "PENDING", availableOnly: true });
  }

  /** One departure by its tour code (returns an array; usually 0 or 1). */
  function byTourCode(code) {
    return get("/collectives_public?select=*&tour_code=eq." + enc(code));
  }

  /** Distinct package names, for building a menu / filter. */
  async function packages() {
    const rows = await get("/collectives_public?select=package");
    return [...new Set(rows.map((r) => r.package).filter(Boolean))].sort();
  }

  return { configure, departures, available, byTourCode, packages };
})();

// Works both as a global (plain <script>) and as a module import.
if (typeof module !== "undefined" && module.exports) module.exports = CollectivesAPI;
