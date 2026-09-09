// SPDX-License-Identifier: Apache-2.0
// Probes a relay endpoint from the computer without a VPN, separately checking
// the transport, DNS/UDP and TCP egress.
#include "tunnel.h"
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

using Bytes = std::vector<uint8_t>;
using Clock = std::chrono::steady_clock;
static uint16_t U16(const Bytes &b, size_t p) { return (uint16_t(b.at(p)) << 8) | b.at(p + 1); }
static uint32_t U32(const Bytes &b, size_t p) { return (uint32_t(U16(b, p)) << 16) | U16(b, p + 2); }
static void Put16(Bytes &b, size_t p, uint16_t v) { b.at(p) = v >> 8; b.at(p + 1) = v; }
static void Put32(Bytes &b, size_t p, uint32_t v) { Put16(b, p, v >> 16); Put16(b, p + 2, v); }
static void Require(bool b, const char *message) { if (!b) throw std::runtime_error(message); }
static uint16_t Checksum(const uint8_t *p, size_t n, uint32_t sum = 0) {
    while (n > 1) { sum += (uint16_t(p[0]) << 8) | p[1]; p += 2; n -= 2; }
    if (n) sum += uint16_t(p[0]) << 8;
    while (sum >> 16) sum = (sum & 65535) + (sum >> 16);
    return static_cast<uint16_t>(~sum);
}
static uint32_t Ip(const std::string &s) {
    in_addr a{}; Require(inet_pton(AF_INET, s.c_str(), &a) == 1, "Invalid IPv4 address"); return ntohl(a.s_addr);
}
static std::string IpText(uint32_t ip) {
    in_addr a{}; a.s_addr = htonl(ip); char buffer[INET_ADDRSTRLEN];
    Require(inet_ntop(AF_INET, &a, buffer, sizeof(buffer)) != nullptr, "inet_ntop"); return buffer;
}
static Bytes Packet(uint8_t protocol, uint32_t dst, size_t payload) {
    Bytes b(20 + payload, 0); b[0] = 0x45; b[8] = 64; b[9] = protocol;
    Put16(b, 2, b.size()); Put16(b, 6, 0x4000); Put32(b, 12, 0x0a000002); Put32(b, 16, dst);
    Put16(b, 10, Checksum(b.data(), 20)); return b;
}
static Bytes Udp(uint32_t dst, const Bytes &data) {
    Bytes b = Packet(17, dst, data.size() + 8);
    Put16(b, 20, 42053); Put16(b, 22, 53); Put16(b, 24, data.size() + 8);
    std::copy(data.begin(), data.end(), b.begin() + 28); return b;
}
static Bytes Tcp(uint32_t dst, uint16_t port, uint32_t seq, uint32_t ack, uint8_t flags, const std::string &data = "") {
    Bytes b = Packet(6, dst, 20 + data.size());
    Put16(b, 20, 42080); Put16(b, 22, port); Put32(b, 24, seq); Put32(b, 28, ack);
    b[32] = 0x50; b[33] = flags; Put16(b, 34, 65535);
    std::copy(data.begin(), data.end(), b.begin() + 40);
    uint32_t sum = U16(b, 12) + U16(b, 14) + U16(b, 16) + U16(b, 18) + 6 + b.size() - 20;
    Put16(b, 36, Checksum(b.data() + 20, b.size() - 20, sum)); return b;
}
static void Wait(int fd, short events, Clock::time_point deadline) {
    int timeout = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count());
    Require(timeout > 0, "Relay timeout"); pollfd p{fd, events, 0};
    int n;
    do { n = poll(&p, 1, timeout); } while (n < 0 && errno == EINTR);
    Require(n > 0 && (p.revents & events), "Relay poll timeout or closed connection");
}
static void Send(int fd, const Bytes &b) {
    size_t off = 0; auto deadline = Clock::now() + std::chrono::seconds(10);
    while (off < b.size()) {
        Wait(fd, POLLOUT, deadline);
        ssize_t n = send(fd, b.data() + off, b.size() - off, MSG_NOSIGNAL);
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        Require(n > 0, "Relay write failed"); off += n;
    }
}
static void Read(int fd, uint8_t *b, size_t length, Clock::time_point deadline) {
    while (length) {
        Wait(fd, POLLIN, deadline);
        ssize_t n = recv(fd, b, length, 0);
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        Require(n > 0, "Relay read failed"); b += n; length -= n;
    }
}
static Bytes Receive(int fd, Clock::time_point deadline) {
    Bytes b(20); Read(fd, b.data(), b.size(), deadline);
    Require(b[0] >> 4 == 4 && U16(b, 2) >= 20, "Invalid relay IP packet");
    b.resize(U16(b, 2)); Read(fd, b.data() + 20, b.size() - 20, deadline); return b;
}
static size_t SkipName(const Bytes &b, size_t pos) {
    for (int i = 0; i < 128; ++i) {
        uint8_t n = b.at(pos++);
        if ((n & 0xc0) == 0xc0) { b.at(pos); return pos + 1; }
        Require(n < 64, "Invalid DNS label"); if (!n) return pos;
        pos += n; Require(pos < b.size(), "Truncated DNS name");
    }
    throw std::runtime_error("DNS name too long");
}
static uint32_t Dns(int fd, uint32_t resolver, const std::string &domain) {
    Bytes q(12, 0); Put16(q, 0, 0x4d46); Put16(q, 2, 0x0100); Put16(q, 4, 1);
    size_t start = 0;
    do {
        size_t end = domain.find('.', start); if (end == std::string::npos) end = domain.size();
        Require(end > start && end - start < 64, "Invalid DNS domain");
        q.push_back(end - start); q.insert(q.end(), domain.begin() + start, domain.begin() + end); start = end + 1;
    } while (start < domain.size());
    q.insert(q.end(), {0, 0, 1, 0, 1}); Send(fd, Udp(resolver, q));
    Bytes b = Receive(fd, Clock::now() + std::chrono::seconds(12));
    size_t h = (b[0] & 15) * 4;
    Require(b[9] == 17 && U32(b, 12) == resolver && U16(b, h + 2) == 42053, "Unexpected DNS flow");
    Bytes dns(b.begin() + h + 8, b.end());
    Require(U16(dns, 0) == 0x4d46 && (U16(dns, 2) & 0x800f) == 0x8000, "DNS response failed");
    size_t pos = 12;
    for (unsigned i = 0; i < U16(dns, 4); ++i) pos = SkipName(dns, pos) + 4;
    for (unsigned i = 0; i < U16(dns, 6); ++i) {
        pos = SkipName(dns, pos); uint16_t type = U16(dns, pos), length = U16(dns, pos + 8); pos += 10;
        if (type == 1 && length == 4) { uint32_t result = U32(dns, pos); std::cout << "DNS_OK " << domain << " " << IpText(result) << std::endl; return result; }
        pos += length; Require(pos <= dns.size(), "Truncated DNS answer");
    }
    throw std::runtime_error("DNS has no A record");
}
static void Http(int fd, uint32_t dst, uint16_t port, const std::string &host, const std::string &path) {
    uint32_t seq = 123456, ack = 0;
    Send(fd, Tcp(dst, port, seq, ack, 2));
    Bytes b = Receive(fd, Clock::now() + std::chrono::seconds(12));
    size_t h = (b[0] & 15) * 4;
    Require(b[9] == 6 && U32(b, 12) == dst && (b.at(h + 13) & 0x12) == 0x12 && U32(b, h + 8) == seq + 1, "TCP SYN-ACK failed");
    seq++; ack = U32(b, h + 4) + 1;
    Send(fd, Tcp(dst, port, seq, ack, 0x10));
    std::string request = "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n";
    Send(fd, Tcp(dst, port, seq, ack, 0x18, request)); seq += request.size();
    std::string response;
    auto deadline = Clock::now() + std::chrono::seconds(20);
    bool finished = false;
    while (!finished) {
        b = Receive(fd, deadline); h = (b[0] & 15) * 4;
        Require(b[9] == 6 && U32(b, 12) == dst && U16(b, h + 2) == 42080, "Unexpected TCP flow");
        uint8_t flags = b.at(h + 13); Require(!(flags & 4), "TCP reset");
        size_t payload = h + (b.at(h + 12) >> 4) * 4;
        Require(payload <= b.size(), "Invalid TCP header");
        size_t length = b.size() - payload;
        if (length || flags & 1) {
            if (U32(b, h + 4) == ack) {
                response.append(reinterpret_cast<const char *>(b.data() + payload), length); ack += length;
                if (flags & 1) { ack++; finished = true; }
            }
            Send(fd, Tcp(dst, port, seq, ack, 0x10));
        }
        Require(response.size() < 4 * 1024 * 1024, "Response exceeds probe limit");
    }
    Send(fd, Tcp(dst, port, seq, ack, 0x11));
    Require(response.rfind("HTTP/1.", 0) == 0, "Invalid HTTP response");
    std::cout << "HTTP_OK " << response.substr(0, response.find("\r\n")) << " bytes=" << response.size() << "\n";
    std::cout << "RESPONSE_BEGIN\n" << response.substr(0, 2048) << "\nRESPONSE_END\n";
}

int main(int argc, char **argv) {
    int fd = -1;
    try {
        if (argc < 3) throw std::runtime_error("Usage: packet-probe PORT handshake | PORT dns RESOLVER DOMAIN | PORT http IP PORT HOST PATH");
        int port = std::stoi(argv[1]); Require(port > 0 && port <= 65535, "Invalid relay port");
        fd = tether::CreateSocket(); Require(fd >= 0, "Socket creation failed");
        uint32_t id;
        const char *relayAddress = std::getenv("TETHER_PROBE_RELAY_IP");
        int err = tether::Connect(fd, port, &id, relayAddress ? Ip(relayAddress) : 0x7f000001);
        if (err) throw std::runtime_error("Connect failed: " + std::string(strerror(err)));
        std::cout << "USB_RELAY_OK client=" << id << std::endl;
        std::string command = argv[2];
        if (command == "dns" && argc == 5) Dns(fd, Ip(argv[3]), argv[4]);
        else if (command == "http" && argc == 7) {
            int dstPort = std::stoi(argv[4]); Require(dstPort > 0 && dstPort <= 65535, "Invalid HTTP port");
            Http(fd, Ip(argv[3]), dstPort, argv[5], argv[6]);
        } else Require(command == "handshake" && argc == 3, "Invalid probe arguments");
        close(fd); return 0;
    } catch (const std::exception &e) {
        if (fd >= 0) close(fd);
        std::cerr << "PROBE_FAILED " << e.what() << std::endl; return 1;
    }
}
