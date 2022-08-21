We build a SELinux policy for our container

# udica

```
dnf install udica
```

Our container:

```
FROM registry.fedoraproject.org/fedora:37
RUN dnf install -y lldpd iputils iproute procps-ng netcat
RUN dnf install -y bind-utils
ENTRYPOINT ["lldpd", "-d"]
```

```
podman build -t lldpd .
podman run -v /etc/os-release:/etc/os-release --rm -ti --name lldpd --network host   --cap-add CAP_NET_RAW  lldpd
```

building a policy with udica
```
podman inspect lldpd  | sudo udica my_lldpd
semodule -i my_lldpd.cil /usr/share/udica/templates/base_container.cil
podman run --security-opt label=type:my_lldpd.process -v /etc/os-release:/etc/os-release --rm -ti --name lldpd --network host   --cap-add CAP_NET_RAW  lldpd
```

```
$ ps -p 6241 -Z
LABEL                               PID TTY          TIME CMD
system_u:system_r:my_lldpd.process:s0:c19,c331 6241 pts/0 00:00:00 lldpd
```
# customizing the policy

Working on something more restricted:
```
(block mytest
    (blockinherit container)

    (allow process http_cache_port_t ( tcp_socket (  name_bind )))
    (allow process http_port_t ( tcp_socket (  name_connect )))
    (allow process dns_port_t ( tcp_socket (  name_connect )))
    (allow process process ( tcp_socket (  listen )))
    (allow process node_t ( tcp_socket (  node_bind )))
    (allow process node_t ( udp_socket (  node_bind )))
    (allow process unreserved_port_t ( udp_socket (  name_bind )))
)
```
# node

node types are really only use for node_bind (there is no "node_connect" as there is a "name_connect" to use the remote port).

Would like to have a specific node type though. Example patching the selinux-policy package:

```
diff --git a/policy/modules/kernel/corenetwork.te.in b/policy/modules/kernel/corenetwork.te.in
index 495a671..fd1cbb4 100644
--- a/policy/modules/kernel/corenetwork.te.in
+++ b/policy/modules/kernel/corenetwork.te.in
@@ -438,6 +438,7 @@ sid node gen_context(system_u:object_r:node_t,s0 - mls_systemhigh)
 # network_node examples:
 #network_node(lo, s0 - mls_systemhigh, 127.0.0.1, 255.255.255.255)
 #network_node(multicast, s0 - mls_systemhigh, ff00::, ff00::)
+network_node(mydns, s0 - mls_systemhigh, 8.8.8.8, 255.255.0.0)
 
 ########################################
 #
```

```
diff --git a/make-rhat-patches.sh b/make-rhat-patches.sh
index 615a6d6..5b73811 100755
--- a/make-rhat-patches.sh
+++ b/make-rhat-patches.sh
@@ -28,6 +28,12 @@ git clone --depth=1 -q $REPO_MACRO_EXPANDER macro-expander
 
 pushd selinux-policy > /dev/null
 # prepare policy patches against upstream commits matching the last upstream merge
+patch -p1 < ${DISTGIT_PATH}/0001-mydns.patch
+git add policy
+git rev-parse HEAD
+git commit --author "toto <toto.example.com>" -m autoapplied
+git rev-parse HEAD
+
 BASE_HEAD_ID=$(git rev-parse HEAD)
 BASE_SHORT_HEAD_ID=$(c=${BASE_HEAD_ID}; echo ${c:0:7})
 git archive --prefix=selinux-policy-$BASE_HEAD_ID/ --format tgz HEAD > $DISTGIT_PATH/selinux-policy-$BASE_SHORT_HEAD_ID.tar.gz
```

```
bash make-rhat-patches.sh  -l
```

```
$ seinfo --nodecon
Nodecon with network 8.8.8.8 255.255.0.0 has host bits set. Analyses may have unexpected results.

Nodecon: 2
   nodecon 127.0.0.54 255.255.255.255 system_u:object_r:mydns_node_t:s0
   nodecon 8.8.0.0 255.255.0.0 system_u:object_r:mydns_node_t:s0
```

```
[root@raw cloud-user]# sudo semanage node -l
IP Address         Netmask            Protocol Context

8.8.8.8            255.255.0.0        ipv4  system_u:object_r:mydns_node_t:s0 
[root@raw cloud-user]# semanage node -a -M 255.255.255.255 -p ipv4 -t mydns_node_t 127.0.0.54
[root@raw cloud-user]# sudo semanage node -l
IP Address         Netmask            Protocol Context

127.0.0.54         255.255.255.255    ipv4  system_u:object_r:mydns_node_t:s0 
8.8.8.8            255.255.0.0        ipv4  system_u:object_r:mydns_node_t:s0 
```

only used for node_bind though.

# packets

to receive packets:
```
$ sesearch -A  -s mytest.process  -c packet
allow domain unlabeled_t:packet { recv send };
```

Instead we need to use SECMARK for the firewall to label packets with a security context

We use firewalld to generate an initial set of rules

Then add our own based on /usr/share/doc/nftables/examples/secmark.nft

Looks pretty cool
```
# conntrack -L
udp      17 28 src=10.224.122.55 dst=10.224.122.1 sport=68 dport=67 src=10.224.122.1 dst=10.224.122.55 sport=67 dport=68 mark=0 secctx=system_u:object_r:unlabeled_t:s0 use=1
tcp      6 431999 ESTABLISHED src=10.224.122.1 dst=10.224.122.55 sport=43366 dport=22 src=10.224.122.55 dst=10.224.122.1 sport=22 dport=43366 [ASSURED] mark=0 secctx=system_u:object_r:ssh_server_packet_t:s0 use=1
udp      17 7 src=10.224.122.55 dst=10.224.122.1 sport=36829 dport=53 src=10.224.122.1 dst=10.224.122.55 sport=53 dport=36829 mark=0 secctx=system_u:object_r:dns_client_packet_t:s0 use=1
udp      17 7 src=10.224.122.55 dst=10.224.122.1 sport=40148 dport=53 src=10.224.122.1 dst=10.224.122.55 sport=53 dport=40148 mark=0 secctx=system_u:object_r:dns_client_packet_t:s0 use=1
conntrack v1.4.6 (conntrack-tools): 4 flow entries have been shown.
[root@raw ~]# 
```

file can be checked with ```nft -c -f /etc/nftables/secmark.nft```

This already exists:
```
$ seinfo -t internet_packet_t -x

Types: 1
   type internet_packet_t, packet_type;
```

in /etc/sysconfig/nftables.conf
```
include "/etc/nftables/firewalld.nft"
include "/etc/nftables/secmark.nft"
```

We add

```
ip saddr 10.224.122.1 tcp dport 8080 ct state new meta secmark set "internet_server"
```

it's more useful as we can now put rules to distinguish internet vs non internet

```
# conntrack -L -p tcp  --dport=8080
tcp      6 431995 ESTABLISHED src=10.224.122.1 dst=10.224.122.55 sport=35236 dport=8080 src=10.224.122.55 dst=10.224.122.1 sport=8080 dport=35236 [ASSURED] mark=0 secctx=system_u:object_r:internet_packet_t:s0 use=1
tcp      6 431983 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=50484 dport=8080 src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=50484 [ASSURED] mark=0 secctx=system_u:object_r:unlabeled_t:s0 use=1
conntrack v1.4.6 (conntrack-tools): 2 flow entries have been shown.
```

When running podman with --network=host we get an AVC:
```
time->Sat Aug 20 23:09:07 2022
type=AVC msg=audit(1661029747.694:981): avc:  denied  { recv } for  pid=0 comm="swapper/2" saddr=10.224.122.1 src=35250 daddr=10.224.122.55 dest=8080 netif=eth0 scontext=system_u:system_r:mytest.process:s0:c14,c347 tcontext=system_u:object_r:internet_packet_t:s0 tclass=packet permissive=0
```

(actually we have another one for chrony)

Traffic for internet_packet_t can now be allowed in the cil with

```
    (allow process internet_packet_t ( packet (  send recv )))
```

# fixing the chrony AVC

```
[root@raw net]# sesearch -A -c packet -p send -s chronyd_t
allow chronyd_t chronyd_server_packet_t:packet { recv send };
allow chronyd_t ntp_server_packet_t:packet { recv send };
allow domain unlabeled_t:packet { recv send };
allow nsswitch_domain client_packet_t:packet send; [ nis_enabled ]:True
allow nsswitch_domain dns_client_packet_t:packet { recv send };
allow nsswitch_domain kerberos_client_packet_t:packet send; [ kerberos_enabled ]:True
allow nsswitch_domain ldap_client_packet_t:packet send; [ authlogin_nsswitch_use_ldap ]:True
allow nsswitch_domain ocsp_client_packet_t:packet send; [ kerberos_enabled ]:True
allow nsswitch_domain portmap_client_packet_t:packet send; [ nis_enabled ]:True
allow nsswitch_domain server_packet_t:packet send; [ nis_enabled ]:True

[root@raw net]# sesearch -A -c packet -p send -s ntpd_t
allow domain unlabeled_t:packet { recv send };
allow nsswitch_domain client_packet_t:packet send; [ nis_enabled ]:True
allow nsswitch_domain dns_client_packet_t:packet { recv send };
allow nsswitch_domain kerberos_client_packet_t:packet send; [ kerberos_enabled ]:True
allow nsswitch_domain ldap_client_packet_t:packet send; [ authlogin_nsswitch_use_ldap ]:True
allow nsswitch_domain ocsp_client_packet_t:packet send; [ kerberos_enabled ]:True
allow nsswitch_domain portmap_client_packet_t:packet send; [ nis_enabled ]:True
allow nsswitch_domain server_packet_t:packet send; [ nis_enabled ]:True
allow ntpd_t ntp_client_packet_t:packet { recv send };
allow ntpd_t ntp_server_packet_t:packet { recv send };
```
packets labelled chronyd_client_packet_t are denied output.

Fixed with this patch https://bugzilla.redhat.com/show_bug.cgi?id=2120016

# our own types

in mytypes.te, we create a policy_module:

```

policy_module(mytypes, 1.0)


type mytest_dmz_packet_t;
corenet_packet(mytest_dmz_packet_t)

type mytest_dmz_node_t;
corenet_node(mytest_dmz_node_t)

```

```
make -f /usr/share/selinux/devel/Makefile mytypes.pp
/usr/sbin/semodule -i mytypes.pp
```

```
$ seinfo -t mytest_dmz_packet_t -x

Types: 1
   type mytest_dmz_packet_t, packet_type;
```

```
$ sudo conntrack -L
tcp      6 116 TIME_WAIT src=10.224.122.1 dst=10.224.122.55 sport=35284 dport=8080 src=10.224.122.55 dst=10.224.122.1 sport=8080 dport=35284 [ASSURED] mark=0 secctx=system_u:object_r:mytest_dmz_packet_t:s0 use=1
```

nice.

We also define a node type that we can later fill:
```
semanage node -a -M 255.255.255.255 -p ipv4 -t mytest_dmz_node_t  127.0.0.99
semanage node -l
IP Address         Netmask            Protocol Context

127.0.0.99         255.255.255.255    ipv4  system_u:object_r:mytest_dmz_node_t:s0 
8.8.8.8            255.255.0.0        ipv4  system_u:object_r:mydns_node_t:s0 
```

# podman networking and secmark

when running with --network=host, the secmark is properly applied, traffic is blocked.

when running as root with -p 8080:8080, we see
```
tcp      6 431983 ESTABLISHED src=10.224.122.1 dst=10.224.122.55 sport=35292 dport=8080 src=10.88.0.2 dst=10.224.122.1 sport=8080 dport=35292 [ASSURED] mark=0 secctx=system_u:object_r:unlabeled_t:s0 use=1
```
the labeling happens probably in the wrong chain, the forwarding is executed and our packet is not labeled, traffic is not blocked.
TODO

when running as user with -p 8080:8080, we see

```
tcp      6 431997 ESTABLISHED src=10.224.122.1 dst=10.224.122.55 sport=35294 dport=8080 src=10.224.122.55 dst=10.224.122.1 sport=8080 dport=35294 [ASSURED] mark=0 secctx=system_u:object_r:mytest_dmz_packet_t:s0 use=1
```
tagging happened, however conntracks do not reflect the natting, also traffic is not blocked.

The traffic is received by a process "rootlessport".
TODO



# firewalld and secmark

we can just create separate tables, [making sure](https://askubuntu.com/questions/659267/how-do-i-override-or-configure-systemd-services) nftables service does not remove the tables used by firewalld.

as firewalld itself conflicts with nftables, we cannot use nftables.service, we can for example, override firewalld:

```
[Service]
ExecStartPre=nft -f /etc/sysconfig/nftables.conf
```

```
# nft list tables
table inet mytest
table inet firewalld
```

# running on CoreOS

we wrap it all together. To simplify, we will not use firewalld, we will use internet_packet_t and intranet_packet_t.

we write a RPM with our cil that we layer in CoreOS, and a secmark.nft rule file to mark our packets.

https://github.com/freedge/mytest_cil


we build in a [copr repo](https://copr.fedorainfracloud.org/coprs/frigo/mytest_cil/) and set up a webhook so that a build is triggered from github.

when installing the repo, we add
```
metadata_expire=300
```
to be able to update it more frequently during development.

we layer the package then start the container in this fashion:
```
[Unit]
Description=MyApp
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=0
ExecStartPre=-/bin/podman kill busybox1
ExecStartPre=-/bin/podman rm busybox1
ExecStartPre=nft -f /usr/share/mytest/secmark.nft
ExecStart=/bin/podman run --network=host --security-opt label=type:mytest.process --name busybox1 busybox nc -l -p 8080
Restart=always

[Install]
WantedBy=multi-user.target
```

Packets tagged as internet_packet_t are not processed:
```
tcp      6 71 SYN_SENT src=10.224.122.1 dst=10.224.122.13 sport=33332 dport=8080 [UNREPLIED] src=10.224.122.13 dst=10.224.122.1 sport=8080 dport=33332 mark=0 secctx=system_u:object_r:internet_packet_t:s0 use=1
```

Packets tagged as intranet_packet_t are processed
```
tcp      6 115 TIME_WAIT src=10.224.122.1 dst=10.224.122.13 sport=34972 dport=8118 src=10.224.122.13 dst=10.224.122.1 sport=8118 dport=34972 [ASSURED] mark=0 secctx=system_u:object_r:intranet_packet_t:s0 use=1
```



some links:

https://access.redhat.com/documentation/fr-fr/red_hat_enterprise_linux/9/html/using_selinux/creating-selinux-policies-for-containers_using-selinux

https://fedoramagazine.org/use-udica-to-build-selinux-policy-for-containers/

https://discussion.fedoraproject.org/t/coreos-and-udica-selinux-policies/41572/2

https://wiki.nftables.org/wiki-nftables/index.php/Secmark

https://github.com/coreos/fedora-coreos-tracker/issues/467#issuecomment-817382851

https://bugzilla.redhat.com/show_bug.cgi?id=2120016 - chrony selinux pol missing


