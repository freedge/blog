SSHFP are DNS records used to avoid the "trust on first use" problem of SSH connections, when the host key is not known yet.

To create the record, we can run on the host:

```
# ssh-keygen -r host -f /etc/ssh/ssh_host_ecdsa_key
host IN SSHFP 3 1 a346aaf97fcaab54c8d2573717f498f40622dbae
host IN SSHFP 3 2 0d2b0f6d7180e2efd1e2ad7be564ec17011d4727c12e0fd75bfcbc0cdbf07ba0
```

first digit 3 is for ECDSA key, second is for SHA-1 (1) and SHA-256 (2).

We will just use the second one, as Designate does not seem to support giving multiple records.

```
openstack recordset create --type SSHFP --record "3 2 0d2b0f6d7180e2efd1e2ad7be564ec17011d4727c12e0fd75bfcbc0cdbf07ba0" zone.example.com. myhost
```

To use it:
```
ssh -o "VerifyHostKeyDNS=yes" core@myhost.zone.example.com
```

Unfortunately Designate does not support DNSSEC, so we get

```
The authenticity of host 'myhost.zone.example.com (10.0.0.108)' can't be established.
ECDSA key fingerprint is SHA256:DSsPbXGA4u/R4q175WTsFwEdRyfBLg/XW/y8DNvwe6A.
Matching host key fingerprint found in DNS.
Are you sure you want to continue connecting (yes/no/[fingerprint])? 
```
with at least an indication that something is going right. If the SSHFP record exists but does not match, it's more interesting:
```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
The fingerprint for the ECDSA key sent by the remote host is
SHA256:DSsPbXGA4u/R4q175WTsFwEdRyfBLg/XW/y8DNvwe6A.
Please contact your system administrator.
Update the SSHFP RR in DNS with the new host key to get rid of this message.

```

and verbose mode will reveal
```
debug1: found 1 insecure fingerprints in DNS
debug1: mismatching host key fingerprint found in DNS
```

We still need to TOFU though.


some links:

https://weberblog.net/sshfp-authenticate-ssh-fingerprints-via-dnssec/