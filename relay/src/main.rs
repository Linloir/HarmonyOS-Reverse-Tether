// SPDX-License-Identifier: Apache-2.0
mod logger;

fn main() {
    let mut args = std::env::args().skip(1);
    let mut port = 31417;
    let mut dns = None;
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
        "--dns" => dns = Some(args.next().and_then(|s| s.parse().ok()).unwrap_or_else(|| usage())),
        "--help" => {
            println!("harmony-relay [--port PORT] [--dns IPV4]\nListens on 127.0.0.1 only; default port 31417.\nDNS defaults to /etc/resolv.conf; client uses virtual 10.0.0.3.");
            return;
        }
        _ => usage(),
      }
    }
    logger::init().expect("logger initialization");
    let dns = relaylib::dns::configure(dns).unwrap_or_else(|error| {
        eprintln!("DNS configuration failed: {}", error); std::process::exit(2);
    });
    log::info!("Virtual DNS 10.0.0.3:53 -> {}", dns);
    log::info!("Harmony relay {} listening on 127.0.0.1:{}", env!("CARGO_PKG_VERSION"), port);
    if let Err(err) = relaylib::relay(port) {
        eprintln!("Relay failed: {}", err);
        std::process::exit(1);
    }
}

fn usage() -> ! {
    eprintln!("Usage: harmony-relay [--port 1..65535] [--dns IPV4] | --version | --help");
    std::process::exit(2);
}
