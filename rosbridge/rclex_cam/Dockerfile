FROM osrf/ros:humble-desktop as base
SHELL ["/bin/bash", "-c"]

ENV ROS_DISTRO=humble
ENV WORKDIR=/usr/src/app

RUN sudo apt-get update \
    && sudo apt-get install -y python3-catkin-pkg ros-humble-xacro ros-humble-joint-state-publisher-gui ros-humble-gazebo-ros-pkgs

ENV OTP_VERSION=27.1.1 REBAR3_VERSION=3.23.0
RUN /bin/sh -c set -eux; apt-get update; apt-get install -y --no-install-recommends ca-certificates curl gnupg netbase sq wget ; rm -rf /var/lib/apt/lists/*
RUN /bin/sh -c set -eux; apt-get update; apt-get install -y --no-install-recommends git mercurial openssh-client subversion procps ; rm -rf /var/lib/apt/lists/*
RUN /bin/sh -c set -ex; apt-get update; apt-get install -y --no-install-recommends autoconf automake bzip2 default-libmysqlclient-dev dpkg-dev file g++ gcc imagemagick libbz2-dev libc6-dev libcurl4-openssl-dev libdb-dev libevent-dev libffi-dev libgdbm-dev libglib2.0-dev libgmp-dev libjpeg-dev libkrb5-dev liblzma-dev libmagickcore-dev libmagickwand-dev libmaxminddb-dev libncurses5-dev libncursesw5-dev libpng-dev libpq-dev libreadline-dev libsqlite3-dev libssl-dev libtool libwebp-dev libxml2-dev libxslt-dev libyaml-dev make patch unzip xz-utils zlib1g-dev ; rm -rf /var/lib/apt/lists/*

RUN /bin/sh -c set -xe && OTP_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${OTP_VERSION}.tar.gz" && OTP_DOWNLOAD_SHA256="315552992ebbc86f27b54b4267616ad49b10fa2ef6bc4ec2a6992f7054c9157e" && runtimeDeps='libodbc1 libsctp1' && buildDeps='unixodbc-dev libsctp-dev ' && apt-get update && apt-get install -y --no-install-recommends $runtimeDeps && apt-get install -y --no-install-recommends $buildDeps && curl -fSL -o otp-src.tar.gz "$OTP_DOWNLOAD_URL" && echo "$OTP_DOWNLOAD_SHA256 otp-src.tar.gz" | sha256sum -c - && export ERL_TOP="/usr/src/otp_src_${OTP_VERSION%%@*}" && mkdir -vp $ERL_TOP && tar -xzf otp-src.tar.gz -C $ERL_TOP --strip-components=1 && rm otp-src.tar.gz && ( cd $ERL_TOP && ./otp_build autoconf && gnuArch="$(dpkg-architecture --query DEB_HOST_GNU_TYPE)" && ./configure --build="$gnuArch" && make -j$(nproc) && make -j$(nproc) docs DOC_TARGETS=chunks && make install install-docs DOC_TARGETS=chunks ) && find /usr/local -name examples | xargs rm -rf && rm -rf $ERL_TOP /var/lib/apt/lists/* # buildkit
ENV REBAR_VERSION=2.6.4
RUN /bin/sh -c set -xe && REBAR_DOWNLOAD_URL="https://github.com/rebar/rebar/archive/${REBAR_VERSION}.tar.gz" && REBAR_DOWNLOAD_SHA256="577246bafa2eb2b2c3f1d0c157408650446884555bf87901508ce71d5cc0bd07" && mkdir -p /usr/src/rebar-src && curl -fSL -o rebar-src.tar.gz "$REBAR_DOWNLOAD_URL" && echo "$REBAR_DOWNLOAD_SHA256 rebar-src.tar.gz" | sha256sum -c - && tar -xzf rebar-src.tar.gz -C /usr/src/rebar-src --strip-components=1 && rm rebar-src.tar.gz && cd /usr/src/rebar-src && ./bootstrap && install -v ./rebar /usr/local/bin/ && rm -rf /usr/src/rebar-src # buildkit
RUN /bin/sh -c set -xe && REBAR3_DOWNLOAD_URL="https://github.com/erlang/rebar3/archive/${REBAR3_VERSION}.tar.gz" && REBAR3_DOWNLOAD_SHA256="00646b692762ffd340560e8f16486dbda840e1546749ee5a7f58feeb77e7b516" && mkdir -p /usr/src/rebar3-src && curl -fSL -o rebar3-src.tar.gz "$REBAR3_DOWNLOAD_URL" && echo "$REBAR3_DOWNLOAD_SHA256 rebar3-src.tar.gz" | sha256sum -c - && tar -xzf rebar3-src.tar.gz -C /usr/src/rebar3-src --strip-components=1 && rm rebar3-src.tar.gz && cd /usr/src/rebar3-src && HOME=$PWD ./bootstrap && install -v ./rebar3 /usr/local/bin/ && rm -rf /usr/src/rebar3-src # buildkit
ENV ELIXIR_VERSION=v1.17.3 LANG=C.UTF-8
RUN /bin/sh -c set -xe && ELIXIR_DOWNLOAD_URL="https://github.com/elixir-lang/elixir/archive/${ELIXIR_VERSION}.tar.gz" && ELIXIR_DOWNLOAD_SHA256="6116c14d5e61ec301240cebeacbf9e97125a4d45cd9071e65e0b958d5ebf3890" && curl -fSL -o elixir-src.tar.gz $ELIXIR_DOWNLOAD_URL && echo "$ELIXIR_DOWNLOAD_SHA256 elixir-src.tar.gz" | sha256sum -c - && mkdir -p /usr/local/src/elixir && tar -xzC /usr/local/src/elixir --strip-components=1 -f elixir-src.tar.gz && rm elixir-src.tar.gz && cd /usr/local/src/elixir && make install clean && find /usr/local/src/elixir/ -type f -not -regex "/usr/local/src/elixir/lib/[^\/]*/lib.*" -exec rm -rf {} + && find /usr/local/src/elixir/ -type d -depth -empty -delete # buildkit

RUN mkdir -p /usr/src/app
WORKDIR ${WORKDIR}
ADD . ${WORKDIR}

RUN source /opt/ros/${ROS_DISTRO}/setup.bash && \
    mix deps.get && \
    mix rclex.gen.msgs

ADD entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]