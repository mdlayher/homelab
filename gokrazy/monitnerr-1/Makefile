GOK := sed 's,"HTTPPassword": "","HTTPPassword": "$(GOKRAZY_PASSWORD)",g' config.tmpl.json > config.json && gok -i monitnerr-1 --parent_dir=/home/mdlayher/src/github.com/mdlayher/homelab/gokrazy

all:

.PHONY: get update overwrite root

get:
	${GOK} get --update_all

update:
	${GOK} update

overwrite:
	${GOK} overwrite --full /dev/sdx

root:
	${GOK} overwrite --root /tmp/root.squashfs
