{
  formats,
  languagetool,
  lib,
  writeShellApplication,
  ...
}:
let
  inherit (lib)
    getExe'
    ;

  config =
    (formats.javaProperties { }).generate
      "proofread-languagetool.properties"
      {
        cacheSize = "1000";
      };
in
writeShellApplication {
  name = "languagetool-http-server";

  text = ''
    for argument in "$@"; do
      case "$argument" in
        --config)
          exec ${getExe' languagetool "languagetool-http-server"} \
            "$@"
          ;;
      esac
    done

    exec ${getExe' languagetool "languagetool-http-server"} \
      --config ${config} \
      "$@"
  '';
}
