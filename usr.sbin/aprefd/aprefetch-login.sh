#!/bin/sh
#
#	$NetBSD$
#
# Run by pam_exec(8) from the account part of /etc/pam.d/login, once a
# user is let in on the console: close the boot recording window, record
# the session with aprefd -s to update its profile, and prefetch what the
# last console session of the user read.  pam_exec(8) waits for this
# script, so the replay waits for the boot replay in the background.
# See aprefd(8).
#

PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH

session=${PAM_SERVICE:-login}

[ -n "$PAM_USER" ] && [ -c /dev/aprefetch ] || exit 0
uid=$(id -u -- "$PAM_USER" 2>/dev/null) || exit 0
prof=/var/db/aprefetch/session/$uid-$session.prof

aprefctl boot-done
aprefd -s "$uid" "$session" </dev/null >/dev/null 2>&1
if [ -f "$prof" ]; then
	aprefctl replay -w 30 -b 128m "$prof" </dev/null >/dev/null 2>&1 &
fi
exit 0
