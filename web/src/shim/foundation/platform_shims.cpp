// platform_shims.cpp — see platform_shims.h for what belongs here and why.
#include "platform_shims.h"

#include <emscripten/emscripten.h>

namespace {

// xoshiro128** — small, fast, and good enough that `arc4random() % 200 - 100` (BlockBreak.mm's
// particle scatter) looks right. NOT cryptographic, unlike the real arc4random; that difference
// is safe here because every call site in this tree is gameplay dice. If a later stage ever needs
// randomness for something security-relevant, use crypto.getRandomValues via EM_ASM instead of
// widening this.
struct State {
  uint32_t s[4];

  State() {
    // Seed from the page's high-resolution clock. Deterministic seeding was considered and
    // rejected: the engine's own worldgen is offline (docs/terrain-generation.md — the shipped
    // Eden.eden is pre-generated), so nothing here needs reproducibility, and identical particle
    // scatter on every page load would be visible.
    uint64_t seed = (uint64_t)(emscripten_get_now() * 1000.0);
    // SplitMix64 to spread the low-entropy clock value across all four words.
    for (int i = 0; i < 4; i++) {
      seed += 0x9E3779B97F4A7C15ULL;
      uint64_t z = seed;
      z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
      z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
      s[i] = (uint32_t)((z ^ (z >> 31)) >> 32);
    }
    if (!(s[0] | s[1] | s[2] | s[3])) s[0] = 1;  // all-zero state is a fixed point
  }
};

State &state() {
  static State g;
  return g;
}

inline uint32_t rotl(uint32_t x, int k) { return (x << k) | (x >> (32 - k)); }

}  // namespace

extern "C" {

uint32_t arc4random(void) {
  State &g = state();
  const uint32_t result = rotl(g.s[1] * 5, 7) * 9;
  const uint32_t t = g.s[1] << 9;
  g.s[2] ^= g.s[0];
  g.s[3] ^= g.s[1];
  g.s[1] ^= g.s[2];
  g.s[0] ^= g.s[3];
  g.s[2] ^= t;
  g.s[3] = rotl(g.s[3], 11);
  return result;
}

uint32_t arc4random_uniform(uint32_t upper_bound) {
  if (upper_bound < 2) return 0;
  // Rejection sampling, matching BSD's — avoids the modulo bias that plain `arc4random() % n`
  // has. (The engine's own call sites all use plain `%`; this function exists for completeness
  // and for any new port-side code, which should prefer it.)
  const uint32_t min = (uint32_t)(-upper_bound) % upper_bound;
  uint32_t r;
  do {
    r = arc4random();
  } while (r < min);
  return r % upper_bound;
}

}  // extern "C"
