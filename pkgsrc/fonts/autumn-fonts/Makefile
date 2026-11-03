# $NetBSD$

PKGNAME=				autumn-fonts-20261102
CATEGORIES=				fonts
MASTER_SITES=				${MASTER_SITE_GITHUB:=google/fonts/raw/${GF_COMMIT}/ofl/zenkakugothicnew/}
DIST_SUBDIR=				${PKGNAME_NOREV}
DISTFILES=				ZenKakuGothicNew-Light.ttf
DISTFILES+=				ZenKakuGothicNew-Regular.ttf
DISTFILES+=				ZenKakuGothicNew-Medium.ttf
DISTFILES+=				ZenKakuGothicNew-Bold.ttf
DISTFILES+=				ZenKakuGothicNew-Black.ttf
DISTFILES+=				OFL-ZenKakuGothicNew.txt
DISTFILES+=				Outfit-VariableFont_wght.ttf
DISTFILES+=				OFL-Outfit.txt
# Files that are saved under another name than in google/fonts.
SITES.OFL-ZenKakuGothicNew.txt=		-${GF_OFL}/zenkakugothicnew/OFL.txt
SITES.Outfit-VariableFont_wght.ttf=	-${GF_OFL}/outfit/Outfit%5Bwght%5D.ttf
SITES.OFL-Outfit.txt=			-${GF_OFL}/outfit/OFL.txt

MAINTAINER=	pkgsrc-users@NetBSD.org
HOMEPAGE=	https://github.com/Serusion/AutumnBSD
COMMENT=	Outfit and Zen Kaku Gothic New fonts, as used by AutumnBSD
LICENSE=	ofl-v1.1

# google/fonts at the time of the package.
GF_COMMIT=	2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc
GF_OFL=		${MASTER_SITE_GITHUB}google/fonts/raw/${GF_COMMIT}/ofl

EXTRACT_ONLY=	# empty
WRKSRC=		${WRKDIR}
NO_CONFIGURE=	yes
NO_BUILD=	yes

FONTS_DIRS.ttf=		${PREFIX}/share/fonts/X11/TTF
INSTALLATION_DIRS+=	share/doc/autumn-fonts

do-extract:
	cd ${DISTDIR}/${DIST_SUBDIR} && ${CP} ${DISTFILES} ${WRKSRC}

post-install:
	${INSTALL_DATA} ${WRKSRC}/OFL-Outfit.txt \
		${WRKSRC}/OFL-ZenKakuGothicNew.txt \
		${DESTDIR}${PREFIX}/share/doc/autumn-fonts

.include "../../mk/fonts.mk"
.include "../../mk/bsd.pkg.mk"
