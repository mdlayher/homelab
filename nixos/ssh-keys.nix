# The admin's SSH public keys, read by the machines (modules/common.nix) and
# by the KVM's configuration (pikvm/), which is built outside NixOS.
{
  # The admin's regular key.
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN5i5d0mRKAf02m+ju+I1KrAYw3Ny2IHXy88mgyragBN Matt Layher (mdlayher@gmail.com)";

  # The admin's FIDO2 keys, the only ones accepted for SSH from the
  # development container: each signature requires a physical touch on the
  # workstation or laptop the agent is forwarded from. One entry per
  # hardware key, so any single key can be revoked or lost safely.
  fido = [
    "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20AAAAIbmlzdHAyNTYAAABBBFP2wHqgmf7UPkRaoCg47yjiAGYAVNggMFLsB0WMU23IYqpfa2jbKvAc5ZFWGiDNJQYpF0KbhLXK35k/apN3UKMAAAAEc3NoOg== mdlayher home yubikey"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFlR2YATqrkugEKD0YSYQdH2wkTWao+jDw2g/v8NiJtPAAAABHNzaDo= mdlayher desk yubikey"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIE0983a+KBZlq0d/R978t3cCd19kt8y/DIDDvDr57NW5AAAABHNzaDo= mdlayher travel yubikey"
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAII3E30S3ZzFWjq12oPTG/+8fDe2NIk9IWyjZtY9Lo/00AAAABHNzaDo= mdlayher laptop yubikey"
  ];
}
