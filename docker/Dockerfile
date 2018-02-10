FROM debian:9
LABEL maintainer="contact@fogproject.org"

RUN dpkg --add-architecture i386 && apt-get update\
    && DEBIAN_FRONTEND=noninteractive\
    apt-get install -y wget subversion git mercurial meld build-essential rsync libncurses-dev gcc-multilib cpio bc unzip locales texinfo libelf-dev libelf-dev:i386

RUN rm -rf /var/lib/apt/lists/* \
	&& localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

RUN adduser --disabled-password --uid 1000 --gecos "Docker Builder,,," builder
WORKDIR /home/builder
