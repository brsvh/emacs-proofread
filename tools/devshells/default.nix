{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    baseNameOf
    concatStringsSep
    getExe
    map
    removeAttrs
    ;

  inherit (lib.generators)
    toINIWithGlobalSection
    ;

  inherit (pkgs)
    mdformat
    writeText
    ;

  inherit (pkgs.formats)
    toml
    ;

  mdformatWithPlugins = mdformat.withPlugins (
    ps: with ps; [
      mdformat-footnote
      mdformat-frontmatter
      mdformat-gfm
      mdformat-gfm-alerts
    ]
  );

  formatters = with pkgs; [
    elisp-format
    mbake
    mdformatWithPlugins
    nixfmt
  ];
in
{
  files = {
    editorconfig = rec {
      data = {
        root = true;

        "*" = {
          charset = "utf-8";
          end_of_line = "lf";
          indent_size = 8;
          indent_style = "tab";
          insert_final_newline = true;
          max_line_length = 70;
          tab_width = 8;
          trim_trailing_whitespace = true;
        };

        "*.el" = {
          indent_style = "space";
          indent_size = "unset";
          tab_width = 2;
        };

        "*.md" = {
          indent_size = 2;
          indent_style = "space";
          max_line_length = 80;
          trim_trailing_whitespace = false;
        };

        "*.nix" = {
          indent_style = "space";
          max_line_length = 80;
          tab_width = 2;
        };

        "{Makefile,**.mk}" = {
          indent_size = 4;
          indent_style = "tab";
        };
      };

      generator =
        data:
        let
          name = baseNameOf path;

          value = {
            globalSection = {
              root = data.root or true;
            };

            sections = removeAttrs data [
              "root"
            ];
          };
        in
        writeText name (toINIWithGlobalSection { } value);

      packages = with pkgs; [
        editorconfig-checker
      ];

      path = ".editorconfig";
    };

    prek = rec {
      data = {
        default_install_hook_types = [
          "pre-commit"
        ];

        repos = [
          {
            repo = "local";

            hooks = [
              {
                entry = "treefmt --fail-on-change";
                id = "treefmt";
                language = "system";
                name = "treefmt";

                stages = [
                  "pre-commit"
                ];
              }
            ];
          }
        ];
      };

      deps = [
        "treefmt"
      ];

      generator =
        data: (toml { }).generate (baseNameOf path) data;

      hook =
        let
          inherit (pkgs)
            git
            prek
            runtimeShell
            writeScript
            ;

          mkInstall = stage: ''
            if gitDir="$(
              ${getExe git} -C "$PRJ_ROOT" \
                rev-parse --absolute-git-dir \
                2>/dev/null
            )"; then
              mkdir -p "$gitDir/hooks"
              ln -sf "${mkScript stage}" "$gitDir/hooks/${stage}"
            fi
          '';

          mkScript =
            stage:
            writeScript "prek-${stage}" ''
              #!${runtimeShell}
              if [ "''${PREK:-}" = "0" ] || [ "''${LEFTHOOK:-}" = "0" ]; then
                exit 0
              fi

              gitDir="$(
                ${getExe git} -C "$PRJ_ROOT" \
                  rev-parse --absolute-git-dir \
                  2>/dev/null || true
              )"

              if [ -n "$gitDir" ]; then
                if [ -e "$gitDir/MERGE_HEAD" ] \
                  || [ -d "$gitDir/rebase-apply" ] \
                  || [ -d "$gitDir/rebase-merge" ]; then
                  exit 0
                fi

                ref="$(
                  ${getExe git} -C "$PRJ_ROOT" \
                    symbolic-ref --quiet --short HEAD \
                    2>/dev/null || true
                )"

                if [ "$ref" = "update_flake_lock_action" ]; then
                  exit 0
                fi
              fi

              exec ${getExe prek} -C "$PRJ_ROOT" run --stage "${stage}" "$@"
            '';
        in
        concatStringsSep "\n" (
          map mkInstall data.default_install_hook_types
        );

      packages = with pkgs; [
        git
        prek
      ];

      path = "prek.toml";
    };

    treefmt = rec {
      data = {
        formatter = {
          emacs-lisp = {
            command = "elisp-format";

            includes = [
              "*.el"
            ];
          };

          makefile = {
            command = "mbake";

            includes = [
              "*.Makefile"
              "*.makefile"
              "*.mk"
              "*/Makefile"
              "*/makefile"
              "Makefile"
              "Makefile.*"
              "makefile"
              "makefile.*"
            ];

            options = [
              "format"
            ];
          };

          markdown = {
            command = "mdformat";

            exclude = [
              "/.specify/**/*"
            ];

            includes = [
              "*.md"
            ];

            options = [
              "--extensions=footnote"
              "--extensions=frontmatter"
              "--extensions=gfm"
              "--extensions=gfm_alerts"
              "--extensions=tables"
              "--wrap=80"
            ];
          };

          nix = {
            command = "nixfmt";

            includes = [
              "*.nix"
            ];

            options = [
              "--width=50"
            ];
          };
        };
      };

      generator =
        data: (toml { }).generate (baseNameOf path) data;

      packages = formatters ++ [
        pkgs.treefmt
      ];

      path = "treefmt.toml";
    };
  };
}
