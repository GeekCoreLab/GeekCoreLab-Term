#[derive(Debug, Clone)]
pub struct CoreInfo {
    pub product_name: String,
    pub version: String,
    pub stage: String,
    pub capabilities: Vec<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_core_info() -> CoreInfo {
    CoreInfo {
        product_name: "Geekcore Term".to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        stage: "初始化骨架".to_owned(),
        capabilities: vec![
            "Flutter to Rust typed bridge".to_owned(),
            "Windows and Linux desktop shell".to_owned(),
        ],
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
