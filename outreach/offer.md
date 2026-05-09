# Offer — wholesale supply of Chinese RHD passenger & commercial vehicles to South Africa

## Who we are
A wholesale importer of Chinese-made vehicles (passenger cars, SUVs, bakkies,
light commercials, minibuses, heavy trucks and buses) into Southern Africa.
We ship in container or RoRo lots of **100–300+ units per consignment**, FOB
China or CIF Durban / Cape Town / Port Elizabeth.

## What we supply
- **Passenger / SUV / bakkie**: Chery, Omoda, Jaecoo, Jetour, GWM, Haval, Tank,
  BAIC, BYD, JAC, Geely, Changan, Dongfeng, MG, LDV.
- **Minibus / taxi-recap (14 / 16-seater)**: JAC Sunray, FAW Sirius, Foton View,
  Joylong — RHD, NRCS LOA ready.
- **Heavy commercial**: Sinotruk Sitrak, FAW J7, Foton, Dongfeng truck and bus
  variants.
- **Bus**: Yutong, Higer, King Long — diesel and battery-electric.

## What is in place before shipment
- NRCS LOA (Letter of Authority) for each model.
- OEM authorisation letter (genuine, not grey).
- RHD configuration, NaTIS-eligible, SABS pre-clearance where applicable.
- Banking arrangement via DMCC / Dubai-resident entity (mitigates sanctions
  friction for SA-listed and JSE-corporate counterparties).

## What we typically negotiate
- Volume tier / sub-distribution rights for Tier-A dealer groups.
- Buy-back or residual-value guarantee on pilot lots for rental & fleet.
- Full-maintenance lease pricing with parts SLA (48–72 h Gauteng / WC / KZN).
- Chinese export-credit financing (7–10 years) for bus and heavy-truck pilots.

---

## Per-category angles (the LLM picks the right one)

The personalisation prompt receives the lead's `category` field and chooses
the matching block below. **Do not paste the whole offer.** Use the matching
block as the spine of the message and weave in 1–2 facts from the lead's
website analysis.

### Dealer Group  →  *franchise development / sub-distribution*
We are looking for a regional partner to take a sub-distribution territory or
a one-off bulk order of RHD Chinese inventory. NRCS LOA + OEM authorisation
letters are already issued. We can also discuss exclusive area rights against
volume commitments.

### Rental & Fleet  →  *cost-per-asset / lifecycle TCO*
At fleet size of {{N}}, a per-unit price reduction of R30 000–R60 000 against
incumbent supply is R0.4–2.1bn of CapEx saving across one renewal cycle. We
supply direct from OEM (no local distributor margin) plus a service/parts SLA
through certified SA service partners.

### Taxi-Recap & Minibus  →  *Toyota HiAce alternative, financing-grade quality*
14- and 16-seater RHD minibuses (JAC Sunray / FAW Sirius / Foton View /
Joylong) at R310 000–R350 000 ex-port Durban — roughly 25–30% below HiAce.
3-year / 100 000 km warranty, certified SA service partner, minimum lot
100 units (200 recommended for unit-economics).

### Used-car Wholesaler  →  *direct-from-port sourcing of demo / buy-back stock*
Demo and buy-back Chery / Omoda / Haval at 5–15 000 km, wholesale R210k–R340k
per unit, lots of 50–100. Auction-format on request.

### Logistics-Truck Buyer  →  *fleet renewal Sinotruk / FAW / Foton, payback ~36 mo*
6×4 tractor units (Sinotruk Sitrak, FAW J7) RHD at ~35% below European
equivalents. Pilot of 20 units with a full support package and 5/300 000 km
warranty.

### Bus Operator  →  *Yutong / Higer / King Long electric & diesel + Chinese financing*
BYD K9 / Yutong E12 (battery-electric), Yutong ZK6128 / Higer KLQ6128 (diesel)
RHD, BBBEE-aware structure, optional Chinese export-credit at 7–10 years for
30+ unit pilots.

### Mining Fleet · Corporate Fleet · Government Fleet  →  *DO NOT cold-pitch*
These categories buy via tender (CSD / Coupa / Ariba / RT57 / supplier portal).
Cold contact-form fills are ignored or harm reputation. The toolkit marks these
as `channel=tender_only` and skips them. Engage via supplier registration and
tender response, not outreach.

### Industry Assoc (NAAMSA, NADA, NAACAM, RMI)  →  *intel & networking only*
No sales pitch. Use these as gatekeepers / intel sources / member-day speaking
opportunities. Toolkit marks as `tender_only`.

---

## Tone for outgoing messages
- English only, regardless of the lead's site language.
- Direct, professional, no marketing fluff. 4–7 sentences in the form body.
- Reference one specific fact about the company (recent acquisition, brand
  partnership, fleet size, BBBEE level, recent news) — proves the message
  isn't a mass blast.
- No "Hope this finds you well", no "I came across your website".
- Always sign with a real name + company + a working contact channel.

## POPIA Section 69 — mandatory in every message body
Every form submission MUST contain in the body (not only as footer):
1. Sender identification: real name, company, physical address.
2. A working opt-out instruction (e.g. "Reply UNSUBSCRIBE and we will remove
   your address from our outreach list within 24 h.").
3. No misleading "Re: …" subject lines, no fake reply threads.

The `personalize_offer` prompt enforces this: the JSON it returns includes a
`compliance_footer` field that the form-filler appends verbatim to the message
field. If the footer is missing, the toolkit aborts the send.
