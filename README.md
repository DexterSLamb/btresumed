# btresumed

> Event-driven macOS daemon that auto-recovers BLE mouse/keyboard reconnection after sleep.
>
> [中文说明](README.zh-CN.md)

## The problem

On macOS (Sonoma, Sequoia; also real Macs), some BLE peripherals — particularly those using **LE Privacy (RPA)** like Microsoft Modern Mobile Mouse, Logitech MX Master, Logitech MX Keys, various Framework laptop internal BT mice — **fail to auto-reconnect after system sleep**.

Symptoms:

- Wake the Mac → mouse cursor frozen, keyboard unresponsive
- System Settings shows the device "Not Connected"
- Manually toggling **Bluetooth off then on** reconnects the device instantly
- `bluetoothd` log contains `reason 762`, `encryption STATUS 634`, or `MIC failure (HCI 0x3D)`
- Same device works flawlessly on Windows / Linux / ChromeOS of the same machine

This is a known macOS BLE stack issue. Apple has not fixed it for third-party BLE peripherals. The workaround everyone uses is a manual BT toggle.

## What btresumed does

A small native daemon that watches connected BLE peripherals via CoreBluetooth and **automates the exact manual toggle** — but only when needed:

1. Peripheral disconnects → wait **5 seconds** (natural reconnect window)
2. Still disconnected? Is it a **HID-type device** (mouse/keyboard)? Is Bluetooth still powered on by the user?
3. If all yes: call `IOBluetoothPreferenceSetControllerPowerState(0)` then `(1)` — the same private SPI that the System Settings BT toggle uses
4. Device reconnects automatically

Design principles:

- **Event-driven, not timer-driven**: reacts to actual BLE disconnect/connect events, not to wake notifications. Rapid lid-close/open cycles, short sleeps, etc., don't cause unnecessary toggles.
- **No shell scripts, no third-party dependencies**: pure native Objective-C using only Apple system frameworks.
- **Preserves pairing keys**: uses only the power-toggle SPI. Pairing records untouched — safe for dual-boot / multi-boot systems where the same pairing keys are shared across OSes.
- **Respects user intent**: if the user manually disables Bluetooth, the daemon does nothing.

## Is this for you?

**Yes, if**:

- You have a BLE mouse / keyboard / trackpad that doesn't reconnect after sleep on macOS
- You've verified manual BT toggle fixes it
- You want a set-and-forget solution

**No, if**:

- Your device works fine after sleep already
- You're on macOS versions older than Big Sur (CoreBluetooth APIs may differ)
- You're in a managed enterprise environment where background LaunchAgents aren't allowed

## Compatibility

- **Tested**: macOS 14 (Sonoma) — Intel Hackintosh (Comet Lake + Intel AX201 BT). Should work on any Mac or Hackintosh running Sonoma or newer.
- **Device tested**: Microsoft Modern Mobile Mouse
- **Should work for**: any BLE HID device where manual BT toggle restores connection

## Installation

### Prerequisites

- macOS 14+ (Sonoma or Sequoia recommended)
- Xcode Command Line Tools (`xcode-select --install`)
- Admin access (to install LaunchAgent)

### One-shot install

```bash
git clone https://github.com/DexterSLamb/btresumed.git
cd btresumed
sudo ./install.sh
```

Then:
1. macOS will pop up a dialog: **"btresumed" wants to use Bluetooth** → click **Allow**.
2. You may see another prompt in **System Settings → General → Login Items & Extensions** under "Allow in the Background" — toggle it on.

That's it. Next time you wake from sleep and the mouse is stuck, the daemon will quietly toggle BT after 5 seconds and your mouse will reconnect.

### Manual install

```bash
make
sudo make install
```

### Verify

```bash
launchctl print gui/$(id -u)/com.user.btresumed
tail -f /tmp/btresumed.log
```

Expected log on healthy startup:

```
btresumed starting (pid=...)
CBCentralManager created, waiting for state update...
CB state: PoweredOn
found 1 connected BLE peripheral(s)
adopt: ... (Modern Mobile Mouse) state=0
connect: ... (Modern Mobile Mouse)
classified HID-like: ... (Modern Mobile Mouse)
```

## How it works (architecture)

```
┌─────────────────┐       ┌──────────────────┐      ┌─────────────────────────┐
│ CBCentralManager│──────▶│ BTResumed daemon │─────▶│ IOBluetoothPreference   │
│  (BLE events)   │       │                  │      │ SetControllerPowerState │
└─────────────────┘       │  • classify HID  │      │  (System Settings' SPI) │
                          │  • debounce      │      └─────────────────────────┘
                          │  • pending check │
                          └──────────────────┘
```

Key implementation details:

- **Discovery**: `retrieveConnectedPeripheralsWithServices:` with GAP (0x1800) to enumerate all currently connected BLE peripherals (GAP is mandatory on every BLE device).
- **HID classification**: Apple's CoreBluetooth hides the standard HID service (0x1812) from third-party CB clients for privacy. The daemon falls back to a **peripheral name heuristic** (matches keywords: `mouse`, `keyboard`, `trackpad`, `magic`, `mx`, `k380`, …). Adjust `nameLooksLikeHID()` in the source if your device has an unusual name.
- **Disconnect handling**: `didDisconnectPeripheral:` sets a timestamp ticket in `_pending[peripheral.identifier]`. A `dispatch_after` 5s later checks if the peripheral reconnected (ticket cleared by `didConnectPeripheral:`) — if not, evaluate and toggle.
- **Debounce**: 10-second minimum gap between toggles prevents loops if a peripheral is truly dead (e.g., dead battery).
- **BT power intent**: if the user has BT off (`IOBluetoothPreferenceGetControllerPowerState() == 0`), the daemon stays silent.
- **PoweredOff→PoweredOn transitions**: clears stale pending checks (they're artifacts of BT being toggled off, not real failures).
- **Periodic rescan**: every 60 seconds, re-query `retrieveConnectedPeripheralsWithServices:` to adopt newly paired devices without requiring a daemon restart.

## Logs

All daemon activity is logged to `/tmp/btresumed.log`:

```
[timestamp] disconnect: <uuid> (Mouse) err=(no error), check in 5s
[timestamp+5s] check: ... still disconnected → toggle BT
[timestamp+5s] toggle complete
```

Or, on natural recovery:

```
[timestamp] disconnect: <uuid> (Mouse) ...
[timestamp+2s] connect: <uuid> (Mouse)
[timestamp+2s]   pending check canceled (natural recovery)
```

## Troubleshooting

**Daemon started but nothing happens on wake**

Check `/tmp/btresumed.log`. If you see `CB state: Unauthorized` — grant Bluetooth permission in System Settings → Privacy & Security → Bluetooth.

**Peripheral classified `non-HID` but it is a HID device**

The name heuristic didn't match. Edit `nameLooksLikeHID()` in `btresumed.m`, add your device's name or a distinguishing substring, and rebuild.

**Daemon gets killed or exits**

`tail -n 50 /tmp/btresumed.log` — look for error lines. `launchctl print gui/$(id -u)/com.user.btresumed` shows its runtime state.

**Toggle fires but mouse still doesn't reconnect**

- Check battery: dead mice can't reconnect no matter how many times BT toggles.
- Re-pair the device (as a last resort). This changes pairing keys, so multi-boot shared-key setups need to re-sync.

**I rebuilt the binary and TCC keeps asking for permission**

Unsigned binaries change their content hash on every rebuild, which invalidates TCC. Either stop rebuilding, or ad-hoc sign with a stable identifier: `codesign --force --sign - --identifier com.user.btresumed btresumed` (note: ad-hoc signing does NOT remove the "unidentified developer" warning, but it stabilizes cdhash for TCC).

## Limitations

- **Requires Bluetooth permission (TCC)**: LaunchAgent runs in user session, CoreBluetooth needs the standard Privacy & Security → Bluetooth permission. One-click approval on first run.
- **Not code-signed**: built from source, shows as "unidentified developer" in Login Items. Functionally harmless. Removing this requires a paid Apple Developer ID.
- **HID classification by name heuristic**: covers common vendors (Microsoft, Apple, Logitech, Razer, etc.) but may miss obscure devices with unusual names.
- **CoreBluetooth hides HID service**: we cannot use service UUID 0x1812 for classification because Apple restricts it from third-party CB clients.
- **macOS only**: uses Apple-specific IOBluetooth SPI.

## Related work

- [Bluesnooze](https://github.com/odlp/bluesnooze) — similar idea, unconditional toggle (no event filtering, no HID classification)
- [blueutil](https://github.com/toy/blueutil) — CLI Bluetooth utility, often used with SleepWatcher scripts
- [OpenIntelWireless/IntelBluetoothFirmware](https://github.com/OpenIntelWireless/IntelBluetoothFirmware) — kext for Intel AX2xx BT on Hackintosh (btresumed is a userspace complement, not a replacement)

## License

MIT. See [LICENSE](LICENSE).

## Contributing

PRs welcome — especially:

- Additional device name keywords for HID classification
- Testing on different macOS versions
- Testing with different BLE peripherals
