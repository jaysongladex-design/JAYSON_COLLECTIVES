# Collectives — Public Read-Only API (on your own GitHub page)

A read-only feed of your departures, served from **your own site** — no Supabase,
no key. The **app generates** the file; GitHub publishes it.

## The URL

```
https://jaysongladex-design.github.io/JAYSON_COLLECTIVES/collectives-public.json
```

Anyone can open it — in a browser or from any website. It's a **snapshot**: it
reflects your data at the moment you last exported and published it.

## How it works

1. In the app → **Settings → Public API**, click **⬇ Export catalog file**. The
   app writes `collectives-public.json` containing only safe fields.
2. That file lives in the repo's **`docs/`** folder.
3. **GitHub Pages** serves the `docs/` folder at the URL above.

Only the `docs/` folder is published — the app itself (which contains your costs)
is **not** served at any web address.

## One-time setup: turn on GitHub Pages

Repo → **Settings → Pages**:
- **Source:** Deploy from a branch
- **Branch:** `main`  •  **Folder:** `/docs`
- **Save**

Wait ~1 minute for the first build, then the URL is live.

## Refreshing after you change data

1. Click **⬇ Export catalog file** in the app (downloads a new `collectives-public.json`).
2. Replace `docs/collectives-public.json` in the repo with it and push.
3. GitHub Pages redeploys in a minute. Done.

(If you'd like, I can do steps 2–3 for you each time — just say so.)

### Fields you get back

| Field | Meaning |
| --- | --- |
| `package` | e.g. HONG KONG |
| `tour_code` | e.g. GDX 22056 |
| `travel_raw` | dates as typed — "5/16/2026 - 5/21/2026" |
| `travel_start`, `travel_end` | parsed dates |
| `status` | PENDING (upcoming) or FINISHED (trip over) |
| `total_slots`, `slots_left`, `sold_out` | availability |
| `price_per_pax` | selling price per person |

Never included: cost, profit, ROI, balances, payments, customer names. Voided
departures are never in the file.

## Using it from the website

```html
<script src="collectives-api.js"></script>
<script>
  // default URL is baked in — no configure() needed
  CollectivesAPI.available("HONG KONG").then((rows) => {
    rows.forEach((d) => console.log(d.tour_code, d.travel_raw, d.slots_left + " left", "₱" + d.price_per_pax));
  });
  CollectivesAPI.packages().then((list) => console.log(list));
</script>
```

Or with no library at all:

```js
const rows = await (await fetch("https://jaysongladex-design.github.io/JAYSON_COLLECTIVES/collectives-public.json")).json();
```

## Live vs snapshot

This is a **snapshot** — simple, keyless, on your own domain, but you refresh it
by exporting + publishing. If you later want it to **update automatically** the
instant data changes, that's the Supabase route (`collectives-api.sql` +
`collectives-api-function.ts`), which is kept in this repo as the alternative.
