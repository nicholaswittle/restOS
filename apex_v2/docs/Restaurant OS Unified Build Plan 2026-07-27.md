---
title: Restaurant OS — Unified Build Plan
tags: [business, product, restaurant-os, apex, supabase, build-plan, unified, strategy]
aliases: [Unified OS Plan, Final OS Build Plan]
date: 2026-07-27
status: active-ratified
---

# Restaurant OS — Unified Build Plan

> Merges the best of Hermes's bridge-piece strategy with Kimi K3's schema/security/deployment design. One plan. Build order that ships features standalone while the OS emerges underneath.

Related: [[business/WiSense Restaurant OS Master Plan 2026-07-27]], [[business/Restaurant OS Build Strategy 2026-07-27]], [[wisense/projects/RESTAURANT_OS_BUILD_PLAN]], [[Apex Scheduler]], [[business/Reusable Platform Components 2026-07-26]], [[business/Pricing Models Ownership and Exit 2026-07-26]], [[NOW]]

---

## What This Plan Merges

| Source | What We Took |
|---|---|
| Hermes bridge strategy | Build order — each piece useful standalone, ship Apex first |
| Kimi K3 schema | 20-table schema with floor plans, modifier groups, dead letter queue, idempotency keys |
| Kimi K3 security | RLS helper functions, role hierarchy (owner→manager→server→kitchen→readonly) |
| Kimi K3 deployment tiers | Single DB + RLS now → per-client DB at scale → dedicated for enterprise |
| Kimi K3 ML foresight | Prep-time snapshots from day one, train models later |
| Hermes pricing | $25/mo Pro, $99/mo OS, flat rate, no per-user, no add-ons |

---

## Build Order (Revised)

### Step 0: SHIP APEX (Friday — blocking on keystore + accounts)
1. Buy Apple Dev ($99) + Google Play ($25)
2. Create keystores (see [[output/Keystore Setup Instructions 2026-07-20]])
3. Apply RLS migration to Supabase prod
4. Build .aab, upload to Google Play internal testing
5. Build iOS archive from Mac, upload to App Store Connect

**No new code. Just ship what's built.**

### Step 1: STANDALONE FEATURES (2-3 weekends, no OS connection needed)

These add to Apex's existing Supabase. Each is useful whether or not the OS ever happens:

**1a. Manager Log Book** (1 weekend)
- `shift_notes` table: id, organization_id, author_id, shift_date, note, photo_url, created_at
- Manager writes handoff notes at end of shift
- Next shift sees them on clock-in
- 7shifts charges $14.99/mo. You include it free.

**1b. Tip Management** (1 weekend)
- `tip_pools` table: id, organization_id, shift_date, total_cents, split_method, created_at
- `tip_allocations` table: id, tip_pool_id, user_id, hours_worked, amount_cents
- Owner enters total tips → system splits by hours from time_entries
- Employees see their split in the app
- 7shifts charges $49.99/mo. You include it free.

**1c. Labor Cost Dashboard** (1 weekend)
- Pull from existing schedule + time_entries
- Show: scheduled hours × rate vs actual clocked hours × rate
- Daily/weekly/monthly view
- Alert when labor exceeds 30% of projected sales
- 7shifts requires Pro ($69.99/mo) for this. You include it.

**Each of these makes Apex the best scheduling app for independent restaurants. Ship them before touching the OS.**

### Step 2: UNIFIED SUPABASE BACKEND (1 weekend)

Move ordering data into Apex's Supabase using Kimi's schema:

**Phase 1 tables (7):**
| Table | Purpose |
|---|---|
| restaurants | Core tenant record (links to Apex's organizations) |
| restaurant_settings | Config + feature flags + paused state + fee + tax |
| restaurant_locations | Single location first, multi-ready |
| menu_categories | Display grouping |
| menu_items | Core sellable items with price, availability, sort_order |
| modifier_groups | Grouped rules (size, crust, toppings, wing sauce) |
| modifier_options | Selectable options with pricing |

**Phase 2 tables (3):**
| Table | Purpose |
|---|---|
| menu_item_modifier_groups | Junction with overrides |
| online_orders | Full order record with state machine |
| order_items | Line items snapshot |

Port the ordering frontend to read/write from Supabase instead of D1. Now both apps share one database.

### Step 3: OS BRIDGE FEATURES (2-3 weekends)

Now that both apps share Supabase, the OS features emerge:

**3a. Labor vs Revenue Dashboard** (1 weekend)
- Pull time clock (Apex) + order totals (ordering) from same Supabase
- "Tonight: $2,400 in orders, $480 in labor = 20%"
- Weekly trends, overtime alerts

**3b. No-Show Call-Out Engine** (1 weekend)
- Staff marks "can't make it" in Apex
- System auto-texts available employees with matching role
- First responder gets the shift
- Ordering adjusts capacity if no one fills it

**3c. Smart Ordering Capacity** (1 weekend)
- Ordering checks Apex schedule before accepting orders
- "1 cook on shift → max 15 orders/hour → order #16 gets longer wait warning"
- Auto-pause when critically understaffed
- Auto-resume when next cook clocks in

### Step 4: PRODUCTION INTEGRATION (DEFER until a pilot venue commits)

**Phase 4 tables (deferred):**
| Table | Purpose |
|---|---|
| integration_connections | Square etc. status |
| integration_credentials | Encrypted tokens (Supabase Vault) |
| pos_menu_map | Internal ↔ external ID mapping |
| sync_jobs | Sync audit trail |
| pos_order_map | Idempotency keys |
| dead_letter_queue | Failed operations |

Only build when: a pilot venue gives written approval AND you're ready for a real pilot.

### Step 5: ML & ADVANCED (DEFER — capture data now, build later)

**Capture from day one:**
- `prep_time_snapshots` table — record order submitted → order ready timestamps
- No model training yet, just data collection

**Build later (months away):**
- Prep-time estimation model
- Order throttling algorithm
- Staffing recommendations based on sales patterns
- Labor optimization suggestions

---

## Security Model (Kimi K3)

### RLS Helper Functions
```sql
CREATE OR REPLACE FUNCTION is_member(org_uuid UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_members
    WHERE organization_id = org_uuid
    AND user_id = auth.uid()
  );
$$ LANGUAGE sql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION has_role(org_uuid UUID, required_role TEXT)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM organization_members
    WHERE organization_id = org_uuid
    AND user_id = auth.uid()
    AND role IN (required_role, 'manager', 'owner')
  );
$$ LANGUAGE sql SECURITY DEFINER;
```

### Role Hierarchy
| Role | Permissions |
|---|---|
| owner | Everything — billing, settings, all staff, all data |
| manager | Schedule, time clock, orders, log book, tips, staff management |
| server | View schedule, clock in/out, view orders, write log notes |
| kitchen | View schedule, clock in/out, view/accept orders |
| readonly | View schedule only (e.g. seasonal staff) |

All new tables get RLS with `organization_id` scoping — same pattern as existing Apex tables.

---

## Deployment Tiers (Kimi K3)

| Tier | When | Architecture |
|---|---|---|
| **2A** | NOW (start here) | Single Supabase project, shared schema, RLS per organization_id |
| **2B** | Scale (10+ clients) | Per-client Supabase project on paid tier |
| **2C** | Enterprise | Dedicated Supabase projects for franchises/multi-location |

Start at 2A. A single Supabase project with RLS handles dozens of restaurants. Move to 2B only if performance or isolation requirements demand it.

---

## Full Schema (Merged — 16 tables, phased)

### Phase 1: Core + Menu (ship first, 7 tables)
```sql
-- Links to Apex's existing organizations table
CREATE TABLE restaurants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id),
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE restaurant_settings (
  restaurant_id UUID PRIMARY KEY REFERENCES restaurants(id),
  paused BOOLEAN NOT NULL DEFAULT false,
  prep_minutes INT NOT NULL DEFAULT 30,
  fee_cents INT NOT NULL DEFAULT 0,
  tax_rate REAL NOT NULL DEFAULT 0.06,
  payment_mode TEXT NOT NULL DEFAULT 'manual'
);

CREATE TABLE restaurant_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID REFERENCES restaurants(id),
  address TEXT,
  city TEXT,
  state TEXT DEFAULT 'PA',
  postcode TEXT,
  lat REAL,
  lon REAL,
  phone TEXT,
  hours_json JSONB
);

CREATE TABLE menu_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID REFERENCES restaurants(id),
  name TEXT NOT NULL,
  sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE menu_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID REFERENCES restaurants(id),
  category_id UUID REFERENCES menu_categories(id),
  name TEXT NOT NULL,
  description TEXT,
  price_cents INT NOT NULL,
  available BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE modifier_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  menu_item_id UUID REFERENCES menu_items(id),
  name TEXT NOT NULL,
  required BOOLEAN NOT NULL DEFAULT false,
  min_select INT DEFAULT 0,
  max_select INT DEFAULT 1
);

CREATE TABLE modifier_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  modifier_group_id UUID REFERENCES modifier_groups(id),
  name TEXT NOT NULL,
  price_delta_cents INT NOT NULL DEFAULT 0
);
```

### Phase 2: Orders (after backend unified, 3 tables)
```sql
CREATE TABLE online_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id UUID REFERENCES restaurants(id),
  public_token TEXT UNIQUE NOT NULL,
  status TEXT NOT NULL DEFAULT 'waiting',
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at TIMESTAMPTZ,
  rejected_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  pickup_minutes INT NOT NULL DEFAULT 30,
  customer_json JSONB NOT NULL,
  notes TEXT NOT NULL DEFAULT '',
  subtotal_cents INT NOT NULL,
  fee_cents INT NOT NULL DEFAULT 0,
  tax_cents INT NOT NULL DEFAULT 0,
  total_cents INT NOT NULL,
  payment_mode TEXT NOT NULL DEFAULT 'manual',
  payment_status TEXT NOT NULL DEFAULT 'pending'
);

CREATE TABLE order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES online_orders(id),
  menu_item_id UUID REFERENCES menu_items(id),
  name TEXT NOT NULL,
  price_cents INT NOT NULL,
  quantity INT NOT NULL DEFAULT 1,
  notes TEXT
);

CREATE TABLE order_item_modifiers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_item_id UUID REFERENCES order_items(id),
  modifier_option_id UUID REFERENCES modifier_options(id),
  name TEXT NOT NULL,
  price_delta_cents INT NOT NULL DEFAULT 0
);
```

### Phase 3: OS Bridge (Standalone Apex features, 3 tables)
```sql
CREATE TABLE shift_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id),
  author_id UUID REFERENCES auth.users(id),
  shift_date DATE NOT NULL,
  note TEXT NOT NULL,
  photo_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE tip_pools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID REFERENCES organizations(id),
  shift_date DATE NOT NULL,
  total_cents INT NOT NULL,
  split_method TEXT NOT NULL DEFAULT 'hours',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE tip_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tip_pool_id UUID REFERENCES tip_pools(id),
  user_id UUID REFERENCES auth.users(id),
  hours_worked REAL NOT NULL,
  amount_cents INT NOT NULL
);
```

### Phase 4: Integration (DEFER, 6 tables)
```sql
-- Only build when a pilot venue commits to a real pilot
CREATE TABLE integration_connections (...);
CREATE TABLE integration_credentials (...); -- Supabase Vault for tokens
CREATE TABLE pos_menu_map (...);
CREATE TABLE sync_jobs (...);
CREATE TABLE pos_order_map (...); -- idempotency keys
CREATE TABLE dead_letter_queue (...);
```

### Phase 5: ML Data Capture (capture now, 1 table)
```sql
CREATE TABLE prep_time_snapshots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES online_orders(id),
  restaurant_id UUID REFERENCES restaurants(id),
  submitted_at TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ,
  ready_at TIMESTAMPTZ,
  pickup_minutes_actual INT,
  items_count INT,
  staff_on_shift INT
);
-- No model training yet. Just capture data.
```

### Phase 6: Floor Plan (future, 1 table)
```sql
CREATE TABLE location_tables (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id UUID REFERENCES restaurant_locations(id),
  label TEXT NOT NULL,
  seats INT,
  status TEXT NOT NULL DEFAULT 'open' -- open/seated/dirty/reserved
);
-- Only needed for dine-in table management. Skip for v1.
```

---

## Pricing (Unchanged)

| Tier | Price | Features |
|---|---|---|
| Free | $0 | 1 location, 20 employees, basic scheduling + swaps + time clock |
| Pro | $25/mo flat | Unlimited employees + log book + tip management + labor cost reports + offline mode |
| OS | $99/mo flat | Everything in Pro + ordering platform + smart capacity + no-show engine + labor vs revenue dashboard |
| Multi-Location | $199/mo | Up to 3 locations, full OS |

---

## What Makes This Different from Dead Projects

| Dead Projects | This Plan |
|---|---|
| Built platform before any feature | Each feature ships standalone |
| No user in mind | Pilot venue + FFL dealer + 67 cold prospects |
| Built for self | Built for real restaurants with validated demand |
| Over-engineered infrastructure | Phased — 7 tables first, scale later |
| Hoped users would come | Users exist, Apex is shipping Friday |
| All-or-nothing | Bridge pieces — each useful on its own |

---

## Timeline

| Week | What | Result |
|---|---|---|
| This Friday | Ship Apex to Google Play + App Store | Apps live |
| Weekend 1 | Manager log book + tip management | Apex is best free scheduling app |
| Weekend 2 | Labor cost dashboard | Apex Pro tier is ready ($25/mo) |
| Weekend 3 | Unified Supabase backend | Ordering data moves into Supabase |
| Weekend 4 | Labor vs revenue dashboard | First OS feature |
| Weekend 5 | No-show call-out engine | Nobody has this |
| Weekend 6 | Smart ordering capacity | The killer feature, OS is live |

6 weekends from shipping Apex to a working restaurant OS. Each weekend produces a shippable feature. No dead infrastructure.