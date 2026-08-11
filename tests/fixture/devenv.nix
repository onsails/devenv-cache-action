{ pkgs, ... }: {
  packages = [ pkgs.jq pkgs.ripgrep ];
  enterShell = "echo devenv-cache-action fixture";
}
