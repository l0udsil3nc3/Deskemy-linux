# AppImage

The Linux deliverable's build recipe. Two files: `make-appdir.sh` (the
AppDir assembly — its header comment carries the bundling rules: what gets
included, what must stay out and why) and this README (the whole pipeline).

Build inside the Fedora distrobox (`deskemy-build`) — never on the
immutable host. Any distro with libmpv + binutils will do for step 2.

## Build

**1. Compile the release binary**

```sh
podman exec -i --user 1000:1000 deskemy-build \
  bash -lc 'cd <repo>/app && cargo build --release'
```

**2. Assemble the AppDir** (as the normal user; writes `<repo>/Deskemy.AppDir`,
~286 MB, gitignored):

```sh
./packaging/appimage/make-appdir.sh
```

**3. Pack it** — appimagetool must run as **root** (its self-extraction fails
as uid 1000), then hand the artifact back to the desktop user:

```sh
podman exec -i --user 0:0 -e ARCH=x86_64 deskemy-build \
  bash -lc '<appimagetool> <repo>/Deskemy.AppDir <repo>/Deskemy-<ver>-x86_64.AppImage && \
            chown 1000:1000 <repo>/Deskemy-<ver>-x86_64.AppImage'
```

appimagetool: <https://github.com/AppImage/AppImageKit/releases>
(ours lives at `~/.cache/appimage-tools/appimagetool`).

## Verify

Launch it as the desktop user with the session bus available (a bare
`podman exec` as root drops `DBUS_SESSION_BUS_ADDRESS` and breaks D-Bus
users of the app, the folder picker first among them — see issue #10), and
check the log for the whole chain coming up:

```
INFO deskemy: renderer renderer=skia-opengl
INFO deskemy::video: OpenGL context version=4.6 … renderer=…
INFO deskemy::video: mpv rendering into Slint's OpenGL context
```

`DESKEMY_DATA_DIR` picks the library directory. The desktop session sets it
(`~/deskemy-data`); without it the app falls back to
`~/.local/share/com.spooksy.deskemy/` — an easy way to mistake a fresh
database for a broken import.

## Known noise (benign)

- `desktop-file-validate`: "more than one main category" hint.
- `Cannot load libcuda.so.1` on non-NVIDIA machines (mpv's probe).
- The clipboard falls back to X11 when the compositor lacks
  `ext-data-control` (warns in the log).
