# JAYSON Collectives — Performance Monitoring Dashboard

An interactive executive dashboard for monitoring **travel-collective ("blocking") performance** — payables, receivables, profitability, ROI, selling velocity, and capital exposure.

> **Open [`collectives-dashboard.html`](collectives-dashboard.html)** (or `index.html`) in any browser. It's a single, fully self-contained file — Chart.js is embedded, so it works with **no internet connection**.

## Features

- **KPI cards** — investment, paid to supplier, balance payable, cash collected, profit, ROI, slots, velocity, and FAST / HEALTHY / SLOW / VERY SLOW counts.
- **Financial Analysis** — payables, collections, net profit, ROI %, margin, remaining exposure.
- **Cash Flow & Exposure** — outstanding supplier balances vs cash still collectible from unsold slots, by settlement month; exposure concentration by package.
- **Highlights & Velocity** — best/worst performers, highest ROI/profit, and a ranked "needs attention" watch-list.
- **13 interactive charts** and a **sortable departure register**.
- **8 dynamic filters** (package, status, travel/holding month, sell-out state, ROI & profit range, search) that update every visual live.
- **Import CSV / Template / Export / Print** buttons.

## How the numbers are calculated

| Metric | Formula |
| --- | --- |
| **Profit** | Cash Collected from Pax − Paid to Supplier |
| **ROI %** | Profit ÷ Total Cost |
| **Selling velocity** | Slots sold ÷ selling days (holding → sold-out, or holding → today for ongoing) |
| **Supplier due date** | Entered due date, else travel start − 21 days |

**Status benchmarks (slots/day)** — per package: Singapore / Hong Kong / Bangkok `0.70 / 0.40 / 0.20` · Da Nang (all) `0.60 / 0.30 / 0.10` · Korea Nami `0.35 / 0.15 / 0.05` · ADORA Cruise `0.30 / 0.15 / 0.05` (FAST / HEALTHY / SLOW thresholds; below SLOW = VERY SLOW).

## Updating the data

1. Click **Template** to download a CSV with the exact column format.
2. Fill in your latest figures (or export your workbook to CSV with those headers).
3. Click **Import CSV** — every KPI, chart, and table recalculates instantly.

---

*Blue &amp; Gold executive edition. Dashboard "as-of" date is fixed at 11 July 2026 for consistent ongoing-velocity math.*
