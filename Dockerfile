# syntax=docker/dockerfile:1

# Stage 1: Get Chrome/Chromium from chromedp/headless-shell
FROM docker.io/chromedp/headless-shell:stable AS chrome

# Build the guest-facing exeuntu helper.
FROM docker.io/library/golang:1.27.1 AS exeuntu-cli
ARG EXEUNTU_GIT_VERSION=unknown
WORKDIR /src/exeuntu-cli
COPY cli/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -tags osusergo,netgo \
        -ldflags "-X main.gitVersion=${EXEUNTU_GIT_VERSION} -extldflags=-static -s -w" \
        -o /out/exeuntu .

FROM docker.io/library/archlinux:base-devel AS runtime

# Use Bash by default.
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# Install updates and the full developer package set from Arch's official repos.
# claude, codex, pi, and opencode are installed later via `exeuntu update`,
# matching upstream and keeping one owner for each agent binary.
RUN pacman -Syu --noconfirm --needed \
		base-devel bash ca-certificates wget ripgrep git jq sqlite curl vim neovim \
		lsof iproute2 less nginx make python python-pip tree net-tools file fd \
		python-pipx psmisc sudo socat openssh libcap unzip util-linux rsync iputils \
		openbsd-netcat man-db man-pages mitmproxy systemd systemd-sysvcompat atop \
		btop iotop ncdu glibc-locales glib2 nss libx11 libxcomposite libxdamage libxext libxi \
		libxrandr mesa gtk3 noto-fonts noto-fonts-extra noto-fonts-emoji docker docker-buildx docker-compose \
		imagemagick ffmpeg bubblewrap github-cli dbus tailscale uv inetutils perl sed \
		tar which rust go && \
	# openssh generates host keys during package installation. Do not bake
	# per-image private keys into exeuntu.
	rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub && \
	# Allow non-root users to use ping without sudo by granting CAP_NET_RAW.
	setcap cap_net_raw=+ep /usr/bin/ping && \
	pacman -Scc --noconfirm

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

# Pin AUR recipes, including their upstream source checksums. Update these
# commits deliberately when updating AUR packages; official packages still roll.
RUN git clone https://aur.archlinux.org/yay-bin.git /home/exedev/yay-bin && \
	cd /home/exedev/yay-bin && \
	git checkout --detach 13e0a4754d106a9252b7479bf1b370fbe454fc48 && \
	makepkg -si --noconfirm --needed && \
	yay --version && \
	cd /home/exedev && \
	rm -rf /home/exedev/yay-bin && \
	sudo pacman -Scc --noconfirm

USER root

RUN fc-cache -f -v

# Install the DuckDB CLI (a single static binary).
ARG DUCKDB_VERSION=1.5.5
RUN case "$(uname -m)" in \
		x86_64) ARCH=amd64 ;; \
		aarch64|arm64) ARCH=arm64 ;; \
		*) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
	esac && \
	curl -fsSL "https://install.duckdb.org/v${DUCKDB_VERSION}/duckdb_cli-linux-${ARCH}.zip" -o /tmp/duckdb.zip && \
	unzip -o /tmp/duckdb.zip -d /usr/local/bin duckdb && \
	rm /tmp/duckdb.zip && \
	chmod 0755 /usr/local/bin/duckdb && \
	duckdb --version

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

# Set up interactive shells and noninteractive login shells. Arch's default
# .bash_profile only sources .bashrc, which returns early outside interactive use.
# exe.dev logins also need the runtime directory when PAM has not populated it.
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/exedev/.bashrc && \
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.bashrc && \
    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' \
        'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> /home/exedev/.profile && \
    printf '%s\n' '[[ -f ~/.profile ]] && . ~/.profile' \
        '[[ -f ~/.bashrc ]] && . ~/.bashrc' > /home/exedev/.bash_profile

# Configure git to use 'main' as default branch name
RUN git config --global init.defaultBranch main

# Pre-install the DuckDB extensions the look integration's usage text needs
# (httpfs for s3://, iceberg for iceberg_scan; iceberg loads avro itself) into
# ~/.duckdb/extensions, so the first query works without a runtime download.
# Extensions are per-user and per-DuckDB-version, so this must run as exedev
# after the CLI.
RUN duckdb -c "INSTALL httpfs; INSTALL iceberg; INSTALL avro;" && \
    duckdb -c "SET autoinstall_known_extensions=false; LOAD httpfs; LOAD iceberg; LOAD avro;"

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

# Create config directories for LLM agents. The OpenCode plugin has no
# dependencies; pre-creating node_modules avoids a first-run SDK install.
RUN mkdir -p \
      /home/exedev/.claude \
      /home/exedev/.codex \
      /home/exedev/.pi \
      /home/exedev/.config/opencode/plugins \
      /home/exedev/.config/opencode/node_modules && \
    chown -R exedev:exedev /home/exedev/.claude /home/exedev/.codex /home/exedev/.pi /home/exedev/.config/opencode

# Disable OpenCode's own updater; exeuntu owns the system binary.
COPY opencode.json /home/exedev/.config/opencode/opencode.json
# Dynamically register models from attached exe.dev LLM integrations.
COPY opencode-plugin/exe-dev.js /home/exedev/.config/opencode/plugins/exe-dev.js
# OpenCode otherwise installs its plugin SDK on first start even though this
# dependency-free plugin does not import it. A minimal lock avoids that fetch.
COPY opencode-plugin/runtime-dependencies.json /home/exedev/.config/opencode/package.json
COPY opencode-plugin/runtime-lock.json /home/exedev/.config/opencode/package-lock.json
RUN chown exedev:exedev \
      /home/exedev/.config/opencode/opencode.json \
      /home/exedev/.config/opencode/package.json \
      /home/exedev/.config/opencode/package-lock.json \
      /home/exedev/.config/opencode/plugins/exe-dev.js

# Copy LLM agent instructions to Claude, Codex, OpenCode, Pi, and Shelley config directories
# Shelley and OpenCode use ~/.config/ (XDG convention).
COPY AGENTS.md /home/exedev/.config/shelley/AGENTS.md
RUN chown exedev:exedev /home/exedev/.config/shelley/AGENTS.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.claude/CLAUDE.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.codex/AGENTS.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.config/opencode/AGENTS.md && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.pi/AGENTS.md

# Install Claude, Codex, and OpenCode through exeuntu's direct updaters.
USER root
RUN exeuntu update claude && \
    test -x /usr/local/bin/claude && \
    /usr/local/bin/claude --version
RUN exeuntu update codex && \
    test -x /usr/local/bin/codex && \
    /usr/local/bin/codex --version
RUN exeuntu update opencode && \
    test -x /usr/local/bin/opencode && \
    HOME=/tmp/opencode-smoke /usr/local/bin/opencode --version && \
    rm -rf /tmp/opencode-smoke

# Install pi (pi-coding-agent) through exeuntu's updater.
ARG PI_VERSION=
USER exedev
RUN if [ -n "${PI_VERSION}" ]; then \
        exeuntu update pi --home /home/exedev --version "${PI_VERSION}"; \
    else \
        exeuntu update pi --home /home/exedev; \
    fi && \
    test -x /home/exedev/.local/bin/pi && \
    /home/exedev/.local/bin/pi --version
USER root
RUN ln -sf /home/exedev/.local/bin/pi /usr/local/bin/pi

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
COPY nginx-main.conf /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /var/www/html/index.html
RUN chmod 644 /var/www/html/index.html && nginx -t

# Install xterm-ghostty terminfo for Ghostty terminal support
COPY xterm-ghostty.terminfo /tmp/xterm-ghostty.terminfo
RUN tic -x - < /tmp/xterm-ghostty.terminfo && rm /tmp/xterm-ghostty.terminfo

# Install the prebuilt Oh My Pi release independently of upstream Pi, whose
# binary is owned by exeuntu update. Follow the latest AUR recipe; CI rebuilds
# this stage without cache so scheduled builds pick up new releases.
USER exedev
RUN git clone https://aur.archlinux.org/oh-my-pi-bin.git /home/exedev/oh-my-pi-bin && \
    cd /home/exedev/oh-my-pi-bin && \
    makepkg -si --noconfirm --needed && \
    omp --version && \
    cd /home/exedev && \
    rm -rf /home/exedev/oh-my-pi-bin && \
    sudo pacman -Scc --noconfirm

RUN mkdir -p /home/exedev/.omp/agent && \
    ln -s /home/exedev/.config/shelley/AGENTS.md /home/exedev/.omp/agent/AGENTS.md
COPY --chown=exedev:exedev omp-models.yml /home/exedev/.omp/agent/models.yml

USER root

# Empty the machine ID baked in by package configuration, so each VM built from
# this image generates its own on first boot. A shared one defeats anything that
# assumes machine IDs are unique, such as systemd's FixedRandomDelay=. Empty
# rather than removed: systemd reads an absent /etc/machine-id as a first boot
# and presets all units, re-enabling the ones disabled above. Keep this last, so
# that no package install bakes in a new ID.
RUN : > /etc/machine-id && \
	ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Expose the web server ports
EXPOSE 8000 9999

LABEL "exe.dev/login-user"="exedev"
LABEL "exe.dev/install-shelley"="true"
CMD ["/usr/local/bin/init"]
