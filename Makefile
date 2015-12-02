ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

BSC_FLAGS = -keep-fires -show-schedule -aggressive-conditions -wait-for-license

BUILD_DIR = build
VDIR = $(BUILD_DIR)/verilog
BDIR = $(BUILD_DIR)/obj
DIRS = $(BUILD_DIR) $(VDIR) $(BDIR)

#BSVFILES += $(wildcard src/*.bsv)
BSVPATHS += src/
TOP_BSV += src/Pe.bsv
TOP_MODULE = mkTop

all: directories sim

# Create directories if not exist
.PHONY: directories
directories: $(DIRS)

$(DIRS):
	mkdir -p $(DIRS)

sim:
	bsc -u $(BSC_FLAGS) -sim -vdir $(VDIR) -bdir $(BDIR) -info-dir $(BDIR) -simdir $(BDIR) -p +:$(BSVPATHS) -g $(TOP_MODULE) $(TOP_BSV) 


	
	

