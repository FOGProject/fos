Builds FOG Operating System (FOS) inits as well as kernels used by fog.

This container does not contain FOS or the kernels, It is just a full build environment.

NOTE: /path/to/fos/repo is not the real path, this is the path to the fos repository local to the machine you plan on running this on. Typically this would be something like ~/fos. This is the only path you will need to change to build.

To build the FOS and/or kernels, once pulled:

##### Build Everything
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -n
```
##### Build only both inits
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nf
```
##### Build only both kernels
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nk
```
##### Build 64 bit init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa x64
```
##### Build 32 bit init
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nfa x86
```
##### Build 64 bit kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka x64
```
##### Build 32 bit kernel
```
docker run -v /path/to/fos/repo:/home/builder/fos:Z -u builder -it fogproject/fos-builder /home/builder/fos/build.sh -nka x86
```
