# Image Signature Key Custody & Rotation Policy

**Status:** CURRENT (adopted 2026-11-03)
**Scope:** signatures on container images consumed by SIS tenant stacks —
produced by the EvergreenImageRegistry (EIR) build pipeline, enforced by
`ops/tenant-provision.sh` at the provisioning boundary.
**Consequence of violation:** an unsigned or untrusting deployment is a
fail-closed abort (`provisioning aborted`), never a warning.

---

## 1. The trust model, in one paragraph

A tenant host must be able to answer "may I run this byte sequence?"
without Kubernetes admission control. The industry answer for
compose-class hosts is nothing; ours is one command at one boundary:
`cosign verify` on every image the rendered stack references, before a
single byte is pulled. The signature binds the image digest to the
identity that produced it. Everything in this document follows from
choosing what that identity is.

## 2. Operative mode: keyless (default)

EIR's build workflow signs every pushed image with `cosign sign` under
GitHub Actions' workload identity (Fulcio OIDC certificate + Rekor
transparency log) since 2026-09-13. No long-lived key exists to hold.

**Trust anchor:** the certificate identity
`https://github.com/WyattAu/EvergreenImageRegistry/...` at issuer
`https://token.actions.githubusercontent.com`. Only that repository's
workflows can mint signatures a keyless-armed gate accepts.

**Arming:**

```bash
TENANT_COSIGN_IDENTITY='^https://github\.com/WyattAu/EvergreenImageRegistry/'
```

**Custody obligations in this mode** (they do not disappear, they move):

| Obligation | Practice |
|---|---|
| Rotation | Nothing to rotate: signing certificates live ~10 days. "Rotation" = the GitHub org's own credential hygiene (2FA on member accounts, least-privilege workflow tokens — the default `GITHUB_TOKEN` is already repo-scoped) |
| Revocation | An identity you no longer trust is removed by narrowing `TENANT_COSIGN_IDENTITY` — one env var, no ceremony. A leaked *workflow token* is bounded by its job lifetime and auditable in Rekor |
| Recovery | There is no secret to lose. Losing the Rekor log would matter; Rekor is Sigstore-operated public infrastructure with its own transparency guarantees |
| Verification online | Keyless verify consults the Fulcio chain/Rekor bundle — the tenant host needs egress. Accepted: tenant hosts already pull images over egress |

**Residual risk accepted:** trust in Sigstore public infrastructure
(Fulcio/Rekor) and in the GitHub org's membership. Both are the same
trust the estate already places in GitHub for its source of record.

## 3. Alternative mode: static key (documented, not armed)

Arm `TENANT_COSIGN_KEY` only when a deployment must verify **offline**
(no Rekor/Fulcio egress) or a contract requires a long-lived key. From
the moment of arming, this ceremony applies:

### 3.1 Generation

- `cosign generate-key-pair` on an **offline, air-gapped machine**; pass
  phrase via `COSIGN_PASSWORD` from the operator vault, never on a
  command line or in shell history.
- Entropy source is the OS CSPRNG; no key reuse across environments
  (production and staging never share a key pair).

### 3.2 Storage

- Private key: SOPS-encrypted in the operator vault (age to the operator
  key), **plus** one offline copy on removable media in a second physical
  location. Never on a CI runner, never in a repo, never in dotfiles.
- Public key: committed to this repo (`.docs/cosign.pub` or SOPS
  contract), so the trust anchor is itself version-controlled and
  diff-auditable.

### 3.3 Rotation (scheduled: annual; event-driven: suspected compromise, operator personnel change)

1. Generate the new pair offline (3.1).
2. Commit the new public key with a signed commit referencing the
   incident/change record; update the arming env on hosts **before**
   signing anything with the new key.
3. Re-sign currently deployed images under the new key (`cosign sign
   --key` over the running tag set) so no host is ever forced to choose
   between "stale signature" and "gate disabled".
4. Overwrite and destroy the old private key material; the old public
   key remains in git history for verifying images signed during the
   transition window.
5. Record the rotation in `.docs/engineering-loop.md`.

**Trust window rule:** at no moment is the gate disabled to accommodate
a rotation. Two keys verify during the window if necessary
(`--key new --key old` in sequence), never zero.

### 3.4 Revocation & incident response

- A compromised private key is revoked by **narrowing trust**, not by
  deleting: flip the arming env to the new key (or to keyless mode)
  first, then rotate. The gate stays fail-closed throughout.
- Images signed by the compromised key after the incident timestamp are
  treated as unsigned: re-provision, do not patch in place.

### 3.5 Recovery test

The offline copy is restore-tested **annually**: decrypt on the air-gapped
machine, verify a known image, shred the working copy. An untested backup
is a rumor, not a recovery.

## 4. Producer ↔ consumer contract (the defect this closes)

Discovered 2026-11-03 while writing this document: EIR signs **keyless**;
`tenant-provision.sh` verified with `--key`. An armed gate in that state
would have rejected **every** EIR image — the loop could never have
fired. The gate now accepts exactly one arming mode
(`TENANT_COSIGN_IDENTITY` **xor** `TENANT_COSIGN_KEY`) and verifies with
the matching method. Rule going forward: **any change to the producer's
signing mode must ship with the consumer gate change in the same
commit**, verified by provisioning a scratch stack before it ships to a
tenant.

## 5. Decision memo: estate images in the EIR build matrix (backlog #21)

The cosign loop's last open link is an estate image signed by EIR.
authbox's source is **private**; EIR is **public**. Options:

| Option | Mechanism | Trade-off |
|---|---|---|
| A. Build privately, sign in EIR | authbox CI builds/pushes the image; EIR's sign step signs the pushed ref | no source exposure; two pipelines to keep in sync |
| B. Token-scoped checkout in EIR | EIR checks out authbox with a fine-grained read-only PAT (secret) | single pipeline; a secret in a public repo's CI (scoped, revocable); source stays private |
| C. Publish authbox | open-source the control plane | simplest; changes the product's exposure — a business call, not an engineering one |

**Recommendation:** Option A — the signing identity is what tenants
trust, not where the source lives, and Option A keeps the private/public
boundary exactly where it is. Requires the GitHub Actions billing fix
first: authbox cannot build anything until its CI can run.
