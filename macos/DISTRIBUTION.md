# SharedMic macOS distribution (issue 19)

Personal-use distribution: a Mac build the owner can install without Xcode —
download, double-click, pair, no scary Gatekeeper block, login-launch working
from the installed location.

## Signing decision

| | Ad-hoc (`-`) | Developer ID Application |
|---|---|---|
| Build flag | `SHAREDMIC_SIGN_IDENTITY` unset (default) | `SHAREDMIC_SIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)"` + `SHAREDMIC_TEAM_ID` |
| Gatekeeper on another machine / fresh account | **Blocked.** Quarantined download gets "cannot be opened" / moved-to-trash flow; the owner must strip quarantine (`xattr -d com.apple.quarantine`) or right-click → Open. Documented, not fixed. | Passes Gatekeeper silently **once notarized and stapled** (below). |
| `SMAppService` login item | Registers, but the registration is tied to an ad-hoc identity: macOS may forget or refuse it after updates, and it never survives a move to another machine. Toggle works on the machine that built it; treat any failure as expected (the menu shows the error). | Stable. Registration is bound to Team ID + bundle ID and survives updates and moves within the same machine. |
| Keychain pairing store across updates | **Fragile.** Ad-hoc signatures have no Team ID, so the Keychain access group changes on every rebuild/re-sign. An update install typically **loses the pairing** and needs a re-pair. | **Preserved.** Same Team ID + same bundle ID + same `kSecAttrService` (`com.sharedmic.SharedMic.pairing`) means an update overwrites the app while the Keychain item stays put — no re-pair. |
| Hardened runtime | Xcode silently disables it for ad-hoc (`Disabling hardened runtime with ad-hoc codesigning`). | Enforced, with the entitlements below. |

**Recommendation for personal use:** Developer ID + notarization if the owner
has a paid Apple Developer membership; otherwise ad-hoc with the documented
quarantine workaround and re-pair-after-update. The build script supports both
from the same source; only the environment variables change.

What ad-hoc never affects: the protocol, the TLS pinning, or the audio path.
Signing is an envelope, not a behaviour change.

## Notarization + stapling (Developer ID only)

1. One-time setup: `xcrun notarytool store-credentials SharedMic --apple-id … --team-id …`.
2. Build: `SHAREDMIC_SIGN_IDENTITY="Developer ID Application: …" SHAREDMIC_TEAM_ID=… SHAREDMIC_NOTARIZE_PROFILE=SharedMic sh macos/scripts/build-distribution.sh`.
3. The script zips the app, submits with `--wait`, staples the ticket onto
   `SharedMic.app`, validates, then re-zips the **stapled** app for distribution.

Ad-hoc builds skip this entirely — Apple does not notarize ad-hoc signatures.

## Entitlements audit

`macos/SharedMic/SharedMic.entitlements` (wired via `CODE_SIGN_ENTITLEMENTS`
in `macos/project.rb`) requests exactly one entitlement:

- `com.apple.security.network.client = YES` — the app is a TLS **client** to
  the Windows agent (`Network.framework` `NWConnection`, TLS 1.3). No
  listening socket, so no `network.server`.

Deliberately **not** requested:

- No `com.apple.security.device.audio-input` / `microphone`: the app never
  captures. It **renders** to BlackHole and **observes** Core Audio device
  membership for demand detection — observation is not capture and prompts no
  consent dialog.
- No `com.apple.security.device.camera`, no speech recognition, no input
  monitoring.
- No Bonjour (`NSBonjourServices` / `NSLocalNetworkUsageDescription`): the
  Windows host is entered manually, so there is nothing to browse for. Plain
  outbound LAN TCP needs no extra entitlement beyond `network.client`.
- No App Sandbox: sandboxing would block the Core Audio device observation
  and BlackHole rendering this utility exists for. The app relies on the
  hardened runtime instead (enforced on Developer ID builds).
- No Keychain sharing (`keychain-access-groups`): the pairing store
  (`KeychainPairingStore`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  service `com.sharedmic.SharedMic.pairing`) uses the default per-Team-ID
  group, which is exactly what preserves the pairing across Developer ID
  updates and isolates ad-hoc builds from each other.

Verify what a build actually carries:

```sh
codesign -d --entitlements - /Applications/SharedMic.app
```

## Distribution format

**Zip** (`SharedMic-<version>.zip` containing `SharedMic.app`), built with
`ditto -c -k --keepParent` so resource forks, permissions, and the code
signature survive. No DMG: there is nothing to license, background-art, or
drag-target — a zip has fewer steps to get wrong, and
Troubleshooting-proof install is three lines (below). Notarization staples to
the `.app` before zipping, so the ticket travels inside the archive.

## Version stamping

Source of truth: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` at the top
of `macos/project.rb` (currently `0.1.0` / `1`). They flow into the build as
Xcode build settings; `macos/SharedMic/Info.plist` references them as
`$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` for
`CFBundleShortVersionString` / `CFBundleVersion`.

Where the version surfaces:

- Finder → Get Info and the "You have version …" update prompt.
- In-app: the menu-bar footer reads the stamped bundle back
  (`AppVersion.current()`), so the running build always reports what it was
  built with — the string to quote in bug reports.
- The distribution zip filename (`SharedMic-0.1.0.zip`).

Bump the version by editing the two constants in `macos/project.rb` and
re-running it; never hand-edit the `.xcodeproj`.

## Install (Mac side)

Prerequisites: macOS 14.4+, [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole),
same LAN as the Windows agent.

1. Unzip `SharedMic-<version>.zip`, drag `SharedMic.app` to `/Applications`.
   (Step zero for ad-hoc builds from another machine: if Gatekeeper refuses,
   run `xattr -d com.apple.quarantine /Applications/SharedMic.app` once —
   Developer ID + notarized builds never need this.)
2. Launch **from /Applications** (not from the Downloads disk image, not from
   Terminal) — the login-launch registration and the Keychain item both
   resolve to the app's on-disk location.
3. Open the menu-bar mic icon → enter the Windows host/IP, port, and the
   58-character pairing string from the Windows tray → Pair.
4. Start voice input in an app that opens BlackHole (e.g. Raycast): the menu
   shows demand, the byte counter leaves zero, audio flows. Stop input: the
   session ends after the 1 s debounce.
5. Optional: enable "Launch at login" in the menu. Verify it in System
   Settings → General → Login Items.

Updating: quit the app, replace `/Applications/SharedMic.app` with the new
one, relaunch. Developer ID builds keep the pairing; ad-hoc builds usually
need a re-pair (see table above).

## Fresh-account verification checklist (acceptance)

On a fresh macOS user account, with the artifact:

- [ ] Install per the steps above, launch with no Terminal.
- [ ] Gatekeeper behaviour matches the signing decision (silent for
      notarized Developer ID; documented quarantine flow for ad-hoc).
- [ ] Pair with the Windows agent; first demand streams.
- [ ] "Launch at login" toggle sticks, and the app actually launches after
      log-out/log-in from `/Applications`.
- [ ] Update install preserves the stored pairing (Developer ID expectation).
