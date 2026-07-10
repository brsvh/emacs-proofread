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
      nixpkgs,
      self,
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

        flake = {
          overlays = {
            default =
              final: prev:
              let
                inherit (prev)
                  emacsPackagesFor
                  ;

                package =
                  {
                    lib,
                    llm,
                    melpaBuild,
                    posframe,
                    projectRoot,
                    ...
                  }:
                  let
                    inherit (lib)
                      licenses
                      maintainers
                      ;
                  in
                  melpaBuild {
                    packageRequires = [
                      llm
                      posframe
                    ];

                    meta = {
                      description = "Context-aware LLM proofreading for GNU Emacs";
                      homepage = "https://codeberg.org/bingshan/emacs-proofread";
                      license = licenses.gpl3Plus;
                      maintainers = with maintainers; [ brsvh ];
                    };

                    pname = "proofread";
                    src = projectRoot + /lisp;
                    version = "0.1.0";
                  };

                scope = finalAttrs: prevAttrs: {
                  proofread = finalAttrs.callPackage package {
                    inherit
                      projectRoot
                      ;
                  };
                };
              in
              {
                emacsPackagesFor =
                  emacs:
                  (emacsPackagesFor emacs).overrideScope scope;
              };
          };
        };

        partitionedAttrs = {
          devShells = "tool";
          formatter = "tool";
        };

        partitions = {
          tool = {
            extraInputsFlake = projectRoot + /tool;

            module =
              {
                ...
              }:
              {
                imports = [
                  (projectRoot + /tool/flake-module.nix)
                ];
              };
          };
        };

        perSystem =
          {
            lib,
            pkgs,
            system,
            ...
          }:
          let
            inherit (lib)
              foldl'
              versions
              ;
          in
          {
            _module = {
              args = {
                pkgs = import nixpkgs {
                  inherit
                    system
                    ;

                  overlays = [
                    self.overlays.default
                  ];
                };
              };
            };

            packages =
              foldl'
                (
                  acc: base:
                  let
                    inherit (pkgs)
                      emacsPackagesFor
                      writeShellApplication
                      ;

                    version = "${versions.major base.version}";

                    emacs =
                      (emacsPackagesFor base).emacsWithPackages
                        (
                          epkgs: with epkgs; [
                            llm
                            posframe
                            proofread
                          ]
                        );
                  in
                  acc
                  // {
                    "emacs${version}-with-proofread" =
                      writeShellApplication
                        {
                          name = "emacs${version}-with-proofread";

                          runtimeInputs = [
                            emacs
                          ];

                          text = ''
                            exec emacs --init-directory "$(mktemp -d)" "$@"
                          '';
                        };

                    "emacs${version}-run-proofread-tests" =
                      writeShellApplication
                        {
                          name = "emacs${version}-run-proofread-tests";

                          runtimeInputs = [
                            emacs
                          ];

                          text = ''
                            initdir="$(mktemp --tmpdir -d emacs-proofread-test-XXXXXX)"
                            trap 'rm -rf "$initdir"' EXIT

                            emacs --batch \
                              --init-directory "$initdir" \
                              -l "${projectRoot + /test/proofread-tests.el}" \
                              -f ert-run-tests-batch-and-exit
                          '';
                        };

                    "emacs${version}-byte-compile-proofread" =
                      writeShellApplication
                        {
                          name = "emacs${version}-byte-compile-proofread";

                          runtimeInputs = [
                            emacs
                          ];

                          text = ''
                            initdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-XXXXXX)"
                            workdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-src-XXXXXX)"
                            trap 'rm -rf "$initdir" "$workdir"' EXIT

                            cp lisp/proofread.el "$workdir/proofread.el"

                            emacs --batch \
                              --init-directory "$initdir" \
                              --eval '(setq byte-compile-error-on-warn t)' \
                              -f batch-byte-compile \
                              "$workdir/proofread.el"
                          '';
                        };
                  }
                )
                { }
                (
                  with pkgs;
                  [
                    emacs30
                    emacs31
                  ]
                );
          };

        systems = [
          "x86_64-linux"
        ];
      };
}
