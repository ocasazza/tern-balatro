self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.tern-balatro;
  # Tern reads plugins from its config directory: the app support directory on
  # darwin, the XDG config directory elsewhere.
  ternDir =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/Tern"
    else
      "${config.xdg.configHome}/tern";
in
{
  options.programs.tern-balatro = {
    enable = lib.mkEnableOption "the Balatro block for Tern";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "tern-balatro.packages.\${system}.default";
      description = "The tern-balatro plugin to link into Tern's plugin directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.file."${ternDir}/plugins/balatro".source = "${cfg.package}/share/tern/plugins/balatro";
  };
}
