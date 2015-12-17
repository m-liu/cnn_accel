ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

BSC_FLAGS = -keep-fires -show-schedule -aggressive-conditions -wait-for-license

BUILD_DIR = build
VDIR = $(BUILD_DIR)/verilog
BDIR = $(BUILD_DIR)/obj
DIRS = $(BUILD_DIR) $(VDIR) $(BDIR)

#BSVFILES += $(wildcard src/*.bsv)
BSVPATHS += src/:test/
TOP_BSV += test/CacheBankedTb.bsv
TOP_MODULE = mkCacheBankedTb

all: directories compile link

# Create directories if not exist
.PHONY: directories
directories: $(DIRS)

$(DIRS):
	mkdir -p $(DIRS)

compile:
	bsc -u $(BSC_FLAGS) -sim -vdir $(VDIR) -bdir $(BDIR) -info-dir $(BDIR) -simdir $(BDIR) -p +:$(BSVPATHS) -g $(TOP_MODULE) $(TOP_BSV) 

link:
	bsc -e $(TOP_MODULE) -sim -o $(BDIR)/out $(BSC_FLAGS) -vdir $(VDIR) -bdir $(BDIR) -info-dir $(BDIR) -simdir $(BDIR) -p +:$(BSVPATHS)

	
clean:
	rm -f $(BDIR)/*
	rm -f $(VDIR)/*
	

