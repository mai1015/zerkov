// Minimal upstream reproducer: no networking, singleton, properties or game code.
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

class DiscoveryProbe : public RefCounted {
    GDCLASS(DiscoveryProbe, RefCounted);
protected:
    static void _bind_methods() {}
};

void initialize_probe(ModuleInitializationLevel level) {
#ifndef DISCOVERY_ZERO_CLASSES
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        GDREGISTER_CLASS(DiscoveryProbe);
    }
#else
    (void)level;
#endif
}

void terminate_probe(ModuleInitializationLevel) {}

extern "C" GDExtensionBool GDE_EXPORT discovery_probe_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library,
        GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_probe);
    init.register_terminator(terminate_probe);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
