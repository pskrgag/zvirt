.intel_syntax noprefix
.text
.global _start

_start:
	// Check the Long Mode Active bit in IA32_EFER.
	mov ecx, 0xC0000080
	rdmsr

	bt eax, 10

	jnc not_long_mode
	mov al, 'H'

	jmp report

not_long_mode:
	mov al, 'F'

report:
	mov dx, 0x3F8
	out dx, al
	mov dx, 0xF4
	out dx, al
