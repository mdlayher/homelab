# Machines trading backups with this server over SFTP; see buddy.nix.
{
  homelab.buddies.yost = {
    index = 1;
    sshPort = 22;
    wireguardKey = "RGJlPoOZesYzxoepCot/1RnPN+6lmg2ri+KRdqXdlGA=";
    sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvTUjLxy4YZD/5KDIhRxaeecfY1qwdVQNm3jErzDbOD buddy-backup";
  };
}
