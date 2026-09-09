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
        None => parse_resolver(&std::fs::read_to_string("/etc/resolv.conf")?)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "No IPv4 DNS resolver; specify --dns ADDRESS"))?,
    };
    if u32::from(address) == VIRTUAL_DNS || address.is_unspecified() || address.is_multicast() || address.is_broadcast() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "Invalid upstream DNS address"));
    }
    let upstream = SocketAddrV4::new(address, 53);
    UPSTREAM.set(upstream).map_err(|_| io::Error::new(io::ErrorKind::AlreadyExists, "DNS already configured"))?;
    Ok(upstream)
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
