package feature_session_api_tests

import "core:testing"
import api ".."
import proto "../../session_proto"
import ipc "../../../platform/ipc"

@(test)
test_api_types :: proc(t: ^testing.T) {
	// Verify that API compiles and types align
	var_client: ipc.Client
	_ = var_client
	testing.expect(t, true)
}
