{
  "targets": [
    {
      "target_name": "calayers",
      "sources": ["src/addon.mm", "src/backend.mm"],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include\")"
      ],
      "defines": ["NAPI_DISABLE_CPP_EXCEPTIONS"],
      "xcode_settings": {
        "OTHER_CPLUSPLUSFLAGS": ["-fobjc-arc", "-std=c++17"],
        "MACOSX_DEPLOYMENT_TARGET": "11.0",
        "CLANG_ENABLE_OBJC_ARC": "YES"
      },
      "link_settings": {
        "libraries": [
          "-framework Cocoa",
          "-framework QuartzCore",
          "-framework CoreText",
          "-framework CoreGraphics",
          "-framework ImageIO",
          "-framework IOSurface",
          "-framework UniformTypeIdentifiers"
        ]
      }
    }
  ]
}
