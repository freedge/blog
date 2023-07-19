This is some playing around, with OVN-Kubernetes and IPv6 single stack clusters.

Assuming a Kubernetes cluster running OVN-Kubernetes (OVNK) as CNI,
egress traffic from pods get snatted using the node IP, unless some EgressIP
are used.

In order to restrict this egress traffic, we can define network policies, and to make things
simpler, divide our workload into security zones. Each pod receive a "securityZone"
label, it is then possible to write a NetworkPolicy with
```
      - namespaceSelector: {}
        podSelector:
          matchLabels:
            securityZone: dmz
```
in each namespace needing it, here with the idea of allowing traffic from pods towards
any other pod of the cluster having securityZone=dmz.

For each pod of the cluster created with label securityZone=dmz, OVNK will update address_sets in OVN database to track each individual IP. Each of this individual IP will be installed as flows for OpenVSwitch to accept or drop traffic appropriately.

When the traffic egresses the stack and passes through a firewall, the firewall only sees the node IP though. Since stacks are multi-tenant and workload comes from various security zones, the firewall just lets everything pass through.

I had one idea, what if, instead of using SNAT, we 
- use IPv6 and just have the podCIDR routed throughout the data center, and
- encode the securityZone as part of the IPv6 address, and
- use wildcard ACLs to filter the traffic using securityZones within and outside the cluster

In practice a pod would receive an IP like this:
```
fd00:10:244:2:2000:bbbb:cccc:dddd/64

fd00:10:244:---------------------  podSubnet (for this cluster)
fd00:10:244:2:-------------------  podCidr   (on 1 particular node)
-------------:2000:--------------  dmz ipamHint. 0x2000 = dmz securityZone 
------------------:bbbb:cccc:dddd  one particular IPAM offset on that node
```
and this IP will be used throughout the data center.

This would allow to use wildcard ACL in this fashion:
- instead of using a podSelector with matchLabel, that will track each individual pod IP in an address_set, we can use a single IP/netmask, that looks like this:
```
ipBlock: 
  ipmask: fd00:10:244:0:2000::/ffff:ffff:ffff:0:ffff::
```
- if we have multiple stacks following this convention, we could allow egress traffic towards all the DMZ pods of the data center with a single IP/netmask as well:
```
ipBlock: 
  ipmask: fd00:10:244:0:2000::/ffff:ffff:ff00:0:ffff::
```
- from the external firewall point of view, it will receive the IP of the pod and will be able to use wildcard ACLs to allow traffic based on the securityZone.

So this is a proof of concept, using OVN-Kubernetes in a single stack IPv6 cluster started with [Kind](https://github.com/ovn-org/ovn-kubernetes/blob/master/docs/kind.md). This is running on an IPv4 only environment (my laptop is IPv4 only) so we need DNS64 and NAT64 to allow any connectivity.

Also Kube netpols do not support ipmask like this, so we'll have to do something in OVNK to make that work.

# step 1: booting Kind

We boot a Kind cluster with IPv6 and no IPv4 options:
```
sudo ./kind.sh -ep podman --ipv6 --no-ipv4 --disable-snat-multiple-gws
```
the "disable snat" option will be helpful for later when we disable all snatting.

Normally Kind publishes the Kubernetes API service on a port listening on localhost, but this does not work for IPv6. I documented the failure in  https://bugzilla.redhat.com/show_bug.cgi?id=2223204
and we workaround by using a different [apiServerAddress](
https://github.com/ovn-org/ovn-kubernetes/commit/ba51f0974a217b6583aa56136c24b6c48b0cee7a).

# step 2: controlling the pod IP

OVNK can allocate a maximum of [65536](https://github.com/ovn-org/ovn-kubernetes/blob/86f9e1fd9439527eb12b3661c7e4feda311ab217/go-controller/pkg/allocator/ip/allocator.go#L94) IPs for each node.
A pod IP is allocated by computing 1 + the podCIDR + a bitmap offset,
so technically only 16 (17 ?) bits are used. If this is a pod IP:

```fd00:10:244:2:aaaa:bbbb:cccc:dddd/64```
aaaa, bbbb, cccc will always be 0 (well, maybe not the last bit of cccc, but for this experiment I don't really care).

We are changing this logic so that we can encode an ipamHint in the "aaaa" place.
This is done through an [ipamHint](https://github.com/ovn-org/ovn-kubernetes/commit/0f42616b0fa61ba20fbe84e497dc12e014fea430) annotation on the pod
([.](https://github.com/ovn-org/ovn-kubernetes/commit/ba30cb76a6b598ab11df8a935ccc805d56161c0f)). We keep the existing logic and just OR our ipamHint on top of above computation.

# step 3: using the ipamHint in netpol

Well there is no "ipmask" available in network policies, so we are going to hack around some more:
We will consider a /80 cidr in a netpol as really, meant to be a "ffff:ffff:ffff:0:ffff::" mask. For example for such a netpol rule:
```
egress:
    - to:
        - ipBlock:
            cidr: fd00:10:244:0:1fff::/80
```
will mean ```ipmask: fd00:10:244:0:1fff::/ffff:ffff:ffff:0:ffff::```

https://github.com/ovn-org/ovn-kubernetes/commit/2a3992dfb6039cf93139a9e9161c581719b4a58f

This new mask is supported already in OVN ACL, and in OVS flows as well, so it just works.

# step 4: disabling SNAT

now that we have the proper IP on our pods (that reflect the securityZone they belong to),
and we are able to use that IP in netpols that are local to the cluster, we also want the pod IP to be seen outside the cluster.
It seems there are 2 ways SNAT is configured on OVNK clusters. Without ```--disable-snat-multiple-gws``` the natting is added automatically by OVN (.. I think?)
and with ```--disable-snat-multiple-gws``` the natting is handled by OVNK code.

So after enabling the disablement, we make sure [no SNAT is ever added](https://github.com/ovn-org/ovn-kubernetes/commit/e0073c71a9b347149fa2b224dd2d2899c0403f63).

Pods IP are now expected to be routed throughout the data center (or at least, the part that supports IPv6) but traffic is still tunnelled between each pod.

We need some extra routing rules in the VM (see commit) and within the podman nodes to achieve this.

To achieve this on a real data center, we would need to expose the podCIDR to the external network, for example through BGP. Metallb does not implement this feature but this [ticket](https://github.com/metallb/metallb/issues/1211) mentions that Cilium should be doing this already. Doing this whole idea with Cilium is probably less hackish and could work straight out of the box.

# step 5: making it work with PaloAlto firewall

My idea initially was to have a pan firewall handle the NAT64 part and the firewalling part with wildcard ACL.

While the [NAT64](https://docs.paloaltonetworks.com/pan-os/11-0/pan-os-networking-admin/nat64/configure-nat64-for-ipv6-initiated-communication) works fine, PaloAlto only supports wild card ACLs for ipv4 addresses! There is a [RFE](https://live.paloaltonetworks.com/t5/general-topics/ip-wildcard-mask-for-ipv6-adresses/m-p/549758#M112139) opened to extend that.

At this point I considered just stopping there, because giving the visibility of the securityZone to a PaloAlto firewall was the whole purpose of this. Also I gave up trying to automate the firewall set-up there, so here are just some pictures:

![traffic](/doc/ipv6paloflow.png)
![nat](/doc/ipv6palonat64.png)
![policy error](/doc/ipv6palowildcard.png)


# step 6: NAT64 with Tayga

So we trash the PaloAlto firewall, we will use [Tayga](https://github.com/openthread/tayga) instead. Tayga is already packaged for Fedora so I'll just use that.

/etc/tayga/default.conf ended up looking like this:
```
tun-device nat64
ipv4-addr 10.224.123.250
ipv6-addr fd42::99
prefix fd64:ff9b::/96
dynamic-pool 10.224.123.248/29
data-dir /var/lib/tayga/default
map 10.224.123.247 fd00:10:96::70e9
```

To set-up tayga we need a bit of plumbing:
```
ip -6 addr add fd42::12/64 dev eth0
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
systemctl start tayga@default

ip link set nat64 up
ip route add 10.224.123.248/29 dev nat64
ip -6 route add fd64:ff9b::/96 dev nat64
ip -6 route add fd42::98/127 dev nat64
```

We use fd64:ff9b::/96 because of a [limitation](https://github.com/openthread/tayga/blob/master/README#L70C6-L70C6)
so that NAT64 works for all IPs and not just public ones.

For traffic from a pod contacting fd64:ff9b::ae0:7b01, Tayga will add a line in its dynamic database (/var/lib/tayga/default/dynamic.map) and pick up a free IP from the dynamic IPv4 range.

For ingress traffic we add 
```map 10.224.123.247 fd00:10:96::70e9```
in the conf so that a service IP can be contacted using one specific IPv4 IP.

We can also add some filtering rules with iptables, which supports those wildcard ACLs:

```
ip6tables -A OUTPUT -s fd42:0:0:0:1234::/ffff:ffff:ffff:0:ffff:: -d fd64:FF9B::/96 -j  ACCEPT -p tcp
ip6tables -A OUTPUT -s fd42::/64 -d fd64:FF9B::/96 -j  DROP -p tcp
```

# step 7: DNS64

Let's also make DNS64 work. CoreDNS supports a dns64 plug-in:

```
    Corefile: |
      local:53 {
          errors
          health {
             lameduck 5s
          }
          ready
          kubernetes cluster.local net in-addr.arpa ip6.arpa {
             pods insecure
             ttl 30
          }
          prometheus :9153
          forward . fd64:ff9b::808:808 {
             max_concurrent 1000
          }
          dns64 {
            prefix fd64:ff9b::/96
          }
          cache 30
          reload
          loadbalance
      }
      .:53 {
          errors
          health {
             lameduck 5s
          }
          ready
          kubernetes cluster.local net in-addr.arpa ip6.arpa {
             pods insecure
             ttl 30
          }
          prometheus :9153
          forward . fd64:ff9b::808:808 {
             max_concurrent 1000
          }
          dns64 {
            prefix fd64:ff9b::/96
            translate_all
          }
          cache 30
          reload
          loadbalance
      }

```

We split in 2 so that depending on the zone:
- we use IPv6 addresses in our IPv6 only environment
- we use A records from any other zone and perform DNS64 on them. We ignore any AAAA records because we don't have IPv6 communication outside the cluster.


# Conclusion

It is possible to run and work with an IPv6 single stack Kind cluster, in an IPv4 only environment.
Support for Wildcard ACLs is not universal. It works with nftables/iptables and OVN/OVS but it's not supported in netpol and not supported by all Firewall vendors.

OVN-Kubernetes is designed to tunnel traffic and do SNAT, having a logical router per node to egress the traffic. We don't really need any of that anymore, so maybe investigating other CNI like Cilium would make more sense for this use case.