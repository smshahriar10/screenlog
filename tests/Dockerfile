# Test image for screenlog: Ubuntu 24.04 with the runtime packages install.sh installs
# plus the test tooling. Built once by `make docker-image`; the tag is the checksum of this file.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Dhaka \
    SCREENLOG_IN_DOCKER=1
# mirror: the exact apt list install.sh installs on a PC (spec section 9 step 2 + jq + libglib2.0-bin)
#   ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core rclone jq libglib2.0-bin
# test-only: everything else below
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ffmpeg xprintidle imagemagick curl x11-utils fonts-dejavu-core rclone jq libglib2.0-bin \
      bash make file ca-certificates util-linux tzdata procps time locales fontconfig \
      shellcheck bats bats-support bats-assert bats-file parallel \
      xvfb xauth x11-xserver-utils; \
    rm -rf /var/lib/apt/lists/*; \
    locale-gen de_DE.UTF-8; \
    mkdir -p /root/.parallel; touch /root/.parallel/will-cite; \
    fc-cache -f
WORKDIR /work
CMD ["make", "test"]
