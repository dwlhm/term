package platform_ipc_contract

// Contract tests of the IPC package, written before the package (spec section
// 10). They use a protocol of their own, not term's messages, so passing them
// also shows the package works outside term. `make test-ipc-contract` runs them
// and lists the IDs still red; a test moves to src/platform/ipc/tests (and into
// `make test`) in the slice that turns it green.

import ipc "../"

TEST_ROLE_CLIENT :: u8(1)

// A small catalog: one plain request, one with progress, one notice.
TEST_PING     :: u8(20) // → TEST_PONG
TEST_PONG     :: u8(21)
TEST_JOB      :: u8(22) // → TEST_JOB_DONE, with TEST_JOB_STEP progress
TEST_JOB_DONE :: u8(23)
TEST_JOB_STEP :: u8(24)
TEST_CHANGED  :: u8(25) // notice

test_catalog := [?]ipc.Msg_Spec{
	{request = TEST_PING, answer = TEST_PONG},
	{request = TEST_JOB, answer = TEST_JOB_DONE, progress = TEST_JOB_STEP},
	{request = TEST_CHANGED, notice = true},
}

test_protocol :: proc() -> ipc.Protocol {
	return {name = "ipc contract", version = {0, 1, 0}, roles = {int(TEST_ROLE_CLIENT)}, catalog = test_catalog[:]}
}
