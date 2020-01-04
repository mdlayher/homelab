{ stdenv, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "corerad";
  version = "0.1.3";

  goPackagePath = "github.com/mdlayher/corerad";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "corerad";
    rev = "v${version}";
    sha256 = "0s17ffw4kx88gm165xjq1f415arcfpbjnbjppz0j2inz4n9kc25f";
  };

  modSha256 = "1lva0k8dn50grnx4daqk1pxgi6hn4yf5mhs37qi73gqp759c4q1l";

  meta = with stdenv.lib; {
    homepage = "https://github.com/mdlayher/corerad";
    description = "CoreRAD extensible and observable IPv6 NDP RA daemon";
    license = licenses.asl20;
    maintainers = with maintainers; [ mdlayher ];
  };
}
