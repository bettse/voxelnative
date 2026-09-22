# Everyday chores for the native visionOS client. Run from native/.
DEVICE   ?= 70B79CDE-6606-5BF2-BFBC-1345834E5D85
SIM      ?= AAA51166-3572-43B8-9B71-9090483A2301
BUNDLE   ?= dev.ericbetts.voxelnative
OUT      ?= /tmp/vdev
SIMLOG    = $(shell xcrun simctl get_app_container $(SIM) $(BUNDLE) data 2>/dev/null)/Documents/native.log

.PHONY: sim deploy devlog devshots simlog simshot test integration help

sim:            ## build + launch in the simulator, screenshot to /tmp/voxel_sim.png
	./sim.sh

deploy:         ## build + install + launch on the headset
	./deploy.sh

devlog:         ## pull the headset's Documents (native.log + shots) into $(OUT) and tail the log
	rm -rf $(OUT) && xcrun devicectl device copy from --device $(DEVICE) --domain-type appDataContainer \
	  --domain-identifier $(BUNDLE) --source Documents --destination $(OUT) >/dev/null 2>&1 && tail -40 $(OUT)/native.log

devshots:       ## list the newest headset screenshots (after devlog)
	ls -t $(OUT)/shot-*.png | head -5

simlog:         ## tail the simulator app log
	tail -60 "$(SIMLOG)"

simshot:        ## screenshot the running simulator to /tmp/voxel_sim_now.png
	xcrun simctl io $(SIM) screenshot /tmp/voxel_sim_now.png

test:           ## LuantiKit unit tests
	cd LuantiKit && swift test 2>&1 | grep -E "error:|Executed .* tests|failed" | tail -3

integration:    ## join the running dev server (throwaway account) and check auth/spawn/blocks
	cd LuantiKit && LUANTI_DEV_SERVER=127.0.0.1:30000 swift test --filter DevServerJoinTests 2>&1 | grep -E "error:|Executed .* tests?|failed|skipped" | tail -3

help:
	@grep -E '^[a-z]+:.*##' Makefile | sed 's/:.*##/  -/'
