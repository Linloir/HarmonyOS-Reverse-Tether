// SPDX-License-Identifier: Apache-2.0
#include "tunnel.h"
#include <cassert>
#include <chrono>
#include <cstring>
#include <iostream>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

static void ReadExact(int fd, uint8_t *buffer, size_t size) {
    while (size) {
        pollfd p{fd, POLLIN, 0};
        assert(poll(&p, 1, 3000) == 1);
        ssize_t count = read(fd, buffer, size);
        assert(count > 0);
        buffer += count; size -= count;
    }
}

static void IPv6Framing() {
    int tun[2], relay[2];
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, tun) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, relay) == 0);
    tether::Tunnel tunnel;
    assert(tunnel.Start(tun[0], relay[0], true));
    std::vector<uint8_t> packet(48, 0);
    packet[0] = 0x60; packet[5] = 8; packet[6] = 17; packet[7] = 64;
    packet[8] = 0xfd; packet[23] = 2; packet[24] = 0xfd; packet[39] = 3;
    packet[45] = 8;
    assert(write(tun[1], packet.data(), packet.size()) == 48);
    uint8_t buffer[65575];
    ReadExact(relay[1], buffer, packet.size());
    assert(memcmp(buffer, packet.data(), packet.size()) == 0);
    // IPv6's length field arrives later than IPv4's. Each partial boundary
    // must wait for enough data, including a split before payload-length byte.
    for (size_t split : {size_t(3), size_t(4), size_t(5), size_t(6), size_t(39)}) {
        assert(write(relay[1], packet.data(), split) == static_cast<ssize_t>(split));
        pollfd pending{tun[1], POLLIN, 0};
        assert(poll(&pending, 1, 10) == 0);
        assert(write(relay[1], packet.data()+split, packet.size()-split) == static_cast<ssize_t>(packet.size()-split));
        ReadExact(tun[1], buffer, packet.size());
        assert(memcmp(buffer, packet.data(), packet.size()) == 0);
    }
    uint8_t v4[28] = {0x45, 0, 0, 28, 0, 0, 0, 0, 64, 17};
    std::vector<uint8_t> mixed(packet);
    mixed.insert(mixed.end(), v4, v4+sizeof(v4));
    mixed.insert(mixed.end(), packet.begin(), packet.end());
    assert(write(relay[1], mixed.data(), mixed.size()) == static_cast<ssize_t>(mixed.size()));
    for (size_t expected : {packet.size(), sizeof(v4), packet.size()}) {
        pollfd pending{tun[1], POLLIN, 0}; assert(poll(&pending, 1, 3000) == 1);
        assert(read(tun[1], buffer, sizeof(buffer)) == static_cast<ssize_t>(expected));
    }
    // Maximum non-jumbo IPv6 frame has 65535 bytes of payload plus its header.
    std::vector<uint8_t> maximum(65575, 0); maximum[0] = 0x60; maximum[4] = 255; maximum[5] = 255;
    assert(write(relay[1], maximum.data(), maximum.size()) == static_cast<ssize_t>(maximum.size()));
    ReadExact(tun[1], buffer, maximum.size());
    assert(memcmp(buffer, maximum.data(), maximum.size()) == 0);
    tunnel.Stop();
    assert(tunnel.Start(tun[0], relay[0], false));
    assert(write(tun[1], packet.data(), packet.size()) == 48);
    pollfd pending{relay[1], POLLIN, 0}; assert(poll(&pending, 1, 50) == 0);
    assert(write(relay[1], packet.data(), packet.size()) == 48);
    for (int i=0; i<100 && tunnel.Status().find("\"state\":\"error\"")==std::string::npos; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(tunnel.Status().find("\"state\":\"error\"")!=std::string::npos);
    tunnel.Stop();
    for (int fd : {tun[0], tun[1], relay[0], relay[1]}) close(fd);
}

static void TunFailureClassification() {
    int tun[2], relay[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, tun) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, relay) == 0);
    tether::Tunnel tunnel;
    assert(tunnel.Start(tun[0], relay[0]));
    close(tun[1]);
    for (int i=0; i<100 && tunnel.Status().find("\"state\":\"error\"")==std::string::npos; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(tunnel.Status().find("\"tunError\":true")!=std::string::npos);
    tunnel.Stop();
    for (int fd : {tun[0], relay[0], relay[1]}) close(fd);
}

int main() {
    int tun[2], relay[2];
    assert(socketpair(AF_UNIX, SOCK_DGRAM, 0, tun) == 0);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, relay) == 0);
    tether::Tunnel tunnel;
    assert(tunnel.Start(tun[0], relay[0]));
    uint8_t packet[28] = {0x45, 0, 0, 28, 0, 0, 0, 0, 64, 17};
    packet[12] = 10; packet[15] = 2; packet[16] = 1; packet[19] = 1;
    packet[24] = 0; packet[25] = 8;
    assert(write(tun[1], packet, sizeof(packet)) == sizeof(packet));
    uint8_t buffer[56];
    ReadExact(relay[1], buffer, sizeof(packet));
    assert(memcmp(packet, buffer, sizeof(packet)) == 0);

    // A real TUN write must preserve each IP packet even when TCP splits the
    // header and coalesces the rest of this packet with the following packet.
    assert(write(relay[1], packet, 3) == 3);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    std::vector<uint8_t> pair(packet + 3, packet + sizeof(packet));
    pair.insert(pair.end(), packet, packet + sizeof(packet));
    assert(write(relay[1], pair.data(), pair.size()) == static_cast<ssize_t>(pair.size()));
    for (int i = 0; i < 2; ++i) {
        pollfd p{tun[1], POLLIN, 0};
        assert(poll(&p, 1, 3000) == 1);
        assert(read(tun[1], buffer, sizeof(buffer)) == sizeof(packet));
        assert(memcmp(packet, buffer, sizeof(packet)) == 0);
    }
    assert(tunnel.Status().find("\"rxPackets\":2") != std::string::npos);

    // Unknown framing fails closed instead of treating partial input as an IP
    // packet or allocating unbounded storage.
    uint8_t bad[] = {0x45, 0, 0, 1};
    assert(write(relay[1], bad, sizeof(bad)) == sizeof(bad));
    for (int i = 0; i < 100 && tunnel.Status().find("\"state\":\"error\"") == std::string::npos; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(tunnel.Status().find("\"state\":\"error\"") != std::string::npos);
    assert(tunnel.Status().find("\"tunError\":false") != std::string::npos);
    tunnel.Stop();

    // Restart uses new duplicates, and stopping an idle poll stays bounded.
    assert(tunnel.Start(tun[0], relay[0]));
    auto start = std::chrono::steady_clock::now();
    tunnel.Stop();
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(1));
    for (int fd : {tun[0], tun[1], relay[0], relay[1]}) close(fd);
    IPv6Framing();
    TunFailureClassification();
    std::cout << "PASS: IPv4/IPv6 packets, split/coalesced framing, maximum IPv6 payload, disabled IPv6, invalid framing, restart, bounded stop\n";
}
