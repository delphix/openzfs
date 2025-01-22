dnl #
dnl # Determine if tools required for the agent are installed
dnl #
AC_DEFUN([ZFS_AC_CONFIG_ALWAYS_AGENT], [
	AC_MSG_CHECKING([for agent build tools])
	AS_IF([cargo &>/dev/null && PATH=$PATH:/usr/local/go/bin go version &>/dev/null],
		[ac_agent_tools="yes"], [ac_agent_tools="no"])

	AC_MSG_RESULT([$ac_agent_tools])
	AM_CONDITIONAL([BUILD_AGENT], [test "x$ac_agent_tools" = "xyes"])
])
