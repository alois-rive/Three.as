// three.js Layers: a 32-bit mask. An object is rendered when it shares a
// layer with the camera (both start on layer 0).

export class Layers {
    mask: u32 = 1;

    set(channel: i32): void { this.mask = (<u32>1 << channel) >>> 0; }
    enable(channel: i32): void { this.mask |= <u32>1 << channel; }
    enableAll(): void { this.mask = 0xFFFFFFFF; }
    toggle(channel: i32): void { this.mask ^= <u32>1 << channel; }
    disable(channel: i32): void { this.mask &= ~(<u32>1 << channel); }
    disableAll(): void { this.mask = 0; }
    test(layers: Layers): bool { return (this.mask & layers.mask) != 0; }
    isEnabled(channel: i32): bool { return (this.mask & (<u32>1 << channel)) != 0; }
}
