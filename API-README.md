# Collectives — Public Read-Only API

A read-only feed of your departures for the front-end website. Safe fields only —
no cost, profit, ROI, balances, or customer names ever leave the database.

## Setup (once)

1. Run `supabase-migration.sql` in Supabase → SQL Editor (creates the tables).
2. Run `collectives-api.sql` in the same place (creates the public catalog).

That's it — the API is live. Supabase turns the view into a web endpoint automatically.

## The endpoint

```
GET  https://YOUR_PROJECT.supabase.co/rest/v1/collectives_public?select=*
Headers:
  apikey:        YOUR_ANON_KEY
  Authorization: Bearer YOUR_ANON_KEY
```

Read-only: only `GET` works. There is no way to add, edit, or delete through this key.

### Fields you get back

| Field | Meaning |
| --- | --- |
| `package` | e.g. HONG KONG |
| `tour_code` | e.g. GDX 22056 |
| `travel_raw` | dates as typed — "5/16/2026 - 5/21/2026" |
| `travel_start`, `travel_end` | parsed dates |
| `status` | PENDING (upcoming) or FINISHED (trip over) |
| `total_slots` | paid + free slots |
| `slots_left` | how many are still open |
| `sold_out` | true / false |
| `price_per_pax` | selling price per person |

Fields deliberately **not** included: total cost, profit, ROI, balance payable,
payment records, customer names. Voided departures are never returned.

### Common queries

```
# Everything a customer can still book (upcoming, slots left), soonest first
…/collectives_public?select=*&status=eq.PENDING&slots_left=gt.0&order=travel_start.asc

# One package
…/collectives_public?select=*&package=eq.HONG%20KONG

# One tour code
…/collectives_public?select=*&tour_code=eq.GDX%2022056
```

## Using it from the website

Include `collectives-api.js`, configure it once, then call the read methods:

```html
<script src="collectives-api.js"></script>
<script>
  CollectivesAPI.configure("https://YOUR_PROJECT.supabase.co", "YOUR_ANON_KEY");

  // Bookable Hong Kong departures
  CollectivesAPI.available("HONG KONG").then((rows) => {
    rows.forEach((d) => {
      console.log(d.tour_code, d.travel_raw, d.slots_left + " left", "₱" + d.price_per_pax);
    });
  });

  // Menu of packages
  CollectivesAPI.packages().then((list) => console.log(list));
</script>
```

## Where the values come from

- `YOUR_PROJECT` and `YOUR_ANON_KEY` are in your Supabase dashboard →
  **Project Settings → API**. Do not paste them into any file that goes to a
  **public** GitHub repo — put them in the front end's own config/`.env`.
- The anon key **is** meant to be public in the website, and that's fine here:
  it can reach only this safe catalog. The reason to still keep it out of the
  back-office repo is habit and to avoid confusion with the sensitive key.

## One thing still open

Your existing booking table lets the anon key read every customer record — that
predates this API and is unrelated to it. Until its row-level security is
tightened, that exposure remains. Say the word and I'll write that fix.
