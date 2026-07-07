{
  description = "Context-aware LLM proofreading for GNU Emacs";

  inputs = {
    flake-parts = {
      inputs = {
        nixpkgs-lib = {
          follows = "nixpkgs";
        };
      };

      url = "git+https://github.com/hercules-ci/flake-parts.git?ref=main";
    };

    nixpkgs = {
      url = "git+https://github.com/NixOS/nixpkgs.git?ref=nixos-unstable";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      ...
    }:
    let
      inherit (flake-parts.lib)
        mkFlake
        ;

      projectRoot = ./.;
    in
    mkFlake
      {
        inherit
          inputs
          ;

        specialArgs = {
          inherit
            projectRoot
            ;
        };
      }
      {
        imports = [
          flake-parts.flakeModules.partitions
        ];

        partitionedAttrs = {
          devShells = "tools";
          formatter = "tools";
        };

        partitions = {
          tools = {
            extraInputsFlake = projectRoot + /tools;

            module =
              {
                ...
              }:
              {
                imports = [
                  (projectRoot + /tools/flake-module.nix)
                ];
              };
          };
        };

        systems = [
          "x86_64-linux"
        ];
      };
}
