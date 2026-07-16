/* =============================================================================
 * collectives-api.js  -  read-only client for the Collectives public catalog
 * -----------------------------------------------------------------------------
 * The catalog is a static JSON file published on your own GitHub page.
 * No key, no server, no dependencies — just fetch it.
 *
 *   // default URL is baked in; call configure(url) only to override it
 *   CollectivesAPI.available("HONG KONG").then(render);
 *
 * Every method only READS. Refresh the data by re-exporting from the app and
 * publishing the new collectives-public.json.
 * ========================================================================== */

const CollectivesAPI = (() => {
  let URL_ = "https://jaysongladex-design.github.io/JAYSON_COLLECTIVES/collectives-public.json";

  // Optional: point at a different published file.
  function configure(url) { if (url) URL_ = url; }

  // Fetch the whole catalog (small file — filter in JS).
  async function all() {
    const res = await fetch(URL_, { cache: "no-store" });
    if (!res.ok) throw new Error("API " + res.status + ": " + (await res.text()));
    return res.json();
  }

  const byStart = (a, b) => String(a.travel_start || "").localeCompare(String(b.travel_start || ""));

  /** All non-void departures, soonest first. Optional filters. */
  async function departures({ pkg, status, availableOnly } = {}) {
    let rows = await all();
    if (pkg) rows = rows.filter((r) => r.package === pkg);
    if (status) rows = rows.filter((r) => r.status === status);
    if (availableOnly) rows = rows.filter((r) => r.slots_left > 0);
    return rows.sort(byStart);
  }

  /** Only what a customer can still book: upcoming and with slots left. */
  function available(pkg) {
    return departures({ pkg, status: "PENDING", availableOnly: true });
  }

  /** One departure by its tour code (returns an array; usually 0 or 1). */
  async function byTourCode(code) {
    return (await all()).filter((r) => r.tour_code === code);
  }

  /** Distinct package names, for building a menu / filter. */
  async function packages() {
    return [...new Set((await all()).map((r) => r.package).filter(Boolean))].sort();
  }

  return { configure, all, departures, available, byTourCode, packages };
})();

// Works both as a global (plain <script>) and as a module import.
if (typeof module !== "undefined" && module.exports) module.exports = CollectivesAPI;
