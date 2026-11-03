/*
 * register_types.cpp — GDExtension 入口
 *
 * 注意：这里只在 SCENE 级初始化时注册类；**不要**在 INITIALIZATION 阶段碰场景树或资源。
 * 入口符号必须与 qy_native.gdextension 里的 entry_symbol 完全一致。
 */
#include <gdextension_interface.h>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "qy_native.h"

#ifdef QY_WITH_WEBVIEW2
#  include "qy_webview.h"
#endif

using namespace godot;

namespace {

void initialize_qy_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(QyNative);
#ifdef QY_WITH_WEBVIEW2
    GDREGISTER_CLASS(QyWebView);
#endif
}

void uninitialize_qy_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    /* 目前没有需要手动释放的全局状态；WebView2 的生命周期挂在节点上 */
}

}  // namespace

extern "C" {

GDExtensionBool GDE_EXPORT qy_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                           const GDExtensionClassLibraryPtr p_library,
                                           GDExtensionInitialization *r_initialization) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
    init_obj.register_initializer(initialize_qy_module);
    init_obj.register_terminator(uninitialize_qy_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init_obj.init();
}

}  // extern "C"
