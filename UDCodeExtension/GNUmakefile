# UDCode's OData Workbench extension (docs/UDCODE.md): OData.bundle, OData v4
# services in UDCode. Built against UDCode's SDK (its udcodekit archive,
# .github/pins.env's UDCODEKIT_VERSION) installed on the same GNUstep stack
# as UDCode's; the top GNUmakefile builds it only where that SDK is.
# Scripts/udcx.sh packages it, its libraries inside it.
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

BUNDLE_NAME = OData
BUNDLE_EXTENSION = .bundle
OData_PRINCIPAL_CLASS = ODWExtension
OData_NEEDS_GUI = yes
OData_STANDARD_INSTALL = no

# The Workbench's parts compiled in (Examples/Workbench/files.make), their
# XIBs and the built-in service's Catalog among the bundle's resources.
WORKBENCH = ../Examples/Workbench
include $(WORKBENCH)/files.make
ODW_OBJC_FILES = \
	ODWBottomViewController.m \
	ODWBuilderViewController.m \
	ODWExtension.m \
	ODWNavigatorViewController.m \
	ODWRequests.m \
	ODWServiceSheet.m \
	ODWServices.m
ODW_RESOURCE_FILES = \
	Resources/LanguageInfo.plist \
	ODWBottom.xib \
	ODWBuilder.xib \
	ODWNavigator.xib \
	ODWServiceSheet.xib
OData_OBJC_FILES = $(ODW_OBJC_FILES) $(addprefix $(WORKBENCH)/,$(WORKBENCH_KIT_OBJC_FILES))
OData_RESOURCE_FILES = $(ODW_RESOURCE_FILES) $(addprefix $(WORKBENCH)/,$(WORKBENCH_KIT_RESOURCE_FILES))

OData_INCLUDE_DIRS = -I. -I$(WORKBENCH) \
	-I../Source/ODataKit/include -I../Source/ODataKit/include/ODataKit \
	-I../Source/ODataIncrementalStore/include -I../Source/ODataIncrementalStore/include/ODataIncrementalStore \
	-I../Source/ODataService/include -I../Source/ODataService/include/ODataService \
	-I../Source/HTTPServerKit/include -I../Source/HTTPServerKit/include/HTTPServerKit \
	-I../Source/OTelKit/include -I../Source/OTelKit/include/OTelKit \
	-I../Source/ODataSync/include -I../Source/ODataSync/include/ODataSync
OData_LIB_DIRS = -L../obj
# Its own libraries, which the package puts beside its binary (ODataKit's,
# and the Core Data FreeCoreData is): found from where the binary is.
# UDCode's own (UDCodeKit, GNUstep's) are the running UDCode's: on Linux left
# for it, as UDCode's own plug-ins leave them; a Windows DLL is linked
# against all it uses.
OData_BUNDLE_LIBS += -lODataSync -lODataService -lHTTPServerKit -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData -ldispatch
ifneq ($(filter mingw% windows%,$(GNUSTEP_TARGET_OS)),)
OData_BUNDLE_LIBS += -lUDCodeKit -lUDPieceTable -lLSPKit -lgnustep-gui -lgnustep-base -lobjc
else
OData_LDFLAGS += -Wl,-rpath,'$$ORIGIN'
endif

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter

# The built-in service's model: FreeCoreData's momc compiles it into the
# bundle's resources (its Catalog.momd), where WBConnection looks first.
OData_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../Examples/Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

include $(GNUSTEP_MAKEFILES)/bundle.make
