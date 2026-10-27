{ pkgs, ... }:
{
  users.groups.zeroclaw = { };
  users.users.zeroclaw = {
    description = "ZeroClaw agent service";
    isSystemUser = true;
    group = "zeroclaw";
    extraGroups = [ ];
    home = "/var/lib/zeroclaw";
    createHome = true;
    homeMode = "0700";
    shell = "${pkgs.shadow}/bin/nologin";
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [ ];
    linger = false;
  };

  # Prepare only private persistent paths; do not provision credentials or a daemon.
  # ZeroClaw's default configuration lives beneath $HOME/.zeroclaw.
  systemd.tmpfiles.rules = [
    "d /var/lib/zeroclaw 0700 zeroclaw zeroclaw -"
    "d /var/lib/zeroclaw/.zeroclaw 0700 zeroclaw zeroclaw -"
    "d /var/lib/zeroclaw/.zeroclaw/workspace 0700 zeroclaw zeroclaw -"
  ];
}
