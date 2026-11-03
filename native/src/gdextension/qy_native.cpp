#include "qy_native.h"

#include <vector>

#include <godot_cpp/core/class_db.hpp>

#include "crowd_kernel.h"

namespace godot {

void QyNative::_bind_methods() {
    ClassDB::bind_method(D_METHOD("api_version"), &QyNative::api_version);
    ClassDB::bind_method(D_METHOD("build_info"), &QyNative::build_info);
    ClassDB::bind_method(D_METHOD("crowd_separation", "positions", "radius", "strength", "max_neighbors"),
                         &QyNative::crowd_separation,
                         DEFVAL(24.0f), DEFVAL(1.0f), DEFVAL(6));
}

int32_t QyNative::api_version() const {
    return static_cast<int32_t>(QY_API_VERSION);
}

String QyNative::build_info() const {
    const qy_api_v1 *api = qy_get_api(QY_API_VERSION);
    return api != nullptr ? String(api->build_info()) : String("qy_native: api mismatch");
}

PackedFloat32Array QyNative::crowd_separation(const PackedFloat32Array &positions,
                                             float radius, float strength,
                                             int32_t max_neighbors) const {
    const int32_t n = static_cast<int32_t>(positions.size() / 2);
    if (n <= 0) {
        return PackedFloat32Array();
    }
    const float *src = positions.ptr();

    /* 装箱：PackedFloat32Array 是 interleaved float，内核要 qy_vec2[]。这一步是唯一拷贝。 */
    std::vector<qy_vec2> pts(static_cast<size_t>(n));
    for (int32_t i = 0; i < n; ++i) {
        pts[static_cast<size_t>(i)].x = src[i * 2 + 0];
        pts[static_cast<size_t>(i)].y = src[i * 2 + 1];
    }
    std::vector<float> dx(static_cast<size_t>(n));
    std::vector<float> dy(static_cast<size_t>(n));

    qy_crowd_desc desc{};
    desc.count = n;
    desc.cell_size = radius * 2.0f;
    desc.radius = radius;
    desc.strength = strength;
    desc.max_neighbors = max_neighbors;
    qy::crowd_separation(pts.data(), desc, dx.data(), dy.data(), nullptr);

    PackedFloat32Array out;
    out.resize(n * 2);
    float *dst = out.ptrw();
    for (int32_t i = 0; i < n; ++i) {
        dst[i * 2 + 0] = dx[static_cast<size_t>(i)];
        dst[i * 2 + 1] = dy[static_cast<size_t>(i)];
    }
    return out;
}

}  // namespace godot
