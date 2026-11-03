/*
 * qy_native.h — GDExtension 绑定层（薄壳）
 *
 * 这一层**只做三件事**：把 Godot 的 Variant 拆成 POD、调用内核、把结果包回 Variant。
 * 任何业务规则、状态机、平衡数值都不许写在这里（否则 C# 直连路径就与 GDScript 路径行为分叉）。
 */
#ifndef QY_GODOT_NATIVE_H
#define QY_GODOT_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class QyNative : public RefCounted {
    GDCLASS(QyNative, RefCounted)

protected:
    static void _bind_methods();

public:
    QyNative() = default;
    ~QyNative() override = default;

    /* 内核版本号：GDScript/C# 启动时对齐，不匹配就降级到纯脚本实现 */
    int32_t api_version() const;

    /* "qy_native api=1 tag=<构建标签>" —— 打印到日志，方便确认加载到的是哪一份 DLL */
    String build_info() const;

    /*
     * 群体分离（GDScript 便利接口，一次拷贝进出）。
     *   positions: 长度必须是偶数，x,y 交替
     * 返回：同长度的 dx,dy 交替数组
     * 说明：GDScript 侧每帧调用的上限建议 ≤ 2k 个体；万级规模请走 C# 的 P/Invoke 通道
     *       （那条路径是 Span 零拷贝，不产生 Variant）。
     */
    PackedFloat32Array crowd_separation(const PackedFloat32Array &positions,
                                        float radius, float strength, int32_t max_neighbors) const;
};

}  // namespace godot

#endif  // QY_GODOT_NATIVE_H
