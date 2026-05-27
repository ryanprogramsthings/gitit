use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let bridges = vec!["src/lib.rs"];
    for bridge in &bridges {
        println!("cargo:rerun-if-changed={bridge}");
    }
    swift_bridge_build::parse_bridges(bridges)
        .write_all_concatenated(&out_dir, "GititCore");

    // Stash the OUT_DIR path so build-rust.sh can find it.
    let marker = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
        .join("target")
        .join("swift-bridge-out-dir.txt");
    if let Some(parent) = marker.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(&marker, out_dir.to_string_lossy().as_bytes());
}
