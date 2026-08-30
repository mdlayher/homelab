# Hand-written hardware configuration for a Raspberry Pi 4 Model B Rev 1.2
# booting from an SD card, matching the layout of the standard NixOS aarch64
# SD image (root filesystem labeled NIXOS_SD, firmware partition FIRMWARE).
# Verify against nixos-generate-config output on the machine after install.
{ lib, ... }:

{
  boot = {
    initrd.availableKernelModules = [
      "mmc_block"
      "usbhid"
      "usb_storage"
      "xhci_pci"
    ];

    loader = {
      # The Pi firmware and U-Boot live on the FIRMWARE partition and boot the
      # kernel via the extlinux configuration; no systemd-boot or EFI here.
      grub.enable = false;
      generic-extlinux-compatible = {
        enable = true;
        # Keep /boot bounded, as common.nix does for systemd-boot machines.
        configurationLimit = 10;
      };
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    # Nothing at runtime needs the firmware partition; don't block boot on it.
    options = [
      "nofail"
      "noauto"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
