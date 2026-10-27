# ois-live: the store against Microsoft's public reference services,
# Northwind v4 (read) and TripPin (write). ois-classes: TripPin's classes,
# generated from its $metadata, compiled into a client and used.
#
#   make -C Tests/Live live
#
# Needs the library built first (make at the root), network access, and
# FreeCoreData's momc for the model.
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

TOOL_NAME = ois-live ois-model
ois-live_OBJC_FILES = ois-live.m
ois-live_INCLUDE_DIRS = -I../../Source/ODataKit/include -I../../Source/ODataIncrementalStore/include -I../../Source/ODataKit/include/ODataKit -I../../Source/ODataIncrementalStore/include/ODataIncrementalStore
ois-live_LIB_DIRS = -L../../obj
ois-live_TOOL_LIBS += -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData
ois-model_OBJC_FILES = ../../Tools/ois-model.m
ois-model_INCLUDE_DIRS = -I../../Source/ODataKit/include -I../../Source/ODataIncrementalStore/include -I../../Source/ODataKit/include/ODataKit -I../../Source/ODataIncrementalStore/include/ODataIncrementalStore
ois-model_LIB_DIRS = -L../../obj
ois-model_TOOL_LIBS += -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions

MOMC ?= momc

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
-include GNUmakefile.postamble

NORTHWIND = https://services.odata.org/V4/Northwind/Northwind.svc/
TRIPPIN = https://services.odata.org/V4/TripPinServiceRW/
RUN = LD_LIBRARY_PATH="$(CURDIR)/../../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" PATH="$(CURDIR)/../../obj:$$PATH"

.PHONY: live classes Catalog.momd Northwind.momd TripPin.momd NorthwindGenerated.momd
Catalog.momd: ../../Examples/Catalog/Catalog.xcdatamodeld
	$(MOMC) $< $@

TripPin.momd: TripPin.xcdatamodeld
	$(MOMC) $< $@

Northwind.momd: Northwind.xcdatamodeld
	$(MOMC) $< $@

# Northwind's model, generated from its $metadata and compiled, as a
# client built on it would be.
NorthwindGenerated.momd: all
	rm -rf NorthwindGenerated.xcdatamodeld
	$(RUN) ./$(GNUSTEP_OBJ_DIR_NAME)/ois-model $(NORTHWIND) NorthwindGenerated.xcdatamodeld
	$(MOMC) NorthwindGenerated.xcdatamodeld $@

# TripPin's model and classes, generated; the classes compiled into
# ois-classes, which uses them against the service. The headers are
# included as a client includes them, <ODataIncrementalStore/...>.
classes: all
	rm -rf TripPinClasses Generated TripPinGenerated.momd
	$(RUN) ./$(GNUSTEP_OBJ_DIR_NAME)/ois-model --classes TripPinClasses $(TRIPPIN) Generated/TripPin.xcdatamodeld
	$(MOMC) Generated/TripPin.xcdatamodeld TripPinGenerated.momd
	mkdir -p include && ln -sfn ../../../Source/ODataIncrementalStore/include/ODataIncrementalStore include/ODataIncrementalStore
	$(MAKE) -f GNUmakefile.classes MAKEFILE_NAME=GNUmakefile.classes
	$(RUN) ./$(GNUSTEP_OBJ_DIR_NAME)/ois-classes TripPinGenerated.momd

live: all Catalog.momd Northwind.momd TripPin.momd NorthwindGenerated.momd
	$(RUN) ./$(GNUSTEP_OBJ_DIR_NAME)/ois-live .
	$(MAKE) classes

after-clean::
	rm -rf Catalog.momd Northwind.momd TripPin.momd NorthwindGenerated.momd NorthwindGenerated.xcdatamodeld \
	  TripPinClasses Generated TripPinGenerated.momd include
