# pkgsrc packages

Packages for AutumnBSD that are not in pkgsrc yet. Each directory is laid out like a pkgsrc package; to build one, copy it into the same category of a pkgsrc tree:

```sh
cp -R pkgsrc/x11/akture /usr/pkgsrc/x11/
cd /usr/pkgsrc/x11/akture
make install
```

- [x11/akture](x11/akture): the Akture display manager, developed in [Serusion/Akture](https://github.com/Serusion/Akture)
