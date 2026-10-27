# GNU Makefile for the ODataKit libraries on GNUstep:
#   ODataKit               what a client and a service share
#   ODataIncrementalStore  the client: a Core Data store over an OData service
#   OTelKit                OpenTelemetry tracing: spans, sampling, OTLP export
#   HTTPServerKit          an HTTP server for APIs: the listener (GCDWebServer,
#                          ashalkhakov/GCDWebServer's library), a pipeline and
#                          router, sign-in, observability
#   ODataSync              an offline Core Data store kept in sync with a
#                          service (docs/offline-sync.md)
#   ODataService           the server: a Core Data store served over OData,
#                          and as an HTTPServerKit application's module
# (ois-serve, and the loopback check over it, are in Server/).
# Requires clang + libobjc2 (the modern runtime). GCC's libobjc will not do.
#
# Core Data on GNUstep is FreeCoreData:
#   https://github.com/ashalkhakov/FreeCoreData
# Install that framework first, then:
#
#   export GNUSTEP_MAKEFILES=/usr/share/GNUstep/Makefiles
#   . /usr/share/GNUstep/Makefiles/GNUstep.sh
#   make
#   make install
#

ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

ifeq ($(findstring gcc,$(CC)),gcc)
$(error OIS requires clang + libobjc2. GCC's libobjc is the old fragile runtime.)
endif

# Each library's headers by <Library/Header.h>, and in the tree by name.
OIS_INCLUDE_DIRS = -ISource/ODataKit/include -ISource/ODataIncrementalStore/include -ISource/ODataService/include \
	-ISource/HTTPServerKit/include -ISource/ODataKit/include/ODataKit \
	-ISource/ODataIncrementalStore/include/ODataIncrementalStore -ISource/ODataService/include/ODataService \
	-ISource/HTTPServerKit/include/HTTPServerKit -ISource/OTelKit/include -ISource/OTelKit/include/OTelKit \
	-ISource/ODataSync/include -ISource/ODataSync/include/ODataSync
OIS_OBJCFLAGS = -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions -Wall -Wno-unused-parameter
ADDITIONAL_OBJCFLAGS += $(OIS_OBJCFLAGS)

# In the order they depend on each other (which make -j is told below).
LIBRARY_NAME = ODataKit ODataIncrementalStore OTelKit HTTPServerKit ODataService ODataSync

# Windows: a DLL exports what it marks, and once the runtime marks its
# classes, its C functions and constants too must be: each library's macro
# (<NAME>_EXPORT in its headers) is "export" while it is built, and
# FOUNDATION_EXPORT's import everywhere else.
ifneq ($(filter mingw% windows%,$(GNUSTEP_TARGET_OS)),)
ODataKit_CPPFLAGS += "-DODATAKIT_EXPORT=__declspec(dllexport) extern"
ODataIncrementalStore_CPPFLAGS += "-DODATAINCREMENTALSTORE_EXPORT=__declspec(dllexport) extern"
OTelKit_CPPFLAGS += "-DOTELKIT_EXPORT=__declspec(dllexport) extern"
HTTPServerKit_CPPFLAGS += "-DHTTPSERVERKIT_EXPORT=__declspec(dllexport) extern"
ODataService_CPPFLAGS += "-DODATASERVICE_EXPORT=__declspec(dllexport) extern"
ODataSync_CPPFLAGS += "-DODATASYNC_EXPORT=__declspec(dllexport) extern"
# POSIX there as MinGW has it: clock_gettime in winpthreads, gmtime_r in
# time.h when asked for, dlopen (store backends) in dlfcn-win32; zlib, which
# elsewhere comes with the libraries HTTPServerKit links, named.
OTelKit_LIBRARIES_DEPEND_UPON += -lpthread
HTTPServerKit_CPPFLAGS += -D_POSIX_THREAD_SAFE_FUNCTIONS
HTTPServerKit_LIBRARIES_DEPEND_UPON += -ldl -lpthread -lz
ODataService_LIBRARIES_DEPEND_UPON += -ldl
HS_MEMORY_SYSTEM = windows
# ODataSync syncs with a server there, not yet with devices nearby
# (Source/ODataSync/windows): no libcurl, no dns_sd.
ODS_SYSTEM = windows
ODS_DISCOVERY = Source/ODataSync/windows/ODataSyncPeerDiscovery.m
ODS_SYSTEM_LIBS =
ODATAKIT_PEERS =
else
HS_MEMORY_SYSTEM = linux
ODS_SYSTEM = linux
ODS_DISCOVERY = Source/ODataSync/ODataSyncPeerDiscovery.m
ODS_SYSTEM_LIBS = -lcurl $(DNSSD_LIBS)
# The Device app, which syncs with devices nearby, and its check.
ODATAKIT_PEERS = Examples/DeviceDesktop
endif

# The version httpserverkit_build_info says.
HTTPSERVERKIT_VERSION ?= $(shell git -C "$(CURDIR)" describe --tags --always 2>/dev/null || echo dev)

ODataKit_NEEDS_GUI = no
ODataKit_OBJC_FILES = \
	Source/ODataKit/ODataApply.m \
	Source/ODataKit/ODataBatch.m \
	Source/ODataKit/ODataCSDL.m \
	Source/ODataKit/OISXML.m \
	Source/ODataKit/ODataError.m \
	Source/ODataKit/ODataExpression.m \
	Source/ODataKit/ODataLexer.m \
	Source/ODataKit/ODataPropertyMapper.m \
	Source/ODataKit/ODataPredicateBuilder.m \
	Source/ODataKit/ODataRegex.m \
	Source/ODataKit/ODataSchema.m \
	Source/ODataKit/ODataTransport.m \
	Source/ODataKit/ODataValue.m

ODataKit_HEADER_FILES = \
	ODataApply.h \
	ODataBatch.h \
	ODataCSDL.h \
	ODataXML.h \
	ODataError.h \
	ODataExpression.h \
	ODataKit.h \
	ODataPredicateBuilder.h \
	ODataPropertyMapper.h \
	ODataRegex.h \
	ODataSchema.h \
	ODataTransport.h \
	ODataValue.h \
	OISCoreData.h \
	OISRuntime.h

ODataKit_HEADER_FILES_DIR = Source/ODataKit/include/ODataKit
ODataKit_HEADER_FILES_INSTALL_DIR = ODataKit
ODataKit_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataKit_LIB_DIRS = -L./obj
ODataKit_LIBRARIES_DEPEND_UPON += -lCoreData -ldispatch
ODataKit_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataKit_CFLAGS += -fblocks

ODataIncrementalStore_NEEDS_GUI = no
ODataIncrementalStore_OBJC_FILES = \
	Source/ODataIncrementalStore/ODataClassWriter.m \
	Source/ODataIncrementalStore/ODataClient.m \
	Source/ODataIncrementalStore/ODataConfiguration.m \
	Source/ODataIncrementalStore/ODataFunctionExpression.m \
	Source/ODataIncrementalStore/ODataHistory.m \
	Source/ODataIncrementalStore/ODataIncrementalStore.m \
	Source/ODataIncrementalStore/ODataModelBuilder.m \
	Source/ODataIncrementalStore/ODataOperationCall.m \
	Source/ODataIncrementalStore/ODataStreamTransfer.m \
	Source/ODataIncrementalStore/ODataSearchPredicate.m \
	Source/ODataIncrementalStore/ODataTemporalPredicate.m \
	Source/ODataIncrementalStore/ODataHierarchyPredicate.m \
	Source/ODataIncrementalStore/ODataQuery.m \
	Source/ODataIncrementalStore/ODataPredicateTranslator.m \
	Source/ODataIncrementalStore/ODataQueryBuilder.m \
	Source/ODataIncrementalStore/ODataResourceIdentifier.m

ODataIncrementalStore_HEADER_FILES = \
	ODataClassWriter.h \
	ODataClient.h \
	ODataConfiguration.h \
	ODataFunctionExpression.h \
	ODataHistory.h \
	ODataIncrementalStore.h \
	ODataModelBuilder.h \
	ODataOperationCall.h \
	ODataStreamTransfer.h \
	ODataSearchPredicate.h \
	ODataTemporalPredicate.h \
	ODataHierarchyPredicate.h \
	ODataQuery.h \
	ODataPredicateTranslator.h \
	ODataQueryBuilder.h \
	ODataResourceIdentifier.h

ODataIncrementalStore_HEADER_FILES_DIR = Source/ODataIncrementalStore/include/ODataIncrementalStore
ODataIncrementalStore_HEADER_FILES_INSTALL_DIR = ODataIncrementalStore
ODataIncrementalStore_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataIncrementalStore_LIB_DIRS = -L./obj
ODataIncrementalStore_LIBRARIES_DEPEND_UPON += -lODataKit -lOTelKit -lCoreData -ldispatch
ODataIncrementalStore_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataIncrementalStore_CFLAGS += -fblocks

OTelKit_NEEDS_GUI = no
OTelKit_OBJC_FILES = \
	Source/OTelKit/OTHTTP.m \
	Source/OTelKit/OTLPExporter.m \
	Source/OTelKit/OTTrace.m

OTelKit_HEADER_FILES = \
	OTHTTP.h \
	OTLPExporter.h \
	OTTrace.h \
	OTelKit.h

OTelKit_HEADER_FILES_DIR = Source/OTelKit/include/OTelKit
OTelKit_HEADER_FILES_INSTALL_DIR = OTelKit
OTelKit_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
OTelKit_LIB_DIRS = -L./obj
OTelKit_LIBRARIES_DEPEND_UPON += -ldispatch
OTelKit_OBJCFLAGS += $(OIS_OBJCFLAGS) -DOTELKIT_VERSION='"$(HTTPSERVERKIT_VERSION)"'
OTelKit_CFLAGS += -fblocks

HTTPServerKit_NEEDS_GUI = no
HTTPServerKit_OBJC_FILES = \
	Source/HTTPServerKit/HSApplication.m \
	Source/HTTPServerKit/HSAuthentication.m \
	Source/HTTPServerKit/HSLog.m \
	Source/HTTPServerKit/HSMessage.m \
	Source/HTTPServerKit/HSObservability.m \
	Source/HTTPServerKit/HSPipeline.m \
	Source/HTTPServerKit/HSRouter.m \
	Source/HTTPServerKit/HSServer.m \
	Source/HTTPServerKit/HSSignature.m \
	Source/HTTPServerKit/linux/HSSignatureSystem.m \
	Source/HTTPServerKit/$(HS_MEMORY_SYSTEM)/HSMemorySystem.m \
	Source/HTTPServerKit/HSStages.m

HTTPServerKit_HEADER_FILES = \
	HSApplication.h \
	HSAuthentication.h \
	HSLog.h \
	HSMessage.h \
	HSObservability.h \
	HSPipeline.h \
	HSRouter.h \
	HSServer.h \
	HSStages.h \
	HTTPServerKit.h

HTTPServerKit_HEADER_FILES_DIR = Source/HTTPServerKit/include/HTTPServerKit
HTTPServerKit_HEADER_FILES_INSTALL_DIR = HTTPServerKit
HTTPServerKit_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
HTTPServerKit_LIB_DIRS = -L./obj
HTTPServerKit_LIBRARIES_DEPEND_UPON += -lOTelKit -lGCDWebServer -ldispatch -lgnutls
HTTPServerKit_OBJCFLAGS += $(OIS_OBJCFLAGS) -DHTTPSERVERKIT_VERSION='"$(HTTPSERVERKIT_VERSION)"'
HTTPServerKit_CFLAGS += -fblocks

ODataService_NEEDS_GUI = no
ODataService_OBJC_FILES = \
	Source/ODataService/ODataMetadataWriter.m \
	Source/ODataService/ODataOperationCatalog.m \
	Source/ODataService/ODataServer.m \
	Source/ODataService/ODataService.m \
	Source/ODataService/ODataServiceBatch.m \
	Source/ODataService/ODataTimeline.m \
	Source/ODataService/OISAuthorization.m \
	Source/ODataService/OISPlan.m \
	Source/ODataService/OISServiceCall+Plan.m \
	Source/ODataService/OISServiceCall+Tracing.m \
	Source/ODataService/OISServiceCall+Write.m

ODataService_HEADER_FILES = \
	ODataMetadataWriter.h \
	ODataPermissions.h \
	ODataServer.h \
	ODataService.h

ODataService_HEADER_FILES_DIR = Source/ODataService/include/ODataService
ODataService_HEADER_FILES_INSTALL_DIR = ODataService
ODataService_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS)
ODataService_LIB_DIRS = -L./obj
ODataService_LIBRARIES_DEPEND_UPON += -lHTTPServerKit -lOTelKit -lODataKit -lCoreData -ldispatch
ODataService_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataService_CFLAGS += -fblocks

ODataSync_NEEDS_GUI = no
ODataSync_OBJC_FILES = \
	Source/ODataSync/ODSClock.m \
	Source/ODataSync/ODSCodec.m \
	Source/ODataSync/ODSConflicts.m \
	Source/ODataSync/ODSDownloader.m \
	Source/ODataSync/ODSMerge.m \
	Source/ODataSync/ODSModel.m \
	Source/ODataSync/ODSRecorder.m \
	Source/ODataSync/ODSRequests.m \
	Source/ODataSync/ODSStore.m \
	Source/ODataSync/ODSUploader.m \
	Source/ODataSync/ODSVersions.m \
	Source/ODataSync/ODataSyncChange.m \
	Source/ODataSync/ODataSyncEngine.m \
	$(ODS_DISCOVERY) \
	Source/ODataSync/ODataSyncPeerIdentity.m \
	Source/ODataSync/ODataSyncPeerServer.m \
	Source/ODataSync/ODataSyncPeerTokens.m \
	Source/ODataSync/ODataSignIn.m \
	Source/ODataSync/ODataSyncPeerTransport.m \
	Source/ODataSync/ODataSyncPeerTrust.m \
	Source/ODataSync/ODataSyncRemote.m \
	Source/ODataSync/ODataSyncService.m \
	Source/ODataSync/$(ODS_SYSTEM)/ODSSystem.m \
	Source/ODataSync/$(ODS_SYSTEM)/ODSSystemIdentity.m \
	Source/ODataSync/$(ODS_SYSTEM)/ODSSystemPeerClient.m \
	Source/ODataSync/$(ODS_SYSTEM)/ODataSyncPeerListener.m

ODataSync_HEADER_FILES = \
	ODataSync.h \
	ODataSyncEngine.h \
	ODataSyncMerging.h \
	ODataSyncPeerServer.h \
	ODataSyncPeerTokens.h \
	ODataSignIn.h \
	ODataSyncService.h \
	ODataSyncPeerIdentity.h \
	ODataSyncPeerListener.h \
	ODataSyncPeerTrust.h \
	ODataSyncPeerTransport.h \
	ODataSyncPeerDiscovery.h


ODataSync_HEADER_FILES_DIR = Source/ODataSync/include/ODataSync
ODataSync_HEADER_FILES_INSTALL_DIR = ODataSync
# Peers (docs/peer-sync.md): what they need of the system is in
# Source/ODataSync/linux (ODSSystem.h): TLS by GnuTLS (the listener, the
# identity) and libcurl (the transport), Bonjour by Avahi's dns_sd compatibility
# library (libavahi-compat-libdnssd-dev; avahi-daemon running, to use it).
DNSSD_CFLAGS := $(shell pkg-config --cflags avahi-compat-libdns_sd 2>/dev/null || echo -I/usr/include/avahi-compat-libdns_sd)
DNSSD_LIBS := $(shell pkg-config --libs avahi-compat-libdns_sd 2>/dev/null || echo -ldns_sd)
ODataSync_INCLUDE_DIRS = $(OIS_INCLUDE_DIRS) -ISource/ODataSync $(DNSSD_CFLAGS)
ODataSync_LIB_DIRS = -L./obj
ODataSync_LIBRARIES_DEPEND_UPON += -lODataService -lHTTPServerKit -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData -ldispatch \
	-lgnutls $(ODS_SYSTEM_LIBS)
ODataSync_OBJCFLAGS += $(OIS_OBJCFLAGS)
ODataSync_CFLAGS += -fblocks

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/library.make
-include GNUmakefile.postamble

# make -j builds the libraries side by side: the client and the service
# link against libODataKit, so it is built first; the service against
# libHTTPServerKit too, and the client and the server against libOTelKit;
# ODataSync against the client and the service (its peer server).
ODataIncrementalStore.all.library.variables ODataService.all.library.variables: ODataKit.all.library.variables
ODataService.all.library.variables: HTTPServerKit.all.library.variables
HTTPServerKit.all.library.variables ODataIncrementalStore.all.library.variables: OTelKit.all.library.variables
ODataSync.all.library.variables: ODataIncrementalStore.all.library.variables ODataService.all.library.variables

ODATAKIT_SCRIPTS = Scripts
# What an application builds against the installed libraries with: a
# fragment every GNUmakefile includes, and pkg-config files
# (Scripts/install-build-files.sh, docs/building.md).
ODATAKIT_VERSION ?= $(shell git -C "$(CURDIR)" describe --tags --always 2>/dev/null || echo 0.0.0)
ODATAKIT_BUILD_FILES = HEADERS_DIR="$(patsubst $(MAYBE_DESTDIR)%,%,$(GNUSTEP_HEADERS))" \
	LIBRARIES_DIR="$(patsubst $(MAYBE_DESTDIR)%,%,$(GNUSTEP_LIBRARIES))" MAKEFILES_DIR="$(GNUSTEP_MAKEFILES)" \
	DESTDIR="$(DESTDIR)" VERSION="$(ODATAKIT_VERSION)" \
	GNUSTEP_OBJC_FLAGS="$(shell gnustep-config --objc-flags 2>/dev/null)" GNUSTEP_BASE_LIBS="$(shell gnustep-config --base-libs 2>/dev/null)" \
	sh $(ODATAKIT_SCRIPTS)/install-build-files.sh

after-install::
	$(ODATAKIT_BUILD_FILES) install libraries

after-uninstall::
	$(ODATAKIT_BUILD_FILES) uninstall libraries

# The rest of the repository, on the libraries: the command-line tools
# (Tools/), the example apps and the server's tools (Server/); the tools,
# the Workbench, the Device app, the launcher that chooses between them,
# and the server's tools installed beside the libraries.
ODATAKIT_PARTS = Tools Examples/Catalog Examples/Workbench $(ODATAKIT_PEERS) Examples/Launcher Server
ODATAKIT_INSTALLED = Tools Examples/Workbench $(ODATAKIT_PEERS) Examples/Launcher Server

after-all::
	@for part in $(ODATAKIT_PARTS); do $(MAKE) -C $$part || exit 1; done

after-install::
	@for part in $(ODATAKIT_INSTALLED); do $(MAKE) -C $$part install || exit 1; done

after-clean::
	@for part in $(ODATAKIT_PARTS) Tests Tests/Live; do $(MAKE) -C $$part clean || exit 1; done

# make check:
#   the unit tests (the discovery test runs when avahi-daemon does)
#   the store's predicates and grouping over PostgreSQL, MySQL and MariaDB,
#     each given by its URL (POSTGRES_URL, MYSQL_URL, MARIADB_URL: a server
#     a test may create a database on); without one they are skipped, but
#     not in CI, where a missing server is a failure
#   ois-filter (Tools/)
#   the server over loopback (Server/)
#   the live service checks and the Workbench's online self-test, against
#     services.odata.org: out of our hands, so they warn rather than fail
#   the Device app syncing with the Workbench, as peers
# The windows run under Xvfb when there is no display.
XVFB = $(if $(DISPLAY),,$(shell command -v xvfb-run >/dev/null 2>&1 && echo xvfb-run -a))
ODATAKIT_RUN = LD_LIBRARY_PATH="$(CURDIR)/obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" PATH="$(CURDIR)/obj:$$PATH" AVAHI_COMPAT_NOWARN=1

check::
	AVAHI_COMPAT_NOWARN=1 $(MAKE) -C Tests run-tests
	@for server in POSTGRES_URL MYSQL_URL MARIADB_URL; do \
	  if [ -z "$$(printenv $$server)" ]; then \
	    if [ -n "$$CI" ]; then echo "check: $$server is not set; the store's SQL tests need it in CI"; exit 1; fi; \
	    echo "check: no $$server: its SQL tests are skipped"; \
	  fi; \
	done
	@if [ -n "$$POSTGRES_URL$$MYSQL_URL" ]; then \
	  CD_TEST_POSTGRES_URL="$$POSTGRES_URL" CD_TEST_MYSQL_URL="$${MYSQL_URL:+$${MYSQL_URL%/*}/oistest}" \
	    $(MAKE) -C Tests run-tests || exit 1; fi
	@if [ -n "$$MARIADB_URL" ]; then \
	  CD_TEST_MYSQL_URL="$${MARIADB_URL%/*}/oistest" $(MAKE) -C Tests run-tests || exit 1; fi
	$(MAKE) -C Tools check
	$(MAKE) -C Server check
	$(MAKE) -C Tests/Live live || echo "::warning::the live service checks failed (services.odata.org)"
	cd Examples/Workbench && $(ODATAKIT_RUN) $(XVFB) ./Workbench.app/Workbench --self-test \
	  || echo "::warning::the Workbench's online self-test failed"
	@if [ -n "$(ODATAKIT_PEERS)" ]; then \
	  $(ODATAKIT_RUN) XVFB="$(XVFB)" Scripts/peer-sync-check.sh \
	    Examples/Workbench/Workbench.app/Workbench Examples/DeviceDesktop/DeviceDesktop.app/DeviceDesktop || exit 1; \
	else echo "check: devices nearby are not synced with here yet: the peer sync check is skipped"; fi
