# ois-serve, an example application of its own (catalog-server), and the
# loopback check: tools over the libraries at the repository root
# (OTelKit, HTTPServerKit, ODataService), which are built there first.
#
# GNUstep, with gnustep-make (this file):
#   . /path/to/GNUstep.sh
#   make -C .. && make          # ois-serve, ois-serve-check, catalog-server
#   make check                  # the loopback check over the Catalog model
#
# macOS: Makefile.apple (make -f Makefile.apple check).

INCLUDE_DIRS = -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include \
	-I../Source/HTTPServerKit/include -I../Source/ODataKit/include/ODataKit \
	-I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService \
	-I../Source/HTTPServerKit/include/HTTPServerKit -I../Source/OTelKit/include -I../Source/OTelKit/include/OTelKit \
	-I../Source/ODataSync/include -I../Source/ODataSync/include/ODataSync

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

