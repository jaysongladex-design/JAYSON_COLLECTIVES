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

This is a **snapshot** — keyless, on your own domain. You refresh it either by
exporting the file, or with one click via the **Publish** button (below).

## One-click Publish (near-live)

The app's **Settings → Public API → ⚡ Publish** button pushes your current data
to the API — it goes live about a minute later. It works through `api/publish.js`
(a Vercel function) so no secret ever touches the app.

**Set up once:**

1. **Create a GitHub token** (so the function can update the file):
   GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate.
   - Repository access: only **JAYSON_COLLECTIVES**
   - Permissions → Repository → **Contents: Read and write**
   - Copy the token (starts `github_pat_…`).
2. **Add two settings in Vercel** → Project → Settings → Environment Variables:
   - `GH_TOKEN` = the token from step 1
   - `PUBLISH_SECRET` = any passphrase you make up (e.g. a long random phrase)
   - Tick **Production**, Save.
3. **Redeploy** in Vercel (Deployments → ⋯ → Redeploy) so the settings take effect.
4. In the app → **Settings → Public API**, type the **same** `PUBLISH_SECRET`
   passphrase into the Publish passphrase box.

Now click **⬆ Publish to API now** whenever you want the API to catch up to your
data. The token stays in Vercel; the passphrase stops anyone else from publishing.

## Fully-automatic alternative

If you'd rather it update the **instant** you change data (no button), that's the
Supabase route (`collectives-api.sql` + `collectives-api-function.ts`), kept in
this repo as the bigger alternative.
