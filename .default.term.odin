name = "default"
title = "Repository workspace: fastfetch and ls"
cwd = "."
layout = Split {
	direction = .Vertical,
	ratio = 0.5,
	first = Pane { command = "fastfetch", cwd = "." },
	second = Pane { command = "ls", cwd = "." },
}
