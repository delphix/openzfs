liboci_sdk_so_SOURCES = $(wildcard *.go *.sum *.mod)

dist_noinst_DATA = $(liboci_sdk_so_SOURCES)

liboci_sdk.so: $(liboci_sdk_so_SOURCES)
	go build -o liboci_sdk.so -buildmode=c-shared main.go

all: \
	liboci_sdk.so

install-exec-hook:
	cp liboci_sdk.so $(DESTDIR)$(libdir)/liboci_sdk.so
