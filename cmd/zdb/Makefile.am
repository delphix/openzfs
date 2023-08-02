# Unconditionally enable debugging for zdb
zdb_CPPFLAGS = $(AM_CPPFLAGS) $(FORCEDEBUG_CPPFLAGS)
zdb_CFLAGS   = $(AM_CFLAGS) $(LIBCRYPTO_CFLAGS)

sbin_PROGRAMS += zdb
CPPCHECKTARGETS += zdb

zdb_SOURCES = \
	%D%/zdb.c \
	%D%/zdb_il.c \
	%D%/../libzoa_util/libzoa_util.c \
	%D%/zdb.h

zdb_LDADD = \
	lib/libzpool.la \
	lib/libzfs_core.la \
	lib/libnvpair.la

zdb_LDADD += $(LIBCRYPTO_LIBS)

if BUILD_RUST
zdb_LDADD += -lzoa
zdb_LDFLAGS = -L$(abs_top_builddir)/cmd/zfs_object_agent/$(RUSTDIR)
zdb_CFLAGS += -DHAVE_LIBZOA
endif

# include $(top_srcdir)/config/CppCheck.am
