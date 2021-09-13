{ config, pkgs, lib, ... }:

with lib;

{
  services.yggdrasil = {
    enable = true;
    # forward-port v4
    package = mkDefault /nix/store/y9b7vw3h4x2w2klc1q6ysvbcpj1sbf3g-yggdrasil-0.4.0;
    persistentKeys = true;
    config.Peers = [
      "tls://ygg.mkg20001.io:443"
      "tcp://ygg.mkg20001.io:80"
    ];
  };

  users.users.mkg20001 = {
    isNormalUser = true;
    extraGroups = ["wheel"];
  };
  security.sudo.wheelNeedsPassword = false;
}

