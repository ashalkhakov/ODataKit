# OIS Device for the desktop, on GNUstep: the iOS Device app's counterpart,
# to sync with a Workbench and with peers nearby (README.md). Requires
# FreeCoreData, gnustep-gui, libqrencode (the pairing code's QR), and the
# libraries at the repository root, built there first (make -C ../..).
#
#   make
#   openapp ./DeviceDesktop.app                      # or ./DeviceDesktop.app/DeviceDesktop
#   ./DeviceDesktop.app/DeviceDesktop --self-test http://127.0.0.1:8640/odata/
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = DeviceDesktop
# The app's own; the iOS app's model of a device and its peers; the
# Workbench's device, model and Sync window; linux/: what differs by system.
DeviceDesktop_OBJC_FILES = main.m DDAppController.m DDPeersWindow.m DDSelfTest.m linux/DDSystem.m \
	../Device/DVSession.m ../Device/DVPeers.m \
	../Workbench/WorkbenchSupport.m ../Workbench/WorkbenchModel.m ../Workbench/WorkbenchDevice.m ../Workbench/WBSync.m
ROOT = ../..
DeviceDesktop_INCLUDE_DIRS = -I. -I../Device -I../Workbench \
	-I$(ROOT)/Source/ODataKit/include -I$(ROOT)/Source/ODataIncrementalStore/include -I$(ROOT)/Source/ODataService/include \
	-I$(ROOT)/Source/ODataKit/include/ODataKit -I$(ROOT)/Source/ODataIncrementalStore/include/ODataIncrementalStore \
	-I$(ROOT)/Source/ODataService/include/ODataService -I$(ROOT)/Source/HTTPServerKit/include \
	-I$(ROOT)/Source/HTTPServerKit/include/HTTPServerKit -I$(ROOT)/Source/OTelKit/include -I$(ROOT)/Source/OTelKit/include/OTelKit \
	-I$(ROOT)/Source/ODataSync/include -I$(ROOT)/Source/ODataSync/include/ODataSync
DeviceDesktop_LIB_DIRS = -L$(ROOT)/obj -L$(ROOT)
DeviceDesktop_GUI_LIBS += -lODataSync -lODataService -lHTTPServerKit -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData -ldispatch -lqrencode

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions

# FreeCoreData loads compiled models only: the Catalog, compiled by its
# momc, in Resources (coredata-model.make, from make -C Tools/momc install).
DeviceDesktop_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble
