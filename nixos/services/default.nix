{ lib, ... }:
let
  modulesFromHere = [
    "services/misc/gitlab.nix"
    "services/monitoring/prometheus/default.nix"
    "services/monitoring/prometheus.nix"
    "services/networking/jitsi-videobridge.nix"
    "services/web-servers/nginx/default.nix"
  ];

in {
  disabledModules = modulesFromHere;

  imports = with lib; [
    ./ceph/client.nix
    ./ceph/server.nix
    ./collectdproxy.nix
    ./consul.nix
    ./gitlab
    ./graylog
    ./haproxy.nix
    ./jitsi/jitsi-videobridge.nix
    ./logrotate
    ./nginx
    ./nullmailer.nix
    ./percona.nix
    ./postgresql.nix
    ./prometheus.nix
    ./rabbitmq36.nix
    ./rabbitmq.nix
    ./raid
    ./redis.nix
    ./sensu/api.nix
    ./sensu/client.nix
    ./sensu/server.nix
    ./sensu/uchiwa.nix
    ./telegraf.nix

    (mkRemovedOptionModule [ "flyingcircus" "services" "percona" "rootPassword" ] "Change the root password via MySQL and modify secret files")
  ];
}
