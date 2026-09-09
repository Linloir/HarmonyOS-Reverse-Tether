// SPDX-License-Identifier: Apache-2.0
#include "tunnel.h"
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <deque>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace tether {
namespace {
constexpr size_t MAX_PACKET = 65535;
constexpr size_t MAX_QUEUE = 1024 * 1024;
using Clock = std::chrono::steady_clock;
struct Fd {
    int value;
    ~Fd() { if (value >= 0) close(value); }
};
bool Nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}
int Wait(int fd, short events, Clock::time_point deadline) {
    for (;;) {
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        if (ms <= 0) return ETIMEDOUT;
        pollfd p{fd, events, 0};
        int n = poll(&p, 1, static_cast<int>(ms));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return errno;
        if (n == 0) return ETIMEDOUT;
        if (p.revents & events) return 0;
        return ECONNRESET;
    }
}
}

int CreateSocket() {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (!Nonblock(fd)) { close(fd); return -1; }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    return fd;
}

int Connect(int fd, uint16_t port, uint32_t *clientId, uint32_t address) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(address);
    auto deadline = Clock::now() + std::chrono::seconds(5);
    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        if (errno != EINPROGRESS) return errno;
        int result = Wait(fd, POLLOUT, deadline);
        if (result) return result;
        int err = 0;
        socklen_t size = sizeof(err);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size) != 0) return errno;
        if (err) return err;
    }
    uint8_t id[4];
    size_t offset = 0;
    while (offset < sizeof(id)) {
        ssize_t n = recv(fd, id + offset, sizeof(id) - offset, 0);
        if (n > 0) { offset += n; continue; }
        if (n == 0) return ECONNRESET;
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return errno;
        int result = Wait(fd, POLLIN, deadline);
        if (result) return result;
    }
    if (clientId) *clientId = (uint32_t(id[0]) << 24) | (uint32_t(id[1]) << 16) | (uint32_t(id[2]) << 8) | id[3];
    return 0;
}

Tunnel::~Tunnel() { Stop(); }

bool Tunnel::Start(int tunFd, int socketFd) {
    Stop();
    int tun = dup(tunFd);
    int sock = dup(socketFd);
    if (tun < 0 || sock < 0 || !Nonblock(tun) || !Nonblock(sock)) {
        int err = errno;
        if (tun >= 0) close(tun);
        if (sock >= 0) close(sock);
        error_ = err;
        return false;
    }
    stopping_ = false;
    error_ = 0;
    txBytes_ = rxBytes_ = txPackets_ = rxPackets_ = dropped_ = 0;
    running_ = true;
    try {
        worker_ = std::thread(&Tunnel::Run, this, tun, sock);
    } catch (...) {
        close(tun); close(sock);
        running_ = false; error_ = EAGAIN;
        return false;
    }
    return true;
}

void Tunnel::Stop() {
    stopping_ = true;
    if (worker_.joinable()) worker_.join();
    running_ = false;
}

void Tunnel::Fail(int code) { error_ = code; }

std::string Tunnel::Status() {
    std::ostringstream out;
    out << "{\"state\":\"" << (running_ ? "running" : error_ ? "error" : "idle")
        << "\",\"errno\":" << error_ << ",\"txBytes\":" << txBytes_
        << ",\"rxBytes\":" << rxBytes_ << ",\"txPackets\":" << txPackets_
        << ",\"rxPackets\":" << rxPackets_ << ",\"dropped\":" << dropped_ << "}";
    return out.str();
}

void Tunnel::Run(int tunFd, int socketFd) {
    Fd tun{tunFd}, sock{socketFd};
    std::vector<uint8_t> outbound, incoming;
    std::deque<std::vector<uint8_t>> packets;
    size_t sendOffset = 0, queuedBytes = 0;
    uint8_t buffer[MAX_PACKET];
    while (!stopping_) {
        short tunEvents = outbound.size() - sendOffset < MAX_QUEUE - MAX_PACKET ? POLLIN : 0;
        if (!packets.empty()) tunEvents |= POLLOUT;
        short sockEvents = queuedBytes + incoming.size() < MAX_QUEUE - MAX_PACKET ? POLLIN : 0;
        if (sendOffset < outbound.size()) sockEvents |= POLLOUT;
        pollfd fds[] = {{tun.value, tunEvents, 0}, {sock.value, sockEvents, 0}};
        int n = poll(fds, 2, 200);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { Fail(errno); break; }
        if (stopping_) break;
        if ((fds[0].revents | fds[1].revents) & (POLLNVAL | POLLERR)) { Fail(EIO); break; }
        if (fds[0].revents & POLLIN) {
            ssize_t count = read(tun.value, buffer, sizeof(buffer));
            if (count > 0) {
                size_t size = static_cast<size_t>(count);
                size_t header = (buffer[0] & 0x0f) * 4;
                if (size < 20 || buffer[0] >> 4 != 4 || header < 20 || header > size ||
                    ((size_t(buffer[2]) << 8) | buffer[3]) != size) {
                    ++dropped_;
                } else {
                    if (sendOffset) {
                        outbound.erase(outbound.begin(), outbound.begin() + sendOffset);
                        sendOffset = 0;
                    }
                    outbound.insert(outbound.end(), buffer, buffer + size);
                    ++txPackets_; txBytes_ += size;
                }
            } else if (count == 0) { Fail(ENODEV); break; }
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { Fail(errno); break; }
        }
        if (fds[1].revents & POLLOUT) {
            ssize_t count = send(sock.value, outbound.data() + sendOffset, outbound.size() - sendOffset, MSG_NOSIGNAL);
            if (count > 0) {
                sendOffset += count;
                if (sendOffset == outbound.size()) { outbound.clear(); sendOffset = 0; }
            } else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { Fail(errno); break; }
        }
        if (fds[1].revents & POLLIN) {
            ssize_t count = recv(sock.value, buffer, sizeof(buffer), 0);
            if (count == 0) { Fail(ECONNRESET); break; }
            if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { Fail(errno); break; }
            if (count > 0) incoming.insert(incoming.end(), buffer, buffer + count);
            size_t offset = 0;
            while (incoming.size() - offset >= 4) {
                const uint8_t *ip = incoming.data() + offset;
                size_t header = (ip[0] & 0x0f) * 4;
                size_t length = (size_t(ip[2]) << 8) | ip[3];
                if (ip[0] >> 4 != 4 || header < 20 || length < header) { Fail(EPROTO); break; }
                if (incoming.size() - offset < length) break;
                packets.emplace_back(ip, ip + length);
                queuedBytes += length;
                offset += length;
            }
            if (error_) break;
            if (offset) incoming.erase(incoming.begin(), incoming.begin() + offset);
        }
        if ((fds[0].revents & POLLOUT) && !packets.empty()) {
            const auto &packet = packets.front();
            ssize_t count = write(tun.value, packet.data(), packet.size());
            if (count == static_cast<ssize_t>(packet.size())) {
                rxBytes_ += count; ++rxPackets_;
                queuedBytes -= packet.size(); packets.pop_front();
            } else if (count >= 0) { Fail(EIO); break; }
            else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) { Fail(errno); break; }
        }
        if ((fds[0].revents | fds[1].revents) & POLLHUP) { Fail(ECONNRESET); break; }
    }
    running_ = false;
}
}
