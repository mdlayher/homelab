{ config, ... }:

let
  vars = import ./vars.nix;

  guest0 = vars.interfaces.guest0;
  iot0 = vars.interfaces.iot0;
  lab0 = vars.interfaces.lab0;
  lan0 = vars.interfaces.lan0;

in {
  services.dhcpd4 = {
    interfaces =
      [ "${lan0.name}" "${guest0.name}" "${iot0.name}" "${lab0.name}" ];
    enable = true;
    machines = [
      {
        hostName = "monitnerr-1";
        ethernetAddress = "dc:a6:32:1e:66:94";
        ipAddress = "${vars.hosts.monitnerr-1.ipv4}";
      }
      {
        hostName = "nerr-3";
        ethernetAddress = "04:d9:f5:7e:1c:47";
        ipAddress = "${vars.hosts.nerr-3.ipv4}";
      }
      {
        hostName = "servnerr-3";
        ethernetAddress = "06:cb:90:4d:a2:59";
        ipAddress = "${vars.hosts.servnerr-3.ipv4}";
      }
      {
        hostName = "switch-livingroom01";
        ethernetAddress = "f0:9f:c2:0b:28:ca";
        ipAddress = "192.168.1.2";
      }
      {
        hostName = "switch-office01";
        ethernetAddress = "f0:9f:c2:ce:7e:e1";
        ipAddress = "192.168.1.3";
      }
      {
        hostName = "ap-livingroom01";
        ethernetAddress = "44:d9:e7:02:2a:56";
        ipAddress = "192.168.1.5";
      }
      {
        hostName = "hdhomerun";
        ethernetAddress = "00:18:dd:32:52:c0";
        ipAddress = "192.168.1.8";
      }
    ];
    # Assumes /24 subnets.
    extraConfig = ''
      ddns-update-style none;

      option space ubnt;
      option ubnt.unifi-address code 1 = ip-address;

      class "ubnt" {
        match if substring (option vendor-class-identifier, 0, 4) = "ubnt";
        option vendor-class-identifier "ubnt";
        vendor-option-space ubnt;
      }

      # Trusted LANs.
      subnet ${lan0.dhcp_24}.0 netmask 255.255.255.0 {
        default-lease-time 86400;
        max-lease-time 86400;

        option subnet-mask 255.255.255.0;
        option broadcast-address ${lan0.dhcp_24}.255;
        option routers ${lan0.ipv4};
        option domain-name-servers ${lan0.ipv4};
        option domain-search "${vars.domain}";
        option domain-name "${vars.domain}";

        option ubnt.unifi-address 138.197.144.228;

        range ${lan0.dhcp_24}.20 ${lan0.dhcp_24}.240;
      }

      subnet ${lab0.dhcp_24}.0 netmask 255.255.255.0 {
        default-lease-time 86400;
        max-lease-time 86400;

        option subnet-mask 255.255.255.0;
        option broadcast-address ${lab0.dhcp_24}.255;
        option routers ${lab0.ipv4};
        option domain-name-servers ${lab0.ipv4};

        range ${lab0.dhcp_24}.20 ${lab0.dhcp_24}.240;
      }

      # Untrusted LANs.
      subnet ${guest0.dhcp_24}.0 netmask 255.255.255.0 {
        # Guest devices should have short leases.
        default-lease-time 3600;
        max-lease-time 3600;

        option subnet-mask 255.255.255.0;
        option broadcast-address ${guest0.dhcp_24}.255;
        option routers ${guest0.ipv4};
        option domain-name-servers ${guest0.ipv4};
        range ${guest0.dhcp_24}.20 ${guest0.dhcp_24}.240;
      }

      subnet ${iot0.dhcp_24}.0 netmask 255.255.255.0 {
        default-lease-time 86400;
        max-lease-time 86400;

        option subnet-mask 255.255.255.0;
        option broadcast-address ${iot0.dhcp_24}.255;
        option routers ${iot0.ipv4};
        option domain-name-servers ${iot0.ipv4};
        range ${iot0.dhcp_24}.20 ${iot0.dhcp_24}.240;
      }
    '';
  };
}
