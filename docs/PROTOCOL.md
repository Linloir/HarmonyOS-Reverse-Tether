# RevTether tunnel protocol (0.2)

The HDC reverse mapping connects the phone to the relay's TCP listener on
`127.0.0.1` (default port 31417). Each connection begins with a four-byte,
big-endian identifier sent by the relay. Both directions then carry concatenated
raw IP packets. There is no additional length prefix: IPv4 uses its total-length
field and IPv6 uses `40 + payload_length`. An incomplete frame waits for more TCP
data. The maximum complete frame is 65,535 bytes.

## Capability and host policy handshake

Version 0.2 reuses the existing identifier without adding bytes or requiring a
client acknowledgement:

| Bits | Meaning |
| --- | --- |
| 31–24 | Magic `0xA5` |
| 23–22 | Host IPv6 policy: `00` inherit, `01` off, `10` on, `11` reserved |
| 21 | Relay supports IPv6 when set |
| 20–0 | Truncated diagnostic client counter |

For counter zero, the values are `A5200000`, `A5600000`, and `A5A00000`.
The relay's internal counter is separate from this wire value. Connection/socket
ownership and flow routing never rely on the truncated counter being unique.

Older phone clients consume and ignore the identifier as before, then continue
to send IPv4. A new phone considers a handshake without the magic or capability
bit IPv4-only, even if its local IPv6 setting is enabled. Reserved policy `11`
must be rejected or treated as IPv6 disabled; it must never enable IPv6. The
relay only emits the three defined policies.

The phone setting defaults to off. The resulting setting is:

| Host policy | Phone off | Phone on |
| --- | --- | --- |
| inherit (default) | IPv4 | IPv4 and IPv6 |
| off | IPv4 | IPv4 |
| on | IPv4 and IPv6 | IPv4 and IPv6 |

The phone applies this effective policy to its VPN configuration. The relay also
drops IPv6 frames when host policy is `off`; it keeps the connection available
for IPv4. With `inherit`, the relay accepts IPv6 frames and the phone decides
whether to route them into the VPN. The handshake is sent on every connection,
so a policy change takes effect after reconnecting to the updated relay.

## Addresses and DNS

The client uses IPv4 `10.0.0.2` and, when enabled, IPv6
`fd00:7265:7674::2/128`. Virtual DNS endpoints are `10.0.0.3:53` and
`[fd00:7265:7674::3]:53`. TCP and UDP to either endpoint are proxied to the host's
configured resolver. DNS message contents are preserved, including A/AAAA
questions; client and resolver address families may differ. Other destinations
are opened using host sockets of the requested address family. Existing
`10.0.2.2` to `127.0.0.1` host alias behavior is preserved.

```
harmony-relay --ipv6 inherit
harmony-relay --ipv6 on --dns 2001:db8::53
harmony-relay --ipv6 off --dns 192.0.2.53
harmony-relay --ipv6 on --dns '[::1]:5300'
```

`--dns` accepts a bare IPv4/IPv6 address with port 53, an IPv4 address with a
port, or a bracketed IPv6 address with a port. The examples use documentation
addresses and must be replaced with a reachable resolver. Unspecified,
multicast, broadcast, and either virtual DNS address cannot be upstream DNS.
Without `--dns`, Linux reads `/etc/resolv.conf`; Windows examines active
adapters' IPv4 and IPv6 resolvers, preserving IPv6 scope IDs and preferring lower
interface metrics. Resolver selection is performed when the process starts.

`--network-quality-capabilities` continues to print exactly `root-listener-v1`.
`--ipv6-capabilities` prints exactly `ipv6-policy-v1`. Supervisors can use this
independent query before passing `--ipv6`; older IPv4-only relays may reject the
query. An old relay may continue in IPv4 mode for `inherit` or `off`, but an
explicit `on` request must report that an upgraded relay is required.
No capability or policy selection starts a service outside the existing host
network namespace. IPv6 Internet access additionally requires a usable IPv6
host route; turning the setting on cannot create that connectivity.

## IPv6 support and packet bounds

The relay supports IPv6 TCP and UDP, including DNS over both transports. It
creates host sockets and synthesizes return IP/transport headers with correct
IPv4 or IPv6 pseudo-header checksums. IPv6 UDP replies always have a nonzero
checksum. Return TCP packets respect both the phone's advertised MSS and the
configured 1500-byte VPN MTU, including IP and TCP header lengths. If no MSS is
advertised, the fallback is 1220 bytes for IPv6 or 536 bytes for IPv4.

Hop-by-Hop and Destination Options headers are parsed with bounded TLV lengths;
unknown options requesting discard are dropped. Atomic Fragment headers are
accepted. Extension traversal is bounded at 16 headers. Responses use a fresh
IPv6 base header instead of reflecting request extensions.

This is a TCP/UDP socket proxy, not a general IPv6 router. It does not reassemble
non-atomic IP fragments, support jumbograms, forward routing/AH/ESP headers, or
proxy ICMP/ICMPv6 (including echo and Packet Too Big). Such supported-length
unsupported packets are discarded without losing framing or disconnecting the
tunnel. Structural errors such as invalid lengths, truncated extension headers,
or zero IPv6 UDP checksums close only the offending client connection.

Upstream path MTU discovery and socket packetization are handled by the host
kernel. The relay does not synthesize ICMPv6 Packet Too Big back to the phone.
Phone-originated UDP should fit one VPN MTU (at most 1452 payload bytes for IPv6
without extension headers); larger fragmented datagrams are outside this
version's support. Incoming UDP datagrams are not fragmented by the relay.
Large UDP datagrams and IPv6 paths requiring phone-side ICMPv6 feedback need
separate support and are not covered by basic TCP/UDP/DNS acceptance.

## Isolated verification

```
cargo test --locked --manifest-path relay/Cargo.toml
cargo build --locked --manifest-path relay/Cargo.toml
python3 relay/tests/dual_stack_integration.py --binary relay/target/debug/harmony-relay
```

The integration suite uses real IPv4/IPv6 sockets on loopback, independent IP
packet/checksum construction, a multi-packet TCP echo with MSS 1000, host policy
enforcement, and real A/AAAA DNS answers over UDP and TCP across all client and
resolver family combinations. It also checks the IPv6 STUN fixture response.
It does not need Internet access, privileged ports, or a connected phone.

For an authorized device test, the standalone standard-library fixture can be
copied to the test host:

```
python3 relay/tests/network_fixtures.py --serve-fixtures \
  --bind-v4 127.0.0.1 --bind-v6 ::1
```

The first stdout line is JSON describing ephemeral ports for TCP echo, HTTP
(`/small`, `/large`), UDP echo, STUN Binding, and DNS over TCP/UDP. HTTP bodies
include a SHA-256 header and their sizes/hashes are present in JSON. DNS answers
for `revtether.test` default to the bind addresses and can be changed with
`--answer-v4` / `--answer-v6`. The service stops on SIGINT or SIGTERM. Binding an
authorized test address instead of loopback makes it usable from the relay's
network namespace; the script does not create addresses, routes, or firewall
rules. A local ULA test proves the VPN data path, not public IPv6 connectivity.

Cross-compilation for Windows amd64 or Linux arm64 is a build check only.
Runtime acceptance for each target must be recorded separately.


## Optional application catalog (client 0.2.1)

The UI creates a request only after an explicit USB import action. Manual entry and viewing settings do not create requests. Authenticated `GET /v1/applications/request` returns `{request: 0}` unless the UI has an uncompleted, uncanceled request younger than 45 seconds. An authorized host may then run `bm dump -a -l` and `POST /v1/applications` with `{request, applications: [{bundleName, label}]}`. Failure results use `applications: []` and `error: "read_failed" | "unsupported"`. No inventory is exposed by public status.

The catalog endpoint alone allows a 128 KiB ASCII JSON body (escaped Unicode); all existing controls retain the 4 KiB body limit and headers are bounded to 8 KiB. Names, labels, count, duplicates and request freshness are validated before an atomic cache replacement. Canceled, expired and replaced requests return 409. Reading a catalog never configures, stops or restarts a VPN. Selection is a draft until the user saves settings.
