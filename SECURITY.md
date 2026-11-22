# Security policy

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/cro13/ReMTP/security/advisories/new) for this repository. You'll get a reply
within a week, and we'll agree on a disclosure date once a fix is ready.

## Scope

ReMTP talks to USB devices and, only when you ask it to, pauses and restores macOS's `ptpcamerad`
service with `launchctl`. To switch a device's USB mode it uses ADB: through the local adb server when
one runs, otherwise directly over USB with its own key. Reports about these areas are especially welcome:

- reading or writing outside the folders a user chose (path traversal from device file names)
- leaving system services disabled after ReMTP quits or crashes
- the ADB key: ReMTP creates one RSA-2048 key ("ReMTP ADB key") in the login Keychain the first time it
  talks to a device's ADB interface directly over USB. It uses the key only to authenticate to the device
  (signing its challenge, or offering the public key for "Allow USB debugging?") and never exports the
  private key.
- ADB commands: ReMTP only sends the fixed shell commands `svc usb getFunctions`,
  `svc usb setFunctions mtp` and `svc usb setFunctions`. Anything that makes it send something else is
  in scope.
- tampered release artifacts (releases are signed and notarized; checksums are published with each release)

## Supported versions

Only the latest release gets security fixes.
