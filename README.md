<p align="center">
<picture>
<source media="(prefers-color-scheme: dark)" srcset="autumn-logo/autumnbsd-lockup-dark.svg">
<img src="autumn-logo/autumnbsd-lockup.svg" alt="AutumnBSD" width="380">
</picture>
</p>

# AutumnBSD

A NetBSD-based desktop OS designed to make older PCs more pleasant to use.

When using a laptop that is over a decade old—without upgrades like an SSD or additional RAM—delays are typically caused by HDD seek times or swapping due to insufficient memory. AutumnBSD aims to reduce these wait times at the OS level.

## Current Feature: aprefetch

This feature records the files and FFS (Fast File System) metadata accessed during startup. On subsequent boots, it sorts these items based on their physical location on the disk and pre-fetches them in a single, efficient pass. It is designed to transform scattered, random disk accesses into a more streamlined, sequential sweep.

On the target hardware used for testing, the time required for the userland to load (from the `init` process to the login prompt) was reduced from 16.2 seconds to 7.3 seconds (median value over 5 runs). When accounting for the removal of the wait time for the `postfix` service to start, this figure drops to 5.4 seconds (based on a single measurement). Pre-fetching for individual applications is not yet implemented. 

- [HDD Acceleration Specification](AutumnBSD_SPEC_HDD.md): Design, phased implementation, and performance measurement results.
- [TLA+ Model](tla/aprefetch/README.md): Model checking for scenarios where prefetching occurs concurrently with standard read operations or unmount requests.
- Manual pages: [aprefetch(4)](share/man/man4/aprefetch.4), [aprefd(8)](usr.sbin/aprefd/aprefd.8), [aprefctl(8)](usr.sbin/aprefctl/aprefctl.8)

## Future Work

- Compressed Memory, azram (phase 1 implemented, not yet measured on the target hardware): Keeps pages compressed in RAM using LZ4 before they are swapped out—similar to `zram`, except that pages that do not compress, or that would need memory when it is short, still go to the HDD swap as before. This will also serve as a temporary buffer for data that cannot yet be written to disk. [Specification](AutumnBSD_SPEC_MEMORY.md); manual pages: [azram(4)](share/man/man4/azram.4), [azramctl(8)](usr.sbin/azramctl/azramctl.8)
- Display Manager, Akture (in development, not yet run on the target hardware): A custom-built, low-dependency login screen, developed in [Serusion/Akture](https://github.com/Serusion/Akture) and packaged for pkgsrc in [pkgsrc/x11/akture](pkgsrc/x11/akture). It will begin prefetching the user session while the password is being entered, once aprefetch has per-application profiles.
- Package Installation (under consideration): Consolidating post-installation tasks and `fsync` operations to reduce wait times on HDD-based systems.

## Design Philosophy

- Performance is never pursued at the expense of correctness or data integrity. We strictly honor `fsync` guarantees, and the prefetching mechanism is designed so that any failure simply results in the data not being prefetched—with no negative impact on system stability or data safety.
- Key design aspects are verified using formal methods; specifically, `aprefetch` has been validated through TLA+ model checking.
- We maintain minimal dependencies while ensuring a polished, desktop-ready appearance.

## Target Hardware

The design and performance measurements are based on this specific hardware. - Model: NEC LaVie S LS150/F (laptop from around 2011)
- CPU: Intel Pentium B950 (2.1GHz, 2 cores, 2 threads, no AES-NI)
- Memory: 4GB
- Storage: 512GB HDD
- GPU: Intel HD Graphics (Sandy Bridge generation, i915)

## Building

Installation images are not yet available for distribution.

The build system is identical to NetBSD’s `build.sh`, allowing for cross-compilation from any UNIX-like OS. To create a release and installation image for the `amd64` architecture, run the following commands from the root of the repository:

```sh
./build.sh -U -u -j4 -m amd64 -O ~/obj release
./build.sh -U -u -j4 -m amd64 -O ~/obj install-image
```

For details on the available options, please refer to [BUILDING](BUILDING).

## Related Projects

- [NetBSD](https://www.NetBSD.org/): The foundation for AutumnBSD.
- KyanBSD: A sister project based on FreeBSD. It focuses on robustness for data center environments, incorporating features such as a hypervisor and formal verification using Frama-C. While the two projects have different objectives, they will share certain components, such as the display manager.

## License

Code added by AutumnBSD (e.g., `aprefetch`, `azram`) is licensed under the BSD-2-Clause license. All other code is subject to the NetBSD license. For third-party components (such as those found in `external/`), please consult the individual source files and [doc/3RDPARTY](doc/3RDPARTY).

## Contact

Please submit bug reports or suggestions via [Issues](https://github.com/Serusion/AutumnBSD/issues) or by opening a Pull Request.
