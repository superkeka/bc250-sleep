# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=bash
# What differs between the systems bc250-sleep runs on, sourced by its scripts (set LOG first):
#   steamos  SteamOS: read-only /usr that an update replaces, GRUB, pacman
#   ostree   Bazzite and other rpm-ostree systems: read-only /usr, the kernel's build files in the image,
#            kernel arguments and the initramfs through rpm-ostree, a compiler only in a container
#   pacman   CachyOS, Arch: kernel arguments through limine-entry-tool or GRUB, the initramfs by mkinitcpio
#   other    whatever is installed is used; nothing is installed and the boot configuration is left alone
# The functions return 0 on success and print what went wrong otherwise.

sys_kind() {
	if [ -e /run/ostree-booted ] && command -v rpm-ostree > /dev/null; then
		echo ostree
	elif grep -qE '^ID="?steamos"?$' /etc/os-release 2> /dev/null; then
		echo steamos
	elif command -v pacman > /dev/null; then
		echo pacman
	else
		echo other
	fi
}
SYS=$(sys_kind)

sys_log() {
	echo "$(date '+%F %T') $*" >> "${LOG:-/dev/null}" 2> /dev/null
}

# The user of the display session: the one logged in on seat0, else the first ordinary user.
sys_user() {
	local u
	u=$(loginctl list-sessions --no-legend 2> /dev/null | awk '$4 == "seat0" || $5 == "seat0" { print $3; exit }')
	[ -n "$u" ] || u=$(getent passwd 1000 | cut -d: -f1)
	echo "${u:-deck}"
}

# SteamOS keeps /usr and /boot read-only between changes.
RO=""
sys_rw() {
	RO=""
	if [ "$SYS" = steamos ] && steamos-readonly status 2> /dev/null | grep -q enabled; then
		RO=1
		steamos-readonly disable >> "${LOG:-/dev/null}" 2>&1
	fi
}
sys_ro() {
	[ -z "$RO" ] || steamos-readonly enable >> "${LOG:-/dev/null}" 2>&1
	RO=""
}

# --- the kernel's build files and a compiler ------------------------------------------------------------

KVER=${KVER:-$(uname -r)}
KBUILD=/usr/lib/modules/$KVER/build
# The image a module is built in where the system has no compiler (ostree); kept between boots.
BUILD_IMAGE=localhost/bc250-sleep-build
# CachyOS builds its kernels with clang: modules for them are built the same way.
sys_clang() {
	if [ -f "$KBUILD/.config" ]; then
		grep -q '^CONFIG_CC_IS_CLANG=y' "$KBUILD/.config"
	else
		grep -q 'clang' /proc/version 2> /dev/null
	fi
}
sys_compilers() {
	if sys_clang; then echo "clang ld.lld make"; else echo "gcc make"; fi
}
# What the build lacks (printed), and whether it lacks anything.
sys_tools_missing() {
	local t missing=""
	if [ "$SYS" = ostree ] && ! command -v gcc > /dev/null; then
		podman image exists "$BUILD_IMAGE" 2> /dev/null || missing="build-container"
	else
		for t in $(sys_compilers) objdump; do
			command -v "$t" > /dev/null || missing="$missing $t"
		done
	fi
	[ -f "$KBUILD/Makefile" ] || missing="$missing build-files-of-$KVER"
	missing=${missing# }
	echo "$missing"
	[ -z "$missing" ]
}

# pacman: base-devel and <pkgbase>-headers at the version of the installed kernel package. The repository
# may carry a newer kernel than this system runs; the files of this one are then taken from the same
# repository's server by their file name (SteamOS's keeps the earlier versions).
sys_tools_pacman() {
	local pkgbase ver repo server i pkgs
	pkgbase=$(cat "/usr/lib/modules/$KVER/pkgbase" 2> /dev/null)
	[ -n "$pkgbase" ] || { echo "the package of kernel $KVER is not known (no pkgbase file)"; return 1; }
	ver=$(pacman -Q "$pkgbase" 2> /dev/null | cut -d' ' -f2)
	[ -n "$ver" ] || { echo "pacman does not know the kernel package $pkgbase"; return 1; }
	pkgs="base-devel"
	sys_clang && pkgs="$pkgs clang llvm lld"
	sys_log "installing $pkgs and $pkgbase-headers $ver"
	# A fresh SteamOS image has no keys for pacman to check packages with.
	if ! [ -s /etc/pacman.d/gnupg/pubring.gpg ] && ! [ -s /etc/pacman.d/gnupg/pubring.kbx ]; then
		{ pacman-key --init && pacman-key --populate; } >> "$LOG" 2>&1
	fi
	# Early in a boot the network may not be there yet.
	for i in 1 2 3 4 5 6 7 8 9 10; do
		pacman -Sy >> "$LOG" 2>&1 && break
		[ "$i" = 10 ] || sleep 15
	done
	# shellcheck disable=SC2086
	if pacman -S --needed --noconfirm $pkgs "$pkgbase-headers=$ver" >> "$LOG" 2>&1; then
		# The build files say how the kernel was built.
		! sys_clang || pacman -S --needed --noconfirm clang llvm lld >> "$LOG" 2>&1
		return
	fi
	repo=$(pacman -Si "$pkgbase-headers" 2> /dev/null | sed -n 's/^Repository *: *//p' | head -1)
	server=$(pacman-conf --repo="$repo" Server 2> /dev/null | head -1)
	[ -n "$server" ] || return 1
	# shellcheck disable=SC2086
	pacman -S --needed --noconfirm $pkgs >> "$LOG" 2>&1 &&
		pacman -U --needed --noconfirm "$server/$pkgbase-headers-$ver-x86_64.pkg.tar.zst" >> "$LOG" 2>&1
}

# ostree: the image carries the kernel's build files (Bazzite: kernel-devel); the compiler goes into a
# container image of the same Fedora release, built once and kept.
sys_tools_ostree() {
	local release i
	[ -f "$KBUILD/Makefile" ] || { echo "the system image has no build files for $KVER (kernel-devel)"; return 1; }
	command -v gcc > /dev/null && return 0
	command -v podman > /dev/null || { echo "no compiler and no podman to run one in"; return 1; }
	release=$(rpm -E %fedora 2> /dev/null)
	case "$release" in '' | *%*) echo "not a Fedora-based system: no image to build in"; return 1 ;; esac
	sys_log "building the container image $BUILD_IMAGE (Fedora $release, gcc)"
	for i in 1 2 3 4 5; do
		printf 'FROM registry.fedoraproject.org/fedora:%s\nRUN dnf -y install gcc make binutils elfutils-libelf-devel zstd xz && dnf clean all\n' "$release" |
			podman build -q -t "$BUILD_IMAGE" -f - >> "$LOG" 2>&1 && return 0
		[ "$i" = 5 ] || sleep 15
	done
	return 1
}

sys_tools() {
	sys_tools_missing > /dev/null && return 0
	case "$SYS" in
	steamos | pacman)
		local rc
		sys_rw
		sys_tools_pacman
		rc=$?
		sys_ro
		return $rc
		;;
	ostree) sys_tools_ostree ;;
	*)
		echo "install a compiler (gcc, or clang for a kernel built with it), make, objdump and the build files of $KVER"
		return 1
		;;
	esac
}

# Runs a build tool on the host, or in the build container where the host has no compiler (paths under
# /usr/lib/modules, /usr/src, /etc/bc250-sleep and /tmp are the same inside), for at most SYS_TIMEOUT
# seconds when that is set.
sys_exec() {
	if [ "$SYS" = ostree ] && ! command -v gcc > /dev/null; then
		timeout "${SYS_TIMEOUT:-0}" podman run --rm --network=none --security-opt label=disable -e TMPDIR \
			-v /usr/lib/modules:/usr/lib/modules:ro -v /usr/src:/usr/src:ro \
			-v /etc/bc250-sleep:/etc/bc250-sleep -v /tmp:/tmp \
			"$BUILD_IMAGE" "$@"
	else
		timeout "${SYS_TIMEOUT:-0}" "$@"
	fi
}

# make for a module of the running kernel, with the compiler the kernel was built with.
sys_make() {
	if sys_clang; then
		sys_exec make LLVM=1 "$@"
	else
		sys_exec make "$@"
	fi
}

# SELinux (Bazzite) lets systemd run programs and the kernel load modules only from files labelled so.
sys_label() {
	command -v selinuxenabled > /dev/null && selinuxenabled || return 0
	local f
	for f in "$@"; do
		case "$f" in
		*.ko) chcon -t modules_object_t "$f" 2> /dev/null ;;
		*) chcon -t bin_t "$f" 2> /dev/null ;;
		esac
	done
	return 0
}

# --- kernel arguments ------------------------------------------------------------------------------------

# How kernel arguments are set here: grub (a snippet per name; SteamOS reads /etc/default/grub.d, other
# systems /etc/default/grub), limine (CachyOS: a limine-entry-tool drop-in per name), ostree (rpm-ostree
# kargs), or none.
sys_karg_method() {
	if [ "$SYS" = ostree ]; then
		echo ostree
	elif [ "$SYS" = steamos ]; then
		echo grub
	elif command -v limine-entry-tool > /dev/null && command -v limine-update > /dev/null &&
		[ -s "/usr/lib/modules/$KVER/pkgbase" ]; then
		echo limine
	elif command -v grub-mkconfig > /dev/null && [ -f /boot/grub/grub.cfg ]; then
		echo grub
	else
		echo none
	fi
}

sys_grub_update() {
	if command -v update-grub > /dev/null; then
		update-grub > /dev/null 2>&1
	else
		grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1
	fi
}

# The kernel command line the next boot gets (as far as this system can say), one line per boot entry.
sys_next_cmdline() {
	local cfg
	case "$(sys_karg_method)" in
	ostree) rpm-ostree kargs 2> /dev/null ;;
	limine) limine-entry-tool --get-cmdline "$(cat "/usr/lib/modules/$KVER/pkgbase")" --no-hooks 2> /dev/null | tail -1 ;;
	grub)
		for cfg in /efi/EFI/steamos/grub.cfg /boot/efi/EFI/steamos/grub.cfg /boot/grub/grub.cfg; do
			[ -r "$cfg" ] || continue
			grep -E '^[[:space:]]*(steamenv_boot[[:space:]]+)?linux[[:space:]]' "$cfg"
			break
		done
		;;
	esac
}

# The file of one named group of arguments (grub and limine).
sys_karg_file() {
	case "$(sys_karg_method)" in
	limine) echo "/etc/limine-entry-tool.d/bc250-sleep-$1.conf" ;;
	grub) echo "/etc/default/grub.d/bc250-$1.cfg" ;;
	esac
}

sys_karg_configured() {
	local a next
	case "$(sys_karg_method)" in
	ostree)
		next=" $(rpm-ostree kargs 2> /dev/null) "
		for a in $2; do
			case "$next" in *" $a "*) ;; *) return 1 ;; esac
		done
		;;
	grub)
		if [ "$SYS" = steamos ]; then
			[ -f "$(sys_karg_file "$1")" ]
		else
			grep -q "# bc250-sleep $1\$" /etc/default/grub 2> /dev/null
		fi
		;;
	limine) [ -f "$(sys_karg_file "$1")" ] ;;
	*) return 1 ;;
	esac
}

# sys_karg add|remove NAME "ARGS": a group of kernel arguments for the next boot, or out of it.
sys_karg() {
	local op=$1 name=$2 args=$3 file a before after
	case "$(sys_karg_method)" in
	ostree)
		local opts=""
		for a in $args; do
			if [ "$op" = add ]; then opts="$opts --append-if-missing=$a"; else opts="$opts --delete-if-present=$a"; fi
		done
		# shellcheck disable=SC2086
		rpm-ostree kargs $opts >> "${LOG:-/dev/null}" 2>&1 || { echo "rpm-ostree kargs failed"; return 1; }
		;;
	grub)
		sys_rw
		if [ "$SYS" = steamos ]; then
			file=$(sys_karg_file "$name")
			if [ "$op" = add ]; then
				printf '# bc250-sleep (%s)\nGRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} %s"\n' "$name" "$args" > "$file"
			else
				rm -f "$file"
			fi
		else
			sed -i "/# bc250-sleep $name\$/d" /etc/default/grub
			[ "$op" = remove ] || printf 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} %s" # bc250-sleep %s\n' "$args" "$name" >> /etc/default/grub
		fi
		if ! sys_grub_update; then
			[ "$op" = remove ] || { rm -f "$(sys_karg_file "$name")"; sed -i "/# bc250-sleep $name\$/d" /etc/default/grub 2> /dev/null; }
			sys_grub_update
			sys_ro
			echo "the boot loader's configuration could not be written: nothing changed"
			return 1
		fi
		sys_ro
		;;
	limine)
		file=$(sys_karg_file "$name")
		if [ "$op" = remove ]; then
			rm -f "$file"
		else
			before=$(sys_next_cmdline)
			mkdir -p "$(dirname "$file")"
			printf '# bc250-sleep (%s)\nKERNEL_CMDLINE[default]+=" %s"\n' "$name" "$args" > "$file"
			# A drop-in's += can replace a command line that only /etc/kernel/cmdline holds: the next boot
			# must keep every argument it had and get these.
			after=" $(sys_next_cmdline) "
			for a in $before $args; do
				case "$a" in BOOT_IMAGE=* | initrd=*) continue ;; esac
				case "$after" in *" $a "*) ;; *)
					rm -f "$file"
					echo "limine-entry-tool would not keep $a: add \"$args\" to KERNEL_CMDLINE in /etc/default/limine by hand"
					return 1
					;;
				esac
			done
		fi
		limine-update >> "${LOG:-/dev/null}" 2>&1 || { [ "$op" = remove ] || rm -f "$file"; limine-update > /dev/null 2>&1; echo "limine-update failed: nothing changed"; return 1; }
		;;
	*)
		echo "this system's boot loader is not one bc250-sleep knows: add \"$args\" to the kernel command line by hand"
		return 1
		;;
	esac
}

# --- the S3 table in the initramfs ------------------------------------------------------------------------

# How the S3 table reaches the kernel: steamos (its own archive /boot/acpi_override.cpio, loaded by GRUB),
# mkinitcpio (its acpi_override hook), dracut (acpi_override; on ostree in an initramfs rpm-ostree builds
# here), or none.
sys_acpi_method() {
	if [ "$SYS" = steamos ]; then
		echo steamos
	elif command -v mkinitcpio > /dev/null && [ -e /usr/lib/initcpio/install/acpi_override ]; then
		echo mkinitcpio
	elif command -v dracut > /dev/null; then
		echo dracut
	else
		echo none
	fi
}
ACPI_MKINITCPIO=/etc/initcpio/acpi_override/bc250-sleep-SSDT-S3.aml
ACPI_MKINITCPIO_CONF=/etc/mkinitcpio.conf.d/bc250-sleep.conf
ACPI_DRACUT_DIR=/etc/bc250-sleep/acpi
ACPI_DRACUT_CONF=/etc/dracut.conf.d/bc250-sleep.conf

sys_initramfs_update() {
	case "$(sys_acpi_method)" in
	mkinitcpio)
		if [ "$(sys_karg_method)" = limine ]; then
			limine-update >> "${LOG:-/dev/null}" 2>&1
		else
			mkinitcpio -P >> "${LOG:-/dev/null}" 2>&1
		fi
		;;
	dracut)
		if [ "$SYS" = ostree ]; then
			# An initramfs built here, with this system's dracut configuration, from the next deployment on.
			# Where that is on already (the user's), every update builds one with the table in it.
			if rpm-ostree status --json 2> /dev/null | grep -q '"regenerate-initramfs" *: *true'; then
				[ -e /etc/bc250-sleep/initramfs-enabled ] || { echo "the initramfs is built here already: the table goes in with the next update"; return 0; }
				[ "${1:-}" = remove ] || return 0
				rpm-ostree initramfs --disable >> "${LOG:-/dev/null}" 2>&1 && rm -f /etc/bc250-sleep/initramfs-enabled
			elif [ "${1:-}" != remove ]; then
				rpm-ostree initramfs --enable >> "${LOG:-/dev/null}" 2>&1 && touch /etc/bc250-sleep/initramfs-enabled
			fi
		else
			dracut -f --regenerate-all >> "${LOG:-/dev/null}" 2>&1
		fi
		;;
	esac
}

# The table configured for the boot (in the archive, or with the initramfs generator).
sys_acpi_configured() {
	case "$(sys_acpi_method)" in
	steamos) [ -e "$ACPI_BOOT" ] && python3 /etc/bc250-sleep/acpi-archive.py has "$ACPI_BOOT" /etc/bc250-sleep/SSDT-S3.aml ;;
	mkinitcpio) [ -f "$ACPI_MKINITCPIO" ] && [ -f "$ACPI_MKINITCPIO_CONF" ] ;;
	dracut) [ -f "$ACPI_DRACUT_DIR/SSDT-S3.aml" ] && [ -f "$ACPI_DRACUT_CONF" ] ;;
	*) return 1 ;;
	esac
}

# SteamOS: the archive of ACPI tables GRUB hands to the kernel. Where the board has a master copy that a
# service keeps /boot equal to, that copy is changed as well.
ACPI_BOOT=/boot/acpi_override.cpio
ACPI_MASTER=/var/lib/bc250-acpi-fix/acpi_override.cpio
ACPI_GRUBCFG=/etc/default/grub.d/bc250-sleep-acpi.cfg
sys_acpi_steamos() {
	local work rc=0
	work=$(mktemp -d)
	[ -e "$ACPI_BOOT" ] && cp -f "$ACPI_BOOT" "$work/archive"
	if [ "$1" = add ]; then
		python3 /etc/bc250-sleep/acpi-archive.py add "$work/archive" /etc/bc250-sleep/SSDT-S3.aml >> "${LOG:-/dev/null}" 2>&1 || rc=1
		if [ "$rc" = 0 ] && [ ! -e "$ACPI_BOOT" ] && ! grep -qs 'acpi_override.cpio' /etc/default/grub /etc/default/grub.d/*.cfg; then
			echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="${GRUB_EARLY_INITRD_LINUX_CUSTOM:-} acpi_override.cpio"' > "$ACPI_GRUBCFG"
		fi
	else
		python3 /etc/bc250-sleep/acpi-archive.py remove "$work/archive" SSDT-S3.aml >> "${LOG:-/dev/null}" 2>&1 || rc=1
	fi
	if [ "$rc" = 0 ]; then
		[ -e "$ACPI_MASTER" ] && cp -f "$work/archive" "$ACPI_MASTER"
		sys_rw
		cp -f "$work/archive" "$ACPI_BOOT.new"
		mv -f "$ACPI_BOOT.new" "$ACPI_BOOT"
		sync
		[ -e "$ACPI_GRUBCFG" ] && sys_grub_update
		sys_ro
	else
		echo "the ACPI archive could not be written"
	fi
	rm -f "$work/archive"
	rmdir "$work"
	return $rc
}

# sys_acpi add|remove: the S3 table into the boot, or out of it; counts from the next boot.
sys_acpi() {
	case "$(sys_acpi_method)" in
	steamos) sys_acpi_steamos "$1" ;;
	mkinitcpio)
		if [ "$1" = add ]; then
			install -D -m 644 /etc/bc250-sleep/SSDT-S3.aml "$ACPI_MKINITCPIO"
			# The hook may be in the HOOKS of mkinitcpio.conf already.
			if grep -qs '^[^#]*HOOKS=.*acpi_override' /etc/mkinitcpio.conf; then
				echo "# bc250-sleep: acpi_override is in HOOKS of /etc/mkinitcpio.conf" > "$ACPI_MKINITCPIO_CONF"
			else
				printf '# bc250-sleep: the S3 table in the early initramfs\nHOOKS+=(acpi_override)\n' > "$ACPI_MKINITCPIO_CONF"
			fi
		else
			rm -f "$ACPI_MKINITCPIO" "$ACPI_MKINITCPIO_CONF"
		fi
		if ! sys_initramfs_update "$1"; then
			[ "$1" = remove ] || { rm -f "$ACPI_MKINITCPIO" "$ACPI_MKINITCPIO_CONF"; sys_initramfs_update remove; }
			echo "the initramfs could not be built (mkinitcpio): nothing changed"
			return 1
		fi
		;;
	dracut)
		if [ "$1" = add ]; then
			install -D -m 644 /etc/bc250-sleep/SSDT-S3.aml "$ACPI_DRACUT_DIR/SSDT-S3.aml"
			printf '# bc250-sleep: the S3 table in the early initramfs\nacpi_override="yes"\nacpi_table_dir="%s"\n' "$ACPI_DRACUT_DIR" > "$ACPI_DRACUT_CONF"
		else
			rm -f "$ACPI_DRACUT_CONF" "$ACPI_DRACUT_DIR/SSDT-S3.aml"
		fi
		if ! sys_initramfs_update "$1"; then
			[ "$1" = remove ] || rm -f "$ACPI_DRACUT_CONF" "$ACPI_DRACUT_DIR/SSDT-S3.aml"
			echo "the initramfs could not be built (dracut): nothing changed"
			return 1
		fi
		;;
	*)
		echo "no initramfs generator bc250-sleep knows: the S3 table (/etc/bc250-sleep/SSDT-S3.aml) has to reach the kernel by hand (an early initramfs with kernel/firmware/acpi/SSDT-S3.aml)"
		return 1
		;;
	esac
}
