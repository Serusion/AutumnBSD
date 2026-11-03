# $NetBSD$

DISTNAME=	akture-0.0.20261103.1
CATEGORIES=	x11
MASTER_SITES=	${MASTER_SITE_GITHUB:=Serusion/}
GITHUB_PROJECT=	Akture
GITHUB_TAG=	45e61d809bd9b61bc3053adaf1a42d1f8aa000af

MAINTAINER=	pkgsrc-users@NetBSD.org
HOMEPAGE=	https://github.com/Serusion/Akture
COMMENT=	Lightweight X11 display manager with privilege separation
LICENSE=	2-clause-bsd

# kqueue(2), setusercontext(3) and OpenPAM.
ONLY_FOR_PLATFORM=	NetBSD-*-* FreeBSD-*-*

WRKSRC=			${WRKDIR}/${GITHUB_PROJECT}-${GITHUB_TAG}
USE_BSD_MAKEFILE=	yes
USE_TOOLS+=		pkg-config
BUILD_DIRS=		akture akture-greeter akture-conv
AUTO_MKDIRS=		yes

MAKE_FLAGS+=	AKTURE_PREFIX=${PREFIX}
MAKE_FLAGS+=	AKTURE_ETCDIR=${PKG_SYSCONFDIR}
MAKE_FLAGS+=	AKTURE_DBDIR=${VARBASE}/db/akture
MAKE_FLAGS+=	AKTURE_RUNDIR=${VARBASE}/run/akture
MAKE_FLAGS+=	AKTURE_XSERVER=${X11BASE}/bin/X
MAKE_FLAGS+=	AKTURE_FONT_UI=${AKTURE_FONT_UI}
MAKE_FLAGS+=	AKTURE_FONT_CLOCK=${AKTURE_FONT_CLOCK}
MAKE_FLAGS+=	MKDEBUG=no

# The default fonts, from fonts/autumn-fonts.
DEPENDS+=		autumn-fonts-[0-9]*:../../fonts/autumn-fonts
AKTURE_FONT_UI=		${PREFIX}/share/fonts/X11/TTF/Outfit-VariableFont_wght.ttf
AKTURE_FONT_CLOCK=	${PREFIX}/share/fonts/X11/TTF/ZenKakuGothicNew-Light.ttf

PKG_SYSCONFSUBDIR=	akture
EGDIR=			${PREFIX}/share/examples/akture
BUILD_DEFS+=		VARBASE SYSCONFBASE

# The greeter runs as this user; the name is compiled into Akture.
PKG_GROUPS=		_akture
PKG_USERS=		_akture:_akture
PKG_GECOS._akture=	Akture greeter
PKG_HOME._akture=	${VARBASE}/db/akture

RCD_SCRIPTS=		akture
MAKE_DIRS+=		${PKG_SYSCONFDIR}/sessions ${PKG_SYSCONFDIR}/hooks.d
OWN_DIRS_PERMS+=	${VARBASE}/db/akture \
			${REAL_ROOT_USER} ${REAL_ROOT_GROUP} 0755
CONF_FILES+=		${EGDIR}/akture.conf ${PKG_SYSCONFDIR}/akture.conf
CONF_FILES+=		${EGDIR}/sessions/fluxbox \
			${PKG_SYSCONFDIR}/sessions/fluxbox
CONF_FILES+=		${EGDIR}/pam.d/akture ${SYSCONFBASE}/pam.d/akture
CONF_FILES+=		${EGDIR}/pam.d/akture-autologin \
			${SYSCONFBASE}/pam.d/akture-autologin
# Hooks run as root: only root may write them.
CONF_FILES_PERMS+=	${EGDIR}/hooks.d/50-aprefetch \
			${PKG_SYSCONFDIR}/hooks.d/50-aprefetch \
			${REAL_ROOT_USER} ${REAL_ROOT_GROUP} 0755
# The greeter records here the resolutions that lack a background.
REQD_FILES_PERMS+=	${EGDIR}/resolutions \
			${VARBASE}/db/akture/resolutions \
			_akture _akture 0644

INSTALLATION_DIRS+=	share/akture/backgrounds

SUBST_CLASSES+=		paths
SUBST_STAGE.paths=	pre-configure
SUBST_MESSAGE.paths=	Adjusting paths for pkgsrc.
SUBST_FILES.paths=	etc/akture.conf etc/sessions/fluxbox
SUBST_FILES.paths+=	akture/akture.8 akture/akture.conf.5
SUBST_FILES.paths+=	akture-greeter/akture-greeter.8
SUBST_FILES.paths+=	akture-conv/akture-conv.1
SUBST_SED.paths=	-e 's,/usr/pkg/,${PREFIX}/,g'
SUBST_SED.paths+=	-e 's,/etc/akture,${PKG_SYSCONFDIR},g'
SUBST_SED.paths+=	-e 's,/usr/share/akture/fonts/Outfit.ttf,${AKTURE_FONT_UI},g'
SUBST_SED.paths+=	-e 's,/usr/share/akture/fonts/ZenKakuGothicNew-Light.ttf,${AKTURE_FONT_CLOCK},g'
SUBST_SED.paths+=	-e 's,/usr/share/akture,${PREFIX}/share/akture,g'
SUBST_SED.paths+=	-e 's,/usr/libexec/akture-greeter,${PREFIX}/libexec/akture-greeter,g'
SUBST_SED.paths+=	-e 's,/usr/X11R7/bin/X,${X11BASE}/bin/X,g'

post-install:
	${INSTALL_DATA} ${WRKSRC}/etc/akture.conf ${DESTDIR}${EGDIR}
	${INSTALL_DATA} ${WRKSRC}/etc/sessions/fluxbox \
		${DESTDIR}${EGDIR}/sessions
	${INSTALL_DATA} ${WRKSRC}/etc/pam.d/akture \
		${WRKSRC}/etc/pam.d/akture-autologin ${DESTDIR}${EGDIR}/pam.d
	${INSTALL_SCRIPT} ${WRKSRC}/autumnbsd/hooks.d/50-aprefetch \
		${DESTDIR}${EGDIR}/hooks.d
	${INSTALL_DATA} /dev/null ${DESTDIR}${EGDIR}/resolutions

.include "../../graphics/freetype2/buildlink3.mk"
.include "../../graphics/png/buildlink3.mk"
.include "../../mk/jpeg.buildlink3.mk"
.include "../../x11/libxcb/buildlink3.mk"
.include "../../x11/libxkbcommon/buildlink3.mk"
.include "../../x11/pixman/buildlink3.mk"
.include "../../mk/pam.buildlink3.mk"
.include "../../mk/bsd.pkg.mk"
