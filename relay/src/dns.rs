// SPDX-License-Identifier: Apache-2.0
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::sync::OnceLock;

pub const VIRTUAL_DNS: u32 = 0x0a000003;
static UPSTREAM: OnceLock<SocketAddrV4> = OnceLock::new();

pub fn parse_resolver(text: &str) -> Option<Ipv4Addr> {
    text.lines().find_map(|line| {
        let mut words = line.split('#').next()?.split_whitespace();
        if words.next()? != "nameserver" { return None; }
        words.next()?.parse().ok()
    })
}

pub fn configure(explicit: Option<Ipv4Addr>) -> io::Result<SocketAddrV4> {
    let address = match explicit {
        Some(ip) => ip,
        None => system_resolver()?,
    };
    if u32::from(address) == VIRTUAL_DNS || address.is_unspecified() || address.is_multicast() || address.is_broadcast() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Invalid upstream DNS address"));
    }
    let upstream = SocketAddrV4::new(address, 53);
    UPSTREAM.set(upstream).map_err(|_| io::Error::new(io::ErrorKind::AlreadyExists, "DNS already configured"))?;
    Ok(upstream)
}

fn no_resolver() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "No IPv4 DNS resolver; specify --dns ADDRESS")
}

#[cfg(not(windows))]
fn system_resolver() -> io::Result<Ipv4Addr> {
    parse_resolver(&std::fs::read_to_string("/etc/resolv.conf")?).ok_or_else(no_resolver)
}

#[cfg(windows)]
fn system_resolver() -> io::Result<Ipv4Addr> {
    use std::mem::size_of;
    use winapi::shared::winerror::{ERROR_BUFFER_OVERFLOW, ERROR_SUCCESS};
    use winapi::um::iphlpapi::GetNetworkParams;
    use winapi::um::iptypes::{FIXED_INFO, IP_ADDR_STRING};

    // GetNetworkParams supplies a DNS list in caller-owned storage. usize storage
    // provides the pointer alignment required by FIXED_INFO and its linked nodes.
    let mut size = size_of::<FIXED_INFO>() as u32;
    for _ in 0..3 {
        let words = (size as usize + size_of::<usize>() - 1) / size_of::<usize>();
        let mut storage = vec![0usize; words];
        let info = storage.as_mut_ptr() as *mut FIXED_INFO;
        let result = unsafe { GetNetworkParams(info, &mut size) };
        if result == ERROR_BUFFER_OVERFLOW {
            continue;
        }
        if result != ERROR_SUCCESS {
            return Err(io::Error::from_raw_os_error(result as i32));
        }
        // The API owns the layout and guarantees that the linked nodes and
        // fixed-size address strings remain valid until storage is released.
        let mut node: *const IP_ADDR_STRING = unsafe { &(*info).DnsServerList };
        while !node.is_null() {
            let record = unsafe { &*node };
            let text: String = record.IpAddress.String.iter().take_while(|&&c| c != 0)
                .map(|&c| c as u8 as char).collect();
            if let Ok(address) = text.parse::<Ipv4Addr>() {
                if !address.is_unspecified() && !address.is_multicast()
                    && !address.is_broadcast() && u32::from(address) != VIRTUAL_DNS {
                    return Ok(address);
                }
            }
            node = record.Next;
        }
        return Err(no_resolver());
    }
    Err(io::Error::new(io::ErrorKind::Other, "DNS configuration changed repeatedly; retry or specify --dns ADDRESS"))
}

pub fn upstream() -> SocketAddrV4 {
    *UPSTREAM.get().expect("DNS must be configured before the relay starts")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn system_resolver_supports_stub_and_skips_ipv6_comments() {
        assert_eq!(parse_resolver("# nameserver 1.1.1.1\nsearch local\nnameserver ::1\nnameserver 127.0.0.53 # stub\n"), Some(Ipv4Addr::new(127, 0, 0, 53)));
        assert_eq!(parse_resolver("nameserver garbage\n"), None);
        assert_eq!(parse_resolver("nameserver 192.0.2.53\nnameserver 198.51.100.53"), Some(Ipv4Addr::new(192, 0, 2, 53)));
    }
}
