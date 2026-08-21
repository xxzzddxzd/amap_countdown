typedef void *id;
typedef void *Class;
typedef void *SEL;
extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *name);
extern id objc_msgSend(id self, SEL op, ...);

__attribute__((constructor)) static void probe(void) {
    Class poolClass = objc_getClass("NSAutoreleasePool");
    if (!poolClass) return;
    id pool = ((id (*)(id, SEL))objc_msgSend)((id)poolClass, sel_registerName("new"));
    ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("drain"));
}
