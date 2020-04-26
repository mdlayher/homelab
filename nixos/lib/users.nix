{ config, ... }:

{
  # Set up matt's account, enable sudo and SSH login.
  users.users.matt = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)"
    ];
  };
}
