{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "zedhook";
  version = "unstable-2022-04-29";

  src = fetchFromGitHub {
    owner = "mdlayher";
    repo = "zedhook";
    rev = "a44f053f8f1eea1d7a21ad7ec321dedc0fb819c6";
    sha256 = "sha256-2eGd4Yejz7iLRNISYUqSxFIQwg1PJ7q2/WUsP/5wEew=";
  };

  # TODO: workaround for buildGoModule using 1.17.
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
