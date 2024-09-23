zdb_CPPFLAGS = $(AM_CPPFLAGS) $(LIBZPOOL_CPPFLAGS)
zdb_CFLAGS   = $(AM_CFLAGS) $(LIBCRYPTO_CFLAGS)

sbin_PROGRAMS   += zdb
CPPCHECKTARGETS += zdb

zdb_SOURCES = \
	%D%/zdb.c \
	%D%/zdb_il.c \
	%D%/../libzoa_util/libzoa_util.c \
	%D%/zdb.h

zdb_LDADD = \
	lib/libzdb.la \
	lib/libzpool.la \
	lib/libzfs_core.la \
	lib/libnvpair.la

zdb_LDADD += $(LIBCRYPTO_LIBS)

if BUILD_AGENT
zdb_LDADD += -lzoa
zdb_LDFLAGS = -L$(abs_top_builddir)/cmd/zfs_object_agent/$(RUSTDIR)
zdb_CFLAGS += -DHAVE_LIBZOA
zdb_LDADD += -loci_sdk -lgcp_sdk
zdb_LDFLAGS += -L$(abs_top_builddir)/lib/liboci_sdk -L$(abs_top_builddir)/lib/libgcp_sdk
endif

# include $(top_srcdir)/config/CppCheck.am
