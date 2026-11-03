# pkgsrc packages

Packages for AutumnBSD that are not in pkgsrc yet. Each directory is laid out like a pkgsrc package; to build one, copy it, and the packages it depends on, into the same categories of a pkgsrc tree:

```sh
cp -R pkgsrc/fonts/autumn-fonts /usr/pkgsrc/fonts/
cp -R pkgsrc/x11/akture /usr/pkgsrc/x11/
cd /usr/pkgsrc/x11/akture
make install
```

- [fonts/autumn-fonts](fonts/autumn-fonts): Outfit and Zen Kaku Gothic New, the fonts of AutumnBSD, from Google Fonts
- [x11/akture](x11/akture): the Akture display manager, developed in [Serusion/Akture](https://github.com/Serusion/Akture); it depends on fonts/autumn-fonts
