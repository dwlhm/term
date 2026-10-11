// ==========================================
// pinnace_ui Compute Shader (Logic & Culling)
// ==========================================

// Structs must match EXACTLY with Odin's memory alignment (16-byte alignment).
struct Transform {
    position: vec3<f32>,
    _pad0: u32,
    size: vec2<f32>,
    scale: vec2<f32>,
    rotation: vec4<f32>,
}

struct Material {
    material_id: u32,
    opacity: f32,
    _pad: vec2<u32>,
}

struct IndirectDrawArgs {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
}

// ------------------------------------------
// Bindings
// ------------------------------------------
@group(0) @binding(0) var<storage, read> transforms: array<Transform>;
@group(0) @binding(1) var<storage, read> materials: array<Material>;

// The output buffer that the vertex shader will read from.
// It contains only the indices of the UI elements that actually need to be drawn.
@group(0) @binding(2) var<storage, read_write> visible_indices: array<u32>;

// We use an atomic counter to keep track of how many elements are visible.
@group(0) @binding(3) var<storage, read_write> draw_args: IndirectDrawArgs;

struct ConfigData {
    resolution: vec2<f32>,
    enable_culling: u32,
    total_elements: u32,
}
@group(1) @binding(0) var<uniform> config: ConfigData;

// ------------------------------------------
// Main Compute Logic (WORKGROUP SIZE matched in Odin config)
// ------------------------------------------
@compute @workgroup_size(256, 1, 1)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let id = global_id.x;
    
    // Safety check
    if (id >= config.total_elements) {
        return;
    }

    let transform = transforms[id];
    let mat = materials[id];

    // If completely transparent or zero size, don't even add it to the draw list
    if (mat.opacity <= 0.0 || transform.size.x <= 0.0 || transform.size.y <= 0.0) {
        return;
    }

    // ----------------------------------------------------
    // Frustum / Screen-Space Culling (The "Zero-Cost" Magic)
    // ----------------------------------------------------
    var is_visible = true;

    if (config.enable_culling == 1u) {
        // Calculate Absolute Screen Bounds
        let min_x = transform.position.x;
        let max_x = transform.position.x + (transform.size.x * transform.scale.x);
        let min_y = transform.position.y;
        let max_y = transform.position.y + (transform.size.y * transform.scale.y);

        // Discard if entirely off-screen
        is_visible = !(max_x < 0.0 || min_x > config.resolution.x || max_y < 0.0 || min_y > config.resolution.y);
    }

    // ----------------------------------------------------
    // Indirect Draw Argument Generation
    // ----------------------------------------------------
    if (is_visible) {
        // Increment the instance count atomically.
        // `atomicAdd` returns the original value before addition, creating a unique index for us!
        let writing_slot = atomicAdd(&draw_args.instance_count, 1u);
        
        // Push the entity ID to the visible list.
        // The vertex shader will pull from here instead of rendering the whole array!
        visible_indices[writing_slot] = id;
    }
}
