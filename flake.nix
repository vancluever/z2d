{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.zls = {
    url = "github:zigtools/zls/07508440588bf06f041da9f6dd3956948368f194";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zls }:
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
              zig_0_12
              zls.packages.${system}.zls
              python3
            ];
          }
        );
    };
}
