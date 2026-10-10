.intel_syntax noprefix
.text
.global _start

_start:
.Lloop:
	jmp .Lloop
