# AppKit catalog on GNUstep. Requires FreeCoreData + gnustep-gui.
# UI is CatalogWindow.xib (GSXib5Loader).
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = Catalog
Catalog_OBJC_FILES = main.m CatalogController.m
Catalog_INCLUDE_DIRS = -I../../Source/ODataKit/include -I../../Source/ODataIncrementalStore/include -I../../Source/ODataKit/include/ODataKit -I../../Source/ODataIncrementalStore/include/ODataIncrementalStore
Catalog_LIB_DIRS = -L../../obj
Catalog_OBJC_LIBS += -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData
Catalog_TOOL_LIBS += -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData
Catalog_RESOURCE_FILES = CatalogWindow.xib

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DCATALOG_MODEL_DIR=\"$(CURDIR)\"

# FreeCoreData loads compiled models only, so Catalog.xcdatamodeld is
# compiled to Catalog.momd by FreeCoreData's momc and lands in Resources.
# momc and coredata-model.make come from `make -C Tools/momc install` there.
Catalog_XCDATAMODELD_FILES = Catalog.xcdatamodeld
include $(GNUSTEP_MAKEFILES)/coredata-model.make

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble
