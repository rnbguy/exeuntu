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

The `yay-bin` AUR recipe commit is pinned and must be updated deliberately.
This does not freeze Arch's official packages or make the entire image reproducible.
The image includes the prebuilt `yay-bin` AUR helper.

Oh My Pi (`omp`) follows the latest `oh-my-pi-bin` AUR recipe. Every CI build,
including the weekly refresh, rebuilds the runtime stage without cache to pick
up the latest version packaged in the AUR. Its
`~/.omp/agent/models.yml` configures the VM-local `llm` integration without API
keys. OMP discovers models from `https://llm.int.exe.xyz/v1/models` and sends
requests to `/v1/chat/completions`, including for custom providers exposed by
the integration. Discovery happens at runtime, not during the image build, and
requires the integration to be attached to the VM.

Inside the VM, run `omp models refresh`, then `omp models exe-dev` to see the
available models. Select one with `omp --model exe-dev/<model-id>`. For a
differently named integration, change the hostname in `~/.omp/agent/models.yml`.
Update `omp` through `yay`; `exeuntu update pi` manages the separate upstream
`pi` binary.
