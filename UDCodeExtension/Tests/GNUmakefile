# The OData extension's tests (an XCTest bundle; tools-xctest), against
# UDCode's SDK installed: the extension's sources and the Workbench's parts
# compiled in (their XIBs and the built-in service's Catalog in this
# bundle, as in OData.bundle), UDCodeKit's document and project linked.
#
#   make            build the bundle
#   make run-tests  build and run it (under xvfb-run where there is no display)
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

BUNDLE_NAME = ODataTests
ODataTests_STANDARD_INSTALL = no

WORKBENCH = ../../Examples/Workbench
include $(WORKBENCH)/files.make
ODataTests_OBJC_FILES = \
	ODWTests.m \
	../ODWBottomViewController.m \
	../ODWExtension.m \
	../ODWNavigatorViewController.m \
	../ODWRequests.m \
	../ODWServiceSheet.m \
	../ODWServices.m \
	$(addprefix $(WORKBENCH)/,$(WORKBENCH_KIT_OBJC_FILES))
ODataTests_RESOURCE_FILES = \
	../ODWBottom.xib \
	../ODWNavigator.xib \
	../ODWServiceSheet.xib \
	$(addprefix $(WORKBENCH)/,$(WORKBENCH_KIT_RESOURCE_FILES))

ODataTests_INCLUDE_DIRS = -I.. -I$(WORKBENCH) \
	-I../../Source/ODataKit/include -I../../Source/ODataKit/include/ODataKit \
	-I../../Source/ODataIncrementalStore/include -I../../Source/ODataIncrementalStore/include/ODataIncrementalStore \
	-I../../Source/ODataService/include -I../../Source/ODataService/include/ODataService \
	-I../../Source/HTTPServerKit/include -I../../Source/HTTPServerKit/include/HTTPServerKit \
	-I../../Source/OTelKit/include -I../../Source/OTelKit/include/OTelKit \
	-I../../Source/ODataSync/include -I../../Source/ODataSync/include/ODataSync
ODataTests_LIB_DIRS = -L../../obj
ODataTests_BUNDLE_LIBS += -lODataSync -lODataService -lHTTPServerKit -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData \
	-lUDCodeKit -lUDPieceTable -lLSPKit -lXCTest -ldispatch
ODataTests_NEEDS_GUI = yes

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter

ODataTests_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../../Examples/Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

include $(GNUSTEP_MAKEFILES)/bundle.make

XCTEST ?= xctest
TEST_TIMEOUT ?= 600

.PHONY: run-tests
run-tests: all
	LD_LIBRARY_PATH="$(CURDIR)/../../obj:$$LD_LIBRARY_PATH" PATH="$(CURDIR)/../../obj:$$PATH" \
	  timeout -s ABRT $(TEST_TIMEOUT) $(XCTEST) $(BUNDLE_NAME).bundle
