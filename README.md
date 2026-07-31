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
