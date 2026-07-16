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
                    version = "0.2.0";
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
                    version = "0.1.1";
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
              baseNameOf
              concatMapStringsSep
              dirOf
              filter
              foldl'
              hasPrefix
              hasSuffix
              removePrefix
              versions
              ;

            elispRelativePath =
              source:
              removePrefix "${toString projectRoot}/" (
                toString source
              );

            elispSources =
              filter
                (
                  source:
                  let
                    name = baseNameOf source;
                  in
                  hasSuffix ".el" name
                  && !(hasSuffix "-autoloads.el" name)
                  && !(hasSuffix "-pkg.el" name)
                )
                (
                  lib.filesystem.listFilesRecursive (
                    projectRoot + /lisp
                  )
                  ++ lib.filesystem.listFilesRecursive (
                    projectRoot + /test
                  )
                );

            implementationElispSources = filter (
              source:
              hasPrefix "lisp/" (elispRelativePath source)
            ) elispSources;

            testElispSources = filter (
              source:
              hasPrefix "test/" (elispRelativePath source)
            ) elispSources;

            languageToolServer = pkgs.callPackage (
              projectRoot
              + /tool/languagetool-server-wrapper.nix
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
                      gnugrep
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
                          projectRoot + /tool/proofread-release/package.nix
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
                            popupCompatInitdir="$testRoot/popup-0.1-compat"
                            popupInitdir="$testRoot/popup"
                            releaseInitdir="$testRoot/release"

                            mkdir -p \
                              "$coreInitdir" \
                              "$llmInitdir" \
                              "$languageToolInitdir" \
                              "$popupCompatInitdir" \
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

                            PROOFREAD_POPUP_V0_1_0_FIXTURE="${
                              projectRoot
                              + /test/fixtures/proofread-popup-v0.1.0.el.in
                            }" \
                            "${emacs-with-proofread-popup}/bin/emacs" --batch \
                              --init-directory "$popupCompatInitdir" \
                              -l "${
                                projectRoot
                                + /test/proofread-popup-v0.1.0-tests.el
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
                            gnugrep
                            languageToolServer
                          ];

                          text = ''
                            initdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-XXXXXX)"
                            workdir="$(mktemp --tmpdir -d emacs-proofread-byte-compile-src-XXXXXX)"
                            trap 'rm -rf "$initdir" "$workdir"' EXIT

                            ${concatMapStringsSep "\n" (
                              source:
                              let
                                relative = elispRelativePath source;
                              in
                              ''
                                mkdir -p "$workdir/${dirOf relative}"
                                cp "${source}" "$workdir/${relative}"
                              ''
                            ) elispSources}
                            mkdir -p "$workdir/tool"
                            cp "${proofreadRelease}/bin/proofread-release" \
                              "$workdir/tool/proofread-release.el"

                            implementationSources=(
                              ${concatMapStringsSep "\n"
                                (
                                  source: ''"$workdir/${elispRelativePath source}"''
                                )
                                (
                                  filter (
                                    source:
                                    elispRelativePath source
                                    != "lisp/proofread/proofread.el"
                                  ) implementationElispSources
                                )
                              }
                            )
                            testSources=(
                              ${concatMapStringsSep "\n" (
                                source: ''"$workdir/${elispRelativePath source}"''
                              ) testElispSources}
                            )

                            compileLog="$workdir/byte-compile.log"

                            {
                              "${emacs-with-proofread-popup}/bin/emacs" --batch \
                                --init-directory "$initdir" \
                                -L "$workdir/lisp/proofread" \
                                -L "$workdir/lisp/proofread-popup" \
                                -L "$workdir/test" \
                                -L "$workdir/tool" \
                                --eval '(setq byte-compile-error-on-warn t)' \
                                -f batch-byte-compile \
                                "$workdir/lisp/proofread/proofread.el"

                              "${emacs-with-proofread-popup}/bin/emacs" --batch \
                                --init-directory "$initdir" \
                                -L "$workdir/lisp/proofread" \
                                -L "$workdir/lisp/proofread-popup" \
                                -L "$workdir/test" \
                                -L "$workdir/tool" \
                                --eval '(setq byte-compile-error-on-warn t)' \
                                -f batch-byte-compile \
                                "''${implementationSources[@]}"

                              "${releaseEmacs}/bin/emacs" --batch \
                                --init-directory "$initdir" \
                                -L "$workdir/tool" \
                                --eval '(setq byte-compile-error-on-warn t)' \
                                -f batch-byte-compile \
                                "$workdir/tool/proofread-release.el"

                              "${emacs-with-proofread-popup}/bin/emacs" --batch \
                                --init-directory "$initdir" \
                                -L "$workdir/lisp/proofread" \
                                -L "$workdir/lisp/proofread-popup" \
                                -L "$workdir/test" \
                                -L "$workdir/tool" \
                                --eval '(setq byte-compile-error-on-warn t)' \
                                -f batch-byte-compile \
                                "''${testSources[@]}"
                            } 2>&1 | tee "$compileLog"

                            if grep -Fq 'Note:' "$compileLog"; then
                              echo 'Byte compilation emitted Note diagnostics:' >&2
                              grep -F 'Note:' "$compileLog" >&2
                              exit 1
                            fi

                            "${emacs-with-proofread-popup}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              -L "$workdir/lisp/proofread" \
                              -L "$workdir/lisp/proofread-popup" \
                              --eval '(progn
                                (require (quote proofread))
                                (require (quote proofread-llm))
                                (require (quote proofread-languagetool))
                                (require (quote proofread-popup))
                                (unless (executable-find
                                         "languagetool-http-server")
                                  (error
                                   "LanguageTool server is unavailable")))'
                          '';
                        };

                    "emacs${version}-checkdoc-proofread" =
                      writeShellApplication
                        {
                          name = "emacs${version}-checkdoc-proofread";

                          runtimeInputs = [
                            coreutils
                          ];

                          text = ''
                            initdir="$(mktemp --tmpdir -d emacs-proofread-checkdoc-XXXXXX)"
                            trap 'rm -rf "$initdir"' EXIT

                            "${emacs-with-proofread-popup}/bin/emacs" --batch \
                              --init-directory "$initdir" \
                              --eval '(progn
                                (require (quote checkdoc))
                                (dolist
                                    (file
                                     (quote
                                      (
                                       ${concatMapStringsSep "\n" (
                                         source:
                                         ''"${projectRoot}/${elispRelativePath source}"''
                                       ) elispSources}
                                       )))
                                  (let ((buffer
                                         (find-file-noselect file)))
                                    (unwind-protect
                                        (with-current-buffer buffer
                                          (let
                                              ((checkdoc-autofix-flag
                                                (quote never)))
                                            (condition-case error-data
                                                (checkdoc-current-buffer)
                                              (error
                                               (error
                                                "Checkdoc failed for %s: %s"
                                                file
                                                (error-message-string
                                                 error-data))))))
                                      (kill-buffer buffer)))))'
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
