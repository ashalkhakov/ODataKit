# XCTest bundle for ODataIncrementalStore.
# Snapshots in Tests/Snapshots — no live OData service.
#
#   make -C Tests run-tests
#   # or from the library root: make test
#
# Requires clang + libobjc2 + GNUstep XCTest
# (https://github.com/gnustep/libs-xctest) and FreeCoreData.

ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang
OBJC_RUNTIME_LIB = ng
RUNTIME_VERSION = gnustep-2.0
GS_WITH_ARC = 1

BUNDLE_NAME = ODataIncrementalStoreTests
ODataIncrementalStoreTests_NEEDS_GUI = no

ODataIncrementalStoreTests_OBJC_FILES = \
	OISCatalogModel.m \
	ODataSnapshotTransport.m \
	ODataPredicateTranslatorTests.m \
	ODataQueryBuilderTests.m \
	ODataValueTests.m \
	ODataSchemaTests.m \
	ODataOperationTests.m \
	ODataExpressionTests.m \
	ODataRegexTests.m \
	ODataHistoryTests.m \
	ODataModelBuilderTests.m \
	ODataResourceIdentifierTests.m \
	ODataSnapshotStoreTests.m \
	ODataServiceTests.m \
	ODataPredicatePairTests.m \
	OTelKitTests.m \
	ODataSyncTests.m \
	ODataSyncConvergenceTests.m \
	ODataSyncPeerTests.m \
	linux/OSPSystem.m \
	ODataXMLTests.m

ODataIncrementalStoreTests_RESOURCE_FILES = Snapshots
ODataIncrementalStoreTests_INCLUDE_DIRS = -I../Source/ODataKit/include -I../Source/ODataIncrementalStore/include -I../Source/ODataService/include -I../Source/ODataKit/include/ODataKit -I../Source/ODataIncrementalStore/include/ODataIncrementalStore -I../Source/ODataService/include/ODataService -I../Source/HTTPServerKit/include -I../Source/HTTPServerKit/include/HTTPServerKit -I../Source/OTelKit/include -I../Source/OTelKit/include/OTelKit -I../Source/ODataSync/include -I../Source/ODataSync/include/ODataSync -I. \
	-I../Source/ODataSync/linux
# gnustep-make builds the library into ../obj; `make -f Makefile` into ..
ODataIncrementalStoreTests_LIB_DIRS = -L../obj -L..
ODataIncrementalStoreTests_OBJC_LIBS += -lODataSync -lODataService -lHTTPServerKit -lOTelKit -lODataIncrementalStore -lODataKit -lXCTest -lCoreData \
	-lcurl -lgnutls

# FreeCoreData's SQL backends, for the pair tests: its Backends directory,
# built (make -C Backends/PostgreSQL, make -C Backends/MySQL there). The
# tests load the one whose server CD_TEST_POSTGRES_URL or CD_TEST_MYSQL_URL
# names; one at a time, since both carry the same CDSQLStore classes.
FREECOREDATA_BACKENDS ?=
ifneq ($(FREECOREDATA_BACKENDS),)
OIS_EMPTY :=
OIS_SPACE := $(OIS_EMPTY) $(OIS_EMPTY)
BACKEND_LD_PATH := $(subst $(OIS_SPACE),:,$(strip $(foreach b,Common PostgreSQL MySQL,$(wildcard $(FREECOREDATA_BACKENDS)/$(b)/obj))))
endif

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions \
	-DOIS_CATALOG_MODEL_DIR=\"$(CURDIR)/../Examples/Catalog\"

XCTEST ?= xctest

.PHONY: check run-tests
run-tests: all $(BUNDLE_NAME).bundle
	LD_LIBRARY_PATH="$(CURDIR)/../obj:$(CURDIR)/..$(if $(BACKEND_LD_PATH),:$(BACKEND_LD_PATH))$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" \
	OIS_SNAPSHOTS="$(CURDIR)/Snapshots" $(XCTEST) "$(BUNDLE_NAME).bundle"

# FreeCoreData loads compiled models only, so Catalog.xcdatamodeld is
# compiled to Catalog.momd by FreeCoreData's momc and lands in Resources.
# momc and coredata-model.make come from `make -C Tools/momc install` there.
ODataIncrementalStoreTests_XCDATAMODELD_FILES = Catalog.xcdatamodeld
vpath %.xcdatamodeld ../Examples/Catalog
include $(GNUSTEP_MAKEFILES)/coredata-model.make

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/bundle.make
-include GNUmakefile.postamble
