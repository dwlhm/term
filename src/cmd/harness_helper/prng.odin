package harness_helper

// Pinned PRNG implementation: xoshiro256** seeded via SplitMix64.
// Compliant with docs/HARNESS_BENCHMARK_PLAN.md V2.2 §6.1.
// Deterministic and independent of OS or runtime RNG.

Xoshiro256pp :: struct {
	s: [4]u64,
}

splitmix64 :: proc(state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	z: u64 = state^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

xoshiro256pp_init :: proc(rng: ^Xoshiro256pp, seed: u64) {
	sm := seed
	rng.s[0] = splitmix64(&sm)
	rng.s[1] = splitmix64(&sm)
	rng.s[2] = splitmix64(&sm)
	rng.s[3] = splitmix64(&sm)
}

rotl :: proc(x: u64, k: u32) -> u64 {
	return (x << k) | (x >> (64 - k))
}

xoshiro256pp_next :: proc(rng: ^Xoshiro256pp) -> u64 {
	res := rotl(rng.s[1] * 5, 7) * 9
	t := rng.s[1] << 17
	rng.s[2] ~= rng.s[0]
	rng.s[3] ~= rng.s[1]
	rng.s[1] ~= rng.s[2]
	rng.s[0] ~= rng.s[3]
	rng.s[2] ~= t
	rng.s[3] = rotl(rng.s[3], 45)
	return res
}

xoshiro256pp_shuffle :: proc(rng: ^Xoshiro256pp, slice: []$T) {
	n := len(slice)
	for i := n - 1; i > 0; i -= 1 {
		j := int(xoshiro256pp_next(rng) % u64(i + 1))
		slice[i], slice[j] = slice[j], slice[i]
	}
}
