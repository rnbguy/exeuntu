# Stage 1: Get Chrome/Chromium from chromedp/headless-shell
FROM docker.io/chromedp/headless-shell:stable AS chrome

# Build the guest-facing exeuntu helper.
FROM docker.io/library/golang:1.26.5 AS exeuntu-cli
ARG EXEUNTU_GIT_VERSION=unknown
WORKDIR /src/exeuntu-cli
COPY cli/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -tags osusergo,netgo \
        -ldflags "-X main.gitVersion=${EXEUNTU_GIT_VERSION} -extldflags=-static -s -w" \
        -o /out/exeuntu .

FROM docker.io/library/archlinux:base-devel

# Use Bash by default.
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# Install updates and the full developer package set from Arch's official repos.
RUN pacman -Syu --noconfirm --needed \
		base-devel bash ca-certificates wget ripgrep git jq sqlite curl vim neovim \
		lsof iproute2 less nginx make python python-pip tree net-tools file fd \
		python-pipx psmisc sudo socat openssh libcap unzip util-linux rsync iputils \
		openbsd-netcat openai-codex man-db man-pages mitmproxy systemd systemd-sysvcompat atop \
		btop iotop ncdu glibc-locales glib2 nss libx11 libxcomposite libxdamage libxext libxi \
		libxrandr mesa gtk3 noto-fonts-emoji docker docker-buildx docker-compose \
		imagemagick ffmpeg bubblewrap github-cli dbus tailscale uv inetutils perl sed \
		tar which rust go && \
	# openssh generates host keys during package installation. Do not bake
	# per-image private keys into exeuntu.
	rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && \
	# Allow non-root users to use ping without sudo by granting CAP_NET_RAW.
	setcap cap_net_raw=+ep /usr/bin/ping

COPY --from=exeuntu-cli /out/exeuntu /usr/local/bin/exeuntu

RUN groupadd --gid 1000 exedev && \
	useradd --uid 1000 --gid exedev --create-home --shell /bin/bash \
		--comment "exe.dev user" --groups wheel,docker exedev && \
	printf '%s\n' 'exedev:100000:65536' > /etc/subuid && \
	printf '%s\n' 'exedev:100000:65536' > /etc/subgid && \
	printf '%s\n' \
		'exedev ALL=(ALL) NOPASSWD:ALL' \
		'Defaults:exedev verifypw=any' > /etc/sudoers.d/exedev && \
	chmod 0440 /etc/sudoers.d/exedev && \
	visudo -cf /etc/sudoers && \
	# Manually enable linger so systemd creates /run/user/1000.
	install -d -m 0755 /var/lib/systemd/linger && \
	touch /var/lib/systemd/linger/exedev

USER exedev

WORKDIR /home/exedev

RUN git clone https://aur.archlinux.org/paru.git /home/exedev/paru && \
	cd /home/exedev/paru && \
	makepkg -si --noconfirm --needed && \
	paru --version && \
	paru -S --noconfirm --needed claude-code pi-coding-agent ttf-symbola

USER root

RUN fc-cache -f -v && \
	rm -rf /home/exedev/.cache/paru /home/exedev/.cargo/registry \
		/home/exedev/.cargo/git /home/exedev/paru && \
	pacman -Scc --noconfirm

# Configure systemd
RUN systemctl mask getty.target \
		systemd-random-seed.service \
		atop-rotate.timer \
		systemd-resolved.service \
		systemd-remount-fs.service \
		systemd-sysusers.service \
		systemd-firstboot.service \
		systemd-network-generator.service \
		systemd-networkd-wait-online.service \
		systemd-update-done.service \
		systemd-update-utmp.service \
		systemd-journal-catalog-update.service \
		modprobe@.service \
		systemd-modules-load.service \
		systemd-udevd.service \
		systemd-udevd-control.socket \
		systemd-udevd-kernel.socket \
		systemd-udev-trigger.service \
		systemd-udev-settle.service \
		ldconfig.service \
		systemd-ask-password-console.path \
		systemd-ask-password-wall.path \
		sshd-vsock.socket \
		sshd.service && \
	# systemd-logind is disabled but not masked so it can populate XDG runtime sockets.
	systemctl disable systemd-logind.service \
		tailscaled.service nginx.service atop.service atopacct.service \
		systemd-machine-id-commit.service systemd-sysctl.service && \
	systemctl enable docker.socket && \
	mkdir -p /etc/systemd/system.conf.d && \
	echo '[Manager]' > /etc/systemd/system.conf.d/container-overrides.conf && \
	echo 'LogLevel=info' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	echo 'LogTarget=console' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	echo 'SystemCallArchitectures=native' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	echo 'DefaultOOMPolicy=continue' >> /etc/systemd/system.conf.d/container-overrides.conf && \
	mkdir -p /etc/systemd/journald.conf.d && \
	echo '[Journal]' > /etc/systemd/journald.conf.d/persistent.conf && \
	echo 'Storage=persistent' >> /etc/systemd/journald.conf.d/persistent.conf && \
	systemctl set-default multi-user.target

# Bake /etc/fstab so systemd-growfs@-.service resizes the root filesystem on
# first boot after the disk is grown.
RUN echo '/dev/vda / ext4 defaults,x-systemd.growfs 0 1' > /etc/fstab

# Stop systemd wiping /tmp at boot; that races non-systemd users of the system
# that also run at boot.
COPY tmpfiles-tmp.conf /etc/tmpfiles.d/tmp.conf

ENV EXEUNTU=1

# Copy the self-contained Chrome bundle from chromedp/headless-shell
COPY --from=chrome /headless-shell /headless-shell
ENV PATH="/usr/local/bin:/headless-shell:${PATH}"

RUN mkdir -p /home/exedev /home/exedev/.config/shelley && \
    chown exedev:exedev /home/exedev /home/exedev/.config /home/exedev/.config/shelley

USER exedev

WORKDIR /home/exedev

# Update PATH in .bashrc to include .local/bin and set XDG_RUNTIME_DIR for systemd user services
# XDG paths are not autopopulated despite the presense of libpam-systemd. Manually add them here.
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.profile

# Configure git to use 'main' as default branch name
RUN git config --global init.defaultBranch main

# Switch back to root to install systemd service
USER root

# Add custom MOTD to exedev's .bashrc.
COPY motd-snippet.bash /tmp/motd-snippet.bash
RUN cat /tmp/motd-snippet.bash >> /home/exedev/.bashrc && rm /tmp/motd-snippet.bash

# Create systemd socket and service for Shelley (socket activation).
# The shelley binary itself is installed at vm creation.
COPY shelley.socket /etc/systemd/system/shelley.socket
COPY shelley.service /etc/systemd/system/shelley.service
RUN chmod 644 /etc/systemd/system/shelley.socket /etc/systemd/system/shelley.service && \
    systemctl enable shelley.socket

# Create systemd oneshot service for /exe.dev/setup script
COPY exe-setup.service /etc/systemd/system/exe-setup.service
RUN chmod 644 /etc/systemd/system/exe-setup.service && \
    systemctl enable exe-setup.service

# TODO(crawshaw/philip): This is called init so that exetini decides
# this wrapper script is an init, and exec's it rather than forking it.
# It would be better if you could indicate that via an env variable or something.
COPY init-wrapper.sh /usr/local/bin/init

# Create config directories for LLM agents
RUN mkdir -p /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi && \
    chown -R exedev:exedev /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi

# Copy LLM agent instructions to Claude, Codex, and Shelley config directories
# Shelley uses ~/.config/shelley/ (XDG convention, directory already created above)
COPY AGENTS.md /home/exedev/.config/shelley/AGENTS.md
RUN chown exedev:exedev /home/exedev/.config/shelley/AGENTS.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.claude/CLAUDE.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.codex/AGENTS.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.pi/AGENTS.md

# Install the pi exe.dev extension (LLM integration + environment context).
# The bundled public catalog supplies pricing and compatibility metadata only;
# reflection-discovered integrations supply every model and provider route.
COPY pi-extension/ /home/exedev/.pi/agent/extensions/exe-dev/
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --max-time 30 \
      https://exe.dev/llm-gateway-models.json \
      -o /home/exedev/.pi/agent/extensions/exe-dev/catalog.json && \
    jq -e '.schemaVersion | numbers' \
      /home/exedev/.pi/agent/extensions/exe-dev/catalog.json > /dev/null
RUN chown -R exedev:exedev /home/exedev/.pi/agent

# Pre-install fd at the path pi checks first (~/.pi/agent/bin/fd), so pi
# doesn't try (and on a fresh VM, often fail with a GitHub API 403) to
# download it on first use.
RUN mkdir -p /home/exedev/.pi/agent/bin && \
    ln -s /usr/bin/fd /home/exedev/.pi/agent/bin/fd && \
    chown exedev:exedev /home/exedev/.pi/agent/bin

# Custom nginx config and index page (nginx is installed but disabled by default)
RUN mkdir -p /etc/nginx/conf.d
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /var/www/html/index.html
RUN chmod 644 /var/www/html/index.html

# Install xterm-ghostty terminfo for Ghostty terminal support
COPY xterm-ghostty.terminfo /tmp/xterm-ghostty.terminfo
RUN tic -x - < /tmp/xterm-ghostty.terminfo && rm /tmp/xterm-ghostty.terminfo

# Expose the web server ports
EXPOSE 8000 9999

LABEL "exe.dev/login-user"="exedev"
LABEL "exe.dev/install-shelley"="true"
CMD ["/usr/local/bin/init"]
