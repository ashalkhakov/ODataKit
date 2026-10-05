# ois-serve, an example application of its own (catalog-server), and the
# loopback check: tools over the libraries at the repository root
# (OTelKit, HTTPServerKit, ODataService), which are built there first.
#
# GNUstep, with gnustep-make:
#   . /path/to/GNUstep.sh
#   make -C .. && make          # ois-serve, ois-serve-check, catalog-server
#   make check                  # the loopback check over the Catalog model
#
# macOS (Apple Foundation and Core Data), without gnustep-make:
#   make && make check          # plain clang; the libraries' sources are
#                               # compiled into the tools

GCDWebServer_DIR = ../ThirdParty/GCDWebServer
include $(GCDWebServer_DIR)/GCDWebServer.make

INCLUDE_DIRS = -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include \
	-I../Source/HTTPServerKit/include -I../Source/ODataKit/include/ODataKit \
	-I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService \
	-I../Source/HTTPServerKit/include/HTTPServerKit -I../Source/OTelKit/include -I../Source/OTelKit/include/OTelKit \
	-I../Source/ODataSync/include -I../Source/ODataSync/include/ODataSync

ifneq ($(GNUSTEP_MAKEFILES),)

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

FLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
TOOL_LIBS_ALL = -lODataSync -lODataIncrementalStore -lODataService -lHTTPServerKit -lOTelKit -lODataKit -lCoreData -ldispatch -lz

TOOL_NAME = ois-serve ois-serve-check catalog-server
ois-serve_OBJC_FILES = ois-serve.m
ois-serve-check_OBJC_FILES = Tests/ois-serve-check.m
catalog-server_OBJC_FILES = Examples/CatalogServer.m
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_INCLUDE_DIRS = $(INCLUDE_DIRS)))
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_OBJCFLAGS = $(FLAGS)))
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_LIB_DIRS = -L../obj))
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_TOOL_LIBS = $(TOOL_LIBS_ALL)))

include $(GNUSTEP_MAKEFILES)/tool.make

# FreeCoreData loads compiled models only.
obj/Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	rm -rf $@ && momc $< $@

check:: all obj/Catalog.momd
	LD_LIBRARY_PATH="$(CURDIR)/../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" ./obj/ois-serve-check obj/Catalog.momd

else

CC = clang
BUILD_DIR = build
# The version httpserverkit_build_info says.
HTTPSERVERKIT_VERSION ?= $(shell git -C "$(CURDIR)" describe --tags --always 2>/dev/null || echo dev)
FLAGS = -fobjc-arc -fblocks -fobjc-exceptions -Wall -Wno-unused-parameter -DHTTPSERVERKIT_VERSION='"$(HTTPSERVERKIT_VERSION)"'
INCLUDES = $(INCLUDE_DIRS) $(GCDWebServer_INCLUDE_DIRS)
LIBS = -framework Foundation -framework CoreData -framework Security -framework Network -framework SystemConfiguration \
	-framework CoreServices -lz
# What differs by system is in each library's apple/ (and linux/, which
# the GNUstep build compiles): this is Apple's.
SOURCES = $(wildcard ../Source/*/*.m ../Source/*/apple/*.m) $(GCDWebServer_OBJC_FILES)
HEADERS = $(wildcard ../Source/*/include/*/*.h ../Source/*/*.h ../Source/*/apple/*.h)

all: $(BUILD_DIR)/ois-serve $(BUILD_DIR)/ois-serve-check $(BUILD_DIR)/catalog-server

$(BUILD_DIR)/ois-serve: ois-serve.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) ois-serve.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/catalog-server: Examples/CatalogServer.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) Examples/CatalogServer.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/ois-serve-check: Tests/ois-serve-check.m $(SOURCES) $(HEADERS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(FLAGS) $(INCLUDES) Tests/ois-serve-check.m $(SOURCES) $(LIBS) -o $@

$(BUILD_DIR)/Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	@mkdir -p $(BUILD_DIR)
	rm -rf $@ && xcrun momc $< $(abspath $@)

check: all $(BUILD_DIR)/Catalog.momd
	./$(BUILD_DIR)/ois-serve-check $(BUILD_DIR)/Catalog.momd

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all check clean

endif
