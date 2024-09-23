libgcp_sdk_so_SOURCES = $(wildcard *.go *.sum *.mod)

dist_noinst_DATA = $(libgcp_sdk_so_SOURCES)

libgcp_sdk.so: $(libgcp_sdk_so_SOURCES)
	go build -o libgcp_sdk.so -buildmode=c-shared main.go

all: \
	libgcp_sdk.so

install-exec-hook:
	cp libgcp_sdk.so $(DESTDIR)$(libdir)/libgcp_sdk.so
