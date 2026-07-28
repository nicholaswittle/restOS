---
title: WiSense Restaurant OS — Master Plan
tags: [business, product, restaurant-os, apex, strategy, vision, pricing, multi-vertical]
aliases: [Restaurant OS, Full OS Plan, WiSense OS]
date: 2026-07-27
status: vision-active
---

# WiSense Restaurant OS — Master Plan

> The big vision: one system that runs the entire restaurant. Scheduling, ordering, labor cost, tip management, shift handoffs, customer flow. No competitor does this. This is the dream.

Related: [[Apex Scheduler]], [[business/Reusable Platform Components 2026-07-26]], [[business/Pricing Models Ownership and Exit 2026-07-26]], [[business/Client Acquisition Strategy — Loom Zoom Boom & FIG Portfolio]], [[NOW]]

---

## The Vision

Walk into a restaurant. The owner is running everything from their phone:

- Staff see their schedule in Apex, get push notifications, swap shifts, clock in
- Customers order from the website, tickets print to the kitchen
- The owner sees labor cost vs revenue in real time
- When a rush hits, the system auto-pauses ordering based on who's on shift
- When someone calls out, the system texts available employees to fill the gap
- Tips are tracked and split automatically
- Shift handoff notes pass from the day shift to the night shift
- The owner closes out the night: $2,400 in sales, $480 in labor (20%), 47 orders, 3 no-shows handled

That's not a scheduling app. That's not a website. That's a restaurant operating system. And nobody else sells one.

---

## What Exists Today (Built)

### Apex Scheduler (staff side)
- Shift scheduling, drag-and-drop
- Shift swaps and covers
- Availability and time-off requests
- Time clock (clock in/out)
- Sidework assignments
- Push notifications
- Multi-tenant (organization_id)
- Flutter + Supabase, 95% complete

### Ordering Platform (customer side)
- 52-item menu, categories, modifiers
- Cart, checkout, pickup scheduling
- Staff console: accept/reject, pause/reopen, sold-out controls
- Kitchen ticket printing (80mm thermal)
- Customer notifications (accepted/rejected)
- Cloudflare Workers + D1 database
- Deployed on Cloudflare Workers (demo)

### WiSense LLC Website (portfolio)
- wisensellc.com — 5 ventures, before/after demo, pricing, journal

---

## The OS — What Connects Them

### Phase 1: SHARED DATA LAYER
Both systems read/write to one Supabase database:
- Apex: shifts, time_entries, availability, swaps, staff
- Ordering: orders, menu, settings, fees
- New shared tables: labor_cost_daily, revenue_daily, shift_handoff_log, tip_pool

### Phase 2: LABOR VS REVENUE DASHBOARD
- Apex time clock data + ordering sales data = real-time labor cost percentage
- Owner sees: "Tonight: $2,400 sales, $480 labor = 20%. Last Friday: $3,100 sales, $520 labor = 17%."
- Alerts when labor exceeds 30% of projected sales
- Weekly trend: are you overstaffing slow nights?

### Phase 3: SMART ORDERING CAPACITY
- Ordering system checks Apex schedule before accepting orders
- "You have 1 cook on shift. Max 15 orders/hour. Order #16 gets 'longer wait time' warning."
- Auto-pause ordering when critically understaffed
- Auto-resume when the next cook clocks in
- No competitor does this

### Phase 4: NO-SHOW / CALL-OUT ENGINE
- Staff member marks themselves "can't make it" in Apex
- System auto-texts all available employees with matching role: "Mike called out for tonight 5-11. Can you cover? Tap yes."
- First responder gets the shift
- Ordering system adjusts capacity if no one fills it
- No competitor does this

### Phase 5: TIP MANAGEMENT
- Owner enters tip pool at end of shift
- System splits by hours worked (from time clock data)
- Employees see their tip breakdown in the app
- 7shifts charges $49.99/mo for this. You include it.

### Phase 6: MANAGER LOG BOOK
- Shift handoff notes: "Walk-in fridge is down. Called repair. Prep extra for tomorrow."
- Day shift → night shift → next day
- Attach photos of issues
- 7shifts charges $14.99/mo for this. You include it.

### Phase 7: OFFLINE MODE
- Kitchen WiFi is unreliable
- Apex works offline, syncs when reconnected
- Orders queue locally, sync when connection returns
- No competitor does this

---

## Multi-Venue by Design — Restaurant Is Vertical One

**The product is a venue operating system, not a restaurant app.** What it
actually manages is shift-based labor: who works when, did they show up, what
did that cost, what does the next crew need to know, and how does the money get
split. That shape is the same in a dining room, on a job site, in a salon
chair, on a retail floor, or in a warehouse. Restaurants are simply the first
vertical — the one with a live prospect list and a working ordering platform.

**The shared core — every vertical, no changes:**

| Module | Why it travels |
|---|---|
| Scheduling + swaps | Every shift-based business has a roster and callouts |
| Time clock | Clock in/out is universal; QR + geofence matter more off-site, not less |
| Labor cost | Labor ÷ revenue is the same equation everywhere |
| Log book | Shift handoff, crew handoff, site handoff, salon close-out — same object |
| Team chat | Replaces the group text in any crew |
| Offline mode | A basement kitchen and a job-site trailer have the same bad signal |
| Payout splits | Tips, bonus pools, job splits — one engine, different label |
| Entitlements | Same tier + per-module plug-in model regardless of vertical |

That list is the whole free and Pro tier. **Everything a venue pays $25/mo for
today is already vertical-agnostic** — nothing about it is restaurant-only.

**The vertical pack — the only part that changes:**

| Piece | Restaurant | Trades / field | Retail | Salon / clinic |
|---|---|---|---|---|
| Demand front-end | Online ordering, menu | Job / work orders | — | Appointments |
| Capacity rule | Orders/hr vs cooks on | Crew vs scheduled tasks | Floor cover | Chairs vs bookings |
| Revenue source | POS / online orders | Invoices, job billing | POS | Booking system |
| Vocabulary | shift, server, kitchen, tips | shift, crew, foreman, job | shift, floor, associate | appointment, chair, stylist |
| Compliance | Food safety, minor hours | OSHA, certifications | Minor hours | Licensure |

A new vertical is a **pack**, not a fork: the same core plus a different
front-end, capacity rule, revenue adapter, and vocabulary.

**The two disciplines that keep this possible — follow them now, cheaply:**

1. **Terminology comes from venue config, never hardcoded.** A feature asks for
   the venue's word for a thing; it does not write `'Tips'` into a widget. Get
   this wrong across twenty screens and vertical two becomes a find-and-replace
   fork.
2. **Vertical-specific logic stays behind a module boundary** — the one
   `lib/core/entitlements.dart` already defines. If a rule only makes sense in
   one vertical, it belongs in that vertical's module, not in the core.

**Do not build vertical two until vertical one is paying.** This section exists
so the architecture stays open, not as a reason to generalize early — building
a platform before having a user is exactly how the dead projects died. The
terminology layer is worth adding the moment a second vertical is real; until
then, just avoid hardcoding the words that would have to change.

---

## The Pricing — Dream Big

### Tier 1: Starter (foot in the door)
- **Free** — 1 location, up to 20 employees
- Scheduling, swaps, time clock, push notifications
- No ordering, no tip management, no log book
- Goal: get them using it, become their tech person

### Tier 2: Pro
- **$25/mo flat** — unlimited employees, 1 location
- Everything in Starter + tip management + manager log book + labor cost reports + offline mode
- No per-user charges. No add-ons.
- Cheaper than 7shifts ($40-150), Deputy ($97+), When I Work ($37-150)
- Restaurant-specific (unlike Sling, ZoomShift)

### Tier 3: OS — Full Restaurant Operating System
- **$99/mo flat** — unlimited employees, 1 location
- Everything in Pro + ordering platform + smart capacity + no-show engine + labor vs revenue dashboard
- The full OS: scheduling + ordering + labor optimization
- No competitor offers this at any price
- This is the dream product

### Tier 4: Multi-Location
- **$199/mo** — up to 3 locations
- Everything in OS, multi-location dashboard
- For small restaurant groups (2-3 locations)

### The Pilot Deal
- Free OS pilot for the first venue, in exchange for social proof (testimonial, case study data)
- The pilot is the proof that it works
- Once measured, their real numbers become the pitch — a labor-cost delta and
  missed-order count you can actually stand behind. Until it is measured, the
  pitch is the capability, not a result.

---

## Revenue Projections — Dream Big

| Clients | Tier | Monthly Revenue | Annual Revenue |
|---|---|---|---|
| 1 | Pro ($25/mo) | $25 | $300 |
| 5 | Pro ($25/mo) | $125 | $1,500 |
| 10 | Pro ($25/mo) | $250 | $3,000 |
| 5 | OS ($99/mo) | $495 | $5,940 |
| 10 | OS ($99/mo) | $990 | $11,880 |
| 20 | OS ($99/mo) | $1,980 | $23,760 |
| 10 OS + 10 Pro | Mixed | $1,240 | $14,880 |
| 20 OS + 20 Pro | Mixed | $2,480 | $29,760 |
| 50 OS clients | OS only | $4,950 | $59,400 |

At 50 OS clients at $99/mo, that's nearly $60K/year in recurring revenue. From one product. Built on code you already have.

---

## The Moat — Why Nobody Else Can Do This Easily

1. **7shifts can't add ordering** — they're a scheduling company. Adding a full ordering platform is a different product. They'd need to build or acquire one.
2. **ChowNow/Slice can't add scheduling** — they're ordering companies. Adding staff scheduling is a different product.
3. **Toast does both but costs $1,000+/mo** — Toast is a POS system with scheduling and ordering, but it's enterprise-priced and requires their hardware.
4. **Square has both but they're disconnected** — Square POS + Square Online + Square Scheduling are separate products that don't talk to each other.
5. **You connect scheduling + ordering + labor cost in one system** — nobody does this for small independent restaurants at an affordable price.

The gap in the market: affordable, restaurant-specific, scheduling + ordering + labor optimization in one system. That's the OS.

---

## Build Order (Don't Build the OS Before You Have Users)

1. **SHIP APEX** — Friday: buy accounts, keystores, .aab, Google Play. Apply RLS migration to Supabase.
2. **GET 1-2 VENUES USING APEX FREE** — a pilot venue + 1 cold prospect. Free tier.
3. **SHIP ORDERING PLATFORM** — pilot venue approves, go live. Get 1-2 venues paying for websites + ordering.
4. **CONNECT THEM** — shared Supabase data layer. Labor vs revenue dashboard. This is the OS prototype.
5. **ADD TIP MANAGEMENT + LOG BOOK** — these are easy builds (CRUD + math) but high value (competitors charge extra for them).
6. **PITCH THE OS** — "I don't just build websites. I run your restaurant. Scheduling, ordering, labor cost, tips, shift handoffs. $99/mo. One system."
7. **SCALE** — 10 OS clients = $1,188/mo. 20 = $2,376/mo. 50 = $4,950/mo.

---

## What to Build First After Apex Ships

### Quick wins (1 weekend each, high differentiator value):

1. **Manager log book** — CRUD + timestamps. 7shifts charges $14.99/mo for this. You include it free in Pro.
2. **Tip management** — owner enters pool, system splits by hours from time clock. 7shifts charges $49.99/mo. You include it free in Pro.
3. **Labor cost dashboard** — time clock hours × hourly rate vs shift schedule. Shows overstaffing in real time.
4. **No-show call-out engine** — staff marks "can't make it" → system texts available employees. Nobody else does this.

Each of these is a weekend build. Each one is a feature competitors charge extra for or don't have. Stack them up and you have the OS.

---

## The Pitch (When the OS is Ready)

"Every restaurant runs on 3 disconnected systems: a scheduling app, a POS, and a website. They don't talk to each other. The owner manually checks three dashboards, three apps, three logins.

WiSense Restaurant OS is one system. Your staff schedule, your customer orders, your labor cost, your tips, your shift handoffs — all in one place. When a rush hits, the system knows who's on shift and adjusts ordering capacity. When someone calls out, the system finds a replacement automatically. When you close out the night, you see exactly what you made and what you spent.

$99/month. One system. One login. One price.

No per-user charges. No add-ons. No POS hardware required.

One number tells you if the night made money. One system runs the floor and the schedule. I'll build you a free demo on your own menu and your own staff."

---

## The 5-Year Dream

- 100 OS clients at $99/mo = $118,800/year recurring
- 50 Pro clients at $25/mo = $15,000/year recurring
- Total: $133,800/year in recurring revenue
- Plus one-time website setups ($299 each)
- Plus the website care plans ($79/mo each)
- You're a one-person software company serving independent restaurants
- No VC, no employees, no office
- Run from your phone on off-weekends

That's the dream. Build it one step at a time. Ship Apex first.