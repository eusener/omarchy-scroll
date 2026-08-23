# Scroll

An Omarchy shell panel for mouse and trackpad scrolling: speed, direction,
scroll method, and discrete-scroll emulation.

Built entirely from the shell's own `qs.Ui` kit, so it follows the active
Omarchy theme, font, and spacing with no styling of its own.

![panel](docs/panel.png)

## Install

```bash
omarchy plugin add https://github.com/eusener/omarchy-scroll.git --enable
```

Third-party plugins are disabled on arrival; `--enable` handles that, or run
`omarchy plugin enable eusener.scroll` later.

Open it with:

```bash
omarchy-shell shell summon eusener.scroll
```

## Two optional steps the plugin cannot do for you

A plugin is only ever cloned into place — nothing it ships is executed at
install time, and it cannot write to your Hyprland or menu config. Both of
these are worth doing by hand.

### 1. Stop the window from tiling

Quickshell's `FloatingWindow` is an ordinary toplevel as far as Hyprland is
concerned, so without a rule it tiles. Add to `~/.config/hypr/hyprland.lua`:

```lua
o.window(
  { class = "^org\\.quickshell$", title = "^Scroll settings$" },
  { float = true, center = true, size = { 560, 740 } }
)
```

The title is matched alongside the class so the rule leaves every other
Quickshell window alone.

### 2. Add it to the Omarchy menu

In `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"setup.scroll": {"icon":"󰍽","label":"Scroll","description":"Mouse and trackpad scroll speed and direction","action":"omarchy-shell shell summon eusener.scroll"},
```

It lands under **Setup**, next to the stock **Input** entry. The file
hot-reloads on save.

A keybinding works too, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + S", "Scroll settings", "omarchy-shell shell summon eusener.scroll")
```

Check `omarchy menu keybindings --print` first — the combination may be taken.

## How settings are applied and kept

Omarchy configures Hyprland in Lua, and `hyprctl keyword` refuses to touch a
non-legacy parser (*"keyword can't work with non-legacy parsers. Use eval."*).
So a live change is a one-key `hl.config()` call sent through `hyprctl eval`,
which merges into the running config.

Values set that way do not survive a reload, so the panel also writes
`~/.config/hypr/scroll.lua` and appends a single `require("hypr.scroll")` line
to your `input.lua` the first time it saves. That file loads after Omarchy's
defaults, so it wins. Dragging a slider previews; releasing it saves.

The panel holds no state of its own: every time it opens it re-reads the
effective values from `hyprctl getoption`, so it cannot drift from the
compositor.

## Command line

The backend is usable on its own:

```bash
bin/omarchy-scroll get              # current settings as JSON
bin/omarchy-scroll set pad-factor 0.75
bin/omarchy-scroll save             # persist the current live values
bin/omarchy-scroll reset            # drop overrides, back to Omarchy defaults
```

Keys: `mouse-factor`, `mouse-natural`, `pad-factor`, `pad-natural`,
`scroll-method`, `emulate-discrete`.

For a plain `omarchy-scroll` on your `PATH`:

```bash
ln -s ~/.config/omarchy/plugins/eusener.scroll/bin/omarchy-scroll ~/.local/bin/omarchy-scroll
```

## Keys

`j`/`k` walk the controls, `h`/`l` adjust the focused slider, `Enter`
activates, `Esc` closes.

## Uninstall

```bash
omarchy plugin remove eusener.scroll
omarchy-scroll reset   # before removing, if you want the defaults back
```

The generated `~/.config/hypr/scroll.lua` and the `require` line in
`input.lua` are yours to delete; an empty `scroll.lua` is harmless.

## Requirements

Omarchy with `omarchy-shell`, and `jq` (already a dependency of Omarchy's own
scripts).

## License

MIT — see [LICENSE](LICENSE).
