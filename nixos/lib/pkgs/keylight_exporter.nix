{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "keylight_exporter";
  version = "0.1.1";

  goPackagePath = "github.com/mdlayher/keylight_exporter";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "keylight_exporter";
    rev = "v${version}";
    sha256 = "141npawcnxj3sz2xqsnyf06r4x1azk3g55941i8gjr7pwcla34r7";
  };

  modSha256 = "0idvwp8r48nzxygw60yrcrcjw6vmjrjqi3ranc2lx89p4lrky5r3";

  meta = with stdenv.lib; {
    homepage = "github.com/mdlayher/keylight_exporter";
    description = "Prometheus exporter for Elgato Key Light devices.";
    license = licenses.mit;
    maintainers = with maintainers; [ mdlayher ];
  };
}
