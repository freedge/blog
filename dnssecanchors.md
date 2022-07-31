I am interested in resolving dnssec-failed.org.

This is a record that is supposed to be signed but the signature [cannot be validated](https://dnssec-analyzer.verisignlabs.com/dnssec-failed.org)

I note that my ISP's DNS does not resolve this name (so, I am benefitting from DNSSEC even though I did not activate it on my laptop!)

```
# dig @192.168.0.254 dnssec-failed.org
;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 40570
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1472
;; QUESTION SECTION:
;dnssec-failed.org.             IN      A
```

It is however, possible to ask explicitly for the broken record by providing the cd flag:
```
# dig +cdflag @192.168.0.254 dnssec-failed.org
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 57242
;; flags: qr rd ra cd; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 1472
;; QUESTION SECTION:
;dnssec-failed.org.             IN      A

;; ANSWER SECTION:
dnssec-failed.org.      300     IN      A       96.99.227.255

```

which in Wireshark, will show "Non-authenticated data: Acceptable" (see [pcap](/doc/dnssec.pcap)):
```
Flags: 0x0110 Standard query
    0... .... .... .... = Response: Message is a query
    .000 0... .... .... = Opcode: Standard query (0)
    .... ..0. .... .... = Truncated: Message is not truncated
    .... ...1 .... .... = Recursion desired: Do query recursively
    .... .... .0.. .... = Z: reserved (0)
    .... .... ...1 .... = Non-authenticated data: Acceptable
```

When activating DNSSEC in systemd-resolved, the cd flag is sent so that systemd-resolved can perform by itself the resolution
```
# resolvectl dns eth0 192.168.0.254
# resolvectl dnssec eth0 yes
# resolvectl query dnssec-failed.org
dnssec-failed.org: resolve call failed: DNSSEC validation failed: missing-key
```

We can force this name to be resolved anyway by adding a negative trust anchor. We create a file /etc/dnssec-trust-anchors.d/test.negative with content
```
dnssec-failed.org.
```

and after restarting systemd-resolved it now resolves fine:
```
# resolvectl query dnssec-failed.org
dnssec-failed.org: 96.99.227.255               -- link: eth0

-- Information acquired via protocol DNS in 965.4ms.
-- Data is authenticated: no; Data was acquired via local or encrypted transport: no
-- Data from: network
```

Another way is to get the DNSKEY for this record and add them in a positive trust anchor:


```
# dig +cdflag @192.168.0.254  dnssec-failed.org. DNSKEY
# dig +cdflag @192.168.0.254  dnssec-failed.org. DS
```

then we create file /etc/dnssec-trust-anchors.d/test.positive with content
```
dnssec-failed.org.      IN      DS      106 5 1 4F219DCE274F820EA81EA1150638DABE21EB27FC
dnssec-failed.org.      IN      DS      106 5 2 AE3424C9B171AF3B202203767E5703426130D76EF6847175F2EED355F86EF1CE
dnssec-failed.org. IN DNSKEY 256 3 5 AwEAAewq/QcrsNX3C/nAAWyNY74f/q9Rb2dGLc3LOIkQBATwzIcDTDHNRjtRDxjquImNpoDKybI2hZ2e8mNKvCK/F/QXV5LafLwSzscqwvzJxEGZUA+JuiGu6kq/8OjE6EEAdYlk4ztN6OWfwuqj4ZolBjKPXCPodYvhj8gl7kqpopqr
dnssec-failed.org. IN DNSKEY 257 3 5 AwEAAb/f/pB/FLWoYp3j+HtldGkbUMT6caAw2rej0DZkgXVFOKn4PWi3BYjCozjEqxeramt+9b1SMuOSJ8vGKWr0YKrfyfJigsVxpsMgJ7QWcxeMACjC/oM8BPjDFBby/CgQQE63nPVX2SfDWCRhEhTOnsPZpKJvq66IHF/w+3u0IpyeplQWvO+HJ9OQPOQrstM7d/IPa7yKEtqS2nhBT0GWX2/GYhT6oE7F4vc2VF9f6MjpB/pWPzkcx636YaxG9P0QRBvzdD/Wztcbz1Scgxw5sUlIkQAzWV1mJfvXF+7NqzGcc94/kMt1VUzN2kYASRyn1ALiFPfNLz4VMUvSw5fpNS0=
```

after restarting systemd-resolved, it logs:
```
Jul 31 06:48:17 raw systemd-resolved[2804]: SELinux enabled state cached to: enabled
Jul 31 06:48:17 raw systemd-resolved[2804]: Successfully loaded SELinux database in 5.536ms, size on heap is 348K.
Jul 31 06:48:17 raw systemd-resolved[2804]: Positive Trust Anchors:
Jul 31 06:48:17 raw systemd-resolved[2804]: dnssec-failed.org. IN DNSKEY 256 3 RSASHA1
Jul 31 06:48:17 raw systemd-resolved[2804]:         AwEAAewq/QcrsNX3C/nAAWyNY74f/q9Rb2dGLc3LOIkQBATwzIcDTDHNRjtRDxjquImNpoD
Jul 31 06:48:17 raw systemd-resolved[2804]:         KybI2hZ2e8mNKvCK/F/QXV5LafLwSzscqwvzJxEGZUA+JuiGu6kq/8OjE6EEAdYlk4ztN6O
Jul 31 06:48:17 raw systemd-resolved[2804]:         Wfwuqj4ZolBjKPXCPodYvhj8gl7kqpopqr
Jul 31 06:48:17 raw systemd-resolved[2804]:         -- Flags: ZONE_KEY
Jul 31 06:48:17 raw systemd-resolved[2804]:         -- Key tag: 44973
Jul 31 06:48:17 raw systemd-resolved[2804]: dnssec-failed.org. IN DNSKEY 257 3 RSASHA1
Jul 31 06:48:17 raw systemd-resolved[2804]:         AwEAAb/f/pB/FLWoYp3j+HtldGkbUMT6caAw2rej0DZkgXVFOKn4PWi3BYjCozjEqxeramt
Jul 31 06:48:17 raw systemd-resolved[2804]:         +9b1SMuOSJ8vGKWr0YKrfyfJigsVxpsMgJ7QWcxeMACjC/oM8BPjDFBby/CgQQE63nPVX2S
Jul 31 06:48:17 raw systemd-resolved[2804]:         fDWCRhEhTOnsPZpKJvq66IHF/w+3u0IpyeplQWvO+HJ9OQPOQrstM7d/IPa7yKEtqS2nhBT
Jul 31 06:48:17 raw systemd-resolved[2804]:         0GWX2/GYhT6oE7F4vc2VF9f6MjpB/pWPzkcx636YaxG9P0QRBvzdD/Wztcbz1Scgxw5sUlI
Jul 31 06:48:17 raw systemd-resolved[2804]:         kQAzWV1mJfvXF+7NqzGcc94/kMt1VUzN2kYASRyn1ALiFPfNLz4VMUvSw5fpNS0=
Jul 31 06:48:17 raw systemd-resolved[2804]:         -- Flags: SEP ZONE_KEY
Jul 31 06:48:17 raw systemd-resolved[2804]:         -- Key tag: 29521
Jul 31 06:48:17 raw systemd-resolved[2804]: . IN DS 20326 8 2 e06d44b80b8f1d39a95c0b0d7c65d08458e880409bbc683457104237c7f8ec8d
Jul 31 06:48:17 raw systemd-resolved[2804]: dnssec-failed.org. IN DS 106 5 1 4f219dce274f820ea81ea1150638dabe21eb27fc
Jul 31 06:48:17 raw systemd-resolved[2804]: dnssec-failed.org. IN DS 106 5 2 ae3424c9b171af3b202203767e5703426130d76ef6847175f2eed355f86ef1ce
Jul 31 06:48:17 raw systemd-resolved[2804]: Negative trust anchors: home.arpa 10.in-addr.arpa 16.172.in-addr.arpa 17.172.in-addr.arpa 18.172.in-addr.arpa
Jul 31 06:48:17 raw systemd-resolved[2804]: Using system hostname 'raw'.
```

and finally
```
# resolvectl query dnssec-failed.org
dnssec-failed.org: 96.99.227.255               -- link: eth0

-- Information acquired via protocol DNS in 1.1492s.
-- Data is authenticated: yes; Data was acquired via local or encrypted transport: no
-- Data from: network
```

this time the failed dnssec-failed.org has been successfully authenticated.

We also note that the ad flag is answered by systemd resolved stub when querying for this record, indicating it is authenticated:

```
# dig dnssec-failed.org

; <<>> DiG 9.16.30-RH <<>> dnssec-failed.org
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 44827
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1

;; OPT PSEUDOSECTION:
; EDNS: version: 0, flags:; udp: 65494
;; QUESTION SECTION:
;dnssec-failed.org.             IN      A

;; ANSWER SECTION:
dnssec-failed.org.      300     IN      A       96.99.227.255

;; Query time: 842 msec
;; SERVER: 127.0.0.53#53(127.0.0.53)
;; WHEN: Sun Jul 31 07:06:46 UTC 2022
;; MSG SIZE  rcvd: 62
```

some links:

https://www.freedesktop.org/software/systemd/man/dnssec-trust-anchors.d.html

https://www.ietf.org/rfc/rfc4035.txt the RFC for the CD bit
