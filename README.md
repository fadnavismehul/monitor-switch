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
./monitor-switch 18   # HDMI 2
./monitor-switch 15   # DisplayPort 1
```

Common DDC input values: DP1 = 15, DP2 = 16, HDMI1 = 17, HDMI2 = 18, USB-C = 27. Some monitors (e.g. LG) use different values.

## Customize

Edit the `hotkeys` table and the `input*` constants at the top of `main.swift`, then run `./install.sh` again.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.monitor-switch
rm ~/Library/LaunchAgents/com.monitor-switch.plist
```

## Troubleshooting

- Check `/tmp/monitor-switch.log`.
- If a shortcut does nothing, another app (BetterDisplay, Lunar, etc.) may have registered the same key combination.
- The command is sent to every external display, so with several DDC-capable monitors attached they will all switch.

## License

MIT
