# iOS Native Libraries

This directory contains the checked-in native Apple archives used by the iOS
app.

The checked-in `NdrFfi.xcframework` and `HashtreeFfi.xcframework` intentionally
ship only these slices:

- `ios-arm64`
- `ios-arm64-simulator`

Do not add `x86_64` simulator slices back. They make the repo much larger and
are not needed for Apple Silicon development.

## Building NdrFfi.xcframework

The iOS library must be built on macOS. Follow these steps:

### Prerequisites

1. macOS with Xcode installed
2. Rust with iOS targets:
   ```bash
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
   ```

### Build Steps

1. Clone the nostr-double-ratchet repository:
   ```bash
   git clone https://github.com/mmalmi/nostr-double-ratchet.git
   cd nostr-double-ratchet
   ```

2. Build arm64 device and simulator archives only:
   ```bash
   cd rust
   cargo build -p ndr-ffi --target aarch64-apple-ios --target aarch64-apple-ios-sim --release
   ```

3. Reassemble the XCFramework with the checked-in headers and an arm64-only
   simulator slice:
   ```bash
   IRIS_CHAT_FLUTTER=/path/to/iris-chat-flutter
   TMPDIR="$(mktemp -d)"
   cp rust/target/aarch64-apple-ios-sim/release/libndr_ffi.a "$TMPDIR/libndr_ffi_sim.a"
   xcodebuild -create-xcframework \
     -library rust/target/aarch64-apple-ios/release/libndr_ffi.a \
     -headers "$IRIS_CHAT_FLUTTER/ios/Frameworks/NdrFfi.xcframework/ios-arm64/Headers" \
     -library "$TMPDIR/libndr_ffi_sim.a" \
     -headers "$IRIS_CHAT_FLUTTER/ios/Frameworks/NdrFfi.xcframework/ios-arm64/Headers" \
     -output "$TMPDIR/NdrFfi.xcframework"
   rm -rf "$IRIS_CHAT_FLUTTER/ios/Frameworks/NdrFfi.xcframework"
   cp -R "$TMPDIR/NdrFfi.xcframework" "$IRIS_CHAT_FLUTTER/ios/Frameworks/"
   ```

4. Generate and copy the Swift bindings:
   ```bash
   cargo build -p ndr-ffi
   cargo run -p ndr-ffi --features uniffi/cli -- \
     generate --library rust/target/debug/libndr_ffi.dylib \
     --language swift \
     --out-dir "$TMPDIR/bindings"
   cp "$TMPDIR/bindings/ndr_ffi.swift" /path/to/iris-chat-flutter/ios/Runner/
   ```

5. Update the checked-in macOS host archive from the release build:
   ```bash
   cp rust/target/release/libndr_ffi.a /path/to/iris-chat-flutter/libndr_ffi.a
   ```

Do not copy `rust/target/debug/libndr_ffi.a` into `iris-chat-flutter`.
The debug archive is much larger and is only for local debugging.

### Xcode Integration

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select the Runner target
3. Go to General > Frameworks, Libraries, and Embedded Content
4. Click + and add the NdrFfi.xcframework
5. Set "Embed & Sign" for the framework

### Enable the Plugin

After adding the framework, edit `ios/Runner/NdrFfiPlugin.swift`:

```swift
// Change this line:
private let NDR_FFI_ENABLED = false
// To:
private let NDR_FFI_ENABLED = true
```

Then uncomment the UniFFI implementation blocks in each handler.

## Placeholder State

Until the native library is built and integrated, the app uses a placeholder
implementation that returns "NotImplemented" errors for all cryptographic
operations. The app will function on iOS but cannot perform actual encryption.
