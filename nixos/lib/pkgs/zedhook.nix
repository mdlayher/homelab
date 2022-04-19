{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "zedhook";
  version = "unstable-2022-04-18";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "zedhook";
    rev = "e30e67abaa5e5b53f11fb613946325fe06f8ca97";
    sha256 = "sha256-+GWMC/EaKiSQQpxu8mudtRdLrWczWR6ZaVhn/VCAa5M=";
  };

  modBuildPhase = ''
    go mod edit -go=1.18
    go mod tidy
  '';

  vendorSha256 = "sha256-AI08Y/QQR62SZSgSguPrtzxmSmCZvhHnj0+phZuLi3E=";

  meta = with lib; {
    homepage = "github.com/mdlayher/zedhook";
    description = "zedhook ZFS event monitoring system.";
    license = licenses.asl20;
    maintainers = with maintainers; [ mdlayher ];
  };
}
