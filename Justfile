default: initrds

ZIG := "zig"

# Package each test_initfs/<name>/ as zig-out/initrds/<name>.img.
initrds:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    output_dir="$PWD/zig-out/initrds"
    mkdir -p "$output_dir"
    for directory in test_initfs/*/; do
        name="${directory%/}"
        name="${name##*/}"

        if [[ ! -f "$directory/init.zig" ]]; then
            echo "Missing init source code: $directory/init.zig" >&2
            exit 1
        fi

        {{ZIG}} build-exe \
            "$directory/init.zig" \
            -target x86_64-linux \
            -O ReleaseSmall \
            -fstrip \
            -fsingle-threaded \
            -femit-bin="$directory/init"

        (
            cd "$directory"
            find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --owner=0:0
        ) | gzip -n > "$output_dir/$name.img"
        echo "Built zig-out/initrds/$name.img"
    done

tap:
	sudo ip tuntap add dev net0 mode tap user "$USER" multi_queue
	sudo ip addr add 192.0.2.1/24 dev net0
	sudo ip link set net0 up

guest:
	clang -c -target x86_64-none-elf guest.s -o guest.o
	ld.lld --image-base=0 -Ttext=0x1000 --entry=_start guest.o -o guest.elf
	llvm-objcopy -O binary --only-section=.text guest.elf guest.bin
