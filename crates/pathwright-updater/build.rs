//! On Windows, the .exe says what it is: its icon, name, version and publisher, and a manifest
//! (it runs as the user who starts it, on Windows 10 and later). A program with none of these
//! is one more thing an antivirus counts against it.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    #[cfg(windows)]
    resources();
}

#[cfg(windows)]
const MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity type="win32" name="Pathwright.Updater" version="1.0.0.0"/>
  <description>Pathwright Updater</description>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0"
        processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
"#;

#[cfg(windows)]
fn resources() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let icon = "../../app/src-tauri/icons/icon.ico";
    println!("cargo:rerun-if-changed={icon}");
    let mut resource = tauri_winres::WindowsResource::new();
    resource
        .set_icon(icon)
        .set("ProductName", "Pathwright Updater")
        .set("FileDescription", "Pathwright Updater")
        .set("CompanyName", "Pathwright")
        .set("LegalCopyright", "MIT License")
        .set("InternalName", "pathwright-updater")
        .set("OriginalFilename", "pathwright-updater.exe")
        .set_manifest(MANIFEST);
    // Without the resource compiler the program still builds, only plainer.
    if let Err(error) = resource.compile() {
        println!("cargo:warning=no Windows resources: {error}");
    }
}
