#!/usr/bin/env node
/**
 * mcp-gladex — MCP server exposing the Gladex Supabase database to Claude.
 *
 * Node.js (ESM), talks to Supabase over the PostgREST REST API
 * ({URL}/rest/v1/{table}) and speaks MCP over stdio using
 * @modelcontextprotocol/sdk.
 *
 * Credentials come from environment variables (SUPABASE_URL / SUPABASE_ANON_KEY,
 * or the VITE_ prefixed equivalents), loaded from a sibling .env file if present.
 * Requires Node.js 18+ (uses the built-in global fetch).
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { config as loadEnv } from "dotenv";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
// Load .env next to this file. Real env vars (e.g. from the MCP config) win.
loadEnv({ path: join(__dirname, ".env") });

const SUPABASE_URL = (
  process.env.SUPABASE_URL ||
  process.env.VITE_SUPABASE_URL ||
  ""
).replace(/\/+$/, "");
const SUPABASE_ANON_KEY =
  process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || "";

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error(
    "[mcp-gladex] Missing SUPABASE_URL / SUPABASE_ANON_KEY. " +
      "Set them in mcp-gladex/.env or in the server's env config."
  );
  process.exit(1);
}

const REST = `${SUPABASE_URL}/rest/v1`;

/* ----------------------------- REST helpers ------------------------------ */

// encodeURIComponent leaves ( ) * ' ! ~ unescaped. We keep * (ilike wildcard)
// but must escape ( ) so they don't break PostgREST or=(...) grouping.
const enc = (s) =>
  encodeURIComponent(String(s)).replace(
    /[()]/g,
    (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase()
  );
const like = (text) => "*" + enc(text) + "*"; // case-insensitive "contains"

/** GET from PostgREST. Returns { rows, total } (total from Content-Range). */
async function sbGet(table, query = "", { count = false } = {}) {
  const url = `${REST}/${table}${query ? "?" + query : ""}`;
  const headers = {
    apikey: SUPABASE_ANON_KEY,
    Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    Accept: "application/json",
  };
  if (count) headers.Prefer = "count=exact";
  const res = await fetch(url, { headers });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(
      `Supabase ${res.status} ${res.statusText} on "${table}": ${body.slice(0, 300)}`
    );
  }
  const rows = await res.json();
  let total = Array.isArray(rows) ? rows.length : 0;
  const cr = res.headers.get("content-range"); // e.g. "0-49/1234"
  if (cr && cr.includes("/")) {
    const t = cr.split("/")[1];
    if (t && t !== "*") total = Number(t);
  }
  return { rows, total };
}

/** Count rows matching an optional PostgREST filter string. */
async function sbCount(table, filter = "") {
  const q = `select=id&limit=1${filter ? "&" + filter : ""}`;
  const { total } = await sbGet(table, q, { count: true });
  return total;
}

/* --------------------------- MCP result helpers -------------------------- */

const ok = (obj) => ({
  content: [{ type: "text", text: JSON.stringify(obj, null, 2) }],
});
const fail = (msg) => ({
  content: [{ type: "text", text: `Error: ${msg}` }],
  isError: true,
});

// Booking rows keep everything inside a jsonb `data` column.
const slimBooking = (row) => {
  const d = row.data || {};
  return {
    id: row.id,
    gdx: d.gdx ?? null,
    lead_name: d.lead_name ?? null,
    destination: d.destination ?? null,
    synced_at: row.synced_at,
  };
};

// Detail tables that hang off a booking, linked by data->>gdx.
const DETAIL_TABLES = {
  hotels: "fusioo_hotel_details",
  tours: "fusioo_tour_details",
  tickets: "fusioo_ticket_details",
  transfers: "fusioo_transfer_details",
};

/* -------------------------------- Server --------------------------------- */

const server = new McpServer({ name: "mcp-gladex", version: "1.0.0" });

// 1) search_bookings
server.tool(
  "search_bookings",
  "Search booking transactions by GDX number, lead (guest) name, or destination. Case-insensitive partial match. Returns up to 50 bookings.",
  {
    query: z.string().min(1).describe("Text to search for"),
    field: z
      .enum(["gdx", "lead_name", "destination"])
      .optional()
      .describe("Restrict to one field; omit to search all three"),
  },
  async ({ query, field }) => {
    try {
      const v = like(query);
      const filter = field
        ? `data->>${field}=ilike.${v}`
        : `or=(data->>gdx.ilike.${v},data->>lead_name.ilike.${v},data->>destination.ilike.${v})`;
      const { rows } = await sbGet(
        "fusioo_booking_transactions",
        `select=id,data,synced_at&${filter}&limit=50`
      );
      return ok({ count: rows.length, bookings: rows.map(slimBooking) });
    } catch (e) {
      return fail(e.message);
    }
  }
);

// 2) get_booking
server.tool(
  "get_booking",
  "Fetch a single booking by its GDX number, including all linked hotel, tour, ticket and transfer details.",
  { gdx: z.string().min(1).describe("The GDX booking number, e.g. GDX-12345") },
  async ({ gdx }) => {
    try {
      const g = enc(gdx);
      const { rows } = await sbGet(
        "fusioo_booking_transactions",
        `select=id,data,synced_at&data->>gdx=eq.${g}&limit=1`
      );
      if (!rows.length) return ok({ found: false, gdx });
      const booking = rows[0];
      const details = {};
      await Promise.all(
        Object.entries(DETAIL_TABLES).map(async ([key, table]) => {
          const r = await sbGet(
            table,
            `select=id,data,synced_at&data->>gdx=eq.${g}`
          );
          details[key] = r.rows.map((x) => x.data);
        })
      );
      return ok({
        found: true,
        gdx,
        id: booking.id,
        synced_at: booking.synced_at,
        booking: booking.data,
        details,
      });
    } catch (e) {
      return fail(e.message);
    }
  }
);

// 3) list_recent_bookings
server.tool(
  "list_recent_bookings",
  "List the 50 most recently synced bookings (GDX, lead name, destination, synced_at).",
  {},
  async () => {
    try {
      const { rows } = await sbGet(
        "fusioo_booking_transactions",
        "select=id,data,synced_at&order=synced_at.desc&limit=50"
      );
      return ok({ count: rows.length, bookings: rows.map(slimBooking) });
    } catch (e) {
      return fail(e.message);
    }
  }
);

// 4) get_reviews
server.tool(
  "get_reviews",
  "List reviews (newest first). Optionally filter by visibility (is_hidden) and/or destination.",
  {
    is_hidden: z
      .boolean()
      .optional()
      .describe("true = only hidden reviews, false = only visible"),
    destination: z
      .string()
      .optional()
      .describe("Filter by destination (case-insensitive partial match)"),
    limit: z
      .number()
      .int()
      .min(1)
      .max(200)
      .optional()
      .describe("Max rows to return (default 50)"),
  },
  async ({ is_hidden, destination, limit }) => {
    try {
      const parts = ["select=*", "order=created_at.desc", `limit=${limit ?? 50}`];
      if (typeof is_hidden === "boolean") parts.push(`is_hidden=eq.${is_hidden}`);
      if (destination) parts.push(`destination=ilike.${like(destination)}`);
      const { rows } = await sbGet("reviews", parts.join("&"));
      return ok({ count: rows.length, reviews: rows });
    } catch (e) {
      return fail(e.message);
    }
  }
);

// 5) check_voucher
server.tool(
  "check_voucher",
  "Check whether a GDX booking has an uploaded voucher; returns file name(s) and URL(s) if present.",
  { gdx: z.string().min(1).describe("The GDX booking number") },
  async ({ gdx }) => {
    try {
      const { rows } = await sbGet(
        "vouchers",
        `select=*&gdx=eq.${enc(gdx)}&order=created_at.desc`
      );
      if (!rows.length) return ok({ gdx, has_voucher: false });
      return ok({
        gdx,
        has_voucher: true,
        count: rows.length,
        vouchers: rows.map((v) => ({
          file_name: v.file_name,
          file_url: v.file_url,
          created_at: v.created_at,
        })),
      });
    } catch (e) {
      return fail(e.message);
    }
  }
);

// 6) get_stats
server.tool(
  "get_stats",
  "Dashboard stats: total bookings, total reviews, pending (hidden) reviews, and bookings that have no uploaded voucher.",
  {},
  async () => {
    try {
      const [total_bookings, total_reviews, pending_reviews] = await Promise.all([
        sbCount("fusioo_booking_transactions"),
        sbCount("reviews"),
        sbCount("reviews", "is_hidden=eq.true"),
      ]);
      // bookings without voucher = booking GDX set minus voucher GDX set
      const [{ rows: bRows }, { rows: vRows }] = await Promise.all([
        sbGet("fusioo_booking_transactions", "select=gdx:data->>gdx&limit=100000"),
        sbGet("vouchers", "select=gdx&limit=100000"),
      ]);
      const voucherGdx = new Set(
        vRows.map((v) => String(v.gdx)).filter((g) => g && g !== "null")
      );
      const bookingGdx = [
        ...new Set(
          bRows.map((b) => String(b.gdx)).filter((g) => g && g !== "null")
        ),
      ];
      const bookings_without_voucher = bookingGdx.filter(
        (g) => !voucherGdx.has(g)
      ).length;
      return ok({
        total_bookings,
        total_reviews,
        pending_reviews, // reviews with is_hidden = true
        bookings_without_voucher,
        unique_booking_gdx: bookingGdx.length,
      });
    } catch (e) {
      return fail(e.message);
    }
  }
);

/* --------------------------------- Boot ---------------------------------- */

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("[mcp-gladex] ready — connected to", SUPABASE_URL);
