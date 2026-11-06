# core: CLI tools, aliases and shell integrations shared by every fleet host.
# Mirrors the root profile on tower (Unraid).
{ pkgs, ... }:
{
  imports = [ ./claude-code.nix ];

  # Installs claude-code (unfree) the same way the existing hosts do.
  custom.claude-code.enable = true;

  environment.systemPackages = with pkgs; [
    codex
    yazi
    zoxide
    btop
    lazydocker
    lazygit
    gh
    bat
    glow
    fzf
    ripgrep
    fd
    eza
    atuin
    herdr
    bash-preexec
  ];

  # Fleet-wide atuin config; read via ATUIN_CONFIG_DIR.
  environment.etc."atuin/config.toml".text = ''
    enter_accept = true
  '';
  environment.variables.ATUIN_CONFIG_DIR = "/etc/atuin";

  programs.bash.shellAliases = {
    y = "yazi";
    lg = "lazygit";
    ld = "lazydocker";

    ls = "eza -lh --group-directories-first --icons=auto";
    lsa = "ls -a";
    lt = "eza --tree --level=2 --long --icons --git";
    lta = "lt -a";
  };

  programs.bash.interactiveShellInit = ''
    eval "$(${pkgs.zoxide}/bin/zoxide init bash)"

    # atuin needs bash-preexec loaded first
    source ${pkgs.bash-preexec}/share/bash/bash-preexec.sh
    eval "$(${pkgs.atuin}/bin/atuin init bash)"

    # hh: atuin search; runs the selected command
    hh() {
      local cmd
      cmd=$(${pkgs.atuin}/bin/atuin search -i "$@" 3>&1 1>&2 2>&3) || return
      [ -n "$cmd" ] || return
      history -s "$cmd"
      eval "$cmd"
    }
  '';
}
