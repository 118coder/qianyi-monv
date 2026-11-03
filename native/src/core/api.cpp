/*
 * api.cpp — C ABI 出口（唯一被 __declspec(dllexport) 导出的地方）
 *
 * 同一个 DLL 同时承担两种角色：
 *   · GDExtension 插件（qy_library_init，见 src/gdextension/register_types.cpp）→ GDScript / 编辑器
 *   · 普通原生库（qy_get_api）→ C# 通过 NativeLibrary/DllImport 直连，绕开 Godot 的对象与变体封送
 *
 * 两个入口共享同一份内核实例，所以 C# 与 GDScript 看到的是同一套状态与算法。
 */
#include <cstring>

#include "crowd_kernel.h"
#include "qy_native_api.h"

#ifndef QY_BUILD_TAG
#  define QY_BUILD_TAG "dev"
#endif

namespace {

uint64_t fnv1a64(const void *data, size_t len, uint64_t seed) {
    const uint8_t *p = static_cast<const uint8_t *>(data);
    uint64_t h = (seed != 0) ? seed : 1469598103934665603ull;
    for (size_t i = 0; i < len; ++i) {
        h ^= static_cast<uint64_t>(p[i]);
        h *= 1099511628211ull;
    }
    return h;
}

void api_crowd_separation(const qy_vec2 *pos, const qy_crowd_desc *desc,
                          float *out_dx, float *out_dy, int32_t *out_hits) {
    if (desc == nullptr) {
        return;   // 异常绝不穿过 ABI 边界：这里直接返回，不抛
    }
    qy::crowd_separation(pos, *desc, out_dx, out_dy, out_hits);
}

void api_crowd_separation_mt(const qy_vec2 *pos, const qy_crowd_desc *desc,
                             float *out_dx, float *out_dy, int32_t *out_hits,
                             int32_t workers) {
    if (desc == nullptr) {
        return;
    }
    qy::crowd_separation_mt(pos, *desc, out_dx, out_dy, out_hits, workers);
}

uint64_t api_hash64(const void *data, size_t len, uint64_t seed) {
    if (data == nullptr || len == 0) {
        return seed;
    }
    return fnv1a64(data, len, seed);
}

const char *api_build_info() {
    return "qy_native api=" "1" " tag=" QY_BUILD_TAG;
}

const qy_api_v1 g_api = {
    QY_API_VERSION,
    &api_crowd_separation,
    &api_crowd_separation_mt,
    &api_hash64,
    &api_build_info,
};

}  // namespace

extern "C" {

QY_API uint32_t qy_api_version(void) {
    return QY_API_VERSION;
}

QY_API const qy_api_v1 *qy_get_api(uint32_t min_version) {
    if (min_version > QY_API_VERSION) {
        return nullptr;   // 调用方要求更高版本 → 让它降级，而不是返回半残的表
    }
    return &g_api;
}

}  // extern "C"
