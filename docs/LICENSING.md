# Licensing

**Not legal advice.** This is the working understanding the project is built on, written down so
the code and the build system can be arranged around it deliberately rather than by accident.
Take it to a lawyer before you charge anyone money.

## The short version

Artscripture's own code is one thing. The time-stretching library it links is another, and **which
one it links decides what the resulting binary may be distributed under.**

| Build | Stretcher | The binary may be distributed as |
|---|---|---|
| macOS today | Rubber Band (+ Signalsmith, unused) | **GPLv3 only** — no App Store, no proprietary terms |
| iPad / iOS today | Signalsmith Stretch (MIT) | **anything**, including the App Store and paid |

That second row used to read "none (`IdentityStretcher`) — cannot change speed, so it is not a
product". It is now real, and that is the single most important change to this document: the
permissive path is no longer a goal to be argued for, it is a shipping artefact. The iPad build
was checked on the binary, not inferred from the build files — 640 Signalsmith symbols present,
zero matching "rubberband".

**And the quality objection did not survive contact with measurement.** The worry was that
choosing the free backend meant choosing the worse one, which would make any edition split
awkward to defend. Measured with the same FFT estimator that bounds Rubber Band
(`signalsmithPreservesPitch`), across 220-880 Hz at both half and double speed, Signalsmith's
pitch error is within **0.05 cents** — and identical at both ratios, which means the number
being reported is the estimator's own floor rather than anything the stretcher did. That is
Rubber Band R3 "Finer" territory (~0.00 cents), not R2 "Faster" (up to -26 cents over the same
sweep, -108 at the extremes).

Two things follow. Signalsmith is not a compromise backend, so an edition that ships only it is
not a degraded edition. And Rubber Band's commercial licence becomes a choice about preference
and risk rather than about capability.

## Why linking is the whole question

Rubber Band is published by Particular Programs Ltd under a **dual licence**: GPLv2-or-later,
or a commercial licence bought from them. There is no third option, and Breakfast Quay say
plainly that GPL code cannot legally be distributed on the iOS or macOS App Stores — the store
terms impose usage and DRM restrictions the GPL forbids passing on. This is the same wall VLC
hit.

The GPL's reach is over the **combined work at the moment it is distributed**, not over a
repository. Artscripture's own source is not *derived* from Rubber Band; it calls it. So:

- ship a binary with Rubber Band inside → that binary is a combined work → GPLv3 terms
- ship a binary with only Signalsmith inside → no GPL code is present → our terms

That is why `PlatformStretcher` matters beyond portability. It is the seam that decides which
of those two things is being built, and `CRubberBand` is already a `.when(platforms: [.macOS])`
dependency behind `#if canImport(CRubberBand)`, so a build genuinely can exclude it rather than
merely not calling it.

## What Artscripture's own code is licensed as

The repository was GPLv3 until v0.2.0, which was the correct and honest choice while Rubber Band
was the only backend — the combined work had to be GPL, so labelling the whole thing GPL was
accurate.

It is **Apache-2.0 as of PR #18**, and a permissively-licensed backend now exists, so the plan
below is no longer a recommendation but a description of where things stand:

1. ~~Relicense Artscripture's own code permissively — Apache-2.0.~~ **Done.** Preferred over MIT
   for its explicit patent grant, which is worth having in audio DSP, a field with a long
   history of patented algorithms.
2. **Keep Rubber Band's GPL obligations attached to the builds that link it**, stated in the
   README and in the release notes for those artefacts, not applied to the source tree as a
   whole. Done in `NOTICE`, which carries the per-build column.
3. ~~Ship the App Store / paid build with Signalsmith only.~~ **Possible now.** The iPad build
   already is exactly that. What remains is a decision, not an engineering task.

Two caveats worth knowing before doing this:

- **Relicensing needs every copyright holder's agreement.** If the code is entirely yours (and
  work you commissioned or generated counts as yours), this is a decision, not a negotiation.
  It stops being simple the moment there is an outside contributor, so it is much cheaper to do
  *before* accepting pull requests than after.
- **You cannot un-license what is already out.** `v0.1.0` and `v0.2.0` were released GPLv3 with
  Rubber Band embedded; those stay GPLv3 forever, and anyone who has them keeps those rights.
  That is fine — relicensing applies going forward.

## The third option, if Rubber Band's quality proves irreplaceable

Buy a commercial licence from Particular Programs: a one-time fee, perpetual, no royalties,
covering unlimited applications on any platform. **Pricing is published** — an earlier draft of
this document said it was not, which was wrong — and the attribution tier is the relevant one
for a solo developer.

That is the route if the A/B hearing tests come out decisively for Rubber Band and the App Store
still matters. On the measurements now in hand it is a preference rather than a necessity, since
the free backend holds pitch to the same order of accuracy.

## How the repository should express all this

- `LICENSE` — the project's own terms.
- `LICENSES/` — the full text of every third-party licence that can end up in a build:
  `GPL-3.0.txt`, `MIT-signalsmith-stretch.txt`, `MIT-signalsmith-linear.txt`. Note that
  Signalsmith is **two** MIT libraries from two repositories, not one.
- `NOTICE` — what is linked, under what, and **in which builds**. (Named `NOTICE` rather than
  `THIRD-PARTY.md` as this section once proposed, because that is the file Apache-2.0 itself
  gives a meaning to.) The per-build column is the part that is easy to omit and is exactly the
  part that matters.
- `Sources/CSignalsmithStretch/VENDOR.md` — provenance and versions for the vendored source,
  since a copied library has no package manifest to read them off.
- The release workflow should state the terms of the artefact it produces, because a macOS
  build and an App Store build will not share them.

`App/embed-dependencies.sh` already copies licence files into the bundle's `Resources`, which
is the GPL's "you must give the recipient the licence" obligation being met — keep that working
for whichever libraries a given build actually contains.

## Sources

- [Rubber Band — licensing for open source applications](https://breakfastquay.com/rubberband/license.html)
- [Rubber Band Library](https://breakfastquay.com/rubberband/)
- [Signalsmith Stretch (MIT)](https://github.com/Signalsmith-Audio/signalsmith-stretch)
