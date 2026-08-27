Right now, I have poky (the default Yokto project) configured for use in here:

```
/home/forsythcreations/git/external/bitbake
```

With a setup directory here:

```
/home/forsythcreations/git/external/bitbake/bitbake-builds/poky-master-poky-distro_poky-machine_qemux86-64
```


```
This bitbake configuration provides:
    Poky - The Yocto Project testing distribution

Usage instructions and additional information are in
     /home/forsythcreations/git/external/bitbake/bitbake-builds/poky-master-poky-distro_poky-machine_qemux86-64/build/README

To run builds, source the environment using
    . /home/forsythcreations/git/external/bitbake/bitbake-builds/poky-master-poky-distro_poky-machine_qemux86-64/build/init-build-env

Run 'bitbake-config-build enable-fragment <fragment-name>' to enable additional fragments or replace built-in ones (e.g. machine/<name> or distro/<name> to change MACHINE or DISTRO).

The bitbake configuration files (local.conf, bblayers.conf and more) can be found in
    /home/forsythcreations/git/external/bitbake/bitbake-builds/poky-master-poky-distro_poky-machine_qemux86-64/build/conf

To edit the code in VSCode, open the workspace:
    code /home/forsythcreations/git/external/bitbake/bitbake-builds/poky-master-poky-distro_poky-machine_qemux86-64/bitbake.code-workspace
```



---

Change directory to bitbake-builds

```
source poky-master-poky-distro_poky-machine_qemux86-64/build/init-build-env
```

Follow the steps here:

https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html


Looks like the image can be run using QEMU:

```
runqemu qemux86-64
```