# tern-balatro

A [Tern](https://docs.stencil.so/tern/) block: Balatro jokers wander a card
table, a shop or a blind, and pop `+Mult` when you click them. It is a port of
[`ITSyndicate25/tern-pokemon`](https://github.com/ITSyndicate25/tern-pokemon)
from Pokémon to Balatro.

No Balatro artwork ships with this plugin. On first use `extract.py` opens your
own `Balatro.love`, crops the joker sprites and the scene props out of the
game's texture atlases, and writes them into the plugin's data directory. The
crop grid and every prop coordinate come from the game's own tables
(`P_CENTERS`, `asset_atli`), not from guesswork.

## Using it

Open the palette and pick **New Balatro block**. The first run extracts the
sprites, which takes a few seconds.

| Action                                | Key                               | Button   |
| ------------------------------------- | --------------------------------- | -------- |
| Add a random joker                    | `n` or `+`                        | plus     |
| Choose a joker                        | `+` with the picker open, `+`/`n` | sparkle  |
| Shuffle the jokers                    | `r`                               | swap     |
| Give every joker an edition           | `s`                               | image    |
| Cycle scene: table, shop, blind, none | `t`                               | palette  |
| Light or dark                         | `d`                               | sun/moon |
| Remove the last joker                 | `x` or `delete`                   | trash    |
| Pet a joker                           | click the sprite                  | --       |

An empty pane closes on the next remove. Positions, scene, light/dark and
editions are saved with the block and survive a daemon restart.

## Install

Home Manager, through this flake:

```nix
# flake inputs
tern-balatro.url = "github:ocasazza/tern-balatro";

# a home module list
inputs.tern-balatro.homeManagerModules.default

# home configuration
programs.tern-balatro.enable = true;
```

Without Nix: `tern plugin install github.com/ocasazza/tern-balatro`. The
extractor then needs `python3` on the daemon's `PATH`, or
`TERN_BALATRO_PYTHON`.

## Where your install is found

`Balatro.love` is probed in this order: the Steam `Balatro.app` bundle, the
Steam Windows build, then the Linux Steam roots. Override with

- `TERN_BALATRO_LOVE` — path to your own `Balatro.love`
- `TERN_BALATRO_PYTHON` — interpreter to run `extract.py` with

## Layout

- `plugin.toml` — manifest: the `balatro` block and the stylesheet
- `host.luau` — the block: extraction, walk tick, picker, saved state
- `balatro.css` — scenes painted as gradients, prop placement, sprite styling
- `extract.py` — stdlib-only cropper for the game's atlases
- `package.nix` — packages the directory, with an absolute interpreter baked in
- `module.nix` — the Home Manager module; `flake.nix` exposes both

## Licence

MIT for this plugin. Balatro is © LocalThunk; nothing of it is redistributed
here, and the extracted files stay on your machine.
