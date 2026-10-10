// Guest for the CPU and RAM snapshot tests.
.intel_syntax noprefix
.text
.global _start

_start:
	// Top of RAM in the snapshot test (0x100000 + 0x20000).
	mov rsp, 0x120000
	mov rbx, 0x1122334455667788
	push rbx
	xor ebx, ebx

	mov rcx, 10
	mov rax, 0

loop:
	add rax, rcx

	dec rcx

	// Checkpoint: OUT preserves arithmetic flags.
	mov dx, 0xF4
	out dx, al

	jne loop

	cmp rax, 55
	jne error

	// The marker must survive the snapshot in RAM, not just in a register.
	pop rbx
	mov rdx, 0x1122334455667788
	cmp rbx, rdx
	jne error
	cmp rsp, 0x120000
	jne error

success:
	mov dx, 0x3F8
	mov al, '1'
	out dx, al
	hlt

error:
	mov dx, 0x3F8
	mov al, '0'
	out dx, al
	hlt
