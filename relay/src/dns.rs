// SPDX-License-Identifier: Apache-2.0
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::OnceLock;

pub const VIRTUAL_DNS: u32 = 0x0a000003;
pub const VIRTUAL_DNS_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x7265, 0x7674, 0, 0, 0, 0, 3);
static UPSTREAM: OnceLock<SocketAddr> = OnceLock::new();

pub fn parse_resolver(text: &str) -> Option<IpAddr> {
    text.lines().find_map(|line| {
        let mut words = line.split('#').next()?.split_whitespace();
        if words.next()? != "nameserver" {
            return None;
        }
        words.next()?.parse().ok()
    })
}

pub fn parse_upstream(value: &str) -> Result<SocketAddr, &'static str> {
    if let Ok(ip) = value.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, 53));
    }
    match value.parse::<SocketAddr>() {
        Ok(address) if address.port() != 0 => Ok(address),
        _ => Err("DNS must be an IP address, IPv4:PORT, or [IPv6]:PORT"),
    }
}

pub fn configure(explicit: Option<SocketAddr>) -> io::Result<SocketAddr> {
    let upstream = match explicit {
        Some(address) => address,
        None => system_resolver()?,
    };
    let address = upstream.ip();
    if is_virtual(address)
        || address.is_unspecified()
        || address.is_multicast()
        || matches!(address, IpAddr::V4(ip) if ip.is_broadcast())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid upstream DNS address",
        ));
    }
    UPSTREAM
        .set(upstream)
        .map_err(|_| io::Error::new(io::ErrorKind::AlreadyExists, "DNS already configured"))?;
    Ok(upstream)
}

fn no_resolver() -> io::Error {
    io::Error::new(
        io::ErrorKind::NotFound,
        "No usable DNS resolver; specify --dns ADDRESS",
    )
}

#[cfg(not(windows))]
fn system_resolver() -> io::Result<SocketAddr> {
    parse_resolver(&std::fs::read_to_string("/etc/resolv.conf")?)
        .map(|ip| SocketAddr::new(ip, 53))
        .ok_or_else(no_resolver)
}

// Windows sockaddr layout is independent of the build machine's address
// family constants. Keep decoding pure so IPv6 bytes/scope have unit coverage.
#[cfg(any(windows, test))]
fn windows_dns_address(raw: &[u8]) -> Option<SocketAddr> {
    if raw.len() < 2 {
        return None;
    }
    match u16::from_ne_bytes([raw[0], raw[1]]) {
        2 if raw.len() >= 16 => Some(SocketAddr::new(
            Ipv4Addr::new(raw[4], raw[5], raw[6], raw[7]).into(),
            53,
        )),
        23 if raw.len() >= 28 => {
            let mut octets = [0; 16];
            octets.copy_from_slice(&raw[8..24]);
            let scope = u32::from_ne_bytes([raw[24], raw[25], raw[26], raw[27]]);
            Some(std::net::SocketAddrV6::new(Ipv6Addr::from(octets), 53, 0, scope).into())
        }
        _ => None,
    }
}

#[cfg(windows)]
fn system_resolver() -> io::Result<SocketAddr> {
    use std::mem::size_of;
    use winapi::shared::ifdef::IfOperStatusUp;
    use winapi::shared::winerror::{ERROR_BUFFER_OVERFLOW, ERROR_SUCCESS};
    use winapi::shared::ws2def::AF_UNSPEC;
    use winapi::um::iphlpapi::GetAdaptersAddresses;
    use winapi::um::iptypes::{
        GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_FRIENDLY_NAME, GAA_FLAG_SKIP_MULTICAST,
        GAA_FLAG_SKIP_UNICAST, IP_ADAPTER_ADDRESSES_LH,
    };

    let mut size = 15 * 1024u32;
    for _ in 0..3 {
        // Pointer-aligned caller-owned storage remains alive for the complete
        // linked-list traversal. Windows guarantees nodes point into this buffer.
        let mut storage =
            vec![0usize; (size as usize + size_of::<usize>() - 1) / size_of::<usize>()];
        let head = storage.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        let flags = GAA_FLAG_SKIP_UNICAST
            | GAA_FLAG_SKIP_ANYCAST
            | GAA_FLAG_SKIP_MULTICAST
            | GAA_FLAG_SKIP_FRIENDLY_NAME;
        let result = unsafe {
            GetAdaptersAddresses(
                AF_UNSPEC as u32,
                flags,
                std::ptr::null_mut(),
                head,
                &mut size,
            )
        };
        if result == ERROR_BUFFER_OVERFLOW {
            continue;
        }
        if result != ERROR_SUCCESS {
            return Err(io::Error::from_raw_os_error(result as i32));
        }
        let mut adapter = head;
        let mut choices = Vec::new();
        while !adapter.is_null() {
            let record = unsafe { &*adapter };
            if record.OperStatus == IfOperStatusUp {
                let mut node = record.FirstDnsServerAddress;
                while !node.is_null() {
                    let dns = unsafe { &*node };
                    let address = dns.Address;
                    if !address.lpSockaddr.is_null()
                        && address.iSockaddrLength >= 2
                        && address.iSockaddrLength <= 128
                    {
                        let raw = unsafe {
                            std::slice::from_raw_parts(
                                address.lpSockaddr as *const u8,
                                address.iSockaddrLength as usize,
                            )
                        };
                        if let Some(endpoint) = windows_dns_address(raw) {
                            let ip = endpoint.ip();
                            if !is_virtual(ip)
                                && !ip.is_unspecified()
                                && !ip.is_multicast()
                                && !matches!(ip, IpAddr::V4(ip) if ip.is_broadcast())
                            {
                                let metric = if endpoint.is_ipv6() {
                                    record.Ipv6Metric
                                } else {
                                    record.Ipv4Metric
                                };
                                choices.push((metric, endpoint));
                            }
                        }
                    }
                    node = dns.Next;
                }
            }
            adapter = record.Next;
        }
        choices.sort_by_key(|(metric, _)| *metric);
        return choices
            .first()
            .map(|(_, address)| *address)
            .ok_or_else(no_resolver);
    }
    Err(io::Error::new(
        io::ErrorKind::Other,
        "DNS configuration changed repeatedly; retry or specify --dns ADDRESS",
    ))
}

pub fn upstream() -> SocketAddr {
    *UPSTREAM
        .get()
        .expect("DNS must be configured before the relay starts")
}

pub fn is_virtual(ip: IpAddr) -> bool {
    ip == IpAddr::V4(Ipv4Addr::from(VIRTUAL_DNS)) || ip == IpAddr::V6(VIRTUAL_DNS_V6)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_dns_accepts_both_families_and_optional_ports() {
        assert_eq!(
            parse_upstream("192.0.2.53").unwrap(),
            "192.0.2.53:53".parse().unwrap()
        );
        assert_eq!(
            parse_upstream("2001:db8::53").unwrap(),
            "[2001:db8::53]:53".parse().unwrap()
        );
        assert_eq!(
            parse_upstream("127.0.0.1:5300").unwrap(),
            "127.0.0.1:5300".parse().unwrap()
        );
        assert_eq!(
            parse_upstream("[::1]:5300").unwrap(),
            "[::1]:5300".parse().unwrap()
        );
        assert!(parse_upstream("[::1]:0").is_err());
        assert!(parse_upstream("dns.example").is_err());
    }

    #[test]
    fn windows_dns_decodes_ipv4_and_ipv6_scope_without_unaligned_access() {
        let mut v4 = [0; 16];
        v4[..2].copy_from_slice(&2u16.to_ne_bytes());
        v4[4..8].copy_from_slice(&[192, 0, 2, 53]);
        assert_eq!(
            windows_dns_address(&v4),
            Some("192.0.2.53:53".parse().unwrap())
        );
        let mut v6 = [0; 28];
        v6[..2].copy_from_slice(&23u16.to_ne_bytes());
        v6[8..24].copy_from_slice(&"fe80::53".parse::<Ipv6Addr>().unwrap().octets());
        v6[24..28].copy_from_slice(&17u32.to_ne_bytes());
        assert_eq!(
            windows_dns_address(&v6),
            Some("[fe80::53%17]:53".parse().unwrap())
        );
        assert_eq!(windows_dns_address(&v6[..27]), None);
        assert_eq!(windows_dns_address(&[0]), None);
    }

    #[test]
    fn system_resolver_supports_both_address_families_and_comments() {
        assert_eq!(parse_resolver("# nameserver 1.1.1.1\nsearch local\nnameserver ::1\nnameserver 127.0.0.53 # stub\n"), Some(IpAddr::V6(Ipv6Addr::LOCALHOST)));
        assert_eq!(parse_resolver("nameserver garbage\n"), None);
        assert_eq!(
            parse_resolver("nameserver 192.0.2.53\nnameserver 198.51.100.53"),
            Some(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 53)))
        );
    }
}
