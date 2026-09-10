# KVM

## x86

- CONFIG_SERIAL_8250_DETECT_IRQ should be disabled, since it's racy. KVM eventfd IRQ handling is
  async in case of !MSI interrupts.

  8250 driver in the kernel does following

```c
	udelay(20);
	irq = probe_irq_off(irqs);

    ...

	port->irq = (irq > 0) ? irq : 0;
```
  IRQ raise can be delivered after 20us delay, which would make console poll-driver. It's fine for
  the kernel, but tty wouldn't work, which breaks my tests
