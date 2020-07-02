.PHONY: all _update monitnerr-1 monitnerr-2

all:
	tar cf breakglass.tar --dereference sh \
	&& breakglass -debug_tarball_pattern breakglass.tar monitnerr-1

monitnerr-1: DEVICE := monitnerr-1
monitnerr-1: _update

monitnerr-2: DEVICE := monitnerr-2
monitnerr-2: _update

_update:
	gokr-packer \
	-update=http://gokrazy:$(shell cat ~/.config/gokrazy/$(DEVICE).txt)@$(DEVICE)/ \
	-hostname=$(DEVICE) \
	github.com/gokrazy/breakglass \
	github.com/gokrazy/stat/cmd/gokr-webstat \
	github.com/mdlayher/consrv \
	github.com/prometheus/node_exporter
