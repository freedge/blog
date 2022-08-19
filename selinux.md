some random notes on SELinux commands so I know where to find them

```
dnf install setools-console
```


# fcontext

```
$ ls -lZ /usr/bin/tracepath 
-rwxr-xr-x. 1 root root system_u:object_r:traceroute_exec_t:s0 27920 Jul 21 17:00 /usr/bin/tracepath
$ attr -l abc
Attribute "selinux" has a 38 byte value for abc
$ attr -S -g selinux  abc
Attribute "selinux" had a 38 byte value for abc:
unconfined_u:object_r:admin_home_t:s0
$ ls -Z abc
unconfined_u:object_r:admin_home_t:s0 abc
$ semanage fcontext -l | grep tracepath
/bin/tracepath.*                                   regular file       system_u:object_r:traceroute_exec_t:s0
/usr/bin/tracepath.*                               regular file       system_u:object_r:traceroute_exec_t:s0

# dry run restore
$ restorecon -R -v -n /usr/bin/
```

# login

```
$ semanage login -l
$ usermod myuser -Z staff_u
$ seinfo -u -x
$ seinfo -r

```

# module

```
$ ausearch -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR -ts today
$ ausearch -m AVC -ts recent
$ audit2allow -a -M mymodule
$ sepolicy generate -n leauditor  -u staff_u  --customize -d staff_r
$ dnf install noarch/leauditor_selinux-1.0-1.fc37.noarch.rpm

$ semanage module -l | grep 400
```



# searching policies

```
$ sesearch --dontaudit | grep -P 'shadow_t|admin_home_t|openvswitch_exec_t' | grep staff_t
dontaudit staff_t admin_home_t:file { ioctl lock open read };
dontaudit staff_t shadow_t:file { ioctl lock open read };

$ sesearch --dontaudit -s staff_t -t admin_home_t
$ sesearch --dontaudit -s staff_t -t shadow_t


# logging even the dont audit rules
$ semodule -DB
$ sesearch  -A -s init_t -t var_lib_t  -c lnk_file

# policies to transition between types when systemd starts a service
$ sesearch --type_trans  -s init_t -t haproxy_exec_t 
type_transition init_t haproxy_exec_t:process haproxy_t;

```

# runcon

```runcon``` transitions to the provided type:

```
$ sesearch -A -p transition -s staff_t  -t container_runtime_t
allow staff_t container_runtime_t:process { sigchld sigkill signal signull sigstop transition };
$ ls 
afolder
$ runcon -t container_runtime_t ls
afolder
$ ping
ping: usage error: Destination address required
$ runcon -t container_runtime_t ping
runcon: ‘ping’: Permission denied
```

Last one gives
```
type=AVC msg=audit(1660838673.883:239): avc:  denied  { entrypoint } for  pid=1211 comm="runcon" path="/usr/bin/ping" dev="vda5" ino=765000 scontext=staff_u:staff_r:container_runtime_t:s0-s0:c0.c1023 tcontext=system_u:object_r:ping_exec_t:s0 tclass=file permissive=0

        Was caused by:
                Missing type enforcement (TE) allow rule.

                You can use audit2allow to generate a loadable module to allow this access.
```

Indeed staff_t has the ping_t role (```seinfo -r staff_r -x  | grep ping```), which is allowed to execute ping_exec_t (```sesearch --allow -t ping_exec_t -s ping_t```)

It works as unconfined too:
```
$ sesearch -A -p transition -s unconfined_t  -t container_runtime_t
allow unconfined_t domain:process transition;
```

When the transition is not there:
```
$ runcon -r staff_r -u staff_u -t staff_t ping
runcon: ‘ping’: Permission denied
$ ausearch -ts recent -m AVC  | audit2why
type=AVC msg=audit(1660839026.152:290): avc:  denied  { transition } for  pid=1401 comm="runcon" path="/usr/bin/ping" dev="vda5" ino=765000 scontext=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023 tcontext=staff_u:staff_r:staff_t:s0-s0:c0.c1023 tclass=process permissive=0

        Was caused by:
                Missing role allow rule.

                Add an allow rule for the role pair.

```

runcon works by writing the label in /proc/thread-self/attr/exec then execve.

# handling sudo

there is an interface for that, see /usr/share/selinux/devel/include/admin/sudo.if
```
sudo_role_template(staff, staff_r, staff_t)
```
We can find back who is allowed:
```
$ sesearch --allow -p entrypoint -t sudo_exec_t
allow auditadm_sudo_t sudo_exec_t:file entrypoint;
allow auditadm_t sudo_exec_t:file entrypoint;
allow dbadm_sudo_t sudo_exec_t:file entrypoint;
allow dbadm_t sudo_exec_t:file entrypoint;
allow sandbox_x_domain exec_type:file { entrypoint execute execute_no_trans getattr ioctl lock map open read };
allow secadm_sudo_t sudo_exec_t:file entrypoint;
allow secadm_t sudo_exec_t:file entrypoint;
allow staff_sudo_t sudo_exec_t:file entrypoint;
allow staff_t sudo_exec_t:file entrypoint;
allow svirt_sandbox_domain exec_type:file { entrypoint execute execute_no_trans getattr ioctl lock map open read };
allow sysadm_sudo_t sudo_exec_t:file entrypoint;
allow sysadm_t sudo_exec_t:file entrypoint;
allow virtd_lxc_t exec_type:file entrypoint;

$ sesearch --allow -t staff_sudo_t -p transition  
allow staff_sudo_t staff_sudo_t:process { dyntransition fork getattr getcap getpgid getrlimit getsched getsession noatsecure rlimitinh setcap setexec setkeycreate setpgid setrlimit setsched setsockcreate share siginh sigkill signull sigstop transition };
allow staff_t staff_sudo_t:process { sigkill signal signull sigstop transition };
allow unconfined_t domain:process transition;
```

so staff_t can transition to staff_sudo_t then exec sudo, while user_t cannot.

# vfat and selinux

there is no support for extended attributes there, we find in policy/modules/kernel/filesystem.te:
```
#
# dosfs_t is the type for fat, vfat and exfat
# filesystems and their files.
#
type dosfs_t;
fs_noxattr_type(dosfs_t)
files_mountpoint(dosfs_t)
allow dosfs_t fs_t:filesystem associate;
genfscon fat / gen_context(system_u:object_r:dosfs_t,s0)
genfscon hfs / gen_context(system_u:object_r:dosfs_t,s0)
genfscon hfsplus / gen_context(system_u:object_r:dosfs_t,s0)
genfscon msdos / gen_context(system_u:object_r:dosfs_t,s0)
genfscon ntfs-3g / gen_context(system_u:object_r:dosfs_t,s0)
genfscon ntfs / gen_context(system_u:object_r:dosfs_t,s0)
genfscon ntfs3 / gen_context(system_u:object_r:dosfs_t,s0)
genfscon vfat / gen_context(system_u:object_r:dosfs_t,s0)
genfscon exfat / gen_context(system_u:object_r:dosfs_t,s0)
```

```
$ seinfo --genfscon vfat

Genfscon: 1
   genfscon vfat /  system_u:object_r:dosfs_t:s0
```

# port and boolean

I tried to run a haproxy_exporter process, labelled as haproxy_exec_t, listening to port 9101.
 
```
type=AVC msg=audit(1660845260.440:192): avc:  denied  { name_bind } for  pid=1101 comm="haproxy_exporte" src=9101 scontext=system_u:system_r:haproxy_t:s0 tcontext=system_u:object_r:hplip_port_t:s0 tclass=tcp_socket permissive=0             
                                                                                                
        Was caused by:  
        The boolean haproxy_connect_any was set incorrectly.                               
        Description:    
        Determine whether haproxy can connect to all TCP ports.
                        
        Allow access by executing:
        # setsebool -P haproxy_connect_any 1
```

It fails because the port is an "hplip" port, haproxy only allows to bind standard http ports, or unreserved ports.
9101 is reserved for another purpose. We can change the haproxy_connect_any boolean to make it work.

```
# sesearch  -A -b haproxy_connect_any
allow haproxy_t packet_type:packet recv; [ haproxy_connect_any ]:True
allow haproxy_t packet_type:packet send; [ haproxy_connect_any ]:True
allow haproxy_t port_type:tcp_socket name_bind; [ haproxy_connect_any ]:True
allow haproxy_t port_type:tcp_socket name_connect; [ haproxy_connect_any ]:True
allow haproxy_t port_type:tcp_socket { recv_msg send_msg }; [ haproxy_connect_any ]:True

# sesearch --allow -s haproxy_t -p  name_bind
allow haproxy_t commplex_main_port_t:tcp_socket { name_bind name_connect };
allow haproxy_t http_cache_port_t:tcp_socket { name_bind name_connect };
allow haproxy_t http_port_t:tcp_socket { name_bind name_connect };
allow haproxy_t jboss_management_port_t:tcp_socket name_bind;
allow haproxy_t port_type:tcp_socket name_bind; [ haproxy_connect_any ]:True
allow haproxy_t unreserved_port_t:tcp_socket { name_bind name_connect };
allow nsswitch_domain ephemeral_port_t:tcp_socket name_bind; [ nis_enabled ]:True
allow nsswitch_domain ephemeral_port_t:udp_socket name_bind; [ nis_enabled ]:True
allow nsswitch_domain port_t:tcp_socket name_bind; [ nis_enabled ]:True
allow nsswitch_domain port_t:udp_socket name_bind; [ nis_enabled ]:True
allow nsswitch_domain unreserved_port_t:tcp_socket name_bind; [ nis_enabled ]:True
allow nsswitch_domain unreserved_port_t:udp_socket name_bind; [ nis_enabled ]:True

# semanage port -l | grep 9101
hplip_port_t                   tcp      1782, 2207, 2208, 8290, 8292, 9100, 9101, 9102, 9220, 9221, 9222, 9280, 9281, 9282, 9290, 9291, 50000, 50002
```

Our haproxy exporter expects to connect to port 9999 (jboss_management_port_t), it fails because jboss_management_port_t is only able to bind, not to connect.

We can make it more permissive with
```
setsebool -P haproxy_connect_any 1
```

We can check what boolean was changed from the default with
```
semanage boolean -l -C
```


# podman


We run our haproxy_exporter in a [rootless podman container](https://www.redhat.com/sysadmin/debug-rootless-podman-mounted-volumes).
We need to mount this file:
```
$ ls -lZ afile
-rw-------. 1 cloud-user cloud-user unconfined_u:object_r:user_home_t:s0 93 Aug 18 22:04 afile
```
we skip first non solution which runs as root.

second solution:

```
$ cat afile > args2 ; chmod go-rwx args2
$ podman run --network=host --rm -v `pwd`/args2:/etc/args:Z,U quay.io/prometheus/haproxy-exporter:latest @/etc/args
$ ls -lZ args2
-rw-------. 1 165533 165533 system_u:object_r:container_file_t:s0:c843,c926 93 Aug 18 22:09 args2
```
File can still be accessed with
```
$ podman unshare cat args2
```

third solution:
```
$ cat afile > args3 ; chmod go-rwx args3
$ podman run --network=host --userns=keep-id -u 1000 --rm -v `pwd`/args3:/etc/args:Z quay.io/prometheus/haproxy-exporter:latest @/etc/args
$ ls -lZ args3
-rw-------. 1 cloud-user cloud-user system_u:object_r:container_file_t:s0:c423,c573 93 Aug 18 22:10 args3
```

the process is currently running as 
```
$ ps -p 4504 -Z
LABEL                               PID TTY          TIME CMD
system_u:system_r:container_t:s0:c386,c952 4504 ? 00:00:00 haproxy_exporte
```

since the label changed we note this:
```
$ sudo restorecon -n -v args2
/home/cloud-user/args2 not reset as customized by admin to system_u:object_r:container_file_t:s0:c297,c971
```

selinux code (from fedora policycoreutils) reads:
```
        if (curcon == NULL || strcmp(curcon, newcon) != 0) {
                if (!flags->set_specctx && curcon &&
                                    (is_context_customizable(curcon) > 0)) {
                        if (flags->verbose) {
                                selinux_log(SELINUX_INFO,
                                 "%s not reset as customized by admin to %s\n",
                                                            pathname, curcon);
                        }
                        goto out;
                }
```
which seems loaded from /etc/selinux/targeted/contexts/customizable_types

# super privileged container

Running
```
sudo podman run -ti --rm --privileged registry.fedoraproject.org/fedora:35 sleep 123
$ ps -p `pgrep -f sleep\ 123` -Z
LABEL                               PID TTY          TIME CMD
unconfined_u:system_r:spc_t:s0     1502 pts/0    00:00:00 sleep
```

privileged containers are labelled with [spc_t](https://developers.redhat.com/blog/2014/11/06/introducing-a-super-privileged-container-concept)

```
$ seinfo -r system_r -x |  grep -o .spc_t.
 spc_t 
```
added from [container.te](https://github.com/containers/container-selinux/blob/7ffded0091bc146cc47808fa101246091c66b9d8/container.te)

Trying to transition from an unconfined user works, but not from a confined user:
```
type=SELINUX_ERR msg=audit(1660879704.764:437): op=security_compute_sid invalid_context="staff_u:staff_r:spc_t:s0" scontext=staff_u:staff_r:container_runtime_t:s0 tcontext=system_u:object_r:container_file_t:s0:c1022,c1023 tclass=process
```

# Some links

https://github.com/fedora-selinux/selinux-policy/blob/8c5e5fcc99152baa2e9870f3375d11411ce7a208/policy/modules/contrib/openvswitch.te - how the policies are written in Fedora

https://bugzilla.redhat.com/show_bug.cgi?id=2118784 - RHEL issue

https://bugzilla.redhat.com/show_bug.cgi?id=2118802 - Fedora issue

https://bugzilla.redhat.com/show_bug.cgi?id=2119222 - Fedora issue maybe? systemd not transitioning types

https://discussion.fedoraproject.org/t/selinux-and-protecting-users-ssh-folders/41426 - my first step

https://access.redhat.com/documentation/en-us/red_hat_entegrprise_linux/8/html-single/using_selinux/index#introduction-to-selinux_getting-started-with-selinux - generating policies

