#	$NetBSD$

PROG=	aprefd
SRCS=	aprefd.c aprefio.c
MAN=	aprefd.8

SCRIPTS=	aprefetch-login.sh
SCRIPTSDIR_aprefetch-login.sh=	/usr/libexec

LDADD+=	-lutil -lz
DPADD+=	${LIBUTIL} ${LIBZ}

.include <bsd.prog.mk>
