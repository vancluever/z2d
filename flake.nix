{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.zig-overlay = {
    url = "github:mitchellh/zig-overlay";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.zls = {
    url = "github:zigtools/zls";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.zig-overlay.follows = "zig-overlay";
  };

  outputs = { self, nixpkgs, zig-overlay, zls }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      defaultForEachSupportedSystem = (func:
        nixpkgs.lib.genAttrs supportedSystems (system: {
          default = func system;
        })
      );
    in
    {
      devShells = defaultForEachSupportedSystem
        (system:
          let
            pkgs = import nixpkgs {
              inherit system;
            };
          in
          pkgs.mkShell {
            packages = with pkgs; [
              zig-overlay.packages.${system}."0.15.1"
              zls.packages.${system}.zls
              python3
            ];
          }
        );
    };
}
