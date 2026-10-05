# Physical inventory: gear that has no address, and the cables between it
# and the machines.
#
# A cable end names a device and a port on it. The device is a host or
# loopback holder from the network inventory, an entry in `devices`, or
# both: an entry named for a machine declares that machine's ports, and a
# machine without one has free-form port names. A cable reaching
# its port through an adapter or extension lists those in `via`. A device's
# `reserved` holds ports for gear not cabled yet, by port.
#
# A device may declare `slots`, and a card names the device and slot it
# sits in with `fittedIn`. A card's ports belong to the machine it is
# fitted in, and a port with an operating system device is named for it.
#
# Cables are listed by category. A cable runs from `src` to `dst`, `src`
# being the side that drives the link: it opens a serial console, is the
# USB host, the video source, or the radio feeding an antenna. A serial line's cable carries
# `console` with its `baud`. A USB serial cable carries its adapter's
# `serial`. ./consoles.nix derives each machine's consoles from these.
# nixos/modules/inventory-checks.nix holds the checks on this data.
let
  range = n: builtins.genList (i: i + 1) n;
in
{
  devices = {
    # The onboard hub's ports: usb1, usb2, the mini-PCIe slot (its third)
    # and usb4, the internal flush one. The USB serial console and the
    # RJ45 one cannot be used at once. The SMA bulkhead fitted in a case
    # knockout is a port, where its pigtail lands inside, and a slot, where
    # an antenna screws on outside.
    pikvm = {
      slots = [
        "mini-pcie"
        "sma-main"
      ];
      ports = [
        "usb1"
        "usb2"
        "usb4"
        "hdmi-in"
        "hdmi-out1"
        "hdmi-out2"
        "usb-otg"
        "rj45-serial"
        "usb-serial"
        "atx"
        "ethernet"
        "sma-main"
      ];
      reserved.usb-serial = "exclusive with rj45-serial";
    };

    # Its antenna connectors are U.FL on the card, each led by a pigtail to
    # an SMA bulkhead on the PiKVM's case.
    lte-modem = {
      model = "SIMCom SIM7600G-H";
      fittedIn = {
        device = "pikvm";
        slot = "mini-pcie";
      };
      ports = [
        "main"
        "aux"
        "gps"
      ];
    };

    lte-antenna.fittedIn = {
      device = "pikvm";
      slot = "sma-main";
    };

    # Slots by the board's designations.
    servnerr-4 = {
      slots = [
        "PCIEX16_1"
        "PCIEX16_2"
        "PCIEX16_3"
        "PCIEX1_1"
        "PCIEX1_2"
      ];
      ports = [
        "usb"
        "atx"
      ];
    };

    server-serial = {
      model = "MosChip MCS9922";
      fittedIn = {
        device = "servnerr-4";
        slot = "PCIEX1_1";
      };
      ports = [
        "ttyS1"
        "ttyS2"
      ];
    };

    server-gpu = {
      model = "NVIDIA GeForce 210";
      fittedIn = {
        device = "servnerr-4";
        slot = "PCIEX16_2";
      };
      ports = [
        "dvi"
        "vga"
        "hdmi"
      ];
    };

    # USB serial adapter. Port names are the front-panel labels; the
    # adapter's host reaches it on `upstream`.
    serial-8port = {
      model = "StarTech ICUSB23208FD";
      serial = null;
      upstream = "usb-b";
      ports = map toString (range 8) ++ [
        "usb-b"
        "usb-a"
      ];
      reserved = {
        "3" = "pdu02";
        usb-a = "daisy chain";
      };
    };

    # Selects which host the PiKVM's video, keyboard and ATX reach.
    pikvm-switch = {
      model = "PiKVM Switch";
      ports = [
        "control"
        "uplink-hdmi"
        "uplink-usb"
      ]
      ++ builtins.concatMap (
        n:
        map (p: "host${toString n}-${p}") [
          "hdmi"
          "usb"
          "atx"
        ]
      ) (range 4);
      reserved.host1-atx = "servnerr-4 atx";
    };
  };

  cables = {
    serial = [
      {
        type = "DB9 null-modem";
        console.baud = 115200;
        src = {
          device = "serial-8port";
          port = "1";
        };
        dst = {
          device = "server-serial";
          port = "ttyS1";
        };
      }
      {
        type = "RJ45-DB9, CyberPower pinout";
        console.baud = 9600;
        src = {
          device = "serial-8port";
          port = "2";
        };
        dst = {
          device = "pdu01";
          port = "console";
        };
      }
      {
        type = "USB serial";
        serial = "Q3245527461";
        console.baud = 115200;
        via = [ "USB-A extension" ];
        src = {
          device = "pikvm";
          port = "usb4";
        };
        dst = {
          device = "routnerr-3";
          port = "console";
        };
      }
      {
        type = "RJ45-DB9, Cisco pinout";
        console.baud = 115200;
        src = {
          device = "server-serial";
          port = "ttyS2";
        };
        dst = {
          device = "pikvm";
          port = "rj45-serial";
        };
      }
    ];

    usb = [
      {
        type = "USB-A to USB-B";
        src = {
          device = "pikvm";
          port = "usb1";
        };
        dst = {
          device = "serial-8port";
          port = "usb-b";
        };
      }
      {
        type = "USB";
        via = [ "USB-A to USB-C adapter" ];
        src = {
          device = "pikvm";
          port = "usb2";
        };
        dst = {
          device = "pikvm-switch";
          port = "control";
        };
      }
      {
        type = "USB-C";
        src = {
          device = "pikvm-switch";
          port = "uplink-usb";
        };
        dst = {
          device = "pikvm";
          port = "usb-otg";
        };
      }
      {
        type = "USB-A to USB-C";
        src = {
          device = "servnerr-4";
          port = "usb";
        };
        dst = {
          device = "pikvm-switch";
          port = "host1-usb";
        };
      }
      {
        type = "USB-A to USB-C";
        src = {
          device = "hass";
          port = "usb";
        };
        dst = {
          device = "pikvm-switch";
          port = "host2-usb";
        };
      }
    ];

    video = [
      {
        type = "HDMI";
        src = {
          device = "pikvm-switch";
          port = "uplink-hdmi";
        };
        dst = {
          device = "pikvm";
          port = "hdmi-in";
        };
      }
      {
        type = "HDMI";
        src = {
          device = "server-gpu";
          port = "hdmi";
        };
        dst = {
          device = "pikvm-switch";
          port = "host1-hdmi";
        };
      }
      {
        type = "HDMI";
        src = {
          device = "hass";
          port = "hdmi";
        };
        dst = {
          device = "pikvm-switch";
          port = "host2-hdmi";
        };
      }
    ];

    rf = [
      {
        type = "U.FL to SMA pigtail";
        src = {
          device = "lte-modem";
          port = "main";
        };
        dst = {
          device = "pikvm";
          port = "sma-main";
        };
      }
    ];

    power = [ ];

    network = [ ];
  };
}
