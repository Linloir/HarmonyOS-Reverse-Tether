// SPDX-License-Identifier: Apache-2.0
use std::str::FromStr;

/// Host policy has priority over the local phone setting. Inherit allows the
/// phone to opt in; a new phone defaults off, preserving IPv4-only behavior.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Ipv6Policy {
    #[default]
    Inherit,
    Off,
    On,
}

pub const HANDSHAKE_MAGIC: u32 = 0xa500_0000;
pub const HANDSHAKE_MAGIC_MASK: u32 = 0xff00_0000;
pub const IPV6_CAPABLE: u32 = 0x0020_0000;
pub const CLIENT_ID_MASK: u32 = 0x001f_ffff;

impl Ipv6Policy {
    pub fn wire_id(self, id: u32) -> u32 {
        let policy = match self {
            Self::Inherit => 0,
            Self::Off => 1,
            Self::On => 2,
        };
        HANDSHAKE_MAGIC | IPV6_CAPABLE | (policy << 22) | (id & CLIENT_ID_MASK)
    }
    pub fn permits_ipv6(self) -> bool {
        self != Self::Off
    }
}

impl FromStr for Ipv6Policy {
    type Err = &'static str;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "inherit" => Ok(Self::Inherit),
            "off" => Ok(Self::Off),
            "on" => Ok(Self::On),
            _ => Err("IPv6 policy must be inherit, off, or on"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handshake_is_four_bytes_and_policy_is_independent_of_counter() {
        assert_eq!(Ipv6Policy::Inherit.wire_id(0), 0xa520_0000);
        assert_eq!(Ipv6Policy::Off.wire_id(0), 0xa560_0000);
        assert_eq!(Ipv6Policy::On.wire_id(0), 0xa5a0_0000);
        for policy in [Ipv6Policy::Inherit, Ipv6Policy::Off, Ipv6Policy::On] {
            let id = policy.wire_id(u32::MAX);
            assert_eq!(id & HANDSHAKE_MAGIC_MASK, HANDSHAKE_MAGIC);
            assert_eq!(id & CLIENT_ID_MASK, CLIENT_ID_MASK);
            assert_ne!((id >> 22) & 3, 3); // Reserved policy is never emitted.
        }
        assert!(!Ipv6Policy::Off.permits_ipv6());
        assert!(Ipv6Policy::Inherit.permits_ipv6());
        assert!("true".parse::<Ipv6Policy>().is_err());
    }
}
