# Trust for the dn42 certificate authority, on machines with a dn42
# interface: the router, which peers, and the server and development
# container, which sit on the internal dn42 VLAN. Imported by those hosts'
# own dn42 configuration rather than by flake.nix, since a machine with no way into
# dn42 has no use for its CA. The root is constrained by its own name
# constraints to *.dn42 and dn42's address space, so trusting it says
# nothing about any other name.
#
# The file is the PEM block of https://ca.dn42/crt/root-ca.crt, which is
# CC0 and answers only inside dn42. That file carries an openssl text dump
# ahead of the block and hashes c2c31e0b...; the block alone has sha256
# 59099a41f998528962a3dc9df6282c02989dc604cd934f1504ad12d31a6e2161. The
# certificate's fingerprint holds across encodings and is the number to
# compare with the CA's site:
# 7C:16:2C:DA:B7:CB:97:E9:8C:60:C0:04:EB:36:D7:4E:7B:EC:0D:7F:EB:20:AB:59:BC:9E:99:65:8B:62:D3:E7,
# subject "dn42 Root Authority CA", valid until 2030-12-31.
{
  security.pki.certificateFiles = [ ./dn42-root-ca.pem ];
}
