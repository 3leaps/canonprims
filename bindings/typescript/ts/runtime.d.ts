// SPDX-License-Identifier: MIT OR Apache-2.0
// The few runtime globals this package uses. Every target runtime (Node.js,
// Deno, Bun, browsers) provides them; declaring them here keeps the build free
// of DOM or Node type packages, so the emitted types assume neither.
declare namespace WebAssembly {
  interface Memory {
    readonly buffer: ArrayBuffer;
  }
  class Module {
    constructor(bytes: Uint8Array);
  }
  class Instance {
    constructor(module: Module, imports: object);
    readonly exports: object;
  }
}
declare class TextEncoder {
  encode(input: string): Uint8Array;
}
declare class TextDecoder {
  constructor(label: string, options: { fatal: boolean });
  decode(input: Uint8Array): string;
}
