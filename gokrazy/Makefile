.PHONY: all update

all:
	tar cf breakglass.tar --dereference sh \
	&& breakglass -debug_tarball_pattern breakglass.tar monitnerr-1

update:
	gokr-packer \
	github.com/gokrazy/breakglass \
	github.com/gokrazy/stat/cmd/gokr-webstat \
	github.com/mdlayher/consrv \
	github.com/prometheus/node_exporter
