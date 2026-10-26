{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.nixpkgs-zls.url = "github:nixos/nixpkgs/e63d3acbe89c1faa0ad6016aa0a725a18a4bf671";

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-zls,
    }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      defaultForEachSupportedSystem = (
        func:
        nixpkgs.lib.genAttrs supportedSystems (system: {
          default = func system;
        })
      );
    in
    {
      devShells = defaultForEachSupportedSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
        in
        pkgs.mkShell {
          packages =
            with pkgs;
            [
              zig_0_17
              nixpkgs-zls.legacyPackages.${system}.zls_0_17
              python3
            ]
            ++ (if pkgs.stdenv.hostPlatform.isLinux then [ pkgs.kcov ] else [ ]);
        }
      );
    };
}
