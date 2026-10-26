{
  lib,
  python3,
  runCommand,
}:

# A Tern plugin is a directory: manifest, host half, stylesheet, and the
# extractor that cuts sprites out of the player's own Balatro.love on first use.
# tern-balatro redistributes no Balatro artwork.
runCommand "tern-balatro-0.1.0"
  {
    meta = {
      description = "Tern block where Balatro jokers wander a themed scene";
      homepage = "https://github.com/ocasazza/tern-balatro";
      license = lib.licenses.mit;
      platforms = lib.platforms.darwin ++ lib.platforms.linux;
    };
  }
  ''
    plugin=$out/share/tern/plugins/balatro
    mkdir -p "$plugin"
    # Tern resolves these by name, and a single-file store path carries a hash
    # prefix, so each copy names its destination.
    cp ${./plugin.toml} "$plugin/plugin.toml"
    cp ${./host.luau} "$plugin/host.luau"
    cp ${./balatro.css} "$plugin/balatro.css"

    # Tern spawns the extractor by path, so bake in an absolute interpreter
    # rather than depending on python3 being on the daemon's PATH.
    sed '1s|.*|#!${python3}/bin/python3|' ${./extract.py} > "$plugin/extract.py"
    chmod +x "$plugin/extract.py"
  ''
