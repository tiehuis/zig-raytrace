const mem = @import("std").mem;
const c = @cImport({@cInclude("stdlib.h")});

error NoMem;

pub var c_allocator = mem.Allocator {
    .allocFn = cAlloc,
    .reallocFn = cRealloc,
    .freeFn = cFree,
};

fn cAlloc(self: &mem.Allocator, n: usize, alignment: usize) -> %[]u8 {
    @ptrCast(&u8, c.malloc(usize(n)) ?? return error.NoMem)[0..n]
}

fn cRealloc(self: &mem.Allocator, old_mem: []u8, new_size: usize, alignment: usize) -> %[]u8 {
    if (old_mem.len == 0) {
        cAlloc(self, new_size, alignment)
    } else {
        const old_ptr = @ptrCast(&c_void, &old_mem[0]);
        @ptrCast(&u8, c.realloc(old_ptr, usize(new_size)) ?? return error.NoMem)[0..new_size]
    }
}

fn cFree(self: &mem.Allocator, old_mem: []u8) {
    c.free(@ptrCast(&c_void, &old_mem[0]));
}
