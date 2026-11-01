package platform_pty

Pty_Error :: enum {
	None,
	Master_Open_Failed,
	Slave_Open_Failed,
	Fork_Failed,
}

Pty_Config :: struct {
	shell:  string,
	argv:   []string,
	cwd:    string,
	rows:   int,
	cols:   int,
	xpixel: int,
	ypixel: int,
}
