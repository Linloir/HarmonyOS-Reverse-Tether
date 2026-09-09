// SPDX-License-Identifier: Apache-2.0
#include "tunnel.h"
#include <napi/native_api.h>
#include <cerrno>
#include <string>
#include <unistd.h>

namespace {
tether::Tunnel tunnel;
int32_t currentSession = 0;
std::mutex sessionMutex;

napi_value Undefined(napi_env env) {
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}
napi_value Error(napi_env env, const std::string &message) {
    napi_throw_error(env, nullptr, message.c_str());
    return nullptr;
}
bool Args(napi_env env, napi_callback_info info, size_t required, int32_t *values) {
    size_t count = 3;
    napi_value args[3];
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != required) {
        Error(env, "Invalid argument count"); return false;
    }
    for (size_t i = 0; i < required; ++i) {
        if (napi_get_value_int32(env, args[i], &values[i]) != napi_ok || values[i] < 0) {
            Error(env, "Expected nonnegative integer"); return false;
        }
    }
    return true;
}
napi_value CreateSocket(napi_env env, napi_callback_info) {
    int fd = tether::CreateSocket();
    if (fd < 0) return Error(env, "Cannot create relay socket: " + std::to_string(errno));
    napi_value result;
    napi_create_int32(env, fd, &result);
    return result;
}

napi_value NewSession(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    tunnel.Stop();
    currentSession = currentSession == INT32_MAX ? 1 : currentSession + 1;
    napi_value result;
    napi_create_int32(env, currentSession, &result);
    return result;
}

struct ConnectWork {
    napi_async_work work{};
    napi_deferred deferred{};
    int fd;
    uint16_t port;
    int error = 0;
    ~ConnectWork() { close(fd); }
};

napi_value Connect(napi_env env, napi_callback_info info) {
    int32_t values[2];
    if (!Args(env, info, 2, values)) return nullptr;
    if (values[1] < 1 || values[1] > 65535) return Error(env, "Invalid relay port");
    int fd = dup(values[0]);
    if (fd < 0) return Error(env, "Invalid socket descriptor");
    auto *work = new ConnectWork{};
    work->fd = fd; work->port = static_cast<uint16_t>(values[1]);
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    napi_create_string_utf8(env, "ConnectUsbRelay", NAPI_AUTO_LENGTH, &name);
    napi_status created = napi_create_async_work(env, nullptr, name,
        [](napi_env, void *data) {
            auto *w = static_cast<ConnectWork *>(data);
            w->error = tether::Connect(w->fd, w->port);
        },
        [](napi_env e, napi_status status, void *data) {
            auto *w = static_cast<ConnectWork *>(data);
            if (status == napi_ok && w->error == 0) {
                napi_resolve_deferred(e, w->deferred, Undefined(e));
            } else {
                napi_value message, error;
                std::string text = "USB relay connection failed, errno=" + std::to_string(w->error);
                napi_create_string_utf8(e, text.c_str(), NAPI_AUTO_LENGTH, &message);
                napi_create_error(e, nullptr, message, &error);
                napi_reject_deferred(e, w->deferred, error);
            }
            napi_delete_async_work(e, w->work);
            delete w;
        }, work, &work->work);
    if (created != napi_ok || napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        delete work;
        return Error(env, "Cannot schedule relay connection");
    }
    return promise;
}

napi_value Start(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    int32_t values[3];
    if (!Args(env, info, 3, values)) return nullptr;
    if (values[2] != currentSession) return Error(env, "Stale VPN session");
    if (!tunnel.Start(values[0], values[1])) return Error(env, "Cannot start tunnel: " + tunnel.Status());
    return Undefined(env);
}
napi_value Stop(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    int32_t values[1];
    if (!Args(env, info, 1, values)) return nullptr;
    if (values[0] == currentSession) tunnel.Stop();
    return Undefined(env);
}
napi_value Close(napi_env env, napi_callback_info info) {
    int32_t values[2];
    if (!Args(env, info, 1, values)) return nullptr;
    close(values[0]); return Undefined(env);
}
napi_value Status(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(sessionMutex);
    int32_t values[1];
    if (!Args(env, info, 1, values)) return nullptr;
    if (values[0] != currentSession) return Error(env, "Stale VPN session");
    napi_value result;
    auto text = tunnel.Status();
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor props[] = {
        {"newSession", nullptr, NewSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"createSocket", nullptr, CreateSocket, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
    return exports;
}
}

static napi_module module = {1, 0, nullptr, Init, "tether", nullptr, {nullptr, nullptr, nullptr, nullptr}};
extern "C" __attribute__((constructor)) void RegisterTether() { napi_module_register(&module); }
