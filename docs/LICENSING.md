# Licensing

**Not legal advice.** This is the working understanding the project is built on, written down so
the code and the build system can be arranged around it deliberately rather than by accident.
Take it to a lawyer before you charge anyone money.

## The short version

Artscribe's own code is one thing. The time-stretching library it links is another, and **which
one it links decides what the resulting binary may be distributed under.**

| Build | Stretcher | The binary may be distributed as |
|---|---|---|
| macOS today | Rubber Band | **GPLv3 only** — no App Store, no proprietary terms |
| iPad today | none (`IdentityStretcher`) | anything — but it cannot change speed, so it is not a product |
| the goal | Signalsmith Stretch (MIT) | **anything**, including the App Store and paid |

## Why linking is the whole question

Rubber Band is published by Particular Programs Ltd under a **dual licence**: GPLv2-or-later,
or a commercial licence bought from them. There is no third option, and Breakfast Quay say
plainly that GPL code cannot legally be distributed on the iOS or macOS App Stores — the store
terms impose usage and DRM restrictions the GPL forbids passing on. This is the same wall VLC
hit.

The GPL's reach is over the **combined work at the moment it is distributed**, not over a
repository. Artscribe's own source is not *derived* from Rubber Band; it calls it. So:

- ship a binary with Rubber Band inside → that binary is a combined work → GPLv3 terms
- ship a binary with only Signalsmith inside → no GPL code is present → our terms

That is why `PlatformStretcher` matters beyond portability. It is the seam that decides which
of those two things is being built, and `CRubberBand` is already a `.when(platforms: [.macOS])`
dependency behind `#if canImport(CRubberBand)`, so a build genuinely can exclude it rather than
merely not calling it.

## What Artscribe's own code should be licensed as

The repository is **GPLv3 today**, which was the correct and honest choice while Rubber Band
was the only backend — the combined work had to be GPL, so labelling the whole thing GPL was
accurate.

Once a permissively-licensed backend exists, that choice becomes a *constraint we are imposing
on ourselves* rather than one Rubber Band imposes. The recommendation is therefore:

1. **Relicense Artscribe's own code permissively — Apache-2.0.** Preferred over MIT here for its
   explicit patent grant, which is worth having in audio DSP, a field with a long history of
   patented algorithms.
2. **Keep Rubber Band's GPL obligations attached to the builds that link it**, stated in the
   README and in the release notes for those artefacts, not applied to the source tree as a
   whole.
3. Ship the App Store / paid build with Signalsmith only.

Two caveats worth knowing before doing this:

- **Relicensing needs every copyright holder's agreement.** If the code is entirely yours (and
  work you commissioned or generated counts as yours), this is a decision, not a negotiation.
  It stops being simple the moment there is an outside contributor, so it is much cheaper to do
  *before* accepting pull requests than after.
- **You cannot un-license what is already out.** `v0.1.0` and `v0.2.0` were released GPLv3 with
  Rubber Band embedded; those stay GPLv3 forever, and anyone who has them keeps those rights.
  That is fine — relicensing applies going forward.

## The third option, if Rubber Band's quality proves irreplaceable

Buy a commercial licence from Particular Programs. That is the route if the A/B hearing tests
come out decisively for Rubber Band and the App Store still matters. Pricing is not published;
it is a conversation with them. Worth knowing this exists so the choice is quality-versus-cost
rather than quality-versus-impossible.

## How the repository should express all this

- `LICENSE` — the project's own terms.
- `LICENSES/` — the full text of every third-party licence that can end up in a build
  (`rubberband-GPLv2`, `signalsmith-MIT`).
- `THIRD-PARTY.md` — what is linked, under what, and **in which builds**. The per-build column
  is the part that is easy to omit and is exactly the part that matters.
- The release workflow should state the terms of the artefact it produces, because a macOS
  build and an App Store build will not share them.

`App/embed-dependencies.sh` already copies licence files into the bundle's `Resources`, which
is the GPL's "you must give the recipient the licence" obligation being met — keep that working
for whichever libraries a given build actually contains.

## Sources

- [Rubber Band — licensing for open source applications](https://breakfastquay.com/rubberband/license.html)
- [Rubber Band Library](https://breakfastquay.com/rubberband/)
- [Signalsmith Stretch (MIT)](https://github.com/Signalsmith-Audio/signalsmith-stretch)
