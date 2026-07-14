{
  description = "Context-aware proofreading for GNU Emacs";

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

                emacs-proofread =
                  {
                    lib,
                    llm,
                    melpaBuild,
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
                    files = ''("proofread.el" "proofread-llm.el" "proofread-languagetool.el")'';

                    packageRequires = [
                      llm
                    ];

                    meta = {
                      description = "Context-aware proofreading for GNU Emacs";
                      homepage = "https://github.com/brsvh/emacs-proofread";
                      license = licenses.gpl3Plus;
                      maintainers = with maintainers; [ brsvh ];
                    };

                    pname = "proofread";
                    src = projectRoot + /lisp/proofread;
                    version = "0.1.0";
                  };

                emacs-proofread-popup =
                  {
                    lib,
                    melpaBuild,
                    posframe,
                    projectRoot,
                    proofread,
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
                      proofread
                      posframe
                    ];

                    meta = {
                      description = "Popup diagnostics for proofread";
                      homepage = "https://github.com/brsvh/emacs-proofread";
                      license = licenses.gpl3Plus;
                      maintainers = with maintainers; [ brsvh ];
                    };

                    pname = "proofread-popup";
                    src =
                      projectRoot
                      + /lisp/proofread-popup/proofread-popup.el;
                    version = "0.1.0";
                  };

                scope = finalAttrs: _: {
                  proofread =
                    finalAttrs.callPackage emacs-proofread
                      {
                        inherit
                          projectRoot
                          ;
                      };

                  proofread-popup =
                    finalAttrs.callPackage emacs-proofread-popup
                      {
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

            languageToolServer = pkgs.callPackage (
              projectRoot + /tool/languagetool.nix
            ) { };

            release = with pkgs; emacsPackagesFor emacs31;
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

            packages = {
              inherit (release)
                proofread
                proofread-popup
                ;
            }
            //
              foldl'
                (
                  acc: base:
                  let
                    inherit (pkgs)
                      coreutils
                      emacsPackagesFor
                      gnutar
                      writeShellApplication
                      ;

                    version = "${versions.major base.version}";

                    emacs-with-proofread =
                      (emacsPackagesFor base).emacsWithPackages
                        (
                          epkgs: with epkgs; [
                            keycast
                            proofread
                          ]
                        );

                    emacs-with-proofread-popup =
                      (emacsPackagesFor base).emacsWithPackages
                        (
                          epkgs: with epkgs; [
                            proofread-popup
                          ]
                        );

                    releaseEmacs =
                      (emacsPackagesFor base).emacsWithPackages
                        (
                          epkgs: with epkgs; [
                            llm
                            posframe
                          ]
                        );

                    proofreadRelease =
                      pkgs.callPackage
                        (
                          projectRoot + /tool/proofread-release-wrapper.nix
                        )
                        {
                          emacs = releaseEmacs;
                        };
                  in
                  acc
                  // {
                    "emacs${version}-with-proofread" =
                      writeShellApplication
                        {
                          name = "emacs${version}-with-proofread";

                          runtimeInputs = [
                            coreutils
                            emacs-with-proofread-popup
                            languageToolServer
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
                            coreutils
                            gnutar
                            languageToolServer
                          ];

                          text = ''
                            testRoot="$(mktemp --tmpdir -d emacs-proofread-tests-XXXXXX)"
                            trap 'rm -rf "$testRoot"' EXIT

                            coreInitdir="$testRoot/core"
                            llmInitdir="$testRoot/llm"
                            languageToolInitdir="$testRoot/languagetool"
                            popupInitdir="$testRoot/popup"
                            releaseInitdir="$testRoot/release"

                            mkdir -p \
                              "$coreInitdir" \
                              "$llmInitdir" \
                              "$languageToolInitdir" \
                              "$popupInitdir" \
                              "$releaseInitdir"

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$coreInitdir" \
                              -l "${projectRoot + /test/proofread-tests.el}" \
                              -f ert-run-tests-batch-and-exit

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$llmInitdir" \
                              -l "${
                                projectRoot + /test/proofread-llm-tests.el
                              }" \
                              -f ert-run-tests-batch-and-exit

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$languageToolInitdir" \
                              -l "${
                                projectRoot
                                + /test/proofread-languagetool-tests.el
                              }" \
                              -f ert-run-tests-batch-and-exit

                            "${emacs-with-proofread-popup}/bin/emacs" --batch \
                              --init-directory "$popupInitdir" \
                              -l "${
                                projectRoot + /test/proofread-popup-tests.el
                              }" \
                              -f ert-run-tests-batch-and-exit

                            "${releaseEmacs}/bin/emacs" --batch \
                              --init-directory "$releaseInitdir" \
                              -l "${proofreadRelease}/bin/proofread-release" \
                              -l "${
                                projectRoot + /test/proofread-release-tests.el
                              }" \
                              -f ert-run-tests-batch-and-exit
                          '';
                        };

                    "emacs${version}-byte-compile-proofread" =
                      writeShellApplication
                        {
                          name = "emacs${version}-byte-compile-proofread";

                          runtimeInputs = [
                            coreutils
                            languageToolServer
                          ];

                          text = ''
                            initdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-XXXXXX)"
                            workdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-src-XXXXXX)"
                            trap 'rm -rf "$initdir" "$workdir"' EXIT

                            cp "${
                              projectRoot + /lisp/proofread/proofread.el
                            }" "$workdir/proofread.el"
                            cp "${
                              projectRoot + /lisp/proofread/proofread-llm.el
                            }" "$workdir/proofread-llm.el"
                            cp "${
                              projectRoot
                              + /lisp/proofread/proofread-languagetool.el
                            }" "$workdir/proofread-languagetool.el"
                            cp "${
                              projectRoot
                              + /lisp/proofread-popup/proofread-popup.el
                            }" "$workdir/proofread-popup.el"
                            cp "${proofreadRelease}/bin/proofread-release" \
                              "$workdir/proofread-release.el"

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              -L "$workdir" \
                              --eval '(setq byte-compile-error-on-warn t)' \
                              -f batch-byte-compile \
                              "$workdir/proofread.el"

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              -L "$workdir" \
                              --eval '(setq byte-compile-error-on-warn t)' \
                              -f batch-byte-compile \
                              "$workdir/proofread-llm.el" \
                              "$workdir/proofread-languagetool.el"

                            "${emacs-with-proofread}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              -L "$workdir" \
                              --eval '(progn
                                (require (quote proofread))
                                (require (quote proofread-llm))
                                (require (quote proofread-languagetool))
                                (unless (executable-find
                                         "languagetool-http-server")
                                  (error
                                   "LanguageTool server is unavailable")))'

                            "${emacs-with-proofread-popup}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              -L "$workdir" \
                              --eval '(setq byte-compile-error-on-warn t)' \
                              -f batch-byte-compile \
                              "$workdir/proofread-popup.el"

                            "${releaseEmacs}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              --eval '(setq byte-compile-error-on-warn t)' \
                              -f batch-byte-compile \
                              "$workdir/proofread-release.el"
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
