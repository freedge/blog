A simple sudoers rule like this:
```
auditor ALL = (root) NOPASSWD: /usr/sbin/dmidecode
```
can be leveraged to escalate privileges and run any command as root. This is because ```dmidecode``` provides a ```--dump-bin``` argument that allows to write a file. It is possible to construct an attack where ```dmidecode``` writes a ```authorized_keys``` file for example.

Classic ways to harden the sudo rules:
- use glob expressions
- use regexp expression (since [1.9.10 from last March](https://www.sudo.ws/posts/2022/03/sudo-1.9.10-using-regular-expressions-in-the-sudoers-file/))
- use [NOEXEC](https://github.com/sudo-project/sudo/blob/main/src/sudo_noexec.c)

Here I am interested in running the command in an SELinux jail which is more fun.


# Running commands with a custom SELinux role

```
(block auditor
        (type process)
        (type socket)
        (roletype system_r process)
        (typeattributeset domain (process ))
        (typeattributeset container_domain (process ))
        (typeattributeset svirt_sandbox_domain (process ))
        (typeattributeset mcs_constrained_type (process ))
        (typeattributeset file_type (socket ))
        (allow process socket (sock_file (create open getattr setattr read write rename link unlink ioctl lock append)))
        (allow process proc_type (file (getattr open read)))
        (allow process cpu_online_t (file (getattr open read)))
)
```

and 
```
semanage -i auditor.cil
```

The ```sudoers``` file will look like this:
```
auditor ALL = (root) TYPE=auditor.process ROLE=unconfined_r NOPASSWD: /usr/sbin/dmidecode
```

However the user can still override the SELinux type by running
```
sudo -t unconfined_t -r unconfined_r dmidecode
```

We need to make sure a user is not able to overwrite the SELinux type and put whatever he wants.

# Changing sudo

One way is to modify sudo so that it is not possible to use ```-t``` argument to change the type. [commit](https://github.com/freedge/sudo/commit/6f88810e478c99e6ae1c7c096660b20ed7fc0994)

Note that when building a custom sudo, building with ```./configure --prefix=/srv/sudo/ --with-selinux``` 
we need to change the SELinux context of the sudo binaries with
```
chcon system_u:object_r:shell_exec_t:s0 /srv/sudo/libexec/sudo/sesh 
chcon system_u:object_r:sudo_exec_t:s0 /srv/sudo/libexec/sudo/libsudo_util.so.0.0.0
chcon system_u:object_r:bin_t:s0 /srv/sudo/libexec/sudo/sudo_noexec.so
```

There is something interesting happening when not changing the SELinux context, see:
```
cp /usr/bin/ls .
chcon -t var_t ls
runcon -t container_t ./ls
Segmentation fault
```

We can see what happens with
```
# bpftrace -e 'kprobe:force_fatal_sig {printf("%d-%s %s\n", pid,  comm, kstack());} '
Attaching 1 probe...
139904-ls 
        force_fatal_sig+1
        bprm_execve+1278
        do_execveat_common.isra.0+429
        __x64_sys_execve+50
        do_syscall_64+88
        entry_SYSCALL_64_after_hwframe+99
```
runcon execve fails with NOACCES but the kernel decides to kill it with SIGSEGV.

# Running a plug-in

Another way to enforce the SELinux type is to develop a little plug-in. Here is one [approval_plugin.py](/doc/approval_plugin.py), that can then be referenced in ```/etc/sudo.conf```:

```
Set developer_mode true
Plugin python_approval python_plugin.so \
              ModulePath=/usr/share/doc/sudo/examples/approval_plugin.py \
              ClassName=ApprovalPlugin
```

We need to set developer_mode to true due to [this bug](https://bugzilla.redhat.com/show_bug.cgi?id=2124005).


# Result

Here granting the right to auditor user to run bash as root:

```
$ sudo -s
bash: /root/.bashrc: Permission denied
bash-5.1# dmidecode -s system-version
pc-q35-4.2
bash-5.1# cat /etc/passwd
cat: /etc/passwd: Permission denied
bash-5.1# cat /root/.ssh/authorized_keys
cat: /root/.ssh/authorized_keys: Permission denied
bash-5.1# 
```

We check how to allow access to a device:
```
bash-5.1# fdisk -l /dev/vda1 
fdisk: cannot open /dev/vda1: Permission denied
```

We notice this AVC:
```
type=AVC msg=audit(1662290457.473:5780): avc:  denied  { read } for  pid=140274 comm="fdisk" name="vda1" dev="devtmpfs" ino=289 scontext=unconfined_u:unconfined_r:auditor.process:s0-s0:c0.c1023 tcontext=system_u:object_r:fixed_disk_device_t:s0 tclass=blk_file permissive=0
```
so we add:

```
(allow process fixed_disk_device_t (blk_file (getattr open read)))
```
which works. There is no device cgroups protection (and no reduction of capabilities).

We also check why reading /sys/firmware/dmi/tables/smbios_entry_point works at all: it is because of this policy:
```
$ sesearch -s auditor.process -t sysfs_t -A -p read -c file
allow container_domain sysfs_t:file { getattr ioctl lock open read };
```

# Capabilities

it's pretty nice, but assuming we have a folder where the root user can write, mounted in suid. We see this:

```
mount -o remount /tmp -o suid
```
Using the unprivileged user we can run:
```
cp /usr/bin/bash /tmp/bash
chcon -t container_file_t /tmp/bash
```

Then from the root shell:
```
chown root /tmp/bash
chmod +s /tmp/bash
```

allowing the unprivileged user to break out of the jail.
We can harden a bit more by ensuring we drop capabilities, using [this patch](doc/sudocaps.diff), building with libcap:

```
LIBS=-lcap LT_LDFLAGS=-lcap  ./configure --prefix=/srv/sudo/ --with-selinux --with-all-insults --enable-python
```

# suid bit

However, it is still possible to run a ```chmod +s``` as root, even with all capabilities dropped (after all, this is a command a normal user can run, and the SELinux policy for it is there too)

```
$ sesearch -s auditor.process -t container_file_t -A -p setattr -c file
allow container_domain container_file_t:file { append create entrypoint execute execute_no_trans getattr ioctl link lock map mounton open read relabelfrom relabelto rename setattr unlink watch watch_reads write };
allow svirt_sandbox_domain container_file_t:file { append create execmod execute execute_no_trans getattr ioctl link lock map open read relabelfrom relabelto rename setattr unlink watch watch_reads write };
```

We augment even more the NOEXEC tag so that setattr (__NR_fchmodat and co), just as execve, is blocked.


