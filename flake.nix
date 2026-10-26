{
  description = "Tern block where Balatro jokers wander a themed scene";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        tern-balatro = pkgs.callPackage ./package.nix { };
        default = tern-balatro;
      });

      homeManagerModules.default = import ./module.nix self;

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
