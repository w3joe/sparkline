# GB10 Power Monitor – acceptance checklist

Build, test and install with full Xcode 27 (the Makefile sets `DEVELOPER_DIR`; `xcode-select` is untouched):

```sh
make bootstrap   # once: rustup + xcodegen
make test        # Rust helper tests + PowerCore Swift tests
make install     # Release build copied to /Applications
make run-sim     # fake plugs and fake SSH, separate config and history
```

`build/Build/Products/Release/gb10ctl status | on <a|b> | shutdown <a|b>` talks to the running
app through the same App Group command path as the widgets.

## Verified on this Mac (2026-10-11)

| Check | How | Result |
| --- | --- | --- |
| Rust helper protocol, error kinds | `make test-helper` (10 tests) | Pass |
| Shutdown never cuts power on SSH failure, host-key/preflight failure, timeout, high watts, open SSH, read errors, late confirmation | `make test-core` (55 tests) | Pass |
| Minute rollups, gaps, 7D/30D weighting, 24 h raw and 30-day retention with 31 days of data | `make test-core` | Pass |
| Command bus: expiry, withdraw vs claim, app-not-running, rejection | `make test-core` | Pass |
| Helper bridge: independent plugs, unreachable, wrong password, helper restart | `make test-core` against `tapo-helper --simulate` | Pass |
| Full shutdown in simulation: SSH accepted, outlet off ~30 s after draw fell and SSH closed | `gb10ctl shutdown a` | Pass |
| SSH failure in simulation leaves outlet on and reports why | sim host `spark-a-fail.sim` | Pass |
| Unreachable plug backs off (10/20/40 s) while the other keeps 10 s readings | sim plug IP `unreachable-b` | Pass |
| Widget path: command accepted while running; second command rejected while busy | `gb10ctl` | Pass |
| App not running: error after 5 s, command withdrawn and not run on relaunch | `gb10ctl` with app quit, then relaunch | Pass |
| Signed bundle (app, widget, helper) with team FZ26Z8W5FZ, hardened runtime, App Group | `codesign --verify --deep --strict` | Pass |
| Installed to /Applications, login item registered and enabled | `sfltool dumpbtm` | Pass |

## Needs the real hardware

- [ ] Settings → Tapo: save account, both plugs show model/firmware. Third-Party Compatibility on in the Tapo app.
- [ ] Switch each P110 on/off independently from the menu and dashboard.
- [ ] Wrong password: "Tapo login rejected", polling pauses, Retry resumes after fixing.
- [ ] Wrong or unplugged plug IP: "Plug unreachable" for that Spark only.
- [ ] Per Spark: create key, scan and compare host fingerprint, run the Spark commands, Test SSH access succeeds.
- [ ] Shut the Spark down by hand once, then "Use as powered-down level" to calibrate the threshold.
- [ ] Shut down: outlet switches off only after the draw falls and SSH closes for 30 s.
- [ ] Remove the authorized_keys line: Shut down fails, outlet stays on.
- [ ] Set the timeout to 20 s: Shut down times out, outlet stays on (restore 300 s after).
- [ ] On: outlet on, Spark boots, status goes Starting → Running.
- [ ] Add small and medium widgets (Spark A, Spark B, Both); On and two-tap Shut down work; "Updated HH:MM" shown; after quitting the app an action shows "isn't running".
- [ ] Log out and back in: app relaunches and keeps monitoring.
- [ ] Turn Wi-Fi off for 2 minutes and back on: readings resume, the 1H chart shows a gap.
