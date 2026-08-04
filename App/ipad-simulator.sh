#!/usr/bin/env bash
#
# Prints the UDID of an iPad simulator that `xcodebuild test` can run against,
# creating one if the machine has none.
#
# **Why this is not a name.** `make ios-test` and the `ios-tests` CI job used to
# hard-code `-destination 'platform=iOS Simulator,name=iPad (A16)'`. A concrete
# device is required — `xcodebuild test` refuses `generic/platform=iOS
# Simulator` — but a concrete *name* is a bet on the runner's image, and on
# 2026-08-04 that bet lost: GitHub rotated `macos-26`, `iPad (A16)` stopped
# existing, and every branch went red at once with an error that names the
# destination and not the cause. `main` had been green two days earlier on code
# nobody had touched since.
#
# So: ask the machine what it has. A UDID resolved at run time cannot go stale,
# and the same script serves the Makefile and CI, which is what stops the two
# from drifting apart.
#
# Honours `$SIM` as an override — a device name or a UDID — for when you want a
# particular iPad rather than any.
#
# On failure it prints everything it *did* find. A CI job that dies for want of
# a simulator should say which simulators exist, or diagnosing it costs a round
# trip per guess.
set -euo pipefail

# The iPad scheme's deployment target. A runtime older than this cannot run the
# app, and picking one would fail later and less clearly.
MINIMUM_IOS=26.0

python3 - "$MINIMUM_IOS" "${SIM:-}" <<'PY'
import json
import subprocess
import sys

minimum = tuple(int(part) for part in sys.argv[1].split("."))
requested = sys.argv[2].strip()


def simctl(*args):
    out = subprocess.run(
        ["xcrun", "simctl", *args, "--json"], capture_output=True, text=True, check=True
    )
    return json.loads(out.stdout)


def version(runtime_identifier):
    """`com.apple.CoreSimulator.SimRuntime.iOS-26-2` -> (26, 2)."""
    tail = runtime_identifier.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"):
        return None
    try:
        return tuple(int(part) for part in tail[len("iOS-"):].split("-"))
    except ValueError:
        return None


def fail(message, devices, runtimes):
    print(f"error: {message}", file=sys.stderr)
    print("available iOS simulator runtimes:", file=sys.stderr)
    for runtime in runtimes:
        print(f"  {runtime.get('identifier')}", file=sys.stderr)
    print("available simulators:", file=sys.stderr)
    for runtime, entries in devices.items():
        for device in entries:
            if device.get("isAvailable"):
                print(f"  [{runtime}] {device['name']} {device['udid']}", file=sys.stderr)
    sys.exit(1)


devices = simctl("list", "devices", "available")["devices"]
runtimes = [r for r in simctl("list", "runtimes")["runtimes"] if r.get("isAvailable")]

# An explicit request wins, by name or by UDID, so `SIM=` keeps working.
if requested:
    for entries in devices.values():
        for device in entries:
            if device.get("isAvailable") and requested in (device["name"], device["udid"]):
                print(device["udid"])
                sys.exit(0)
    fail(f"SIM={requested!r} matched no available simulator", devices, runtimes)

# Otherwise the newest iPad that is new enough to run the app.
candidates = []
for runtime, entries in devices.items():
    found = version(runtime)
    if found is None or found < minimum:
        continue
    for device in entries:
        if device.get("isAvailable") and "iPad" in device["name"]:
            candidates.append((found, device["name"], device["udid"]))

if candidates:
    print(max(candidates)[2])
    sys.exit(0)

# None exists — make one, rather than failing on an image that merely ships no
# iPads by default. Newest runtime, and any iPad device type it will accept.
usable = [
    r for r in runtimes
    if version(r.get("identifier", "")) and version(r["identifier"]) >= minimum
]
if not usable:
    fail("no installed iOS runtime is new enough", devices, runtimes)
newest = max(usable, key=lambda r: version(r["identifier"]))

types = [
    t for t in simctl("list", "devicetypes")["devicetypes"] if "iPad" in t.get("name", "")
]
supported = {t.get("identifier") for t in newest.get("supportedDeviceTypes", [])}
if supported:
    types = [t for t in types if t["identifier"] in supported] or types
if not types:
    fail("no iPad device type is available", devices, runtimes)

created = subprocess.run(
    ["xcrun", "simctl", "create", "Artscripture iPad", types[0]["identifier"],
     newest["identifier"]],
    capture_output=True, text=True,
)
if created.returncode != 0:
    fail(f"could not create a simulator: {created.stderr.strip()}", devices, runtimes)
print(created.stdout.strip())
PY
