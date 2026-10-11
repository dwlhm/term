package session_runtime

// Process-local addresses never participate in host or wire identities.
Workspace_ID :: distinct u64
Pane_ID :: distinct u64
Pane_Incarnation :: distinct u64
Viewer_ID :: distinct u64
Lease_ID :: distinct u64
Revision :: distinct u64
Host_Generation :: distinct [2]u64

TOPOLOGY_NODE_CAPACITY :: 32
TOPOLOGY_MIN_RATIO :: f32(0.1)
TOPOLOGY_MAX_RATIO :: f32(0.9)
TOPOLOGY_DEFAULT_RATIO :: f32(0.5)
TOPOLOGY_REVISION_MAX :: Revision(0xffff_ffff_ffff_ffff)

// One-based indexes make zero the explicit absent-node value.
Node_Index :: distinct u8
Orientation :: enum u8 {
	Vertical, // Left/right children, divides width.
	Horizontal, // Top/bottom children, divides height.
}
Topology_Node_Kind :: enum u8 {
	Leaf,
	Split,
}
Topology_Node :: struct {
	used: bool,
	kind: Topology_Node_Kind,
	parent, first, second: Node_Index,
	pane: Pane_ID,
	incarnation: Pane_Incarnation,
	orientation: Orientation,
	ratio: f32,
}
// Unintegrated runtime prerequisite; no PTY, worker, GUI geometry or shell creation.
Workspace_Topology :: struct {
	workspace: Workspace_ID,
	revision: Revision,
	root: Node_Index,
	focused, zoomed: Pane_ID,
	node_count: u8,
	nodes: [TOPOLOGY_NODE_CAPACITY]Topology_Node,
}
Topology_Result :: enum u8 {
	Applied,
	Invalid_Descriptor,
	Invalid_Identity,
	Missing_Pane,
	Duplicate_Pane,
	Pool_Full,
	Invalid_Ratio,
	Invalid_Orientation,
	Not_Empty,
	Revision_Exhausted,
}

Host_Identity :: struct {
	protocol_major: u16,
	protocol_minor: u16,
	generation:     Host_Generation,
	user_id:        u32,
	build_version:  string,
}

Work_Liveness :: enum u8 {
	VerifiedLive,
	Completed,
	Uncertain,
}

Activity_Observation_Kind :: enum u8 {
	Busy,
	ShellReady,
	Unknown,
}

Activity_Observation :: struct {
	kind:                Activity_Observation_Kind,
	observed_at_ns:      i64,
	foreground_name:     string,
	has_background_jobs: bool,
}

Pane_Record :: struct {
	pane_id:     Pane_ID,
	incarnation: Pane_Incarnation,
	workspace_id: Workspace_ID,
	liveness:    Work_Liveness,
	pid:         int,
	exit_code:   int,
	pty_closed:  bool,
	observation: Activity_Observation,
	cwd:         string,
}

Session_Record :: struct {
	workspace_id:   Workspace_ID,
	title:          string,
	title_override: bool,
	topology:       Workspace_Topology,
	active_lease:   Lease_ID,
	created_at_ns:  i64,
}

GUI_Lease :: struct {
	lease_id:      Lease_ID,
	viewer_id:     Viewer_ID,
	workspace_id:  Workspace_ID,
	granted_at_ns: i64,
	expires_at_ns: i64,
}

Command_Outcome_Status :: enum u8 {
	Rejected,
	Accepted,
	Applied,
	Failed,
	Unknown,
}

Command_Outcome :: struct {
	request_id: u64,
	status:     Command_Outcome_Status,
	revision:   Revision,
	error_code: u32,
}

