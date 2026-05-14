# Offer skeleton + email adaptation rules

**Purpose**: the reusable structure behind every outreach email + the rules
for filling the per-lead slots. This is the generation spec — feed it a lead
row (from `data/leads.za.csv`) and it produces a draft in the v5 house style.

Derived from the calibrated top-10 drafts in `manual-first-10.md`.

---

## PART 1 — THE OFFER SKELETON

Every email is **9 blocks**. Each block is either FIXED (identical across
all leads), SEMI-FIXED (one variable inside an otherwise fixed block), or
VARIABLE (written per-lead).

```
┌─────────────────────────────────────────────────────────────────────┐
│ BLOCK              │ TYPE       │ WHAT IT IS                          │
├────────────────────┼────────────┼─────────────────────────────────────┤
│ 0. Subject line    │ SEMI-FIXED │ formula, one variable = lead focus  │
│ 1. Greeting        │ VARIABLE   │ "Hi X team," or "For NAME + TEAM."   │
│ 2. Intel hook      │ VARIABLE   │ 2-3 sentences anchored to a fact    │
│ 3. Who-we-are +    │ SEMI-FIXED │ fixed intro + variable brand list   │
│    brand list      │            │                                     │
│ 4. Volume proof    │ FIXED      │ Uzbekistan / Central Asia / GCC      │
│ 5. Lot sizing      │ FIXED      │ "from 100-unit lots up..."          │
│ 6. Use cases       │ VARIABLE   │ 1-2 numbered — STRONG-FIT LEADS ONLY │
│ 7. Five reasons    │ SEMI-FIXED │ 5 bullets, only the city varies     │
│ 8. Two-question    │ SEMI-FIXED │ Q1 fixed, Q2 city varies            │
│    CTA             │            │                                     │
│ 9. Signature       │ FIXED      │ Easy.car block + HK address + opt-out│
└─────────────────────────────────────────────────────────────────────┘
```

### Block 0 — Subject line  (SEMI-FIXED)

Formula:
```
Direct-from-China <FOCUS> for <COMPANY> — <HOOK>
```
- `<FOCUS>` = the most lead-specific product handle available:
  - if lead already sells specific Chinese brands → those brands
    ("BAIC / BYD / GWM / Haval")
  - if minibus/taxi segment → the minibus models
    ("FAW Sunray / Foton View / Joylong 14-seater RHD")
  - otherwise generic → "RHD supply"
- `<HOOK>` = one of: "open-book pricing", "working session in <CITY>",
  "supplement + new brand coverage", "<their recent move> support"
- Keep under ~80 chars where possible. No spam words (FREE, URGENT, !!!,
  ALL-CAPS). No emoji.

### Block 1 — Greeting  (VARIABLE)

- Default: `Hi <Company> team,`
- If a named decision-maker + team is known and worth routing to:
  `Hi <Company> team,` on line 1, then `For <Name> and the <team> team.`
  as the first sentence of Block 2.

### Block 2 — Intel hook  (VARIABLE)  ← the most important block

2-3 sentences. MUST open with a specific, true fact about the company,
pulled from the `notes` column of the lead row. Then one sentence that
bridges that fact to why we're a fit. Never generic ("we'd like to
introduce ourselves"). See PART 2, Rule C for how to pick the anchor.

### Block 3 — Who-we-are + brand list  (SEMI-FIXED)

Fixed opening:
> We're a Hong Kong-based wholesale importer of RHD Chinese-brand
> vehicles direct from the OEM. NRCS Letters of Authority and OEM
> authorisation letters are in place for:

Then the VARIABLE brand list — tailored to the lead's category (PART 2,
Rule D). Render as a blockquote with a passenger / commercial split where
both apply.

### Block 4 — Volume proof  (FIXED — never edit)

> We ship at volume today — roughly 3,000 vehicles into Uzbekistan and
> another 2,000+ across other Central Asia and GCC markets over the past
> 3 years, with active container and RoRo routes hubbed via Dubai. SA and
> SADC is our current expansion lane: flows into Durban are already
> running for dealer and fleet partners, and we're actively widening that
> network — which is why we're reaching out.

### Block 5 — Lot sizing  (FIXED — never edit)

> We supply from 100-unit lots up — typical range 100–300 per shipment,
> larger lots routine (FOB China or CIF Durban / Cape Town / PE, 6-week
> lead time). For a first engagement we structure a smaller test shipment
> so you can validate specs, paperwork and aftersales without committing
> to scale.

(For minibus/taxi leads the logistics parenthetical may drop "Cape Town /
PE" and the lead time becomes "6–8 week" — that's the only allowed edit.)

### Block 6 — Use cases  (VARIABLE — STRONG-FIT LEADS ONLY)

1-2 numbered items. INCLUDE ONLY IF the lead is a strong fit (already in
the Chinese-brand segment OR a perfect product match). Skip entirely for
generic / cold leads — keeps those emails short. Pattern:
```
  (1) Supplement supply on <brands they already sell> — direct OEM
      pricing versus your current SA distributor channel.
  (2) Brand expansion into <brands they don't yet carry> — <one-line
      market reason>.
```

### Block 7 — Five reasons  (SEMI-FIXED — only the city varies)

Header: `Five reasons this is worth a <30-minute> conversation` (wording
can flex slightly: "worth Gerhardt's 30 minutes", "timely now", etc.)

The 5 bullets, keyword-led, in this order:
1. **Best in-market landed cost** — direct OEM, no SA-channel markup,
   supplier invoices on request, margin maths fully transparent.
2. **Working session in <CITY>** — we'll fly in, and bring a Chinese OEM
   partner along if relevant. ← `<CITY>` is the only variable.
3. **Factory-tour itinerary at our cost** — 3 days, 5 OEMs in
   Shanghai-Chongqing-Hangzhou, NDA-friendly.
4. **Full deal-structure transparency** — open-book invoices, inspection
   on arrival, escrow on first lot, references on request.
5. **Young, technically flexible team** — pilot lots, payment terms
   aligned to sell-through, non-standard contract structures all workable.

### Block 8 — Two-question CTA  (SEMI-FIXED — Q2 city varies)

Header: `Two things would help us come back with something concrete:`

- **Q1 (FIXED)**: Which Chinese brands or models is <COMPANY> currently
  sourcing or considering? — list them, we'll come back within 24 hours
  with FOB pricing and lead times.
- **Q2 (SEMI-FIXED)**: Working session in <CITY> this month, or a China
  factory tour? — say which and we'll send three options.

Q1 NEVER changes — asking them to name models is the whole reply
mechanism. Q2's `<CITY>` follows the lead's HQ city.

### Block 9 — Signature  (FIXED — never edit)

```
Best,
Easy.car team
Wholesale Vehicle Imports — SADC Markets
admin@autosignal.pro · https://easy.car

Easy Car Global Limited
Unit 1618A, 16/F, Pioneer Centre, 750 Nathan Road, Mong Kok, Hong Kong

To opt out: reply UNSUBSCRIBE — we'll suppress within 7 working days.
```
(Web-form sends — e.g. Motus — drop the opt-out line; a form submission
isn't unsolicited bulk mail. Everything else keeps it — POPIA s.69.)

---

## PART 2 — ADAPTATION RULES

How to fill every VARIABLE / SEMI-FIXED slot from a lead row.

### Rule A — Channel selection

Decide HOW to reach the lead from what's in the row:

| Lead has...                                  | Channel             |
|----------------------------------------------|---------------------|
| Verified or generic email (`info@`, etc.)    | **email**           |
| Only a predicted email (no verified/generic) | **contact form**, predicted email as backup only |
| No email at all, only LinkedIn + phone       | **LinkedIn DM** + contact form |
| `do_form_outreach = 0` (tender-only)         | **skip** — not a cold-email target |

### Rule B — TO / CC selection (delivery confidence)

- **TO** = the single highest-confidence address:
  - 🟢 generic mailbox (`info@` / `customercare@` / `enquiries@` /
    `reservations@`) — always exists, 99%+ delivery, OR
  - 🟡 a verified department email from the `notes` column.
- **CC** = up to 2-3 additional verified emails. Maximises the chance a
  real human opens it.
- 🔴 **Predicted personal emails** (guessed `first.last@domain`) → CC
  ONLY, never TO. ~50-70% bounce; a bounce on the TO line kills the whole
  send.
- Never send with a predicted email as the sole recipient.

### Rule C — Intel hook (Block 2) — pick ONE anchor

Read the lead's `notes` + `category` and choose the strongest anchor:

| Signal in the row                           | Angle to take                          |
|----------------------------------------------|----------------------------------------|
| "already sells / carries <Chinese brands>"   | Supplement supply + expand into brands they lack |
| "no Chinese brand yet" / no Chinese distrib  | Close the gap before competitors do    |
| "acquired / added <X> recently"              | Support that specific move (e.g. Motus + Penta) |
| Core business == a product we carry          | Lead with that product (e.g. Bridge Taxi → minibuses) |
| Rental / fleet operator                      | Fleet-renewal unit economics           |
| Finance company for vehicle buyers           | Improve per-unit cost in their financed pipeline |
| Big multi-brand group, no obvious hook       | Scale / direct-channel cost advantage  |

The anchor MUST be a real fact from the row. If `notes` is thin, fall
back to `category` + `hq_city` + company size cues. Never invent.

### Rule D — Brand list (Block 3) — tailor to category

| Category                    | Brand list to show                          |
|-----------------------------|---------------------------------------------|
| Dealer Group                | Full passenger list (Chery, Omoda, Jaecoo, Jetour, GWM, Haval, Tank, BAIC, BYD, JAC, Geely, MG) + commercial (FAW, Foton, Joylong, Sinotruk) |
| Taxi-Recap & Minibus        | ONLY minibus: FAW Sirius/Sunray, Foton View C2, Joylong EFi — with specs (seater, engine) |
| Rental & Fleet / Corporate  | Economy passenger only: Chery, GWM, BYD, MG  |
| Logistics-Truck Buyer       | Commercial only: Sinotruk Sitrak, FAW J7, Foton, Dongfeng |
| Bus Operator                | Yutong, Higer, King Long (diesel + electric) |
| Mining / Government Fleet   | Bakkie + commercial: GWM, JAC, Foton, Sinotruk |

If the lead **already sells** specific brands (from `notes`), split the
list into "your current brands" + "expansion options" — see Block 6.

### Rule E — Working-session city (Blocks 0, 7, 8)

- Primary city = the lead's `hq_city`.
- Always offer Sandton as the alternative (it's the SA business hub) —
  unless the lead IS in Sandton, then just name Sandton.
- Format in the bullet: "Working session in <hq_city> or Sandton".

### Rule F — Subject line focus (Block 0)

Pick `<FOCUS>` by priority:
1. If lead already sells named Chinese brands → use 2-4 of those brands.
2. Else if minibus/taxi segment → the minibus model names.
3. Else → "RHD supply".
Pick `<HOOK>` to match the angle from Rule C.

### Rule G — Use-cases block (Block 6) — include or skip

- **Include** (1-2 numbered items) if the lead is STRONG-FIT:
  already sells Chinese brands, or is a textbook product match.
- **Skip entirely** for generic / cold leads — keeps the email tight and
  under the length budget.

### Rule H — Length discipline

- Body target: **≤ 320 words** (excludes signature).
- Strong-fit leads may run longer because of Block 6 — cap ~380 words.
- LinkedIn DM (Rule A → LinkedIn): **≤ 130 words**, compress Blocks 3-8
  into 2 short paragraphs + the 2-question CTA.

### Rule I — Greeting personalisation (Block 1)

- `contact_name` present AND a senior decision-maker → "For <first name>
  and the <team> team." as Block 2's opener.
- Otherwise → plain "Hi <Company> team,".
- Never guess a first name from an email address.

### Rule J — Invariant blocks — NEVER touch

These are identical in every draft. Changing them per-lead creates
inconsistency and re-introduces claims we'd have to defend differently
each time:
- Block 4 (volume proof)
- Block 5 (lot sizing) — except the one allowed logistics tweak for
  minibus leads
- Block 7 bullets 1, 3, 4, 5 (only bullet 2's city varies)
- Block 8 Q1
- Block 9 (signature + address + opt-out)

---

## PART 3 — CLAIMS LEDGER (what we can say, and the proof behind it)

Every factual claim in the offer, and what backs it. If a claim can't be
backed, it doesn't go in the email.

| Claim in the email                          | Backing                              |
|----------------------------------------------|--------------------------------------|
| "Hong Kong-based importer"                   | Easy Car Global Limited, HK BR No. 80208268-000-04-26-7 |
| "~3,000 into Uzbekistan, 2,000+ Central Asia/GCC, 3 years" | operator-provided — MUST be true; first reply can probe it |
| "NRCS LOA + OEM authorisation in place"      | operator-provided — confirm which brands BEFORE sending per-category lists |
| "5–12% below SA-channel landed cost"         | only stated as "best in-market" + "invoices on request" — soften if not provable |
| "open-book supplier invoices on request"     | operator must actually be willing to show them — it's the trust hook |
| "we'll fly into <city>"                      | operator must be willing — this is the CTA's strongest pull |
| "factory tours at our cost"                  | operator-provided capability |
| "6-week lead time"                           | operator-provided — standard for FOB China RHD |

⚠️ Anything in this ledger marked "operator-provided" must be confirmed
true before the broader 63-lead push — a procurement contact WILL probe
the numbers on the first call, and a contradiction there kills the deal
and the reputation.

---

## PART 4 — CALIBRATION HOOKS

After the first replies come back, these are the slots most likely to
change — update this spec, then regenerate:

1. **Block 2 anchor wording** — which angle pulled replies, which got
   ignored.
2. **Block 0 subject formula** — which `<HOOK>` opened best.
3. **Block 8 Q2** — did "working session" or "factory tour" get picked
   more? Lead with the winner.
4. **Claims ledger** — any claim a prospect pushed back on gets softened
   or dropped.
5. **Brand lists (Rule D)** — every model a prospect actually names in a
   reply becomes a confirmed-demand signal; surface those models earlier
   in future drafts for that category.
