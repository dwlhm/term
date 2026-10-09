package main

import "core:sync"

Backend_Event :: enum u32 {
	Bell          = 1 << 0,
	Title_Changed = 1 << 1,
	Child_Exited  = 1 << 2,
	Notification  = 1 << 3,
}

MAX_NOTIFICATIONS :: 16

Notification_Message :: struct {
	title:       [128]u8,
	title_len:   int,
	message:     [512]u8,
	message_len: int,
}

Notification_Mailbox :: struct {
	entries: [MAX_NOTIFICATIONS]Notification_Message,
	head:    int,
	tail:    int,
}

backend_post_event :: proc(b: ^Backend, event: Backend_Event) {
	if b == nil do return
	sync.atomic_or(&b.pending_events, u32(event))
}

backend_post_notification :: proc(b: ^Backend, title, message: string) {
	if b == nil do return
	mb := &b.mailbox
	head := sync.atomic_load(&mb.head)
	tail := sync.atomic_load(&mb.tail)
	if tail - head >= MAX_NOTIFICATIONS {
		return
	}
	msg := &mb.entries[tail % MAX_NOTIFICATIONS]
	msg.title_len = copy(msg.title[:], title)
	msg.message_len = copy(msg.message[:], message)
	sync.atomic_store(&mb.tail, tail + 1)
	backend_post_event(b, .Notification)
}

backend_take_events :: proc(b: ^Backend) -> u32 {
	if b == nil do return 0
	return sync.atomic_exchange(&b.pending_events, 0)
}

backend_take_notifications :: proc(b: ^Backend, out: []Notification_Message) -> int {
	if b == nil || len(out) == 0 do return 0
	mb := &b.mailbox
	head := sync.atomic_load(&mb.head)
	tail := sync.atomic_load(&mb.tail)
	avail := tail - head
	if avail <= 0 do return 0
	n := min(avail, len(out))
	for i in 0 ..< n {
		out[i] = mb.entries[(head + i) % MAX_NOTIFICATIONS]
	}
	sync.atomic_store(&mb.head, head + n)
	return n
}
