package diag

when ODIN_OS != .Darwin {

Metric_Sample :: struct {
	cpu_user_ns:    u64,
	cpu_system_ns:  u64,
	system_cpu_pct: f32,
	resident_bytes: u64,
	thread_count:   u32,
	timestamp_ns:   u64,
}

metrics_sample_cpu :: proc() -> Metric_Sample {
	return Metric_Sample{}
}

metrics_cpu_pct :: proc(prev: ^Metric_Sample, curr: Metric_Sample, elapsed_ns: u64) -> f32 {
	return 0
}

metrics_system_cpu_pct :: proc(s: Metric_Sample) -> f32 {
	return 0
}

}
