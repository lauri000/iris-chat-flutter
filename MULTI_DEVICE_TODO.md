## Multi-device protocol TODO

- [x] Move bare-pubkey/public-invite bootstrap toward `nostr-double-ratchet` by exposing `SessionManager.setup_user` through `ndr-ffi`.
- [x] Add core coverage that an existing peer learns a newly added device from AppKeys + invite and fans messages out to both devices.
- [x] Refactor Flutter bare-pubkey bootstrap to use manager-driven setup/wait instead of manual AppKeys + device-invite polling.
- [x] Re-arm peer AppKeys/device-invite tracking for stored sessions during Flutter bootstrap.
- [ ] Reproduce and verify the original `iris-chat-flutter` "import existing nsec on new device, then receive messages" report with a focused end-to-end test.
- [ ] Decide whether to move Flutter's group outer-event subscription glue into `ndr-ffi` as well.
- [ ] Revisit the earlier `iris-chat` link-invite acceptance patch and either test/keep it or replace it with a cleaner shared path.
