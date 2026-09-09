// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace tether {
int CreateSocket();
// Consumes the 4-byte gnirehtet client id; returns 0 or a positive errno.
int Connect(int fd, uint16_t port, uint32_t *clientId = nullptr, uint32_t address = 0x7f000001);

class Tunnel {
public:
    ~Tunnel();
    // Duplicates both fds. Caller retains ownership of the originals.
    bool Start(int tunFd, int socketFd);
    void Stop();
    std::string Status();
private:
    void Run(int tunFd, int socketFd);
    void Fail(int code);
    std::thread worker_;
    std::atomic<bool> stopping_{false};
    std::atomic<bool> running_{false};
    std::atomic<int> error_{0};
    std::atomic<uint64_t> txBytes_{0}, rxBytes_{0}, txPackets_{0}, rxPackets_{0}, dropped_{0};
};
}
