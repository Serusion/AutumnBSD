#!@RCD_SCRIPTS_SHELL@
#
# $NetBSD$
#
# PROVIDE: akture
# REQUIRE: DAEMON LOGIN wscons
# KEYWORD: shutdown

if [ -f /etc/rc.subr ]; then
	. /etc/rc.subr
fi

name="akture"
rcvar=${name}
command="@PREFIX@/sbin/${name}"
required_files="@PREFIX@/libexec/akture-greeter"

if [ -f /etc/rc.subr ]; then
	load_rc_config ${name}
	run_rc_command "$1"
else
	echo -n " ${name}"
	${command} ${akture_flags}
fi
