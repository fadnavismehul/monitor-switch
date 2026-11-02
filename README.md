# monitor-switch

A tiny macOS daemon that switches an external monitor's input source with a keyboard shortcut, using DDC/CI. One Swift file, no dependencies, no Accessibility permission needed.

| Shortcut | Input |
|---|---|
| Cmd + Page Up | HDMI 2 |
| Cmd + Page Down | DisplayPort 1 |

Useful when one monitor is shared between a Mac and another computer, and you want to flip between them from the keyboard.

## Requirements

- Apple Silicon Mac (it uses the private `IOAVService` API, as [m1ddc](https://github.com/waydabber/m1ddc) does)
- A monitor that supports DDC/CI input switching (VCP code `0x60`)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`

## Install

```sh
git clone https://github.com/fadnavismehul/monitor-switch.git
cd monitor-switch
./install.sh
```

This builds the binary and installs a LaunchAgent so it starts at login and restarts if it exits.

## Use from the command line

```sh
./monitor-switch 18     # HDMI 2 (waits ~15 s to verify the monitor stayed on it, see below)
./monitor-switch 15     # DisplayPort 1
./monitor-switch read   # print the monitor's current input value
```

Common DDC input values: DP1 = 15, DP2 = 16, HDMI1 = 17, HDMI2 = 18, USB-C = 27. Some monitors (e.g. LG) use different values.

## HDMI link recovery

The Mac is on HDMI 2 (value 18). After the Mac's display has slept, its HDMI link can come back
unusable: the system log shows `HDMIRX does not support scrambling` and an HDCP failure, the monitor
finds no signal on HDMI 2 and auto-switches back to the other input within about 20 seconds. The
hotkey then looks dead, because every switch to 18 is undone by the monitor.

So every switch to 18 (hotkey or CLI) is verified. About 15 seconds after the write the daemon reads
VCP `0x60` back. If the monitor reports another input, it runs one recovery:

1. write 18
2. `pmset displaysleepnow`, wait 4 s
3. `caffeinate -u -t 5` to wake the display, wait 3 s
4. write 18 again, wait 5 s, read `0x60` back and log the result

The sleep/wake forces macOS to set up the HDMI link again while the monitor is listening on HDMI 2.
At most one recovery runs per switch. A read-back that fails outright (no DDC reply) is logged and
does not trigger recovery. If you press Cmd+PageDown before the 15 seconds are up, the pending
check is dropped so it never pulls the monitor back from the other computer.

The input this Mac is plugged into is the `macInput` constant at the top of `main.swift`.

## Log

The daemon logs to `/tmp/monitor-switch.log` with a timestamp per line: the startup line, every
hotkey press and DDC write, each read-back value, and every recovery step. Output is line-buffered,
so `tail -f /tmp/monitor-switch.log` shows lines as they happen.

## Customize

Edit the `hotkeys` table and the `input*` constants at the top of `main.swift`, then run `./install.sh` again.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.monitor-switch
rm ~/Library/LaunchAgents/com.monitor-switch.plist
```

## Troubleshooting

- Check `/tmp/monitor-switch.log` (see Log above). `./monitor-switch read` shows what input the monitor thinks it is on.
- If a shortcut does nothing, another app (BetterDisplay, Lunar, etc.) may have registered the same key combination.
- The command is sent to every external display, so with several DDC-capable monitors attached they will all switch.

## License

MIT
