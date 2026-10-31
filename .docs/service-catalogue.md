# Service catalogue

Proposed product/pricing sheet for customer tenants. Numbers are **proposals,
not validated prices**; revise after the first three customers. Competitor
figures were checked against vendor pricing pages in **October 2026**;
re-verify before publishing anything customer-facing.

Operational detail lives in `ops/tenants/README.md`.

---

## What we sell

Self-hosted business software on hardware we control, sold as a flat monthly
fee per organisation.

| Product | Software | Status | Proposed price |
| --- | --- | --- | --- |
| **Document Management** | Paperless-ngx; scan, OCR, tag, full-text search, correspondences | pilot-ready | **£10/mo** |
| **File Storage** | Ferro; our own Rust platform: WebDAV, S3, OIDC, Cedar authorisation, full-text search | needs auth wiring | **£12/mo** |
| **Photo Library** | Immich; phone photo backup, albums, face/search (ML optional); estate-native replacement (`aperture`) in progress | validate first | **£12/mo** |
| **Office Bundle** | Documents + Files | - | **£20/mo** |

Proposed add-ons: extra storage £2 per 50GB, additional user £1/user/mo,
off-site backup already included.

### Included in every plan

- A dedicated subdomain with TLS (post-quantum key agreement; Let's
  Encrypt certificates with automated renewal)
- Nightly backups, with an off-site copy; monthly automated restore
  drills (the backup is proven, not assumed)
- Security-scanned, continuously patched container images from our own
  registry; digest-pinned upstream images
- A status notification when something breaks, and a human who reads it

---

## Optional add-ons

| Add-on | What it is | Availability |
| --- | --- | --- |
| **Point-in-time recovery** | Database change archiving (WAL): restore to any moment, ~5 min data-loss ceiling instead of 24 h | Per contract; requires PostgreSQL |
| **Snapshot tier** | Instant per-tenant rollback points (~15 min RPO) for accidental-deletion recovery | Requires the ZFS dataset tier |
| **Web application firewall** | OWASP Core-Rule-Set inspection in front of your app | Opt-in; custom-built edge |
| **Hardened isolation** | Per-tenant rootless runtime or microVM boundary | Per contract |

---

## The pitch

> Flat monthly fee. No per-seat pricing. No transaction fees. Your data stays
> on infrastructure you can name, and you can take it with you at any time.

The differentiator is not the software; it is that we run hardened,
CIS-scanned images that we rebuild and re-scan automatically, and that we
answer the phone.

---

## Competitive comparison

### Shopify (the fee story)

Shopify UK pricing, verified October 2026:

| Plan | Monthly | Yearly | Card rate (Shopify Payments) | Third-party gateway fee |
| --- | --- | --- | --- | --- |
| Basic | £25 | £19/mo | 2% + 25p | 2% |
| Grow | £65 | £49/mo | 1.7% + 25p | 1% |
| Advanced | £344 | £259/mo | 1.5% + 25p | 0.6% |
| Plus | from £1,800 | - | 1.3% + 25p | 0.2% |

Also: Amex/international 3.1% + 25p, Klarna 4.99% + 30p, POS Pro £69/mo per
location.

**Why this matters:** Shopify's per-transaction fee is the reason a £5,000/month
business pays roughly £100–125/month in Basic before card interchange, rising
with every sale. On Advanced, the platform fee alone is £259–344/month. That is
the wedge for a self-hosted storefront: **a flat £20/month instead of a
percentage that grows with success.**

**Be honest about the trade:** we are not proposing to replace Shopify in the
pilot. Cart, payments, tax and PCI compliance are a different problem from
hosting, and the card fees you pay your payment provider remain either way. The
defensible version of this pitch is *"your application server costs £20/month
instead of 2–6% of turnover"*; not *"we process your card payments for free."*

### Storage and documents (the per-seat story)

| Vendor | Price | Notes |
| --- | --- | --- |
| Dropbox Business Standard | US$15/user/mo | 3TB team pool, 180-day restore, 3 user minimum |
| Dropbox Business Advanced | US$24/user/mo | 15TB, end-to-end encryption, SSO, compliance tracking |
| Google Workspace Business Starter | £5.90/user/mo (yearly) | 30GB/user, mail, Docs/Sheets/Slides, Meet |

A ten-person team on Dropbox Business Standard pays **US$150/month** (roughly
£118). The same ten people on a flat-fee tenant pay **£12/month** for the
service. That gap is the entire sales conversation.

### Where the incumbents are still better

State this in the pitch; a customer who finds it out later is a churned
customer and a bad review.

| Incumbent strength | Our gap |
| --- | --- |
| Email, collaborative docs, spreadsheets, video calls | We host a service, not an office suite |
| 99.9%+ contractual uptime, multi-region failover | Single host; backups mitigate data loss, not host loss |
| 24/7 staffed support, phone escalation | One operator, business hours |
| Regulatory attestations (SOC 2, ISO 27001, HIPAA BAA) | None held |
| Multi-region data residency | Single UK site |

---

## Positioning

Lead with these three, in order:

1. **Predictable cost.** A flat fee does not scale with your success. Show the
   Shopify comparison where the prospect already pays per-transaction fees.
2. **Exit is a file copy.** Full backup on demand, in a documented format.
   Contrast with proprietary formats and export fees.
3. **Someone actually maintains it.** Images are rebuilt nightly, scanned
   daily, and patched automatically; and there is a human who notices when
   that stops.

Do **not** lead with "we're cheaper". Lead with the cost curve, then price.

---

## Unit economics

Assumptions: one 16-core/128GB EPYC host, ~£5,000 capex, ~£100/month
colo/power/bandwidth, 25 paying tenants at an average £12/month.

| | Monthly |
| --- | --- |
| Revenue (25 × £12) | £300 |
| Host + power + bandwidth | −£100 |
| Gross margin | £200 (67%) |
| Payback on £5,000 capex | ~25 months |

**This is thinner than it looks and the pilot exists to fix that.** Three
realistic levers:

- **Price.** £12/month is priced for a hobby market. A business replacing
  £118/month of Dropbox will accept £40–60/month. Pilot at £12 to win three
  logos, then re-price at £30–40 once there are reference customers.
- **Density.** The `documents` template caps at 2GB RAM per tenant. Measured
  headroom supports more tenants per host than the pessimistic table in
  `ops/tenants/README.md` suggests.
- **Add-ons.** Storage and extra users are where the margin is; the base fee
  is a foot in the door.

**The real business is not the £12.** It is a managed-service relationship
where a customer asks for something custom (migration from Dropbox, an
integration, an on-prem install), and that work is quoted by the day. The
hosting fee keeps the lights on; the services are the profit.

---

## Pre-requisites before taking money

| # | Item | Why it blocks |
| --- | --- | --- |
| 1 | Pilot customers signed (LOI or paid invoice) | Validates demand before £5k capex |
| 2 | Ltd company registered | Contracts, invoicing, employment |
| 3 | ICO data-controller registration | We store personal data (names, emails, documents) |
| 4 | Professional indemnity + cyber insurance | A breach is our liability, not the customer's |
| 5 | Terms of service + acceptable use + SLA disclaimer | Sets the "best effort, no uptime guarantee" boundary |
| 6 | Business premises with non-CGNAT, static-IP broadband | No public ingress means no customer-facing service |
| 7 | Templates validated (`photos`) and auth wired (`files`) | Do not sell an unvalidated template |
| 8 | Off-site backup restore rehearsed per template | An untested backup is a claim, not a backup |

---

## FIPS decision note (from the engineering loop, iteration 5)

Context: Wolfi removed `openssl-provider-fips` from its public package
repo, so the EIR can no longer build honest OpenSSL-based FIPS images
(`nginx`, `postgres`, `redis`, `valkey`, `mysql`). The build job is
disabled fail-closed rather than shipping images that claim FIPS without
the provider. Two real options exist:

1. **Chainguard FIPS Images** (commercial): maintained, certified-path
   FIPS builds. Cost is per-image subscription; current list pricing is
   enterprise-tier (~£1k+/yr for the tiers covering our five variants).
   Selling implication: FIPS becomes a **premium add-on** only if a
   customer segment requires it (UK healthcare/finance/public-sector
   procurement asks for CSTA-certified crypto). At pilot pricing (£10–25)
   the subscription cannot be absorbed; it would need ~40–80 extra
   tenants per host or a dedicated FIPS tier at £60+/mo.
2. **openssl-hardened relabel** (free): Wolfi ships `openssl-hardened-*`
   (hardening flags, no certification). Honest and free, but it is NOT
   FIPS and must not be sold as such.

**Decision for now:** do neither. No pilot customer has asked for FIPS;
building for a requirement nobody has expressed adds a paid dependency
(1) or a marketing-liability (2). Revisit the moment a prospect's
procurement checklist mentions FIPS/CSTA; at that point it justifies a
dedicated tier price. The go-based FIPS variants (boringcrypto) remain
available and green; they cover Go-service FIPS needs already.

## Roadmap

| Phase | Content |
| --- | --- |
| **Pilot** | Documents + Files only. Manual invoicing. 3 customers. |
| **Validate** | Wire a real storefront or ERP tenant; publish honest measured numbers |
| **Own-stack** | Replace third-party images with our own Rust products (Ferro, Tachyon) once they are multi-tenant hardened; the durability moat is code we own, not containers we hardened |
| **Platform** | Customer dashboard (Astro + SolidJS), self-service onboarding, per-tenant usage metering via our own `billing-kit`/`ledger-kit` |
