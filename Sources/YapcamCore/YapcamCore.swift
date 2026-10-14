import CYapcamCore

/// Swift entry point to the Rust core. Owned by the Media/Timeline team.
public enum YapcamCore {
    public static var abiVersion: UInt32 { yc_abi_version() }
}
