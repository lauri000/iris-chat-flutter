# Iris Chat

End-to-end encrypted mobile chat app using the Nostr Double Ratchet protocol.

## Features

- **End-to-end encryption** - Messages encrypted using Double Ratchet (Signal protocol)
- **Decentralized** - Uses Nostr relays, no central server
- **Offline support** - Messages queued when offline, sent when connected
- **QR code invites** - Easy contact sharing via QR codes or links
- **Cross-platform** - Android and iOS

## Architecture

- **Flutter** with Riverpod for state management
- **Rust** native library (ndr-ffi) for cryptography via FFI
- **SQLite** for local message storage
- **Secure storage** for private keys

## Building

### Prerequisites

- Flutter 3.24+
- For Android: Android SDK
- For iOS: macOS with Xcode

### Android

```bash
flutter build apk --release
```

### iOS

1. Build the native library on macOS (see `ios/Frameworks/README.md`)
2. Run:
```bash
flutter build ios --release
```

### Native FFI Artifacts

`iris-chat-flutter` checks in a host macOS static library at
`libndr_ffi.a` for native macOS test/build use. Do not copy the debug Rust
artifact into this repo.

Use the release archive from `nostr-double-ratchet`:

```bash
cd ~/src/nostr-double-ratchet/rust
cargo build -p ndr-ffi --release
cp target/release/libndr_ffi.a ~/src/iris-chat-flutter/libndr_ffi.a
```

The debug archive in `target/debug/libndr_ffi.a` is much larger because it
includes debug symbols and should not be committed.

## GitHub Release Signing (Optional)

The release workflow auto-detects signing configuration from GitHub Actions secrets.
If all required secrets for a platform are present, signing is enabled. If none are
present, unsigned artifacts are built. Partial secret setup fails the workflow.

Required macOS signing secrets:

- `MACOS_SIGNING_IDENTITY` (for example: `Developer ID Application: Example Corp (TEAMID)`)
- `MACOS_CERTIFICATE_P12` (base64-encoded `.p12` that includes private key)
- `MACOS_CERTIFICATE_PASSWORD`

Optional macOS notarization secrets (enable notarization when all are set):

- `MACOS_NOTARIZE_APPLE_ID`
- `MACOS_NOTARIZE_APP_PASSWORD` (app-specific password)
- `MACOS_NOTARIZE_TEAM_ID`

Required Android signing secrets:

- `ANDROID_KEYSTORE_B64` (base64-encoded `.jks`/`.keystore`)
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

## Development

```bash
# Install dependencies
flutter pub get

# Run code generation (freezed, riverpod)
dart run build_runner build

# Run tests
flutter test

# Check the committed macOS FFI artifact guard
flutter test test/unit/macos/ndr_ffi_artifact_test.dart

# Run analyzer
flutter analyze
```

## Project Structure

```
lib/
├── config/          # Providers, router, theme
├── core/            # FFI bindings, services
├── features/        # Feature modules
│   ├── auth/        # Identity management
│   ├── chat/        # Messaging
│   ├── invite/      # QR invites
│   └── settings/    # App settings
└── shared/          # Common utilities
```

## License

MIT
