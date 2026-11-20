/*
 * h4-attach: put an H4 line discipline on a tty so the in-kernel hci_uart driver
 * creates an hci0 device. Same two ioctls btattach issues last, without BlueZ.
 *
 *   usage: h4-attach [-f] /dev/ttyBT0
 *
 * TIOCSETD takes a pointer to int (tty_ioctl does get_user on it); HCIUARTSETPROTO
 * takes the protocol id by value (hci_uart_tty_ioctl passes arg straight to
 * hci_uart_set_proto). Passing a pointer to the latter makes the id look like a
 * huge number and the kernel answers -EPROTONOSUPPORT.
 *
 * The fd must stay open for the lifetime of the attachment: closing it calls
 * mtty_close(), which tears the WCN bus channels down while sdiohal_tx_thread is
 * still running, and that thread then walks the freed list and panics the kernel.
 * So this daemonises by default and keeps the fd; -f keeps it in the foreground
 * for debugging, where the caller is responsible for not closing it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <termios.h>

#ifndef N_HCI
#define N_HCI 15
#endif
#define HCIUARTSETPROTO _IOW('U', 200, int)
#define HCI_UART_H4 0

int main(int argc, char **argv)
{
	const char *dev = "/dev/ttyBT0";
	int foreground = 0;
	int fd, ldisc = N_HCI, proto = HCI_UART_H4;

	if (argc > 1 && strcmp(argv[1], "-f") == 0) {
		foreground = 1;
		if (argc > 2)
			dev = argv[2];
	} else if (argc > 1) {
		dev = argv[1];
	}

	fd = open(dev, O_RDWR | O_NOCTTY);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		return 1;
	}

	{
		struct termios tio;

		/*
		 * Cosmetic here: sprdbt_tty registers as TTY_DRIVER_TYPE_SYSTEM and leaves
		 * set_termios unset (see its driver init), so the tty is a virtual channel
		 * over the WCN bus and no baud rate is ever applied.
		 *
		 * 3000000 matches what the upstream transport uses for this platform
		 * (openwrt/overlay/etc/init.d/unisoc-bt-transport: mu300-pcie -> ttyBT0 at
		 * 3000000), so this stays right if the board ever moves to a real UART.
		 */
		if (tcgetattr(fd, &tio) == 0) {
			cfmakeraw(&tio);
			cfsetispeed(&tio, B3000000);
			cfsetospeed(&tio, B3000000);
			tcsetattr(fd, TCSANOW, &tio);
		}
	}

	if (ioctl(fd, TIOCSETD, &ldisc) < 0) {
		fprintf(stderr, "TIOCSETD N_HCI: %s\n", strerror(errno));
		return 1;
	}
	/* by value, not &proto */
	if (ioctl(fd, HCIUARTSETPROTO, proto) < 0) {
		fprintf(stderr, "HCIUARTSETPROTO H4: %s\n", strerror(errno));
		return 1;
	}

	printf("attached H4 to %s\n", dev);
	fflush(stdout);

	if (foreground) {
		/* Hold the fd until the caller kills us. */
		for (;;)
			pause();
	}

	/* Daemonise so the attachment survives the shell that started it, and never
	 * close fd: mtty_close() would free the WCN bus channels underneath the
	 * still-running sdiohal_tx_thread. */
	if (fork() == 0) {
		setsid();
		for (;;)
			pause();
	}
	return 0;
}
