# FOG Operating System (FOS)
This is the operating system environment used for imaging with FOG. This is a linux based operating system with all the scripts and programs required for perform imaging tasks.

Latest build status: [![Build status](https://badge.buildkite.com/5af7ed69568b5cf1f7092156156a4ca41ba46f6de0fab809ae.svg)](https://buildkite.com/fogproject/fos)

# What does this docker image do?
Builds FOG Operating System (FOS) inits as well as kernels used by fog.

# What do we need?
1. You'll need to install docker on your system.
2. You'll need to install git on your system.
3. You'll need to clone the fos repository.

# How do I get the fos repository?
Pull the fos repository with:

```
git clone https://github.com/fogproject/fos
```

# How do I get the docker image?
Pull the fos-builder image with:
```
docker pull fogproject/fos-builder
```

##### NOTES:
1. This container does not contain FOS or the kernels, It is just a full build environment.
2. `/path/to/fos/repo` is not the real path, this is the path to the fos repository local to the machine you plan on running this on. Typically this would be something like `~/fos`. This is the only path you will need to change to build.

#### How to build?
To build the FOS and/or kernels, once pulled:

##### Build Everything
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -n
```
##### Build only all inits
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nf
```
##### Build only all kernels
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nk
```
##### Build x64 bit init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa x64
```
##### Build 32 bit (x86) init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa x86
```
##### Build x64 bit kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka x64
```
##### Build 32 bit (x86) kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka x86
```
##### Build ARM 64 bit init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa arm64
```
##### Build ARM 32 bit init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa arm
```
##### Build ARM 64 bit kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka arm64
```
##### Build ARM 32 bit kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka arm
```
