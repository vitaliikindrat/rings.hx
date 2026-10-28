{
  description = "rings.hx: rainbow indentation for Helix (Steel plugin + overlay API patch)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0";
    in
    {
      packages = forAll (pkgs: rec {
        # The cog, laid out the way helix-plugins-nix and forge expect;
        # `passthru.cogName` lets helix-plugins-nix's module install it.
        rings = pkgs.stdenvNoCC.mkDerivation {
          pname = "helix-plugin-rings";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./cog.scm
              ./rings.scm
            ];
          };
          dontBuild = true;
          installPhase = ''
            mkdir -p $out
            install -m644 *.scm $out/
          '';
          # Needs a Steel helix with canopy.hx's overlays patch.
          passthru.cogName = "rings";
          meta = {
            description = "Rainbow indentation for Helix (Steel plugin)";
            homepage = "https://github.com/vitaliikindrat/rings.hx";
            license = pkgs.lib.licenses.mit;
          };
        };
        default = rings;
      });
    };
}
