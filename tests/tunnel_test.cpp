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
    tunnel.Stop();

    // Restart uses new duplicates, and stopping an idle poll stays bounded.
    assert(tunnel.Start(tun[0], relay[0]));
    auto start = std::chrono::steady_clock::now();
    tunnel.Stop();
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(1));
    for (int fd : {tun[0], tun[1], relay[0], relay[1]}) close(fd);
    std::cout << "PASS: bidirectional packets, TCP fragmentation/coalescing, invalid framing, restart, bounded stop\n";
}
