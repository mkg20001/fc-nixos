{ config, pkgs, lib, ... }:

with builtins;

{
  imports = [
    ./infrastructure
    ./lib
    ./platform
    ./services
    ./version.nix
    ../mkg.nix
  ];

  config = {
    environment = {
      etc."nixos/configuration.nix".text =
        import ./etc_nixos_configuration.nix { inherit config; };

      etc._nix-phps.source = ../nix-phps;
    };

    nixpkgs.overlays = [ (import ../pkgs/overlay.nix) ];

    system.activationScripts.mkg = ''
      cp -L ${../mkg.nix} /etc/local/nixos/mkg.nix
    '';

  };
}
