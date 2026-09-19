# exeuntu

Create an exe.dev VM from the published Arch Linux image:

```sh
ssh exe.dev new --image=ghcr.io/rnbguy/exearch
```

This branch ports the [exe.dev](https://exe.dev/) default base image to Arch Linux
x86_64. It is kitted-out for developers and includes systemd.

We believe that minimal containers make for terrible developer (and agent)
experiences, so exeuntu includes a lot of stuff, mostly from pacman and the AUR.

You can build exeuntu with Docker, but running it, including systemd,
is difficult with Docker.

The publishing workflow rebuilds the runtime stage with fresh official packages
and publishes the image. It supports branch pushes, manual
runs, and a weekly refresh. GitHub only activates scheduled and manual workflows
when the workflow file exists on the repository's default branch; copy
`.github/workflows/publish-archlinux.yaml` there to enable those triggers. The
workflow explicitly checks out `archlinux` for scheduled and manual builds.

AUR recipe commits are pinned in the Dockerfile and must be updated deliberately.
This does not freeze Arch's official packages or make the entire image reproducible.
The image includes the prebuilt `yay-bin` AUR helper.
