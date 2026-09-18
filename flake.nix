{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.zig = {
    url = "github:mitchellh/zig-overlay";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig,
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
              zig.packages.${system}."master-2026-09-16"
              python3
            ]
            ++ (if pkgs.stdenv.hostPlatform.isLinux then [ pkgs.kcov ] else [ ]);
        }
      );
    };
}
