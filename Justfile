default: initrds

ZIG := "zig"

# Compile test_bins/*.s into matching flat guest binaries.
guests:
    #!/usr/bin/env bash
    set -euo pipefail
    output_dir="$PWD/zig-out/guests"
    mkdir -p "$output_dir"
    for source in test_bins/*.s; do
        name="${source##*/}"
        name="${name%.s}"

        {{ZIG}} build-exe "$source" \
            -target x86_64-freestanding \
            -fentry=_start \
            --image-base 0x100000 \
            -femit-bin="$output_dir/$name.elf"
        {{ZIG}} objcopy -O binary --only-section .text \
            "$output_dir/$name.elf" "test_bins/$name.bin"
        echo "Built test_bins/$name.bin"
    done

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
