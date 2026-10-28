// SPDX-License-Identifier: Apache-2.0
mod logger;

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--network-quality-capabilities") {
        println!("root-listener-v1");
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("--ipv6-capabilities") {
        println!("ipv6-policy-v1");
        return;
    }
    let mut args = std::env::args().skip(1);
    let mut port = 31417;
    let mut dns = None;
    let mut ipv6 = relaylib::policy::Ipv6Policy::Inherit;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--version" => {
                println!("harmony-relay {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "--port" => match args.next().and_then(|s| s.parse::<u16>().ok()) {
                Some(p) if p != 0 => port = p,
                _ => usage(),
            },
            "--ipv6" => {
                ipv6 = args
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or_else(|| usage())
            }
            "--dns" => {
                dns = Some(
                    args.next()
                        .and_then(|s| relaylib::dns::parse_upstream(&s).ok())
                        .unwrap_or_else(|| usage()),
                )
            }
            "--help" => {
                println!("harmony-relay [--port PORT] [--dns ADDRESS] [--ipv6 inherit|off|on]\nListens on 127.0.0.1 only; default port 31417.\nDNS ADDRESS accepts an IP, IPv4:PORT, or [IPv6]:PORT (default port 53).\nDNS defaults to the computer's resolver; virtual addresses are 10.0.0.3 and fd00:7265:7674::3.\nIPv6 policy defaults to inherit (phone default off); explicit host off/on overrides the phone setting.");
                return;
            }
            _ => usage(),
        }
    }
    logger::init().expect("logger initialization");
    let dns = relaylib::dns::configure(dns).unwrap_or_else(|error| {
        eprintln!("DNS configuration failed: {}", error);
        std::process::exit(2);
    });
    log::info!(
        "Virtual DNS 10.0.0.3 / fd00:7265:7674::3 port 53 -> {}",
        dns
    );
    log::info!("IPv6 policy: {:?}", ipv6);
    log::info!(
        "Harmony relay {} listening on 127.0.0.1:{}",
        env!("CARGO_PKG_VERSION"),
        port
    );
    if let Err(err) = relaylib::relay_with_policy(port, ipv6) {
        eprintln!("Relay failed: {}", err);
        std::process::exit(1);
    }
}

fn usage() -> ! {
    eprintln!("Usage: harmony-relay [--port 1..65535] [--dns ADDRESS] [--ipv6 inherit|off|on] | --version | --help");
    std::process::exit(2);
}
